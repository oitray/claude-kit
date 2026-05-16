# Google Workspace Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-17

## Auth

- **Method:** OAuth2 (user consent, managed by MCP server)
- **Vault:** `<credential-vault>` (only if using raw API calls)
- **Secret name:** `GOOGLE-CLIENT-ID`, `GOOGLE-CLIENT-SECRET` (for MCP server initialization)
- **Env var:** `$<credential-env>`, `$<credential-env>`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh google-workspace)"`
- **API base:** Service-specific — `https://www.googleapis.com/drive/v3`, `https://sheets.googleapis.com/v4`, `https://www.googleapis.com/calendar/v3`, `https://gmail.googleapis.com/gmail/v1`

## Common Operations

### Via API / CLI

Direct API calls require a valid OAuth token. For reference:

```bash
# List files in Drive (requires OAuth token)
curl -s -H "Authorization: Bearer $GOOGLE_TOKEN" \
  "https://www.googleapis.com/drive/v3/files?q='root'+in+parents&fields=files(id,name,mimeType)" \
  | jq '.files[] | {name, id}'

# Read a Google Sheet range
curl -s -H "Authorization: Bearer $GOOGLE_TOKEN" \
  "https://sheets.googleapis.com/v4/spreadsheets/$SHEET_ID/values/Sheet1!A1:D10"

# List calendar events (next 7 days)
curl -s -H "Authorization: Bearer $GOOGLE_TOKEN" \
  "https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=$(date -u +%Y-%m-%dT%H:%M:%SZ)&maxResults=25&singleEvents=true&orderBy=startTime" \
  | jq '.items[] | {summary, start: .start.dateTime}'

# Search Gmail
curl -s -H "Authorization: Bearer $GOOGLE_TOKEN" \
  "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=from:<service-email>+newer_than:7d"
```

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| Workspace domain | `<your-org>` |
| Shared Drive: <your-org> | `<TBD>` |
| Shared Drive: Sales | `<TBD>` |

## Gotchas

- **OAuth scopes must match operations.** If an API call returns a permission error, the OAuth consent may not include that scope. Re-authenticate with broader scopes if needed.
- **File IDs, not paths.** Google APIs identify files by opaque IDs, not file paths. Use the Drive search or resolve endpoint to find IDs from names/paths.
- **Sheet ranges use A1 notation.** e.g., `Sheet1!A1:D10`. Tab name is required if the workbook has multiple tabs.
- **Gmail search syntax.** Uses Gmail's native query syntax: `from:`, `to:`, `subject:`, `newer_than:7d`, `has:attachment`, `label:`, `is:unread`. Not regex.
- **Rate limits vary by API.** Drive: 12,000 queries/100 seconds. Sheets: 300 requests/minute/project. Calendar: typically 1,000,000 queries/day. Gmail: 250 quota units/second.
- **Google Docs editing is index-based.** Insertions and deletions reference character indices. Reading the doc first to get current indices is typically necessary before making edits.
- **Batch operations available** for multi-file operations (delete, move, restore, share) to reduce API calls.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| API call returns auth error | Check OAuth token validity and scopes. Re-authenticate if expired |
| Permission denied on operation | OAuth scope may not include that operation. Re-authenticate with broader scopes |
| File not found by path | Google uses opaque IDs, not paths. Use the Drive search/resolve endpoint to convert |
| Sheet range error | Use A1 notation: `Sheet1!A1:D10` (tab name required for multi-tab workbooks) |
| Gmail search returns nothing | Uses Gmail query syntax, not regex: `from:`, `to:`, `subject:`, `newer_than:7d`, `has:attachment` |
| Rate limit 429 | Drive: 12,000/100sec. Sheets: 300/min/project. Calendar: ~1M/day. Gmail: 250 quota units/sec |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
