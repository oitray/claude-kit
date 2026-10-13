# Cloudflare Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-17

## Auth

- **Method:** Global API Key + Email (full admin) or scoped API Token
- **Vault:** `<credential-vault>`
- **Secret names:** `CLOUDFLARE-GLOBAL-API-KEY` (full admin), `CLOUDFLARE-API-TOKEN` (scoped, no DNS write), `CLOUDFLARE-ACCOUNT-ID`
- **Email:** `<your-admin-email>`
- **Env var:** `$CF_KEY` + `$CF_EMAIL` (Global Key) or `$CF_API_TOKEN` (scoped token)
- **Fetch creds (Global Key):** `export CF_KEY=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name CLOUDFLARE-GLOBAL-API-KEY --query value -o tsv) CF_EMAIL=<your-admin-email>`
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
| Zone: <your-other-org> | `<cloudflare-id>` |

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
export CLOUDFLARE_API_KEY=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name CLOUDFLARE-GLOBAL-API-KEY --query value -o tsv)
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
| `<your-other-org>` | `<your-other-org>`, `www.<your-other-org>` | <your-other-org> marketing site (Vite/React SPA + Supabase) |
| `review-sheets` | `review-sheets.pages.dev` | Internal review/approval sheets — **Access-gated to @<your-org>** (see below) |

### Review Sheets — @<your-org>-gated static hosting

Host for interactive **review/approval sheets** (self-contained HTML artifacts — decommission
scopes, flow/field inventories, audit results) that need sharing with <your-org> staff **without** a
Claude Team plan or a GitHub account. GitHub Pages can't gate to a non-GitHub email domain;
Cloudflare Access + the existing Entra IdP can — silent M365 SSO, `@<your-org>` only.

**Publish** (`empirical (2026-07-08)`, motivated by <clickup-task-id>'s lead-decommission approval sheet):

```bash
~/.claude/bin/publish-review.sh <file.html> [more.html ...]   # deploy + gate + print URLs
~/.claude/bin/publish-review.sh --list                        # list published sheets
```

The `/publish-review` slash command wraps it. The script is idempotent — ensures the Pages
project + Access app exist, keeps a persistent build dir (`~/.claude/review-sheets/public`,
gitignored) so prior sheets survive, regenerates the landing index, deploys with the Global Key,
prints the gated URLs.

**Before uploading internal sheets:** verify the Access app, domain coverage, allow policy and
Entra IdP against the rows below. The script checks whether an Access app exists; it does not
validate an existing app's policy. Use only harmless content to establish and verify gating on
both the apex and the deployment's preview hostname before uploading internal content. Any
production setup or corrective write requires explicit approval before execution.

**Access gating** (`empirical (2026-10-05)`: `GET /accounts/<acct>/access/apps`, `/access/apps/<id>/policies`, `/access/identity_providers/<idp>` and `/pages/projects/review-sheets` match every row below; `curl --max-redirs 0` on the apex and on preview host `09d6b92d.review-sheets.pages.dev` both return `302` to `<your-org>.cloudflareaccess.com`):

| Piece | Value |
|---|---|
| Access app | `<your-org> Review Sheets` — id `<azure-uuid>` |
| Self-hosted domains | `review-sheets.pages.dev` + `*.review-sheets.pages.dev` (covers preview deploys) |
| Policy | allow `email_domain: <your-org>` |
| IdP | Entra "Azure AD" `<azure-uuid>` (same IdP as the CF dashboard + Fleet dashboard), `auto_redirect_to_identity: true` (silent SSO) |
| Verify gate | Unauthenticated GET on both apex and preview: require `302` and a `Location` URL with scheme `https` and exact host `<your-org>.cloudflareaccess.com`; fail on any other status or redirect |

Capture and validate the redirect for each hostname, using the harmless probe's URL before
uploading internal sheets and the published sheet's URL after deployment:

```bash
SHEET_URL=https://review-sheets.pages.dev/harmless-probe.html
curl -sS --max-redirs 0 -D gate.headers -o /dev/null "$SHEET_URL" &&
python3 - <<'PY'
from pathlib import Path
from urllib.parse import urlsplit

headers = Path("gate.headers").read_text().splitlines()
statuses = [line.split()[1] for line in headers if line.startswith("HTTP/")]
locations = [line.split(":", 1)[1].strip() for line in headers if line.lower().startswith("location:")]
location = urlsplit(locations[0]) if len(locations) == 1 else None
assert statuses and statuses[-1] == "302", f"Unexpected status: {statuses}"
assert location and location.scheme == "https" and location.netloc == "<your-org>.cloudflareaccess.com", f"Unexpected redirect: {locations}"
print("Access redirect verified")
PY
```

**Gotchas** (bind lag `empirical (2026-07-08)`, observed at app create and not re-probed since, because re-probing needs a new Access app; preview-host coverage `empirical (2026-10-05)`, preview host `302`):

- **Access rules were observed to take ~30–60s to bind** after create. Wait and re-check only
  while the site contains harmless content. An unauthenticated `200` serving internal content
  is an exposure requiring immediate remediation, not a propagation wait. Stop publishing,
  report the exposure and obtain explicit production approval before corrective writes.
- **Preview deploys are a separate hostname.** `<hash>.review-sheets.pages.dev` is NOT covered by an
  app scoped only to the apex — the `*.review-sheets.pages.dev` wildcard self-hosted-domain closes
  that gap. Always share the **production** URL (`review-sheets.pages.dev/...`), which `--branch main`
  guarantees.
- Content is `@<your-org>`-internal, not public — safe for internal flow/API names, ClickUp IDs, voipdoc
  IDs; never secrets/credentials.

Related voipdoc: [Review Sheets — @<your-org>-gated hosting for approval sheets (`/publish-review`)](<internal-url>).

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
export CF_KEY=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name CLOUDFLARE-GLOBAL-API-KEY --query value -o tsv)
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

