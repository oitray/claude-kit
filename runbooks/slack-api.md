# Slack API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-29

## Auth

- **Method:** Bearer token (Bot OAuth token)
- **Vault:** `<credential-vault>`
- **Secret names:**
  - `SLACK-NSSIGNUPBOT-OAUTH-TOKEN` — bot token (`xoxb-...`)
  - `SLACK-NSUSERGROUP-SIGNING-SECRET` — HMAC signing secret for request verification
  - `SLACK-NSUSERGROUP-CLIENT-SECRET` — OAuth app client secret
- **Env var:** `$SLACK_BOT_TOKEN`, `$SLACK_SIGNING_SECRET`, `$<credential-env>`
- **Fetch creds:**
  ```bash
  SLACK_BOT_TOKEN=$(az keyvault secret show \
    --vault-name <credential-vault> \
    --name SLACK-NSSIGNUPBOT-OAUTH-TOKEN \
    --query value -o tsv)

  SLACK_SIGNING_SECRET=$(az keyvault secret show \
    --vault-name <credential-vault> \
    --name SLACK-NSUSERGROUP-SIGNING-SECRET \
    --query value -o tsv)
  ```
- **MCP server:** N/A

> **Convention:** Vault secret names are UPPERCASE-HYPHEN. The `fetch-secrets.sh` script handles mapping automatically via `catalog.json`.

## App Configuration

| Field | Value |
|-------|-------|
| App name | NS Signup Bot |
| App ID | `A0B0PNANWJW` |
| Bot ID | `B0B0LBDQB0V` |
| Bot User ID | `U0B0HC2DQHZ` |
| Workspace | nsusergroup |
| Team ID | `TSHJ96EBD` |

### Bot Token Scopes

| Scope | Purpose |
|-------|---------|
| `chat:write` | Post messages to channels/DMs |
| `users:read` | Look up user profile info |
| `users:read.email` | Look up users by email address |
| `groups:write` | Invite bot to private channels |
| `im:write` | Open DM conversations |
| `channels:join` | Auto-join public channels |
| `channels:read` | List and inspect public channels |
| `groups:read` | List and inspect private channels |

### Event Subscriptions

| Event | Trigger |
|-------|---------|
| `team_join` | Fires when a new user joins the workspace |

### Webhook URLs

| Endpoint | URL |
|----------|-----|
| Interactivity (modal submits, button clicks) | `<internal-url>` |
| Event subscriptions (team_join) | `<internal-url>` |

> Update both URLs in the Slack app dashboard under **Interactivity & Shortcuts** and **Event Subscriptions** once the n8n workflow is live.

## Common Operations

### Verify request signature (HMAC-SHA256)

Slack signs every incoming request. Verify before processing:

```javascript
const crypto = require('crypto');

function verifySlackSignature(req) {
  const signingSecret = process.env.SLACK_SIGNING_SECRET;
  const timestamp = req.headers['x-slack-request-timestamp'];
  const slackSig = req.headers['x-slack-signature'];

  // Reject requests older than 5 minutes (replay attack prevention)
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp)) > 300) {
    throw new Error('Request timestamp too old');
  }

  const sigBasestring = `v0:${timestamp}:${req.rawBody}`;
  const mySignature = 'v0=' + crypto
    .createHmac('sha256', signingSecret)
    .update(sigBasestring, 'utf8')
    .digest('hex');

  if (!crypto.timingSafeEqual(Buffer.from(mySignature), Buffer.from(slackSig))) {
    throw new Error('Invalid signature');
  }
}
```

### Look up user by email

```bash
curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  "https://slack.com/api/users.lookupByEmail?email=user@example.com" | jq .
```

### Invite user to a channel

```bash
# Public channel
curl -s -X POST "https://slack.com/api/conversations.invite" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"channel": "C08H1279HDW", "users": "U0B0HC2DQHZ"}'

# Private channel — bot must already be a member
# Bot join is manual: invite @NS-Signup-Bot in the channel UI
```

### Post a message

```bash
curl -s -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "channel": "C08H1279HDW",
    "text": "New signup request from <@USER_ID>",
    "blocks": []
  }'
```

### Open a modal (interactivity)

```bash
curl -s -X POST "https://slack.com/api/views.open" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "trigger_id": "<trigger_id_from_payload>",
    "view": { "type": "modal", "title": { "type": "plain_text", "text": "Approve Signup" }, "blocks": [] }
  }'
```

### Check API response for errors

