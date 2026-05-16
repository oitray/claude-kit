# ClickUp API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-16

## Auth

- **Method:** Personal API token (n8n + direct REST), MCP (OAuth2 on demand)
- **Vault:** `<credential-vault>`
- **Secret name:** `CLICKUP-API-KEY` (personal API token — use this for everything). Note: `CLICKUP-API-TOKEN` (`pk_...`) is STALE — returns `OAUTH_025`, do not use.
- **Env var:** `$CLICKUP_API_KEY`, `$CLICKUP_TEAM_ID`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh clickup)"` — for direct REST use: `AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv`
- **n8n credential:** API token, credential ID `<credential-id>` ("Clickup API - <your-name>"), type `clickUpApi`. Legacy OAuth2 credential `<credential-id>` still exists but is short-lived and unreliable — do not use for scheduled workflows.
- **Direct API:** `https://api.clickup.com/api/v2/` with `Authorization: <token>` header

## Common Operations

### Via API / CLI

```bash
# Resolve list IDs (canonical source: <credential-vault>)
AE_LIST=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name CLICKUP-AE-LIST-ID --query value -o tsv)
INFRA_LIST=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name CLICKUP-INFRA-LIST-ID --query value -o tsv)

# Get a task
curl -s "https://api.clickup.com/api/v2/task/TASK_ID" \
  -H "Authorization: $CLICKUP_TOKEN"

# Create a task (pick target list per audience rule)
curl -s -X POST "https://api.clickup.com/api/v2/list/$AE_LIST/task" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Task name", "status": "backlog"}'

# Update task status
curl -s -X PUT "https://api.clickup.com/api/v2/task/TASK_ID" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "planning"}'

# Get tasks in a list (iterate both for dual-list views)
for LID in "$AE_LIST" "$INFRA_LIST"; do
  curl -s "https://api.clickup.com/api/v2/list/$LID/task" \
    -H "Authorization: $CLICKUP_TOKEN"
done
```

## Dependencies schema (empirical, 2026-05-16)

`GET /api/v2/task/{id}` returns a `dependencies` array. ClickUp stores each dep edge as TWO entries — one on the dependent's task, one on the blocker's task — both bearing the SAME `chain_id`.

**Probe (live)** — task `<clickup-task-id>` (B) `depends_on` `<clickup-task-id>` (A):

```json
// GET /task/<clickup-task-id> (the dependent)
"dependencies": [
  {"task_id": "<clickup-task-id>", "depends_on": "<clickup-task-id>", "type": 1, "chain_id": "93ec..."},  // B blocked by A
  {"task_id": "<clickup-task-id>", "depends_on": "<clickup-task-id>", "type": 1, "chain_id": "3d82..."}   // C blocked by B (inverse edge stored on B too)
]
// GET /task/<clickup-task-id> (the blocker)
"dependencies": [
  {"task_id": "<clickup-task-id>", "depends_on": "<clickup-task-id>", "type": 1, "chain_id": "93ec..."}   // same edge, stored on A as well
]
```

