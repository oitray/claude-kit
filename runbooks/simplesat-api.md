# SimpleSat API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-30

## Auth

- **Method:** API key (header)
- **Vault:** `<credential-vault>`
- **Secret name:** `SIMPLESAT-API-KEY`
- **Env var:** `$SIMPLESAT_API_KEY` after fetch
- **Fetch creds:** `AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name SIMPLESAT-API-KEY --query value -o tsv`
- **MCP server:** N/A

> **Convention:** API key goes in `X-Simplesat-Token` header. No server-side filtering — all queries pull full result sets and filter client-side.

## Common Operations

### List All Answers (Paginated)

```bash
curl -s "https://api.simplesat.io/api/answers/?page_size=100" \
  -H "X-Simplesat-Token: $SIMPLESAT_API_KEY"
```

Response body: `{ count, next, previous, answers: [...] }` (note: field is `answers`, not `results`).

Answer fields: `id`, `rating` (string), `sentiment`, `answer_label`, `created`, `channel`, `customer.name`, `customer.email`, `customer.company.name`, `ticket.external_id`, `ticket.subject`, `ticket.team_member.name`, `ticket.team_member.email`, `ticket.collaborators`, `ticket.custom_attributes`, `follow_up_answer.comment`, `survey.name`, `survey.id`, `tags`, `is_primary`, `reason`

Pagination: use `next`/`previous` URLs in response; `count` field shows total answers.

### List All Surveys

```bash
curl -s "https://api.simplesat.io/api/surveys/" \
  -H "X-Simplesat-Token: $SIMPLESAT_API_KEY"
```

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| Base URL | `https://api.simplesat.io/api/` |
| Total answers (as of 2026-04-30) | ~517 |
| Verified endpoints | GET `/answers/` (paginated, 100/page) |
| Unverified endpoints | GET `/surveys/`, POST `/customers/create-or-update/` |

## Gotchas

- **No server-side filtering.** The API does not support `?filter=` parameters. Pull all answers via pagination and filter client-side.
- **SF Case ID normalization.** `ticket.external_id` is a 15-character SF Case ID. Convert to 18-character format (`^[a-zA-Z0-9]{15}$` → append padding) for matching against SF.
- **`rating` is a string.** API returns `"rating": "4"` not `4`. Parse with `parseInt()` before numeric comparisons.
- **Company name mismatch.** `customer.company.name` may differ from SF `Account.Name` — use fuzzy matching or explicit mapping.
- **Pagination uses URLs.** Response includes `next` and `previous` fields with full URLs; do not construct them manually.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| 401 Unauthorized | Verify `$SIMPLESAT_API_KEY` is set and valid via `echo $SIMPLESAT_API_KEY`. Re-run `eval "$($HOME/.claude/scripts/fetch-secrets.sh simplesat)"`. |
| Empty or partial results | Confirm `page_size=100` in URL and iterate through all pages using `next` field. |
| `ticket.external_id` doesn't match SF Case ID | Check 15 vs 18 character format. SF IDs may need padding. |

## Resolved Issues

> Log fixes here when an API call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| — | — | — | — |