## Dashboard SSO (M365/Entra)

Cloudflare Dashboard login (`dash.cloudflare.com`) for the `<your-org>` account (`<cloudflare-id>`, plan tier `standard` — Dashboard SSO is free on all plans) is enforced via SSO through the existing Entra "Azure AD" Zero Trust identity provider, on the `<your-org>` email domain. **Enforced 2026-07-02** — connector `<cloudflare-id>`, `enabled: true`, `verification: verified`.

### Enforcement scope

- **Enforced (`<your-org>`):** every `@<your-org>` Cloudflare member logs in via Entra SSO. Roster + Entra-resolution confirmed at enforcement (empirical 2026-07-02): `marissa@`, `steven@`, `jack@`, `alisa@`, `blaine@`, `<your-email>` — all enabled Entra users.
- **Break-glass #1 — `<your-admin-email>`:** deliberately off the enforced domain; confirmed to have **no** matching Entra identity (empirical 2026-07-02, 0 Graph rows), so it authenticates with a normal Cloudflare dashboard login/password and cannot be SSO-locked-out.
- **Break-glass #2 — OTP fallback IdP:** the `onetimepin` identity provider remains present as an emergency login path (verified present immediately pre-enforce).
- **Break-glass #3 — stored API token:** `CLOUDFLARE-SSO-CONNECTOR-TOKEN` in `<credential-vault>` (Account `SSO Connector` write scope). Disables the connector if every browser-based admin is unreachable (see Rollback). Write-capability proven at enforcement via a no-op `PATCH {enabled:false}` dry-run.

### API — connector lifecycle

```bash
# Create (returns a cloudflare_dashboard_sso=<value> TXT verification code)
curl -s -X POST -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  -H "Content-Type: application/json" -d '{"email_domain":"<your-org>"}' \
  "https://api.cloudflare.com/client/v4/accounts/<cloudflare-id>/sso_connectors"

# List
curl -s -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  "https://api.cloudflare.com/client/v4/accounts/<cloudflare-id>/sso_connectors"

# Begin verification (after adding the cloudflare_dashboard_sso=<value> TXT record on the <your-org> zone)
curl -s -X POST -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  "https://api.cloudflare.com/client/v4/accounts/<cloudflare-id>/sso_connectors/$ID/begin_verification"

# Enforce
curl -s -X PATCH -H "X-Auth-Key: $CF_KEY" -H "X-Auth-Email: $CF_EMAIL" \
  -H "Content-Type: application/json" -d '{"enabled":true}' \
  "https://api.cloudflare.com/client/v4/accounts/<cloudflare-id>/sso_connectors/$ID"

# Rollback / disable (break-glass token works here too — no browser session needed)
curl -s -X PATCH -H "Authorization: Bearer $CF_SSO_BREAKGLASS_TOKEN" \
  -H "Content-Type: application/json" -d '{"enabled":false}' \
  "https://api.cloudflare.com/client/v4/accounts/<cloudflare-id>/sso_connectors/$ID"
```

**docs-confirmed:** endpoint shapes per https://developers.cloudflare.com/fundamentals/manage-members/dashboard-sso/ (captured 2026-07-02). **empirical (2026-07-02):** full create → TXT → verify → enforce lifecycle run against the live <your-org> account.

### Gotchas

- Enforcement is **domain-wide**, not per-member — every current and future `@<your-org>` Cloudflare member becomes Entra-gated the moment `enabled:true` lands. Verify every member resolves to a real, enabled Entra identity BEFORE enforcing.
- The Global API Key is required for the member-invite, connector-create, and enforce writes — the narrower `CLOUDFLARE-API-TOKEN` in this runbook's Auth section has no SSO-connector scope.
- The TXT record value must include the literal `cloudflare_dashboard_sso=` prefix — pasting only the trailing value fails verification.
- `/user/tokens/verify` rejects **account-owned** tokens ("Invalid API Token"); confirm an account token's status via `GET /accounts/{id}/tokens/{id}` (`status: active`) or a capability probe, not the user endpoint.

