# ClickUp API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-13

## Auth

- **Method:** Personal API token (n8n + direct REST), MCP (OAuth2 on demand)
- **Vault:** `<credential-vault>`
- **Secret name:** `CLICKUP-API-KEY` (personal API token — use this for everything). Note: `CLICKUP-API-TOKEN` (`pk_...`) is STALE — returns `OAUTH_025`, do not use. `CLICKUP-ACCESS-TOKEN` is a legacy OAuth token format.
- **Env var:** `$CLICKUP_API_KEY`, `$CLICKUP_TEAM_ID`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh clickup)"` — for direct REST use: `AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv`
- **MCP server:** `clickup` — full CRUD via native tools
- **n8n credential:** API token, credential ID `<credential-id>` ("Clickup API - <your-name>"), type `clickUpApi`. Legacy OAuth2 credential `<credential-id>` still exists but is short-lived and unreliable — do not use for scheduled workflows.
- **Direct API:** `https://api.clickup.com/api/v2/` with `Authorization: <token>` header

## Common Operations

### Via API / CLI

```bash
# Get a task
curl -s "https://api.clickup.com/api/v2/task/TASK_ID" \
  -H "Authorization: $CLICKUP_TOKEN"

# Create a task
curl -s -X POST "https://api.clickup.com/api/v2/list/<clickup-list-id>/task" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Task name", "status": "new"}'

# Update task status
curl -s -X PUT "https://api.clickup.com/api/v2/task/TASK_ID" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "planning"}'

# Get tasks in a list
curl -s "https://api.clickup.com/api/v2/list/<clickup-list-id>/task" \
  -H "Authorization: $CLICKUP_TOKEN"
```

### Via MCP

| Operation | MCP Tool |
|-----------|----------|
| Create task | `mcp__clickup__clickup_create_task` — requires `name` and `list_id` |
| Get task | `mcp__clickup__clickup_get_task` — by task ID |
| Update task | `mcp__clickup__clickup_update_task` — status, assignees, tags, priority, etc. |
| Filter tasks | `mcp__clickup__clickup_filter_tasks` — search within a list by status, assignee, tags |
| Add tag | `mcp__clickup__clickup_add_tag_to_task` |
| Remove tag | `mcp__clickup__clickup_remove_tag_from_task` |
| Search | `mcp__clickup__clickup_search` — global keyword search across workspace |

## <your-org>-Specific IDs

| Resource | ID |
|----------|-----|
| **Workspace** | `24555569` |
| **Space:** Office of the CEO | `48531289` |
| **List:** Automations & Engineering | `<clickup-list-id>` |
| **List:** Meeting Inbox | `<clickup-list-id>` |
| **List:** Office of the CEO | `374710674` |
| **List:** Chief of Staff | `900600138445` |

### Assignees

| Person | User ID |
|--------|---------|
| <your-name> | `42469271` |
| Cez Gonzales | `42473716` |

### A&E List Statuses (custom override)
`backlog` → `new` → `planning` → `implementation` → `queued` → `in progress` → `qa` → `completed` (+ `blocked` side-channel)

### Space Statuses (other lists)
`new` → `scheduled` → `in progress` → `requires revisions` → `waiting client response` → `waiting vendor` → `on hold` → `cancelled` → `completed`

### Custom Fields (A&E List)

| Field | ID | Type |
|-------|----|------|
| Task Owner | `11c07c2c-6970-441e-bb50-bf662ad674c3` | text |
| Requestor UPN | `98a794b1-6317-406b-9fcc-3fe839fab9fb` | short_text |
| Time Saved (hrs) | `d236345e-7e82-4243-972d-bb66cddb10f5` | number |
| Plan File | `24322bf6-5a22-4d48-946a-db1a32f06c89` | url |
| Plan Reviewed | `f4c81a99-a26a-4cca-a523-a65526e534a7` | checkbox |
| Codex Reviewed | `2529bf45-0b02-47a3-a1dd-985fee4e6c54` | checkbox |

### Setting Custom Fields via API

Custom fields require individual POST calls (not bulk via task update):

