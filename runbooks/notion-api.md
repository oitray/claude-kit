# Notion API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-26

## Auth

- **Method:** Internal integration bearer token
- **Vault:** `<credential-vault>`
- **Secret name:** `NOTION-API-KEY`
- **Env var:** `$NOTION_TOKEN`
- **Fetch creds:** `NOTION_TOKEN=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name NOTION-API-KEY --query value -o tsv)`
- **MCP server:** Notion MCP exists but prefer direct API per project convention
- **API Version header:** `Notion-Version: 2022-06-28`
- **Content access:** Managed via Creator dashboard → integration → Content access tab (not per-page "..." menu)

## Common Operations

### Search for databases/pages

```bash
curl -s "https://api.notion.com/v1/search" \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{"query": "food", "filter": {"property": "object", "value": "database"}}'
```

### Get database schema

```bash
curl -s "https://api.notion.com/v1/databases/{database_id}" \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28"
```

### Query database rows

```bash
curl -s "https://api.notion.com/v1/databases/{database_id}/query" \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{"page_size": 10}'
```

### Create a page (insert row)

```bash
curl -s -X POST "https://api.notion.com/v1/pages" \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{
    "parent": {"database_id": "{database_id}"},
    "properties": {
      "Name": {"title": [{"text": {"content": "value"}}]},
      "Field": {"rich_text": [{"text": {"content": "value"}}]},
      "Number Field": {"number": 42},
      "Select Field": {"select": {"name": "Option"}},
      "URL Field": {"url": "https://example.com"}
    }
  }'
```

### Update a page

```bash
curl -s -X PATCH "https://api.notion.com/v1/pages/{page_id}" \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{"properties": {"Field": {"number": 99}}}'
```

## <your-org>-Specific IDs

| Resource | ID |
|----------|-----|
| Food Reference DB | `<azure-uuid>` |

## Gotchas

- macOS Python `urllib` needs `ssl._create_unverified_context` to avoid SSL cert errors
- Integration sees nothing by default — must grant access via Creator dashboard Content access tab
- `select` property values must match existing options exactly (case-sensitive) or Notion auto-creates new ones
- Pagination: responses cap at 100 results; use `start_cursor` from `next_cursor` to paginate
- 404 on a page/database usually means the integration lacks access, not that the resource doesn't exist

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| 401 Unauthorized | Token expired or malformed — re-fetch from vault |
| 404 on known database | Integration not granted access — add via Creator dashboard Content access tab |
| 400 validation error on select | Option name doesn't match existing options — check exact casing |

## Resolved Issues

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-26 | Initial setup | N/A | Created integration, stored token, granted full workspace access |