All Slack API responses return `{"ok": true}` or `{"ok": false, "error": "..."}`. Always check `ok` field:

```bash
RESPONSE=$(curl -s ...)
if [ "$(echo $RESPONSE | jq -r .ok)" != "true" ]; then
  echo "Error: $(echo $RESPONSE | jq -r .error)"
fi
```

### Subscribe a bot to message.groups events

Required scope: `groups:history`. Adding scope requires workspace-admin reinstall (consent prompt).

Set Events Request URL at `https://api.slack.com/apps/<APP_ID>/event-subscriptions`:
1. Enable Events → ON
2. Request URL → paste n8n webhook URL
3. Slack POSTs `{"type":"url_verification","challenge":"<token>"}` — the workflow must echo back `{"challenge":"<token>"}` within 3s
4. Subscribe to bot events → add `message.groups` (or `message.channels` for public)

**empirical** (2026-05-14): on a private channel the bot is already a member of, adding `groups:history` and reinstalling produces working `message.groups` events without re-adding the bot to the channel.

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| Workspace | nsusergroup |
| Team ID | `TSHJ96EBD` |
| App ID | `A0B0PNANWJW` |
| Bot ID | `B0B0LBDQB0V` |
| Bot User ID | `U0B0HC2DQHZ` |
| #admin channel ID | `C08H1279HDW` (private) |
| Bot token vault key | `SLACK-NSSIGNUPBOT-OAUTH-TOKEN` |
| Signing secret vault key | `SLACK-NSUSERGROUP-SIGNING-SECRET` |
| Client secret vault key | `SLACK-NSUSERGROUP-CLIENT-SECRET` |
| App config token (temp) vault key | `SLACK-API-TEMP-KEY` (12-hour TTL) |
| App config refresh token vault key | `SLACK-API-REFRESH-KEY` (long-lived) |

## App Manifest Updates (no UI required)

For any Slack app where we hold config tokens (vault keys `SLACK-API-TEMP-KEY` + `SLACK-API-REFRESH-KEY`), changes to display name, scopes, event subscriptions, etc. can be done via API instead of the dashboard.

### Quick path — add a scope

```bash
./scripts/slack-app-config/add-scope.sh groups:history
# or multiple:
./scripts/slack-app-config/add-scope.sh channels:history groups:history
# user scopes:
./scripts/slack-app-config/add-scope.sh --user search:read
```

The script rotates the config tokens (writing the new pair back to vault), exports the current manifest, adds the requested scopes idempotently, posts the update, and prints the reinstall URL if `permissions_updated=true`. Source: `scripts/slack-app-config/add-scope.sh`. App + vault names are overridable via `SLACK_APP_ID` / `KV_VAULT`.

After it surfaces the reinstall URL, click "Reinstall to Workspace" once — Slack does not let API change the active install grant. If `token_rotation_enabled` is false in the manifest, the existing bot token simply gains the new scope (no token swap needed); otherwise re-fetch and update `SLACK-NSSIGNUPBOT-OAUTH-TOKEN`.

### Manual long form (for changes beyond scopes)

**Step 1 — refresh the temp token if expired (12-hour TTL):**

```bash
REFRESH=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show \
  --vault-name <credential-vault> --name SLACK-API-REFRESH-KEY --query value -o tsv)
curl -s -X POST "https://slack.com/api/tooling.tokens.rotate" \
  -d "refresh_token=$REFRESH" \
  | jq '{token, refresh_token, exp}'
# Save token + refresh_token back to vault if rotated:
#   store-secret --vault user --name SLACK-API-TEMP-KEY
#   store-secret --vault user --name SLACK-API-REFRESH-KEY
```

**Step 2 — export the manifest:**

```bash
TOKEN=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show \
  --vault-name <credential-vault> --name SLACK-API-TEMP-KEY --query value -o tsv)
APP_ID=A0B0PNANWJW
curl -s -X POST "https://slack.com/api/apps.manifest.export" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "app_id=$APP_ID" \
  | jq '.manifest' > /tmp/manifest.json
```

**Step 3 — modify and PUT it back:**

```bash
# Edit /tmp/manifest.json, then:
curl -s -X POST "https://slack.com/api/apps.manifest.update" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "app_id=$APP_ID" \
  --data-urlencode "manifest=$(cat /tmp/manifest.json)" \
  | jq
```

Bot display-name renames take effect immediately — no reinstall required as long as scopes don't change. If the response shows `permissions_updated: true`, the app needs to be reinstalled to grant new scopes.