```bash
# Set a URL field (Plan File)
curl -s -X POST "https://api.clickup.com/api/v2/task/TASK_ID/field/FIELD_ID" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": "https://example.com"}'

# Set a checkbox field (Plan Reviewed, Codex Reviewed)
curl -s -X POST "https://api.clickup.com/api/v2/task/TASK_ID/field/FIELD_ID" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": true}'
```

Empty `{}` response = success. Custom fields cannot be set via the task update endpoint (`PUT /task`).

### Priority Values
`urgent` | `high` | `normal` | `low`

### Tags

**Type** (required, pick one): `bug`, `enhancement`, `audit`, `documentation`, `review`

**App** (required, one+): `salesforce`, `<internal-bot>`, `n8n`, `occ`, `<knowledge-base>`, `clickup`, `teams`, `calendly`, `apollo`

**Audience** (optional): `sales`, `support`, `client-success`, `managers`, `marketing`, `revenue-ops`, `hr`, `external`

**Cross-cutting** (optional): `bots`

**System** (managed automatically, do not add/remove manually): `waiting` (task is blocked by a dependency — maintained by `/stan-fix`)

### Creating New Tags

The MCP `add_tag_to_task` tool requires the tag to already exist in the space. To create a new tag:

```bash
AZURE_CONFIG_DIR=~/.azure-admin TOKEN=$(az keyvault secret show --vault-name <credential-vault> --name CLICKUP-ACCESS-TOKEN --query value -o tsv)
curl -s -X POST "https://api.clickup.com/api/v2/space/48531289/tag" \
  -H "Authorization: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tag":{"name":"TAG_NAME","tag_fg":"#FFFFFF","tag_bg":"#7C3AED"}}'
```

## n8n Workflows (ClickUp integrations)

| Workflow | ID | Purpose |
|----------|----|---------|
| <internal-bot>: Automation Request Intake | `TiOTn452CSO2X4EU` | Creates tasks in A&E list |
| <internal-bot>: Task Close Notifier | `fT7AYkSCWMGALhKH` | Teams DM on completion |
| <internal-bot>: Request Status Check | `7wUVFqAi935BVURl` | Queries A&E list |
| Fireflies Meeting Triage | `FXWCMmKyJoyoNaMt` | Daily AI triage of Meeting Inbox |

## A&E Dashboard & Views

**Dashboard:** A&E Ops Console — `https://app.clickup.com/24555569/dashboards/qdc1h-7111`

| View | ID | Type | Config |
|------|----|------|--------|
| Backlog Board | `qdc1h-118251` | board | Group by status |
| By Domain | `qdc1h-118271` | board | Group by tag |
| Bugs & Issues | `qdc1h-118311` | list | Filter: tag = bug |
| Docs & Audits | `qdc1h-118331` | list | Filter: tag = documentation OR audit |
| Recently Completed | `qdc1h-118291` | list | Show closed tasks |

## Gotchas

- **All tasks go in ClickUp**, never GitHub Issues. A&E list `<clickup-list-id>` is the single source of truth.
- **ClickUp node parameter names vary by resource.** `task` resource uses `id` for Task ID. `taskTag` resource uses `taskId`. Always check a working node's JSON before building programmatically.
- **After programmatic node updates:** Verify params stuck by fetching workflow JSON AND confirming in the n8n UI.
- **Fireflies integration** targets Meeting Inbox by list ID. Renaming the list is safe.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `OAUTH_025` error on API calls | Using stale `CLICKUP-API-TOKEN` (`pk_...`). Switch to `CLICKUP-ACCESS-TOKEN` (OAuth format) |
| MCP `add_tag_to_task` fails | Tag must already exist in the space. Create via REST API (see "Creating New Tags" above) |
| Filter returns 0 tasks but they exist | Check list ID and status filter. A&E list uses custom statuses (`new`, `planning`, etc.), not space defaults |
| MCP auth error on clickup tools | `CLICKUP-API-KEY` or `CLICKUP-TEAM-ID` missing. Re-fetch via `fetch-secrets.sh clickup` |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
