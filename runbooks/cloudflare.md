# Cloudflare Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-17

## Auth

- **Method:** Global API Key + Email (full admin) or scoped API Token
- **Vault:** `<credential-vault>`
- **Secret names:** `CLOUDFLARE-GLOBAL-API-KEY` (full admin), `CLOUDFLARE-API-TOKEN` (scoped, no DNS write), `CLOUDFLARE-ACCOUNT-ID`
- **Email:** `<your-admin-email>`
- **Env var:** `$CF_KEY` + `$CF_EMAIL` (Global Key) or `$CF_API_TOKEN` (scoped token)
- **Fetch creds (Global Key):** `export CF_KEY=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name CLOUDFLARE-GLOBAL-API-KEY --query value -o tsv) CF_EMAIL=<your-admin-email>`
- **Auth headers (Global Key):** `-H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL"`
- **Auth headers (Token):** `-H "Authorization: Bearer $CF_API_TOKEN"`
- **CLI:** `wrangler` (Cloudflare's official CLI)
- **API base:** `https://api.cloudflare.com/client/v4`

## Common Operations

### Via API / CLI

```bash
# Verify API token
curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq '.result.status'

# List zones (domains)
curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?per_page=50" \
  | jq '.result[] | {name, id, status}'

# List DNS records for a zone
curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  | jq '.result[] | {type, name, content, proxied}'

# Create a DNS record
curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"A","name":"<your-org-subdomain>","content":"1.2.3.4","proxied":true,"ttl":1}' \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records"

# Update a DNS record
curl -s -X PATCH -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"content":"5.6.7.8"}' \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID"

# Purge entire cache for a zone
curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"purge_everything":true}' \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/purge_cache"

# List Workers scripts
curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/workers/scripts" \
  | jq '.result[].id'

# Wrangler CLI — list deployed Workers
wrangler deployments list

# Wrangler CLI — tail Worker logs
wrangler tail <worker-name>
```

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| Account ID | `<cloudflare-id>` |
| Zone: <your-org> | `<cloudflare-id>` |
| Zone: <voip-mcp>.com | `<cloudflare-id>` |
| Zone: <knowledge-base>.io | `<cloudflare-id>` |

## Gotchas

- **Scoped API tokens are mandatory for automation.** Global API Key grants full account access with no audit trail per-action. Create tokens scoped to specific zones and permissions (e.g., `Zone:DNS:Edit` for DNS changes only).
- **Rate limits vary by plan.** Free/Pro: 1,200 requests per 5 minutes. Enterprise: higher. The API returns `429` with `Retry-After` header.
- **`proxied: true` vs `false`.** Proxied records route through Cloudflare (orange cloud). DNS-only (`false`) exposes the origin IP. MX, TXT, and SRV records cannot be proxied.
- **TTL = 1 means "auto".** When `proxied: true`, TTL is always auto (1). Setting a custom TTL only works on DNS-only records.
- **Purge cache is zone-wide by default.** `purge_everything: true` clears the entire zone. For surgical purges, use `files` array with specific URLs or `tags`/`prefixes` (Enterprise only).
- **Wrangler auth.** `wrangler login` opens a browser OAuth flow. For CI, set `CLOUDFLARE_API_TOKEN` env var. Wrangler reads `wrangler.toml` for project config.
- **API response envelope.** All responses wrap in `{"success": bool, "errors": [], "messages": [], "result": ...}`. Always check `success` field before reading `result`.
- **No "Edit all resources" API token template.** Only "Read all resources" (169 perms) exists. For full admin, use the Global API Key or create a token programmatically via `GET /user/tokens/permission_groups` → `POST /user/tokens`.
- **Scoped tokens can't self-modify.** Listing or editing tokens requires `User:API Tokens:Edit` permission or the Global API Key. A narrowly-scoped token can't escalate itself.
- **Global API Key auth format differs.** Uses `X-Auth-Key` + `X-Auth-Email` headers, NOT `Authorization: Bearer`. The email must match the account owner exactly.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| 401 Unauthorized | Token expired or scope too narrow. Check `https://api.cloudflare.com/client/v4/user/tokens/verify` |
| 403 on DNS edit | Token missing `Zone:DNS:Edit` permission. Create new scoped token in dashboard |
| `wrangler login` opens browser loop | For CI/headless, use env var: `CLOUDFLARE_API_TOKEN=$CF_API_TOKEN wrangler deployments list` |
| API returns `{"success": false}` | Always check `success` field before reading `result`. Error details in `errors[]` array |
| 429 rate limit | Free/Pro plans: 1,200 req/5min. Check `Retry-After` header |

## Cloudflare Pages

### Auth

Pages API and `wrangler pages` require the **Global API Key** — the scoped API token returns `9106 Missing auth headers` on Pages endpoints.

```bash
# Wrangler env vars for Global Key auth (NOT CLOUDFLARE_API_TOKEN)
export CLOUDFLARE_API_KEY=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name CLOUDFLARE-GLOBAL-API-KEY --query value -o tsv)
export CLOUDFLARE_EMAIL="<your-admin-email>"
export CLOUDFLARE_ACCOUNT_ID="<cloudflare-id>"
```

### Deploy

```bash
npx wrangler pages deploy <directory> --project-name <name> --branch main --commit-dirty=true
```

**`--branch main` is required for production.** Without it, wrangler reads the current git branch and creates a preview deployment instead.

### Custom domains

```bash
CF_ACCOUNT_ID="<cloudflare-id>"

# Add custom domain
curl -s -X POST -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  -H "Content-Type: application/json" \
  -d '{"name":"sub.example.com"}' \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/pages/projects/<project>/domains"

# Check domain status
curl -s -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/pages/projects/<project>/domains" \
  | jq '.result[] | {name, status}'
```

**CNAME must be created manually** even when the zone is on the same Cloudflare account. Cloudflare does NOT auto-create it. Status stays `pending` until the CNAME propagates (typically 1–3 minutes).

### Current projects

| Project | Domain | Purpose |
|---------|--------|---------|
| `ns-slack-signup` | `slack.<knowledge-base>.io` | NS User Group Slack self-signup form |

## Email Routing (<knowledge-base>.io)

**Zone:** `<knowledge-base>.io` | **Zone ID:** `<cloudflare-id>`

**Requires:** Global API Key (`X-Auth-Key` + `X-Auth-Email`) — scoped token returns 10000 auth error on email routing endpoints.

### Current state (2026-04-29)

- Email routing is configured in Cloudflare but **not enabled** — <knowledge-base>.io currently uses Outlook MX records (`<knowledge-base>-io.mail.protection.outlook.com`), which conflict with Cloudflare Email Routing.
- Attempting to enable returns error 2008: `Non-Cloudflare MX records exist`.
- A routing rule for `admins@<knowledge-base>.io → <your-email>` is **staged but inactive** — it exists in the Cloudflare config and will activate once the MX records are swapped.

### DNS changes required to activate

Cloudflare Email Routing requires replacing the existing MX and SPF records:

**Remove:**
- MX: `<knowledge-base>-io.mail.protection.outlook.com.` (TTL 3600)
- TXT/SPF: `v=spf1 include:spf.protection.outlook.com include:spf.mtasv.net -all`

**Add:**
- MX: `route1.mx.cloudflare.net.` priority 89
- MX: `route2.mx.cloudflare.net.` priority 62
- MX: `route3.mx.cloudflare.net.` priority 60
- TXT/SPF: `v=spf1 include:_spf.mx.cloudflare.net ~all`
- TXT/DKIM: `cf2024-1._domainkey.<knowledge-base>.io` → `v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78km4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB`

**Note:** These changes will route all <knowledge-base>.io email through Cloudflare. If <knowledge-base>.io email is actively used via Outlook today, confirm mailboxes are migrated or that <knowledge-base>.io mail is unused before swapping.

### Enable and create rule (after DNS changes)

```bash
export CF_KEY=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name CLOUDFLARE-GLOBAL-API-KEY --query value -o tsv)
export CF_EMAIL="<your-admin-email>"
ZONE_ID="<cloudflare-id>"

# Enable routing
curl -s -X POST -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/email/routing/enable"

# Check if admins rule exists
curl -s -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/email/routing/rules" \
  | jq '.result[] | select(.matchers[0].value == "admins@<knowledge-base>.io")'

# Create rule (if not exists)
curl -s -X POST -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  -H "Content-Type: application/json" \
  -d '{
    "actions": [{"type": "forward", "value": ["<your-email>"]}],
    "matchers": [{"type": "literal", "field": "to", "value": "admins@<knowledge-base>.io"}],
    "enabled": true,
    "name": "admins forwarding"
  }' \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/email/routing/rules"
```

### Verify destination address

Cloudflare requires destination addresses to be verified before routing works. After enabling, verify `<your-email>` is confirmed:

```bash
curl -s -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  "https://api.cloudflare.com/client/v4/accounts/<cloudflare-id>/email/routing/addresses" \
  | jq '.result[] | select(.email == "<your-email>")'
```

If not verified, send verification:
```bash
curl -s -X POST -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  -H "Content-Type: application/json" \
  -d '{"email": "<your-email>"}' \
  "https://api.cloudflare.com/client/v4/accounts/<cloudflare-id>/email/routing/addresses"
```

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-29 | Scoped API token (`CLOUDFLARE-API-TOKEN`) returned 10000 auth error on DNS record creation | Token had `Zone:Zone:Read` but not `Zone:DNS:Edit` — zone listing worked, DNS writes rejected | Added Global API Key (`CLOUDFLARE-GLOBAL-API-KEY`) with email `<your-admin-email>` for full admin access |
| 2026-04-29 | Email routing enable failed with error 2008 on <knowledge-base>.io | Outlook MX records (`<knowledge-base>-io.mail.protection.outlook.com`) conflict with Cloudflare Email Routing — Cloudflare requires its own MX records | DNS change required: swap Outlook MX + SPF for Cloudflare MX + SPF records (see Email Routing section) |