**Parsing rule** — to extract a task's blockers (the things IT waits on), filter to `entry.task_id == self.id and entry.depends_on != None`. This rejects:
- The inverse edge (B's record contains the C→B edge where `task_id=C`)
- The mirror copy on the blocker (A's record contains the B→A edge where `task_id=B`)
- Any malformed entry with missing `depends_on`

`type=1` consistently means "blocked by" in the empirical data; `type=2` is undocumented in any payload observed so far. Filter by `task_id` rather than `type` to be schema-defensive.

**Setting a dependency:**

```bash
curl -X POST "https://api.clickup.com/api/v2/task/<dependent-id>/dependency" \
  -H "Authorization: $CLICKUP_API_KEY" -H "Content-Type: application/json" \
  -d '{"depends_on": "<blocker-id>"}'
```

The mirror edge on the blocker is auto-populated server-side; no second call needed.

**Used by:** `scripts/orchestrator/lib/clickup_poller.py:_to_candidate` (CandidateTask.blocked_by_ids) — feeds `check_dependencies_clear()` for the local-poller's dep-aware skip. See `docs/runbooks/local-poller.md` "Dependency-aware skip".

## <your-org>-Specific IDs

| Resource | ID |
|----------|-----|
| **Workspace** | `24555569` |
| **Space:** Office of the CEO | `48531289` |
| **List:** Automations & Engineering (A&E) — SF / VoIP business automations | `<clickup-list-id>` (KV: `CLICKUP-AE-LIST-ID`) |
| **List:** Automation Infrastructure — <internal-bot>/<internal-bot>/orchestrator/MCP/skills/runbooks/CI | `<clickup-list-id>` (KV: `CLICKUP-INFRA-LIST-ID`) |
| **List:** Meeting Inbox | `<clickup-list-id>` |
| **List:** Office of the CEO | `374710674` |
| **List:** Chief of Staff | `900600138445` |

### Assignees

| Person | User ID |
|--------|---------|
| <your-name> | `42469271` |
| Cez Gonzales | `42473716` |

### A&E + Infra List Statuses (shared custom override)

`backlog` → `planning` → `implementation` → `queued` → `in progress` → `qa` → `completed` (+ `blocked` side-channel)

Both lists share the identical workflow so orchestrator dispatch logic is list-agnostic.

### Space Statuses (other lists)
`new` → `scheduled` → `in progress` → `requires revisions` → `waiting client response` → `waiting vendor` → `on hold` → `cancelled` → `completed`

### Custom Fields (shared by A&E + Infra)

ClickUp custom fields are workspace-scoped — same UUID, attached to both lists. Orchestrator code that reads fields by ID works on tasks from either list unchanged.

| Field | ID | Type |
|-------|----|------|
| Task Owner | `<azure-uuid>` | text |
| Requestor UPN | `<azure-uuid>` | short_text |
| Time Saved (hrs) | `<azure-uuid>` | number |
| Plan File | `<azure-uuid>` | url |
| Plan Reviewed | `<azure-uuid>` | checkbox |
| Codex Reviewed | `<azure-uuid>` | checkbox |
| Claude Reviewed | `<azure-uuid>` | checkbox |
| Human Approved | `<azure-uuid>` | checkbox |
| Plan Updated Post-Codex | `<azure-uuid>` | checkbox |
| Scope Validated | `<azure-uuid>` | checkbox |
| Override Gates | `<azure-uuid>` | checkbox |
| Dispatch Lock | `<azure-uuid>` | short_text |
| Preset | `<azure-uuid>` | drop_down |
| Executor | `<azure-uuid>` | drop_down |
| Window | `<azure-uuid>` | drop_down |

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

> Tags are assigned at scoping time, not at task creation. Tasks without a scope block should have no type/app tags.

**Type** (required, pick exactly one): `bug`, `enhancement`, `chore`, `audit`, `documentation`, `review`

Legacy `feat` tag is deprecated — maps to `enhancement`. `scripts/audit-backlog.py` migrates stragglers.

**Type** (required after scoping, pick one): `bug`, `enhancement`, `chore`, `audit`, `documentation`, `review`

**App** (required after scoping, one+): `salesforce`, `<internal-bot>`, `n8n`, `occ`, `<knowledge-base>`, `clickup`, `teams`, `calendly`, `apollo`

**Executor** (optional): `interactive` (held for human dev — blocks auto-dispatch)

**Environment** (optional): `local` (historical tag; no longer gates dispatch — all dispatch is local-poller on Mac Studio since <clickup-task-id>)

**Complexity** (optional, Anthropic presets only): `lite` (haiku), `complex` (opus)

**Team** (optional, reporting only): `engineering`, `support-ops`, `sales-ops`, `revenue-ops`

**Audience** (optional): `sales`, `support`, `client-success`, `managers`, `marketing`, `revenue-ops`, `hr`, `external`

**Cross-cutting** (optional): `bots`

**System** (managed automatically, do not add/remove manually):
- `waiting` — task is blocked by a dependency; maintained by `/stan-fix`
- `scope-needed` — missing valid scope block; dispatch blocked until scope Q&A completes
- `classify-needed` — task scoped but missing type/app/executor tags; dispatch blocked until classification complete
- `cloud` — (deprecated/historical) was auto-added by the cloud orchestrator post-dispatch; Wave 1.5c bulk-stripped this tag from open tasks; cloud orchestrator retired in <clickup-task-id>; tag no longer added
- `rate-limited`, `rate-limited-abandoned`, `urgent`, `budget-paused`, `plan` — pipeline state

### Preset Custom Field

**Field ID:** `<azure-uuid>`

Values currently live in the dropdown: `dev`, `planner`, `triage`, `docs-update`, `support`, `quick`, `code-review`.

Pending additions (orchestrator code already references these — UI add still required): `local-summarize`, `local-classify`, `local-review`, `local-patch`.

Resolution order: Preset field → tag_mapping → default `dev`

Set explicitly when a task has multiple mapped app tags.

**Note on the four pending `local-*` options.** The ClickUp v2 API does not expose an endpoint for adding options to an existing dropdown field. Verified empirically (2026-05-03 — `POST /api/v2/list/{list_id}/field/{field_id}/option`, `PATCH /api/v2/list/{list_id}/field/{field_id}`, `PATCH /api/v2/workspace/{workspace_id}/field/{field_id}` all return 404) and cross-referenced against `developer.clickup.com/reference/setcustomfieldvalue` + `getaccessiblecustomfields` (no mutation endpoint documented for dropdown options). Workarounds: (a) add via ClickUp UI on each list; (b) automate the UI add with Browser Use Cloud per `.claude/rules/browser-automation.md`; (c) recreate the field with the full option list in a single `POST /api/v2/list/{list_id}/field` (destructive — would orphan existing field-value references on prior tasks).

### Executor Custom Field

**Field ID:** `<azure-uuid>`

Values: `local-claude`, `local-codex`, `local-mlx`

Set on tasks to declare which Mac Studio executor the `co.oit.local-poller` daemon should hand off to. The `cloud` option and Maestro `sub-local` subscription were retired in <clickup-task-id> (Wave 4.6). All dispatch is now local-poller — there is no cloud path to bypass. Full daemon reference: `docs/runbooks/local-poller.md`.

### Window Custom Field

**Field ID:** `<azure-uuid>`

Values: `now`, `extended` (default), `off-peak-only`

Meaningful only when `Executor=local-claude`. Ignored for other executors. Controls Anthropic Max plan off-peak scheduling.

### Creating Custom Fields via API

```bash
# Create a dropdown field on a list
CLICKUP_TOKEN=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv)
curl -s -X POST "https://api.clickup.com/api/v2/list/${LIST_ID}/field" \
  -H "Authorization: ${CLICKUP_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "FieldName",
    "type": "drop_down",
    "type_config": {
      "options": [
        {"name": "option1", "orderindex": 0},
        {"name": "option2", "orderindex": 1}
      ]
    }
  }'
```

Fields are workspace-scoped — same UUID returned regardless of which list you POST to. Creating on A&E automatically attaches to Infra too (and vice versa). **You cannot add options to an existing dropdown via API** — create the full option list at field-creation time, or use the ClickUp UI to add options later.

### Creating New Tags

Tags must already exist in the space before they can be assigned to tasks. To create a new tag:

```bash
AZURE_CONFIG_DIR=~/.azure-admin TOKEN=$(az keyvault secret show --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv)
curl -s -X POST "https://api.clickup.com/api/v2/space/48531289/tag" \
  -H "Authorization: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tag":{"name":"TAG_NAME","tag_fg":"#FFFFFF","tag_bg":"#7C3AED"}}'
```

### Removing Tags From Tasks

**empirical** (used in `scripts/audit-backlog.py:290`, `scripts/backfill-workflow-triage.py:462`, `scripts/orchestrator/strip-cloud-tags.sh:32`):

```bash
AZURE_CONFIG_DIR=~/.azure-admin TOKEN=$(az keyvault secret show --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv)
curl -s -X DELETE "https://api.clickup.com/api/v2/task/<task-id>/tag/<tag-name>" \
  -H "Authorization: $TOKEN"
```

| HTTP | Meaning |
|---|---|
| 200 | Returned unconditionally on every well-formed DELETE — whether the tag exists in the space, is on the task, or neither. Treat as success. |
| 401 | Token expired or wrong vault |
| 5xx | ClickUp transient; retry once |

**empirical** (2026-05-16): DELETE returns 200 even for tag names that have never existed in this space — the endpoint never returns 404 for missing tags. Probed against `<clickup-task-id>` with both an already-removed tag and a fictional name `nonexistent-tag-12345xyz`; both 200. Defensive code may still branch on 404 for forward-compatibility, but the branch is dead in practice.

Tag names with spaces must be URL-encoded (e.g. `failed%20run`).

The `scope-needed` tag is the canonical use case: set by `/start-task` for free-text intents, stripped by `scripts/clickup/strip-scope-needed-tag.sh` once a plan is finalized (<clickup-task-id>).

## n8n Workflows (ClickUp integrations)

| Workflow | ID | Purpose |
|----------|----|---------|
| <internal-bot>: Automation Request Intake | `TiOTn452CSO2X4EU` | Creates tasks in A&E list (public intake stays A&E per audience rule) |
| <internal-bot>: Task Close Notifier | `fT7AYkSCWMGALhKH` | Teams DM on completion |
| <internal-bot>: Request Status Check | `7wUVFqAi935BVURl` | Queries A&E list |
| Fireflies Meeting Triage | `FXWCMmKyJoyoNaMt` | Daily AI triage of Meeting Inbox |
| OCC: Auto-Triage on Task Creation | `OgLFf54BpJGGxJnq` | Workspace-wide trigger; classifier runs on both A&E and Infra task-creates (filter accepts either list ID) |

## A&E Dashboard & Views

**Dashboard:** A&E Ops Console — `https://app.clickup.com/24555569/dashboards/qdc1h-7111` (dashboards are UI-only — no v2 API for create/configure).

| View | ID | Type | Config |
|------|----|------|--------|
| Backlog Board | `qdc1h-118251` | board | Group by status |
| By Domain | `qdc1h-118271` | board | Group by tag |
| Bugs & Issues | `qdc1h-118311` | list | Filter: tag = bug |
| Docs & Audits | `qdc1h-118331` | list | Filter: tag = documentation OR audit |
| Recently Completed | `qdc1h-118291` | list | Show closed tasks |
| SF + Inbound Requests | `qdc1h-118771` | list | Filter: tag ANY [`salesforce`, `intake`] |

### Views API

**empirical** (2026-05-13): views ARE programmable via v2 — `GET/POST/PUT/DELETE /api/v2/list/{list_id}/view` and `/api/v2/view/{view_id}/task`. Earlier "UI-only" assumption was wrong; verified by creating `qdc1h-118771` from a single `curl POST`.

```bash
# List views on a list
curl -sS "https://api.clickup.com/api/v2/list/<clickup-list-id>/view" \
  -H "Authorization: $CLICKUP_API_KEY"

# Get tasks rendered by a view (honors its filters + sort)
curl -sS "https://api.clickup.com/api/v2/view/qdc1h-118771/task?page=0" \
  -H "Authorization: $CLICKUP_API_KEY"

# Create a list view — tag-filter, group-by-status, priority/dateCreated sort
curl -sS -X POST "https://api.clickup.com/api/v2/list/<clickup-list-id>/view" \
  -H "Authorization: $CLICKUP_API_KEY" -H "Content-Type: application/json" \
  -d '{
    "name": "SF + Inbound Requests",
    "type": "list",
    "parent": { "id": "<clickup-list-id>", "type": 6 },
    "grouping": { "field": "status", "dir": 1, "collapsed": [], "ignore": false, "single": false },
    "divide": { "field": null, "dir": null, "collapsed": [] },
    "sorting": { "fields": [
      { "field": "priority",    "dir": -1, "idx": 0 },
      { "field": "dateCreated", "dir": -1, "idx": 1 }
    ]},
    "filters": {
      "op": "AND",
      "fields": [
        { "field": "tag", "op": "ANY", "determinor": null, "idx": 0, "values": ["salesforce","intake"] }
      ],
      "search": null, "search_custom_fields": false, "search_description": false,
      "search_name": true, "show_closed": false
    },
    "columns": { "fields": [] },
    "team_sidebar": { "assignees": [], "group_assignees": [], "assigned_comments": false, "unassigned_tasks": false },
    "settings": { "show_subtasks": 1, "show_assignees": true, "show_empty_fields": false }
  }'

# Delete a view
curl -sS -X DELETE "https://api.clickup.com/api/v2/view/{view_id}" \
  -H "Authorization: $CLICKUP_API_KEY"
```

**Filter operators** (empirical from existing views, 2026-05-13): tag filter uses `{ field: "tag", op: "ANY", values: [...] }` — multiple values within a single field = OR. Top-level `filters.op` combines fields (`AND` / `OR`). Other operators (`EQ`, `IS_SET`, `NOT_ANY`, etc.) are likely supported but not yet probed.

**Gotchas:**

- **Sort field names are camelCase, not snake_case.** Passing `date_created` returns `VIEWS_016` validation error. Allowed values (per the error response, empirical 2026-05-13): `subcategory`, `assignee`, `priority`, `dueDate`, `commentCount`, `incompleteCommentCount`, `startDate`, `anyDate`, `timeLogged`, `timeLoggedRollup`, `timeEstimate`, `timeEstimateRollup`, `pointsEstimate`, `pointsEstimateRollup`, `dateCreated`, `dateUpdated`, `dateDone`, `duration`, `name`, `status`, `dateClosed`, `dateDelegated`, `createdBy`, `timeInStatus`, `linked`, `dependencies`, `pages`, `id`, `customItems`, `shadowTaskColor`, `shadowTaskLocation`. Sort `dir`: `-1` = desc, `1` = asc.
- **Pinning to left nav + Sharing visibility are NOT exposed via API.** Both require the UI's view ⋯ menu. Newly-created views default to `visibility: "public"` (org-wide) and unpinned. **pending** — no API endpoint probed yet for either; workaround is to edit in the UI after create.
- **Parent type for lists is `6`.** `{ parent: { id: <list-id>, type: 6 } }` (empirical 2026-05-13). Other parent types (folder / space / team) not yet probed from this codebase.
- **Deep-link format:** `https://app.clickup.com/{workspace_id}/v/li/{list_id}?pr={view_id}` — opens the list with the named view active.

## Gotchas

- **All tasks go in ClickUp**, never GitHub Issues. The single source of truth is split across two lists:
  - `CLICKUP-AE-LIST-ID` (`<clickup-list-id>`) — Salesforce / VoIP business automations
  - `CLICKUP-INFRA-LIST-ID` (`<clickup-list-id>`) — platform / dev-loop machinery (<internal-bot>, <internal-bot>, orchestrator, MCP, skills, runbooks, KV, CI, publish-kit)
  - Read both IDs from `<credential-vault>` rather than hardcoding.
- **No public Move Task endpoint.** ClickUp v2 and v3 do not expose a programmatic way to move tasks between lists. Probed 10 endpoint variants on 2026-04-25 — all 404 or silently no-op. UI-only via `app.clickup.com/v1/...` internal API (browser session). Plan migrations accordingly: existing tasks stay where they are; only new tasks split per the audience rule.
- **No public endpoint to add options to existing dropdown fields.** Probed 2026-05-03: `POST /api/v2/list/{list_id}/field/{field_id}/option`, `PATCH /api/v2/list/{list_id}/field/{field_id}`, `PUT /api/v2/field/{field_id}`, `PATCH /api/v2/workspace/{workspace_id}/field/{field_id}` all return 404. Use the ClickUp UI to add options to existing dropdowns, OR create the field with all options in the initial `POST /api/v2/list/{list_id}/field` call.
- **Custom fields are workspace-scoped.** Same UUID across both lists; setting a value via `POST /task/{id}/field/{fieldId}` works regardless of which list the task lives on, *but* only if the field has been "shown on list" via the UI. Writes to non-attached fields silently no-op (200 OK with empty body, value dropped). The ClickUp API has no public endpoint to attach a field to a list — must be done via UI.
- **ClickUp node parameter names vary by resource.** `task` resource uses `id` for Task ID. `taskTag` resource uses `taskId`. Always check a working node's JSON before building programmatically.
- **After programmatic node updates:** Verify params stuck by fetching workflow JSON AND confirming in the n8n UI.
- **Fireflies integration** targets Meeting Inbox by list ID. Renaming the list is safe.
- **No native idempotency-key header.** `POST /list/{id}/task` does not accept an `Idempotency-Key` header — `developer.clickup.com/reference/createtask` lists no such option (docs-confirmed 2026-05-04). Identical sequential POSTs create separate tasks every time. Client-side dedup is required for at-least-once webhook scenarios. Canonical pattern: `docs/runbooks/<internal-bot>-request-intake.md` § Dedup behavior (n8n `staticData` + reservation pattern, ClickUp `<clickup-task-id>`).
- **Dropdown field reads return an int orderindex, not the option name.** When `GET /task/{id}` returns a `drop_down` custom field, `value` is the integer `orderindex` of the selected option (e.g. `Executor=local-claude` → `{"value": 1}`). Code that checks `if isinstance(val, str)` silently treats every dropdown selection as unset and falls through to defaults. Resolve via `field.type_config.options[].orderindex → name`. Verified empirically 2026-05-04 — three separate bugs surfaced from this pattern: `_should_route_local` (PR #357), `_task_priority_sort_key` (PR #359), and `local_claude.py:_get_custom_field_value`. Mirror the orderindex-resolution shape any time you read a dropdown field by code.
- **List-tasks excludes subtasks by default.** `GET /list/{id}/task` returns 0 subtasks unless `subtasks=true` is included in the query string — even when the subtask matches the `statuses[]` filter. **Empirical** (2026-05-12, this session): `curl ".../task?statuses[]=queued"` returned 0 while `GET /task/<subtask-id>` confirmed `status=queued`; adding `&subtasks=true` returned the task immediately. Caused a 2-day silent rot of the orchestrator's `local-poller` (memory: `reference_clickup_list_tasks_subtasks_filter.md`; umbrella discovery card: <clickup-task-id>; fix shipped via <clickup-task-id>). Always pass `subtasks=true` when polling for status across both parent and subtask cards.

## Webhooks (taskUpdated, taskCreated, taskCommentPosted, etc.)

ClickUp v2 webhooks are scoped to a team and optionally filtered by list/folder/space.

### Register

```bash
curl -X POST "https://api.clickup.com/api/v2/team/{team_id}/webhook" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "endpoint": "https://your-public-receiver.example.com/webhook",
    "events": ["taskUpdated"],
    "list_id": <clickup-list-id>
  }'
```

Response includes `id`, `webhook`, and **`secret`** (used to sign every delivered event via the `X-Signature` header). The secret is generated by ClickUp; clients cannot pre-set it. **Reconcile against your local secret store after registration.**

### Verify signature

ClickUp's `X-Signature` header is the **bare hex digest** — NO `sha256=` prefix.

```python
import hmac, hashlib
expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
# Compare: hmac.compare_digest(expected, request.headers["X-Signature"])
```

### Update or delete

ClickUp v2 has no webhook UPDATE endpoint; to change events or endpoint, DELETE + POST a new one:

```bash
curl -X DELETE "https://api.clickup.com/api/v2/webhook/{webhook_id}" -H "Authorization: $CLICKUP_TOKEN"
```

### Health

GET `/api/v2/team/{team_id}/webhook` lists all team webhooks with `health.status` (`active`, `failing`) and `health.fail_count`. Webhooks pause automatically after repeated 5xx; re-deliver via DELETE + POST.

### <your-org> IDs

- Team ID: `24555569`
- A&E list ID: `<clickup-list-id>` (where `Executor=local-hermes` tasks live)
- Active hermes-bridge webhook: see `~/.claude/projects/<claude-project-token>/memory/reference_clickup_hermes_webhook_id.md` (recorded post-Phase-4)

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `OAUTH_025` error on API calls | Using stale `CLICKUP-API-TOKEN` (`pk_...`). Switch to `CLICKUP-API-KEY` |
| Tag assignment fails | Tag must already exist in the space. Create via REST API (see "Creating New Tags" above) |
| Filter returns 0 tasks but they exist | Check list ID and status filter. A&E + Infra lists share custom statuses (`backlog`, `planning`, `implementation`, `queued`, `in progress`, `qa`, `blocked`, `completed`), not space defaults. URL-encode `statuses[]=` as literal brackets in shell (`statuses\[\]=...`), not `%5B%5D` — the latter returns empty results |
| Custom field write returns 200 but value not stored | Field isn't "shown on list" — toggle the field's visibility on the target list in the UI. No API exists for this. |
| Want to move a task between lists | Not possible via API (probed 10 variants). Recreate-and-archive is the only API path; UI drag is the only "true move." |
| 401 on API calls | `CLICKUP-API-KEY` missing or expired. Re-fetch via `fetch-secrets.sh clickup` |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-05-05 | Doc described retired cloud dispatch + Maestro sub-local | Cloud orchestrator retired in <clickup-task-id>, Maestro retired in Wave 4.6 | Updated lines 134/148/171 to reflect local-poller-only dispatch |
