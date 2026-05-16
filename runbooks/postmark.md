# Postmark Transactional Email API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-29

## Auth

Two token types — Server Token for sending/reading, Account Token for managing servers/domains/signatures.

| Token | Header | Scope |
|-------|--------|-------|
| Server Token | `X-Postmark-Server-Token` | Sending, bounces, templates, stats, webhooks, suppressions, streams, messages |
| Account Token | `X-Postmark-Account-Token` | Servers CRUD, domains CRUD, sender signatures CRUD, template push |

- **Vault:** `<credential-vault>`
- **Secret names:** `POSTMARKAPP-API-KEY` (account), `POSTMARK-SERVER-TOKEN` (server — <knowledge-base>)
- **Env vars:** `$POSTMARKAPP_API_KEY`, `$POSTMARK_SERVER_TOKEN`, `$POSTMARK_VOIPDOCS_SERVER_TOKEN`

| Env var | Purpose |
|---------|---------|
| `$POSTMARKAPP_API_KEY` | Account-level token (servers CRUD, domain management) |
| `$POSTMARK_SERVER_TOKEN` | Server token for <knowledge-base> server (sends from `@<knowledge-base>.io`) |
| `$POSTMARK_VOIPDOCS_SERVER_TOKEN` | Alias for `$POSTMARK_SERVER_TOKEN` (<knowledge-base> server) used by n8n workflows that disambiguate per-server |

- **Fetch creds:** `eval "$(fetch-secrets.sh postmark)"`
- **MCP server:** N/A
- **n8n credential:** `Postmark API` (type `httpHeaderAuth`, ID `YqSILrNP5PiW3NWN`)
- **API base:** `https://api.postmarkapp.com`

## Common Operations

### Via API / CLI

```bash
# Send a transactional email
curl -s https://api.postmarkapp.com/email \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "X-Postmark-Server-Token: $POSTMARK_SERVER_TOKEN" \
  -d '{
    "From": "<service-email>",
    "To": "<service-email>",
    "Subject": "Test notification",
    "HtmlBody": "<h3>Hello</h3><p>This is a test.</p>",
    "MessageStream": "outbound"
  }'
```

```bash
# Send email with plain text fallback
curl -s https://api.postmarkapp.com/email \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "X-Postmark-Server-Token: $POSTMARK_SERVER_TOKEN" \
  -d '{
    "From": "<service-email>",
    "To": "<service-email>",
    "Subject": "Notification",
    "HtmlBody": "<p>HTML content here.</p>",
    "TextBody": "Plain text fallback here.",
    "MessageStream": "outbound"
  }'
```

```bash
# Send email with CC/BCC
curl -s https://api.postmarkapp.com/email \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "X-Postmark-Server-Token: $POSTMARK_SERVER_TOKEN" \
  -d '{
    "From": "<service-email>",
    "To": "<service-email>",
    "Cc": "<service-email>",
    "Subject": "Escalation notice",
    "HtmlBody": "<p>Details here.</p>",
    "MessageStream": "outbound"
  }'
```

```bash
# Get delivery stats
curl -s https://api.postmarkapp.com/deliverystats \
  -H "Accept: application/json" \
  -H "X-Postmark-Server-Token: $POSTMARK_SERVER_TOKEN"
```

```bash
# Get outbound message details (last 50)
curl -s "https://api.postmarkapp.com/messages/outbound?count=50&offset=0" \
  -H "Accept: application/json" \
  -H "X-Postmark-Server-Token: $POSTMARK_SERVER_TOKEN"
```

```bash
# Search outbound messages by recipient
curl -s "https://api.postmarkapp.com/messages/outbound?count=10&offset=0&todate=2026-04-10&recipient=<service-email>" \
  -H "Accept: application/json" \
  -H "X-Postmark-Server-Token: $POSTMARK_SERVER_TOKEN"
```

```bash
# Get server info (verify token works)
curl -s https://api.postmarkapp.com/server \
  -H "Accept: application/json" \
  -H "X-Postmark-Server-Token: $POSTMARK_SERVER_TOKEN"
```

### Via MCP

N/A — no Postmark MCP server configured. All calls go through n8n HTTP Request nodes.

### Set inbound webhook URL on a server

```bash
SERVER_ID=19062972
curl -X PUT "https://api.postmarkapp.com/servers/$SERVER_ID" \
  -H "X-Postmark-Account-Token: $POSTMARKAPP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"InboundHookUrl":"https://n8n.example.com/webhook/<path>"}'
```

