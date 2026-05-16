# NetSapiens API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-03

## Auth

- **Method:** Bearer token
- **Vault:** `<credential-vault>`
- **Secret name:** `NETSAPIENS-API-TOKEN`, `NETSAPIENS-API-URL`
- **Env var:** `$NETSAPIENS_API_TOKEN`, `$NETSAPIENS_API_URL`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh <voip-mcp>)"`
- **Base URL:** `https://<your-netsapiens-host>`

## Common Operations

### Via API / CLI

#### Global phone number lookup (v1 API — cross-domain)

```bash
curl -X POST "https://<your-netsapiens-host>/ns-api/?object=phonenumber&action=read" \
  -H "Authorization: Bearer $NETSAPIENS_API_TOKEN" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "format=json&dialplan=DID+Table&matchrule=sip:13059676756@*"
```

**Parameters:**
- `dialplan` — `DID Table` (contains all <DID-table-size> numbers)
- `matchrule` — Exact: `sip:1NPANXXXXXX@*`
- `matchrule_LIKE` — Partial: `%305%` (uses `%` wildcards, NOT `*`)
- `dest_domain` — Optional domain filter

**Response fields:** `matchrule`, `to_host` (destination domain), `to_user`, `plan_description`, `enable`

#### Call Detail Records (CDR) — v2 API

```bash
curl "$NETSAPIENS_API_URL/ns-api/v2/cdrs?limit=50&domain=<your-sip-domain>&user=1234&start_time=2026-04-01T00:00:00&end_time=2026-04-30T23:59:59" \
  -H "Authorization: Bearer $NETSAPIENS_API_TOKEN"
```

**Endpoint:** `GET /ns-api/v2/cdrs` (NOT the v1 `?object=cdr&action=read` POST form — v1 returns 200 with empty body for CDR lookups; v2 is the working path).

**Query parameters:**
- `domain` — required, <your-org> = `<your-sip-domain>`
- `user` — optional, internal extension (e.g. `1234`); omit for domain-wide CDRs
- `start_time` / `end_time` — ISO 8601 with offset (`2026-04-01T00:00:00`); space-separated `2026-04-01 00:00:00` works in v1 only
- `limit` — page size (default ~50)

**Response:** JSON array of CDR objects. Field naming is **kebab-case** (`call-orig-user`, `call-term-user`, `call-disposition`, `call-orig-from-name`, `call-disconnect-reason-text`, `call-direction` 1=inbound 2=outbound).

**Key fields for skill consumption:**
- `id` — opaque CDR ID (40-char hex)
- `domain` — `<your-sip-domain>`
- `call-orig-user` / `call-term-user` — internal extension on either leg (null if external↔external relay)
- `call-orig-from-user` / `call-orig-to-user` — DID (E.164 11-digit int) of caller / callee
- `call-orig-from-name` — caller display name
- `call-answer-datetime` / `call-disconnect-datetime` — UTC ISO with `+00:00`
- `call-batch-total-duration-seconds` — talk duration
- `call-direction` — 1 (orig/inbound to org) or 2 (term/outbound from org)
- `call-disposition-reason` — SIP code (200 OK, 302 redirect, 486 busy, etc.)
- `call-disconnect-reason-text` — `"Orig: Bye"`, `"Cancel"`, etc.

**Pagination:** `limit` + offset; large windows benefit from page loops. Empty `[]` is a valid response (no calls in window — verify against UI before assuming bug).

## Gotchas

- **v2 API is domain-scoped.** `get_phone_numbers` requires knowing the domain first. For cross-domain lookups, use the v1 API above.
- **Phone format:** Raw digits won't match. Must use `sip:1NPANXXXXXX@*` format.
- **`get_domains` returns DID holding domains** (e.g., `0000.something`), not client domains like `<your-sip-domain>`.
- **`matchrule_LIKE` uses `%` wildcards**, not `*`.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Phone number lookup returns empty | Check format: must be `sip:1NPANXXXXXX@*`, not raw digits |
| v2 domain list returns `0000.*` domains only | v2 API returns DID holding domains, not client domains. Use v1 API for cross-domain lookups |
| `matchrule_LIKE` returns no results | Uses `%` wildcards, not `*`. Example: `%305%` not `*305*` |
| User search finds nothing | Requires a domain parameter. Use v1 domain list first or use v1 API |
| 401 on v1 API calls | Token expired or wrong. Re-fetch via `fetch-secrets.sh <voip-mcp>` |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|

## API Docs

- JSON collection: `https://<your-netsapiens-host>/ns-api/webroot/apidoc/api_doc_collection.json`
- Web UI: `https://<your-netsapiens-host>/ns-api/webroot/apidoc/`