**Display name layering (Slack):**
- `display_information.name` — shown on app store / app directory listing.
- `features.bot_user.display_name` — shown above each message in channels and on the bot's user profile. **This is the one users see.** Update both for consistency.

## Gotchas

- **Private channels require manual bot invite** — `groups:write` scope lets the bot join after being invited, but the initial invite must be done manually in Slack UI (`/invite @NS-Signup-Bot`). The bot cannot invite itself to a private channel.
- **No `admin.users.invite` on Free plan** — The Slack Free plan does not support `admin.users.invite`. Cannot programmatically add users to the workspace via API; the self-signup flow uses Slack's native invite link or manual admin action.
- **`team_join` fires on workspace join, not channel join** — Event fires once per new workspace member. Channel membership is separate.
- **Interactivity requires a public HTTPS URL** — The n8n webhook URL must be reachable by Slack's servers. Test with `curl` from a public endpoint before configuring in the app dashboard.
- **Trigger IDs expire in 3 seconds** — `views.open` must be called within 3 seconds of receiving the interactivity payload. Avoid async operations before opening a modal.
- **Signature verification uses raw body** — Parse headers before JSON-decoding the body. Many frameworks decode before you can read raw bytes; configure middleware to preserve the raw buffer.
- **`users.lookupByEmail` requires `users:read.email` scope** — Ensure this scope is present; `users:read` alone is insufficient.
- **Rate limits** — Tier 3 (50+ calls/min) for most web API methods. `chat.postMessage` is Tier 3. Back off on `429` responses.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `invalid_auth` on API calls | Bot token expired or revoked — re-fetch from vault; check app is still installed in workspace |
| `not_in_channel` on `conversations.invite` | Bot is not a member of the target channel — manually invite bot first |
| `channel_not_found` | Channel ID is wrong or bot lacks `groups:read`/`channels:read` scope |
| Signature verification fails | Check that raw body (not parsed JSON) is used in HMAC; verify `X-Slack-Request-Timestamp` header is present |
| `team_join` events not arriving | Event subscription URL may not be verified — Slack sends a `url_verification` challenge on setup; endpoint must echo `challenge` field back |
| Modal doesn't open | `trigger_id` expired (3s window); ensure `views.open` is called immediately in the request handler |
| `missing_scope` error | Add the required scope in Slack app dashboard → OAuth & Permissions → Reinstall the app |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-29 | Initial runbook created | — | App configured, all n8n workflows deployed |

## n8n Workflow IDs

| Workflow | ID | Webhook Path |
|----------|----|-------------|
| Slack Signup: Request Handler | `4UYQLgYifhi2huXt` | `/webhook/slack-signup-request` |
| Slack Signup: Approval Handler | `kb69S2iyKDDNMequ` | `/webhook/slack-signup-approval` |
| Slack Signup: Channel Assignment | `3j6iYD1pagbCtFMl` | `/webhook/slack-signup-team-join` |
| Slack Signup: Link Expiry Reminder | `mqhXsjZUMbN0T3bR` | cron: daily 9AM ET |
| Slack Signup: Monthly Digest | `qWp19qVnmaD7c9CF` | cron: 1st of month 9AM ET |
| Slack Signup: Error Handler | `GZjGIljvcasGKfRm` | error trigger |

## Static Data Setup (one-time, via n8n UI)

Each workflow reads config from `$getWorkflowStaticData('global')`. Open each workflow in the n8n editor, add a manual trigger + Code node temporarily, run it once to seed the data, then remove it.

Required keys per workflow:

| Key | Value | Workflows |
|-----|-------|-----------|
| `slackBotToken` | `xoxb-...` (from vault `SLACK-NSSIGNUPBOT-OAUTH-TOKEN`) | All 5 |
| `googleSheetId` | `1EUIG79CWBK59V6iwL_2j0zmDFew9djkJybux0TnTlhY` | Request Handler, Approval, Channel Assignment, Monthly Digest |
| `postmarkToken` | from vault `POSTMARKAPP-API-KEY` | Approval Handler |
| `inviteLink` | from vault `SLACK-NSUSERGROUP-INVITE-LINK` | Approval Handler |
| `inviteLinkCreatedAt` | `2026-04-29` | Link Expiry Reminder |
| `channelMap` | `{"NS Service Provider":[],"Vendor":[],"Crexendo/NS Employee":[],"Other":[]}` | Channel Assignment |