**empirical** (2026-05-14): `InboundHookUrl` is empty by default on a newly-created server; setting it routes parsed inbound JSON to the URL via POST. Used by the `slack-email-bridge-inbound` workflow.

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| API base URL | `https://api.postmarkapp.com` |
| Server: <knowledge-base> | ID `19062972` (sends from `@<knowledge-base>.io`) |
| Server: <your-org> (WP) | ID `4812063` |
| Server: <voip-mcp>.com | ID `4602868` |
| Domain: <knowledge-base>.io | ID `4600766` (SPF + DKIM + Return-Path verified) |
| Domain: <your-org> | ID `1337845` (SPF + DKIM + Return-Path verified) |
| Sender address | `<service-email>` |
| Default recipient | `<service-email>` |
| Message stream | `outbound` |
| n8n credential name | `Postmark API` |
| n8n credential ID | `YqSILrNP5PiW3NWN` |
| n8n credential type | `httpHeaderAuth` (generic) |

## Active Code Paths

| Location | Usage |
|----------|-------|
| `<internal-workflow>.json` | "Email No Contact Match" node — sends alert when a WLP training completion has no matching Salesforce Contact |

## Gotchas

- **Auth header is `X-Postmark-Server-Token`**, not `Authorization: Bearer`. Case-sensitive.
- **`From` address must be a verified Sender Signature** in Postmark. Using an unverified address returns 422.
- **`MessageStream`** is required for accounts with multiple streams. <your-org> uses `"outbound"` for transactional email.
- **JSON body fields are PascalCase** (`From`, `To`, `Subject`, `HtmlBody`) — not camelCase or snake_case.
- **In n8n**, the credential is configured as Generic Header Auth. The header name/value pair is stored in the credential, so the HTTP Request node does not need to manually set `X-Postmark-Server-Token`.
- **No batch/bulk endpoint** is used by <your-org>. For bulk sends, Postmark has `/email/batch` (up to 500 per request), but our workflows send one-at-a-time.
- **Rate limit:** 50 emails/second on standard plans. Not typically a concern for <your-org>'s volume.
- **Domain verification is account-wide**, not per-server. New servers inherit all verified domains automatically — no per-server domain setup needed.
- **Server creation via API returns `ApiTokens` array** in the response. Also retrievable later via `GET /servers/{id}` with Account Token. No dashboard needed for token provisioning.
- **When adding Postmark to a domain with existing SPF**, merge `include:spf.mtasv.net` into the existing TXT record — don't replace it. Multiple SPF records on one domain cause validation failures.
- **`LinkClicked` events are unreliable as a user-engagement signal (empirical).** Enterprise email security sandboxes (Microsoft Defender for O365 SafeLinks, Mimecast URL Protect, Proofpoint TAP) auto-click every link in incoming mail to scan destinations. The event fires within 1–10 seconds of `Delivered`, well before any human could see the email. Treat `Delivered` (SMTP 250 from the recipient's MX) as authoritative for delivery; do NOT use `LinkClicked` to confirm a human read the email.
- **`GET /messages/outbound` requires an explicit `offset` query parameter.** Omitting it returns `{"ErrorCode":700,"Message":"Parameter 'offset' is required but has been left out"}`. Always include `--data-urlencode "offset=0"` even when paginating from the start. The `count` parameter is also required.
- **Account-level token (`X-Postmark-Account-Token`) ≠ server-level token (`X-Postmark-Server-Token`).** They live in different vault entries (`POSTMARKAPP-API-KEY` vs `POSTMARK-SERVER-TOKEN`). Account token can list/create/delete servers and read each server's API tokens (`GET /servers/{id}` returns `ApiTokens[]` in plaintext). Server token sends mail and queries that server's messages. Don't conflate.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| 401 Unauthorized | Used `Authorization: Bearer` — Postmark uses `X-Postmark-Server-Token` (case-sensitive) |
| 422 "From address not verified" | `From` must match a verified Sender Signature in Postmark |
| 422 on send | Check field casing — JSON body uses PascalCase (`From`, `To`, `HtmlBody`) not camelCase |
| Missing MessageStream | Required for multi-stream accounts. <your-org> uses `"outbound"` |
| n8n node sends but no auth header | Credential is Generic Header Auth — node shouldn't set `X-Postmark-Server-Token` manually; the credential handles it |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-29 | <knowledge-base>.io domain setup — SPF already verified before DKIM/Return-Path DNS added | Postmark checks SPF via public DNS immediately; DKIM/Return-Path require DNS propagation + explicit verify call | Add DNS records first (`POST /zones/{id}/dns_records`), wait for propagation, then call `PUT /domains/{id}/verifyDkim` and `PUT /domains/{id}/verifyReturnPath` |
