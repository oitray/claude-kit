# Helpjuice API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-11

## Auth

- **Method:** API key (Bearer token)
- **Vault:** `<credential-vault>`
- **Secret name:** `HELPJUICE-API-KEY` (plus `HELPJUICE-SUBDOMAIN` for the subdomain)
- **Env var:** `$HELPJUICE_API_KEY`, `$HELPJUICE_SUBDOMAIN`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh <knowledge-base>)"`
- **MCP server:** `<knowledge-base>` — wraps Helpjuice CRUD operations
- **Base URL:** `https://<voip-mcp>.helpjuice.com/api/v3`

## Common Operations

### Search articles (via MCP)

Use `mcp__voipdocs__voipdocs_helpjuice_search` with query string.

### Get article

```
GET /api/v3/articles/:id
```
Or via MCP: `mcp__voipdocs__voipdocs_helpjuice_get_article`

### Create article

```
POST /api/v3/articles
{ "name": "Title", "body": "<html>...", "category_id": 1348715 }
```
Omit `published: true` to create as draft. Include `published: true` to publish immediately.

### Update article

```
PUT /api/v3/articles/:id
```

**Draft mode (for review):** Send `body` WITHOUT `published: true` → creates draft revision. Published version stays live.

**Direct publish:** Send `body` + `published: true` in one call → publishes immediately.

**Does NOT work:** Two-step (body first, then separate `published: true` call) — second call is a no-op on the draft.

### List categories

```
GET /api/v3/categories
```
Or via MCP: `mcp__voipdocs__voipdocs_helpjuice_get_categories`

## <your-org>-Specific IDs

| Category | ID |
|----------|-----|
| Sales Management | `1348715` |

## Gotchas

- **Draft vs publish:** Default to draft mode (omit `published: true`) unless explicitly told to publish. Bot proposes, human approves.
- **`published: true` alone (no body)** → no-op, article stays as-is.
- **MCP `<knowledge-base>` server** handles most CRUD — use it before falling back to raw API.
- **Article body is HTML**, not markdown.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Article update succeeds but published version unchanged | You sent `body` without `published: true` — creates a draft revision only. Include `published: true` in same call to publish |
| Two-step update (body first, then `published: true`) no-ops | Second call is a no-op on the draft. Must send body + `published: true` in a single call |
| MCP `<kb>_helpjuice_search` returns nothing | Check query — Helpjuice uses keyword search, not fuzzy matching. Try shorter/broader terms |
| 401 Unauthorized | Vault secret expired or wrong. Re-fetch: `eval "$($HOME/.claude/scripts/fetch-secrets.sh <knowledge-base>)"` |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
