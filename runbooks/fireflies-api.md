# Fireflies.ai Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-13

## Auth

- **Method:** API key (Bearer token)
- **Vault:** `<credential-vault>`
- **Secret name:** `FIREFLIES-API-KEY`
- **Env var:** `$FIREFLIES_API_KEY` after fetch
- **Fetch creds:** `AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name FIREFLIES-API-KEY --query value -o tsv`
- **MCP server:** N/A

## Common Operations

### Via API (GraphQL)

All requests go to `https://api.fireflies.ai/graphql` as POST with `Authorization: Bearer $KEY`.

```bash
# Get current user info and active integrations
curl -s -X POST "https://api.fireflies.ai/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FIREFLIES_API_KEY" \
  -d '{"query":"{ user { name email integrations } }"}'
```

```bash
# Get recent transcripts with action items
curl -s -X POST "https://api.fireflies.ai/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FIREFLIES_API_KEY" \
  -d '{"query":"{ transcripts(limit: 5) { id title date participants summary { action_items short_summary } } }"}'
```

```bash
# Get single transcript with full detail
curl -s -X POST "https://api.fireflies.ai/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FIREFLIES_API_KEY" \
  -d '{"query":"{ transcript(id: \"TRANSCRIPT_ID\") { title date participants summary { action_items overview notes keywords } } }"}'
```

```bash
# Introspect any type
curl -s -X POST "https://api.fireflies.ai/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FIREFLIES_API_KEY" \
  -d '{"query":"{ __type(name: \"Transcript\") { fields { name type { name kind ofType { name } } } } }"}'
```

## Key Types

| Type | Notable Fields |
|------|---------------|
| `User` | `user_id`, `email`, `name`, `integrations`, `is_admin`, `num_transcripts` |
| `Transcript` | `id`, `title`, `date` (epoch float), `participants` (email array), `summary`, `apps_preview`, `host_email`, `duration` |
| `Summary` | `action_items` (string, markdown with `**Name**` headers), `overview`, `notes`, `keywords`, `short_summary`, `bullet_gist` |
| `AppOutput` | `transcript_id`, `app_id`, `title`, `prompt`, `response` |

## Action Items Format

Fireflies returns `summary.action_items` as a markdown string with person headers:

```
**All Staff**
Task description here (timestamp)

**<your-name>**
Another task here (timestamp)

**Chris**
Task for Chris (timestamp)
```

The ClickUp integration pushes ALL action items as tasks under the authenticated user's account, regardless of the `**Name**` header. Ownership filtering must happen downstream.

## <your-org>-Specific IDs

| Resource | Value |
|----------|-------|
| User email | `<your-email>` |
| Active integrations | `salesforce`, `onedrive`, `clickup`, `notion` |
| ClickUp target list | Meeting Inbox (`<clickup-list-id>`) |

## n8n Workflows

| Workflow | ID | Purpose |
|----------|-----|---------|
| Daily Task List | `FXWCMmKyJoyoNaMt` | Daily 8AM digest of assigned + watched tasks across all ClickUp spaces |

## Gotchas

- **Action items are per-meeting, not per-person.** The ClickUp integration creates tasks for ALL action items under <your-name>'s account. Filter by the `**Name**` headers in the description if per-person routing is needed.
- **`summary.action_items` is a String**, not a structured array. Parse markdown headers to extract assignees.
- **Transcript `date` is an epoch float** (seconds, not milliseconds). Multiply by 1000 for JS `new Date()`.
- **`participants` is a flat email array**, not structured objects.
- **Integration settings are in the Fireflies web UI** (`app.fireflies.ai → Integrations → ClickUp`), not exposed via the API. The API cannot configure which tasks get pushed.
- **Rate limits:** Not documented, but API responds quickly. Use retry logic on HTTP 429.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `action_items` field not found on Transcript | Use `summary { action_items }` — it's nested under Summary type |
| Empty action items | Some meetings have no extractable action items; check `summary.overview` as fallback |
| GraphQL validation error | Introspect the type first: `__type(name: "TypeName") { fields { name } }` |

## Resolved Issues

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-13 | All Meeting Inbox tasks showed in digest regardless of assignee | Fireflies ClickUp integration creates all tasks under <your-name>'s account | Added `for_ray` field to AI classifier; restructured workflow to use team-wide ClickUp API with assignee/watcher filtering |
