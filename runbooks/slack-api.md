# Slack API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-10-06

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
| App name | NS Signup Bot (displays as **<internal-bot>**; bot username `ns_signup_bot`; `bots.info` 2026-10-06) |
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
| `channels:write.invites` | `conversations.invite` into **public** channels — every role channel is public. Added 2026-10-06 (<clickup-task-id>); without it every invite returns `missing_scope` |
| `groups:history`, `commands` | Email-bridge events / slash commands |

The live grant is the `x-oauth-scopes` response header of `auth.test`. Don't edit the similarly named "ns-group-invite" app; it isn't the one whose token we hold.

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
REFRESH=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show \
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
TOKEN=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show \
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

### Smoke-testing the interactivity handler without a real click

You can exercise the n8n approval/deny handler end-to-end by POSTing the payload Slack would send, to `…/webhook/slack-signup-approval`:

- **Approve (button)** — `type:block_actions`, `actions:[{action_id:"signup_approve", value:"<request_id>|<email>|<role>"}]`, `container.message_ts:"<the card's ts>"`. The handler `chat.update`s that `message_ts`, so it targets only that one message.
- **Deny (modal submit)** — you **cannot** drive deny via a simulated button: the deny branch calls `views.open`, which needs a real `trigger_id` (3-second TTL) you can't forge. POST the `view_submission` directly instead: `view.private_metadata = "<request_id>|<email>|<role>|<channel>|<message_ts>"` and `view.state.values.reason_block.deny_reason.selected_option.value = "<reason text>"`.
- **Signing** — body is `payload=<urlencoded JSON>`; sign with `SLACK-NSUSERGROUP-SIGNING-SECRET`: header `X-Slack-Signature: v0=` + HMAC-SHA256 over `v0:<ts>:<rawBody>`, `X-Slack-Request-Timestamp: <now>` (must be within 300s).
- **Caveat** — `Verify Signature + Parse` *computes* `signatureValid` but no downstream node gates on it, so unsigned POSTs are currently accepted (security gap tracked in <clickup-task-id>). Sign anyway so the smoke matches real traffic.
- Sheet lookups match by `request_id` against column A, so a re-surfaced reminder card (posted long after the original request) still updates the correct row. Empirical <clickup-task-id> (2026-06-01).

### Channel assignment (team_join) — how it works and how to smoke it

Flow (`3j6iYD1pagbCtFMl`): `Code: Get User Email` (`users.info` via `this.helpers.httpRequest`; Code nodes have no `fetch`) → `HTTP: Get Sheet Data` → `Code: Find Row + Map Channels` → `Code: Invite + Welcome DM` (invites only, despite the name) → `HTTP: Update Sheet Row` (`values:batchUpdate`: K:L = `TRUE` / timestamp and N = `SENDING`) → `Code: Send Welcome DM` → `HTTP: Update DM Status` (N = `TRUE` or `FAILED: <slack error>`) → `Code: Check DM Result` (throws on a confirmed failed DM after the outcome is recorded). A thrown transport error or missing/unparseable Slack response leaves N = `SENDING` and raises for reconciliation; replay does not re-send.