### See also

- Voipdoc (Automations & Engineering, internal): <internal-url>

## Fleet dashboard worker

Read-only Cloudflare Worker serving the live fleet dashboard (epic phase board + active
queue across ClickUp lists `<clickup-list-id>` + `<clickup-list-id>`) behind Cloudflare Access with
Entra ID (M365 SSO). The ClickUp token stays server-side; the Worker has two `GET` API
routes and no write handlers by construction. Source: `services/fleet-dashboard/`.
ClickUp: <clickup-task-id> (epic <clickup-task-id>).

### Architecture

`browser → Cloudflare Access (Entra IdP) → Worker → ClickUp API`. Access stamps each
request with a signed `Cf-Access-Jwt-Assertion`; the Worker verifies it (RS256 against
`https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`) **before** any edge-cache
lookup (composition is `auth → cache → handler`; the 60 s cache key ignores the auth
header, which is safe only under that ordering). Full service doc:
`services/fleet-dashboard/README.md`.

### Worker name / routes / env

| Item | Value |
|---|---|
| Worker name | `fleet-dashboard` |
| Route (Part 2) | `<your-domain>/*` (zone `<your-domain>`; commented in `wrangler.toml` until Part 2) |
| API routes | `GET /` (dashboard HTML), `GET /api/epic/:id`, `GET /api/queue` — all other/non-GET → 404/405, no upstream call |
| Vars | `ACCESS_TEAM_DOMAIN` (full team domain incl. suffix), `ACCESS_AUD` (Access app AUD tag), `ENVIRONMENT` |
| Secret | `CLICKUP_TOKEN` via `wrangler secret put CLICKUP_TOKEN` (from Key Vault `<credential-vault>/CLICKUP-API-KEY`) |
| Access app | self-hosted `<your-domain>`, Azure AD IdP, policy allow `<your-email>`, session 168 h |

Local dev bypass: `ENVIRONMENT=dev DEV_BYPASS_ACCESS=1 wrangler dev` (fails closed to 403
if the bypass flag is set in any non-dev environment).

### Part 2 provisioning (interactive — treat as prod-write)

Entra app (`cf-access-fleet-dashboard`, redirect
`https://<team>.cloudflareaccess.com/cdn-cgi/access/callback`, 12-mo secret →
`CF-ACCESS-FLEET-ENTRA-SECRET`) → CF Access self-hosted app (record AUD) → DNS proxied
`fleet` record → Worker vars + secret → uncomment route → `wrangler deploy`. Pattern
reference: the Dashboard SSO (M365/Entra) section above + <clickup-task-id>. Full checklist:
`services/fleet-dashboard/README.md` "Part 2 checklist" + the ClickUp card.

### Secret rotation

Rotate `CLICKUP_TOKEN`: `wrangler secret put CLICKUP_TOKEN` with the new Key Vault value
(no redeploy needed — secrets take effect on the next request). Rotate the Entra client
secret before its 12-mo expiry: `az ad app credential reset` for `cf-access-fleet-dashboard`,
update Key Vault `CF-ACCESS-FLEET-ENTRA-SECRET`, and refresh it in the CF Access Azure AD
IdP config.

### Rollback

`wrangler delete fleet-dashboard` + remove the `fleet` DNS record + disable the Access app.
Part 1 (repo code) rolls back by reverting the PR — no other service imports it.

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-29 | Scoped API token (`CLOUDFLARE-API-TOKEN`) returned 10000 auth error on DNS record creation | Token had `Zone:Zone:Read` but not `Zone:DNS:Edit` — zone listing worked, DNS writes rejected | Added Global API Key (`CLOUDFLARE-GLOBAL-API-KEY`) with email `<your-admin-email>` for full admin access |
| 2026-06-20 | <your-other-org> site dead on every host (Netlify apex no response, `.netlify.app` 404) | Production build crashed on boot (`useLayoutEffect` of undefined → infinite reload loop) from hand-rolled rollup `manualChunks` splitting React into a circular chunk graph | Removed custom `manualChunks` (vite.config.ts) → Rollup default; migrated to CF Pages project `<your-other-org>`; apex+www CNAME → `<your-other-org>` proxied, MX untouched |
| 2026-04-29 | Email routing enable failed with error 2008 on <knowledge-base>.io | Outlook MX records (`<knowledge-base>-io.mail.protection.outlook.com`) conflict with Cloudflare Email Routing — Cloudflare requires its own MX records | DNS change required: swap Outlook MX + SPF for Cloudflare MX + SPF records (see Email Routing section) |