**Sheet columns K–N.** K `channels_assigned`, L `joined_at`, **M = the requester's company with a blank header** (written by the Request Handler's append; never write M from here), N `welcome_dm_sent` (header added 2026-10-06, <clickup-task-id> review round 1).
- **Row match / welcome_dm_sent states** (across all of that email's approved rows):
  1. Any row with N = `TRUE`, or legacy K = `TRUE` with N blank, means the member is onboarded. The flow stops at `IF: Found Approved?`, even when a duplicate unmarked row exists.
  2. Any row with N = `SENDING` means a previous DM attempt has an unknown outcome, including a transport timeout after delivery or a failed status write. `Code: Find Row` throws (Error Handler alert) and does **not** re-send. A human checks the member's DM and then sets N to `TRUE`, or clears it to retry.
  3. Only a confirmed Slack `{ok:false,error:…}` rejection sets N = `FAILED: <error>`; the latest such row, or a row with K not `TRUE`, is (re)run. Invites are idempotent and the DM is retried.
- **Invite:** for each role channel the bot first `conversations.join`s (public channels need the bot as a member), then calls `conversations.invite`. `already_in_channel` counts as success. Any other invite error, or an empty channel list (role missing from `channelMap` and no `Other`), throws, so the row stays unmarked and the Error Handler alerts #admins.
- **Logic + tests:** `n8n/_tests/slack_signup_channel_assign_logic.mjs` (single source), embedded by `n8n/_tests/patch_slack_signup_channel_assign.mjs`. Run `node --test n8n/_tests/slack_signup_channel_assign.test.mjs`; it `node --check`s every Code node in both workflows.
- **Smoke:** append a temporary approved row for `<your-email>` (role `Other`) and POST a signed synthetic `team_join` for `USV2N1H88`. Sign it with `staticData.slackSigningSecret`. The raw body must be `JSON.stringify(body).replace(/\//g,'\\/')`, which is what `Code: Verify + Parse` reconstructs. Verify the path with `GET /executions/<id>?includeData=true`, then delete the temporary row. Never use a real member. Empirical <clickup-task-id> (2026-10-06): exec 300079 ran every node through `Code: Check DM Result`. Replays on the smoke row, with N set by hand: `FAILED: ratelimited` → retried and DMed, N = `TRUE` (300092). `SENDING` → stopped at Find Row with the "state unknown" error, no DM; Error Handler exec 300095 alerted #admins (300094). `TRUE` → stopped at `IF: Found Approved?` (300105).
- **Sheet access outside n8n:** Key Vault `GOOGLE-DRIVE-SA-JSON` (`n8n-462@n8n-helix`) with `sub=<your-admin-email>` and the **`https://www.googleapis.com/auth/drive`** scope can read and write the sheet. The `spreadsheets` / `spreadsheets.readonly` scopes are not delegated (token exchange 401s).

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
| 2026-06-02 | Approval Handler computed `signatureValid` but never enforced it; Channel Assignment / Events Router only checked `if (slackSig)` (header-absent bypass) with no replay window; signing secret hardcoded in both verify nodes (leaked in PR #575) | `rawBody:true` is broken on n8n Cloud, so an unproven payload reconstruction was shipped non-enforcing and never flipped on (<clickup-task-id>) | Rotated the signing secret → `staticData.slackSigningSecret`; both nodes now consume the single-sourced `verifySlackSignature` (`n8n/_tests/slack_signature_verify.mjs`). Approval Handler flipped to fail-closed via **measure-then-enforce** — validated against 5 real historical clicks (block_actions + view_submission) replayed against the live signature before the throw was enabled. Events Router fail-closed (header-absent + 300s replay both closed). Reconstruction reliability characterized: 0 forward-worthy events fail; only `message_changed`/`deleted`/bot events (skipped anyway) mismatch. |
| 2026-06-02 | Second hardcoded secret found in the Events Router (`SLACK-EVENTS-ROUTER-SECRET`, shared HMAC with `Slack Email Bridge: Outbound`) — also leaked in PR #575 | Same hardcode anti-pattern; #575 scrub missed both secrets | De-hardcoded both workflows to `staticData.slackEventsRouterSecret` (value-preserving). VALUE rotation (coupled cutover) tracked in ClickUp <clickup-task-id>. |
| 2026-06-09 | Approval Handler rejected **every** Approve/Deny click with `bad_signature` (fail-closed) since 2026-06-08 — approval fully broken (<clickup-task-id>) | The PR #915 hardening reconstructed Slack's raw body with `encodeURIComponent(body.payload)`. Slack signs proper `application/x-www-form-urlencoded` (space→`+`, and `! * ( ) '` percent-encoded as `%21 %2A %28 %29 %27`). `encodeURIComponent` leaves `*`/`!` literal and emits `%20` for space → the HMAC base string diverges. Slack interactivity payloads echo the card's `*bold*` mrkdwn, so the decoded `payload` **always** contains `*` → every real click mismatched. The PR #915 "validated against 5 historical clicks" replay missed it because those bodies happened to contain no `*`/`!`. **Empirically proven**: replaying real exec 101079's payload+secret, only `formEnc` (Slack `quote_plus` form-encoding) reproduced the live header signature `v0=48217a39…`; `encodeURIComponent` and strict-`%20` did not. | Reconstruction now uses `formEnc` in `Verify Signature + Parse`: `encodeURIComponent(s).replace(/[!*()']/g, c=>'%'+c.charCodeAt(0).toString(16).toUpperCase()).replace(/%20/g,'+')`. Live-verified: exec 101096 (real billyt@claritytech.com Approve, `success`) + self-driven signed-replay smoke exec 101130 (`success`, signature `ok`). |
| 2026-06-09 | Approval/denial welcome+confirmation were impersonal — the request's `name` never reached the email or Slack card (<clickup-task-id>) | The button `value` encoded only `request_id\|email\|role` (no name); `Get Sheet Data` ran AFTER the email/card were built and was read only to compute the status-write row, so the sheet's `name` column (source of truth) was never plumbed forward. | **Option B**: reordered both branches so the sheet read precedes the build (`Approve or Deny? → Get Sheet Data (Approve) → Prepare Approve Data → …`; `Is View Submission? → Get Sheet Data (Deny) → Prepare Deny Data → …`). `Prepare {Approve,Deny} Data` now look up `name` from the sheet by `request_id` and personalize the email (`Hi <firstName>,`) + add `*Name:*` to the Slack confirmation. `Write {Approve,Deny} to Sheet` read sheet values via `$('Get Sheet Data (…)')` (no longer `$json`); `Get Sheet Data` URLs reference `$('Parse Button Action')` / `$('Verify Signature + Parse')` for `googleSheetId`. Offline-verified against real execs 101096 (approve) + 84623 (deny); live-verified exec 101130. |
| 2026-06-09 | Slack mrkdwn injection / notification abuse — the sheet-sourced `name` (set by the requester on the self-signup form, i.e. attacker-controlled) was interpolated raw into the approval card's `mrkdwn` block, so a crafted name could inject `<@U…>`/`<!channel>` mentions or `<https://evil\|Approve>` phishing links into the admin channel card (<clickup-task-id>, flagged by push security review) | Untrusted text rendered in a `mrkdwn` block without escaping Slack's control sequence chars `< > &` | Added an `esc()` helper (`String(s).replace(/[<>&]/g, …&lt;/&gt;/&amp;)`) in both `Prepare Approve Data` + `Prepare Deny Data`; `name`/`email`/`role`/`reason` are escaped in the `mrkdwn` block only (email `TextBody` is plaintext — left as-is). Verified: malicious-name offline test renders `&lt;!channel&gt;…` (trusted decider `<@id>` mention preserved); live smoke exec 101168 `success`. |
| 2026-10-06 | No approved member had been added to role channels or sent the welcome DM since the flow shipped (<clickup-task-id>), and nobody was alerted (<clickup-task-id>) | (1) `Code: Get User Email` / `Code: Invite + Welcome DM` called `fetch`, which is undefined in n8n Code nodes, so every `team_join` threw. 11 failures from 2026-09-21 to 10-05; earlier ones are past retention. (2) `welcomeText` was a multi-line single-quoted string containing `You've`, a syntax error. (3) Error Handler `Post Error to Admin` referenced an unbound `slackApi` credential: "Credentials not found". (4) The bot lacked `channels:write.invites`, and every role channel is public, so invites returned `missing_scope`. (5) `HTTP: Update Sheet Row` sent a literal, non-`{{ }}` body. (6) Both sheet URLs used `$getWorkflowStaticData` in a node-parameter expression, which resolved to a Google 404 | Fixed all six (see "Channel assignment (team_join)" above). Scope added and app reinstalled by <your-name>. Google SA credential shared into the API project so the sheet-node edits could land (`n8n-api.md`). Backfill: 16 approved in-workspace members invited (12 channel adds), DMed and marked; 4 approved-not-in-workspace and 9 unapproved joiners skipped (card <clickup-task-id>). Smoke exec 299171 |
| 2026-10-06 | PR review round 1 (<clickup-task-id>): marking `channels_assigned` before the DM meant a failed DM was never retried | K did double duty as "invited" and "welcomed" | The DM outcome is now tracked separately in column **N** `welcome_dm_sent` (`SENDING` → `TRUE` / `FAILED: …`); see "Channel assignment (team_join)". The first attempt wrote it to **M** and overwrote the company in 16 rows (M's header is blank). Restored within minutes from Drive revision 74 (`GET /drive/v3/files/<id>/revisions` → `exportLinks['text/csv']`); A:M re-verified identical to that revision. A test now fails if any sheet write targets column M |

## n8n Workflow IDs

| Workflow | ID | Webhook Path |
|----------|----|-------------|
| Slack Signup: Request Handler | `4UYQLgYifhi2huXt` | `/webhook/slack-signup-request` |
| Slack Signup: Approval Handler | `kb69S2iyKDDNMequ` | `/webhook/slack-signup-approval` |
| Slack Events Router (was Channel Assignment) | `3j6iYD1pagbCtFMl` | `/webhook/slack-signup-team-join`. Routes `team_join` to channel assignment and `message` to the email-bridge outbound |
| Slack Signup: Pending Approvals Reminder | `qWp19qVnmaD7c9CF` | cron: daily 9AM ET — posts one Approve/Deny card per `status=pending` row; silent if none |
| Slack Signup: Error Handler | `GZjGIljvcasGKfRm` | error trigger. `Post Error to Admin` is a Code node that posts to #admins `C08H1279HDW` with n8n Variable `SLACK_NSSIGNUPBOT_OAUTH_TOKEN` (no n8n credential) |

> **Retired 2026-06-01 (<clickup-task-id>):** `Slack Signup: Link Expiry Reminder` (formerly `mqhXsjZUMbN0T3bR`) deleted. The `nsusergroup.slack.com` invite link is now a **never-expiring** shareable link, so the daily 30-day-expiry nag to the `#admin` channel is obsolete. A duplicate active copy of the reminder (`MDgoMemdQXd7WDSU`) and a duplicate of the digest (`SwwoHiXDLQF4DJIA`) were deleted at the same time — both were accidental re-imports causing double-posts. Workflow JSON archived at `n8n/archive/slack-signup-link-reminder.json`. If the invite link is ever set to expire again, restore from that archive and re-seed `inviteLinkCreatedAt`.

> **Repurposed 2026-06-01 (<clickup-task-id>):** the surviving `qWp19qVnmaD7c9CF` was reworked from a monthly stats digest into the **Pending Approvals Reminder**. It now scans **all** sheet rows (any time period) for `status=pending` and posts **one interactive Approve/Deny card per pending request** (same `action_id`/`value` contract as the Request Handler's cards, so the Approval Handler processes clicks identically). If zero rows are pending it posts nothing. One message per request (not a combined digest) so an Approve `chat.update` only rewrites that request's card. Source: `<internal-workflow>.json`.
>
> **Approval Handler sheet-write fix (<clickup-task-id>):** the 4 Google Sheets nodes in `Slack Signup: Approval Handler` (`Get Sheet Data (Approve/Deny)`, `Batch Update Sheet (Approve/Deny)`) declared `nodeCredentialType: googleSheetsOAuth2Api` but had a `googleDriveOAuth2Api` credential bound → **"Credentials not found"** at runtime → the sheet read returned empty → approvals/denials updated Slack + sent the email but **never wrote the status back to the sheet** (silent failure; the request stayed `pending`). Fixed all 4 to `googleDriveOAuth2Api` (matches the bound credential + the reminder's working `Get All Rows`). Approve now writes `status=approved` correctly (verified rowFound:True, F-col updated).

## Static Data Setup (one-time, via n8n UI)

Each workflow reads config from `$getWorkflowStaticData('global')`. Open each workflow in the n8n editor, add a manual trigger + Code node temporarily, run it once to seed the data, then remove it.

Required keys per workflow:

| Key | Value | Workflows |
|-----|-------|-----------|
| `slackSigningSecret` | 32-hex (from vault `SLACK-NSUSERGROUP-SIGNING-SECRET`) — HMAC request verification | Approval Handler, Channel Assignment / Events Router |
| `slackEventsRouterSecret` | 64-hex (from vault `SLACK-EVENTS-ROUTER-SECRET`) — shared HMAC router↔bridge-outbound | Events Router (`3j6iYD1pagbCtFMl`), Email Bridge Outbound (`0dm4feYeJGjqI8gJ`) |
| `slackBotToken` | `xoxb-...` (from vault `SLACK-NSSIGNUPBOT-OAUTH-TOKEN`) | Request Handler, Approval, Channel Assignment, Pending Approvals Reminder |
| `googleSheetId` | `1EUIG79CWBK59V6iwL_2j0zmDFew9djkJybux0TnTlhY` | Request Handler, Approval, Channel Assignment, Pending Approvals Reminder |
| `postmarkToken` | from vault `POSTMARKAPP-API-KEY` | Approval Handler |
| `inviteLink` | from vault `SLACK-NSUSERGROUP-INVITE-LINK` (never-expiring shareable link) | Approval Handler |
| `channelMap` | role → channel ids. Live 2026-10-06: NS Service Provider = #general `CSWTXMV9V`, #support `CSY4LA70W`, #known-issues `CTS40368N`, #general-discussion `C0AFBADRA66`; Vendor = #general, #vendor-promotions `C0728QP804V`, #general-discussion; Crexendo/NS Employee = #general, #development `CSWTZ5MUP`, #support, #general-discussion; Other = #general, #general-discussion. Any role not in the map (e.g. free-text `Other: …`) uses `Other` | Events Router |

## Signing-secret rotation

The Slack **signing secret** has no rotation API — regenerate in the Slack app UI, then update vault + staticData. Both verify nodes read `sd.slackSigningSecret` (no node-code change needed to rotate).

1. **Regenerate (UI, 2FA-walled — no API, no Browser Use profile authed):** https://api.slack.com/apps/A0B0PNANWJW/general → App Credentials → Signing Secret → Regenerate → Show → copy.
2. **Vault:** `az keyvault secret set --vault-name <credential-vault> --name SLACK-NSUSERGROUP-SIGNING-SECRET --value "$(pbpaste)" --query id -o tsv` (clipboard→vault keeps the value out of shell history/context; no `AZURE_CONFIG_DIR=<azure-config-dir>` prefix — that SP cannot write `<credential-vault>`, see `docs/runbooks/azure-keyvault.md:113`).
3. **Reseed staticData on BOTH workflows** (no code deploy needed):
   ```bash
   python3 scripts/n8n/seed_static_data.py --workflow kb69S2iyKDDNMequ --key slackSigningSecret --value-file <file>
   python3 scripts/n8n/seed_static_data.py --workflow 3j6iYD1pagbCtFMl --key slackSigningSecret --value-file <file>
   ```
4. **Window:** the Approval Handler is fail-closed and the Events Router is fail-closed — between regenerate (Slack signs new) and reseed (staticData still old), real signed requests fail closed. Reseed immediately after regenerating; do not pause mid-rotation.
5. **Verify:** trigger a real Approve/Deny click (Approval Handler) and confirm a `success` execution; OR replay a recent real execution's body+signature against the new secret (see `scripts/n8n/` replay pattern).

The `slackEventsRouterSecret` (shared router↔bridge HMAC) rotates the same way but is **coupled** — reseed both `3j6iYD1pagbCtFMl` and `0dm4feYeJGjqI8gJ` together (see ClickUp <clickup-task-id>).
