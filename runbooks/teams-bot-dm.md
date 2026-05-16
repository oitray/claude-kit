# Teams DM Bot Runbook (portable)

> **Owner:** Your name | **Last verified:** 2026-05-14

Outbound-only Microsoft Teams bot. Your scripts (Claude Code sessions, CI jobs,
cron — anything that can run `curl`) DM you in Teams. Webhook-driven, zero cost
on the free tier, works on any Azure/M365 tenant where you can sideload a
custom app.

The working skeleton is in `examples/teams-dm-bot/`. This runbook explains the
*why* — every architectural choice, every gotcha, every diagnostic. Read it once
end to end before you start, then refer back to the gotcha catalog when
something fails.

## Architecture

Two phases, two code paths, one cached artifact between them.

```
┌───────────────────────────  Bootstrap  ────────────────────────────┐
│                                                                     │
│   You ───"hi"───►  Teams ───signed POST───► Receiver (Worker /      │
│                                              Functions)             │
│                                                  │                  │
│                                                  ▼                  │
│                                       extract conversation          │
│                                       reference, store in           │
│                                       KV / Table Storage            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌──────────────────────────  Steady state  ──────────────────────────┐
│                                                                     │
│   Script ──► fetch-conv-ref.sh (one-shot, reads from receiver)      │
│       │                                                             │
│       ▼                                                             │
│   ~/.config/teams-dm/conv-ref.json + env                            │
│       │                                                             │
│       ▼                                                             │
│   send-dm.sh "msg" ──► AAD client-credentials ──► access_token      │
│                              │                                      │
│                              ▼                                      │
│       POST <serviceUrl>/v3/conversations/<id>/activities            │
│                              │                                      │
│                              ▼                                      │
│                          You see DM in Teams                        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

The receiver exists **only to capture the conversation reference on first
contact**. Once `conv-ref.json` exists on your machine, every subsequent send
is a single outbound HTTPS POST direct to the Bot Connector — the receiver is
not involved. This is why a Worker on the free tier (or a consumption-plan
Function) is enough: it handles one hit per install, plus the occasional
re-bootstrap.

The cached conversation reference is the load-bearing trick. Microsoft's
documented "proactive messaging" pattern requires that the bot has already
received at least one inbound activity from the user, so the bot knows the
`conversationId` and the regional `serviceUrl` to address. Microsoft Learn:
<https://learn.microsoft.com/microsoftteams/platform/bots/how-to/conversations/send-proactive-messages>.

## Prerequisites

### Tools

- An Azure subscription (any tier; Bot Service F0 is free)
- A Microsoft 365 tenant where you have permission to upload custom Teams apps
  to your own account (see "Sideload rejected" in the gotcha catalog if your
  tenant blocks this)
- `az` CLI, `wrangler` (or Azure Functions Core Tools), `curl`, `jq`, `zip`
- Either ImageMagick (`magick`) or `python3` with Pillow installed if you want
  to regenerate the placeholder icons in `examples/teams-dm-bot/manifest/`.
  The shipped icons are usable as-is for sideload; skip this if you're not
  customizing the branding.

### Tenant + bot state (load-bearing for the steady-state path)

The cached-conversation-reference pattern in this guide depends on four
prerequisites being TRUE before any send attempt. If any one is false, the
send path has no self-heal mechanism — it's a single outbound POST — so the
fix is always to re-run the bootstrap flow.

1. **The app is installed in your personal scope.** Completed via the Teams
   sideload step. Sending without this returns "Bot is not installed in user's
   personal scope" from the Bot Connector. Reference: Microsoft Learn —
   <https://learn.microsoft.com/microsoftteams/platform/bots/how-to/conversations/send-proactive-messages>.
2. **The bootstrap "hi" reached the receiver.** Confirm via `wrangler tail` /
   Application Insights showing a `POST /api/messages` with status 200, AND
   the KV key `conv-ref` (Workers) or the `TeamsBotConvRef` table row
   (Functions) populated.
3. **The cached `conversationId` + `serviceUrl` are still valid.** They
   invalidate when you uninstall + reinstall the bot, when the user's chat
   thread is deleted, or when the bot's AAD app is rotated. Re-bootstrap if
   sends start returning 404/410 on the conversation.
4. **The bot's AAD app credentials are valid in the target tenant.** The
   client secret hasn't expired, `Microsoft.BotService` is registered as a
   resource provider on the subscription, the Azure Bot resource exists and
   isn't disabled, and the tenant policy permits custom Teams app upload.
   Sends fail with 401/403 if any of these regress. Reference: Microsoft
   Learn —
   <https://learn.microsoft.com/microsoftteams/platform/concepts/deploy-and-publish/apps-upload>
   (custom app sideload prerequisites).

## One-time setup

### Step 1 — Register the AAD app and Bot resource

This creates the identity the bot speaks with and the Bot Service registration
that routes Teams traffic to your receiver.

```bash
# 0. Capture your tenant id — referenced by --tenant-id below and reused in
#    Step 2's wrangler secret put / functionapp appsettings.
TENANT_ID="$(az account show --query tenantId -o tsv)"

# 1. App registration (the bot's identity).
APP_ID="$(az ad app create \
  --display-name "MyTeamsDMBot" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)"

# 2. Pin single-tenant explicitly. `az ad app create` may default to
#    multi-tenant in some CLI versions — re-assert it to be safe.
az ad app update --id "$APP_ID" --sign-in-audience AzureADMyOrg

# 3. Generate a client secret. Capture both the value (shown ONCE) and
#    the expiry — set a calendar reminder to rotate before expiry.
az ad app credential reset --id "$APP_ID" --append --display-name "bot-secret" \
  --years 2 --query "{secret:password, expires:endDateTime}" -o json

# 4. Register Microsoft.BotService on the subscription if you've never
#    used a Bot resource before. Idempotent; safe to re-run.
az provider register --namespace Microsoft.BotService --wait

# 5. Create the resource group + Bot Service registration (F0 free tier).
# `--app-type SingleTenant` matches the audience pin from Step 2; current
# azure-cli no longer accepts the legacy `--kind registration` flag.
az group create -n my-bot-rg -l westus2
az bot create \
  --app-type SingleTenant \
  --tenant-id "$TENANT_ID" \
  --sku F0 \
  --resource-group my-bot-rg \
  --name my-teams-dm-bot \
  --appid "$APP_ID"

# 6. Enable the Teams channel (Bot Service defaults to Web Chat only).
az bot msteams create --resource-group my-bot-rg --name my-teams-dm-bot
```

You now have an AAD app (with a client secret in hand), a Bot Service
registration, and the Teams channel enabled. The messaging endpoint URL on
the Bot resource is still empty — you set that in Step 2 after deploying the
receiver.

### Step 2 — Deploy the receiver

Pick one option. The Worker is recommended for cost and cold-start latency;
the Function is the right call if you already operate in Azure end to end.

#### Option A: Cloudflare Workers (recommended)

The skeleton is in `examples/teams-dm-bot/worker/`. The full validation flow
lives in `validateBotFrameworkToken()` (`worker/index.js`) — signature against
the Bot Framework JWKS, issuer/audience/exp claims, and the `serviceUrl` trust
binding. The `TRUSTED_SERVICE_URL_HOSTS` allowlist near the top of that file
is the public-cloud set (`smba.trafficmanager.net`,
`webchat.botframework.com`, `directline.botframework.com`); if you're on a
sovereign cloud (Gov, China) edit that list before deploy.

```bash
cd examples/teams-dm-bot/worker

# Create a KV namespace and copy the id into wrangler.toml.
wrangler kv:namespace create CONV_REF

# Set secrets. SETUP_SECRET is any random string — used by fetch-conv-ref.sh
# to authorize pulling the cached reference back to your machine.
wrangler secret put BOT_APP_ID         # the app id from Step 1
wrangler secret put BOT_APP_SECRET     # the secret value from Step 1
wrangler secret put <credential-env>      # your AAD tenant id
wrangler secret put SETUP_SECRET       # `openssl rand -hex 32`

wrangler deploy
```

Note your Worker URL (e.g. `https://my-bot.<account>.workers.dev`), then point
the Bot Service messaging endpoint at `<worker-url>/api/messages`:

```bash
az bot update --resource-group my-bot-rg --name my-teams-dm-bot \
  --endpoint "https://my-bot.<account>.workers.dev/api/messages"
```

Tail logs in a second terminal while you sideload + send the "hi":

```bash
wrangler tail
```

#### Option B: Azure Functions

The skeleton is in `examples/teams-dm-bot/functions/`. Python v2 model, one
function app, two routes: `POST /api/messages` (`bot_messages`) and
`GET /api/conv-ref` (`fetch_conv_ref`). Cached references land in an Azure
Table called `TeamsBotConvRef` in whatever storage account backs
`AzureWebJobsStorage`.

```bash
cd examples/teams-dm-bot/functions

# Create a storage account first. AzureWebJobsStorage points here, and the
# Table client in function_app.py writes the cached conv reference into a
# `TeamsBotConvRef` table inside this account. Names must be 3-24 chars,
# lowercase + digits only, and globally unique.
STORAGE_NAME="mybotstor$(openssl rand -hex 3)"
az storage account create \
  --name "$STORAGE_NAME" \
  --resource-group my-bot-rg \
  --location westus2 \
  --sku Standard_LRS

# Provision the function app (Python 3.11 on consumption plan).
az functionapp create \
  --resource-group my-bot-rg \
  --consumption-plan-location westus2 \
  --runtime python --runtime-version 3.11 \
  --functions-version 4 \
  --name my-bot-fn \
  --storage-account "$STORAGE_NAME" \
  --os-type Linux

# Application settings (analogous to Worker secrets).
az functionapp config appsettings set \
  --resource-group my-bot-rg --name my-bot-fn \
  --settings \
    BOT_APP_ID=<app-id> \
    BOT_APP_SECRET=<secret> \
    <credential-env>=<tenant-id> \
    SETUP_SECRET=$(openssl rand -hex 32)

# Deploy code.
func azure functionapp publish my-bot-fn --python
```

Point the Bot Service messaging endpoint at the function URL:

```bash
az bot update --resource-group my-bot-rg --name my-teams-dm-bot \
  --endpoint "https://my-bot-fn.azurewebsites.net/api/messages"
```

### Step 3 — Sideload the Teams app

The shipped manifest at `examples/teams-dm-bot/manifest/manifest.json` pins
`manifestVersion: 1.17`, declares a single `personal`-scope bot, and omits
`isNotificationOnly` deliberately so the bootstrap "hi" works on first try.
Manifest schema reference: Microsoft Learn —
<https://learn.microsoft.com/microsoftteams/platform/resources/schema/manifest-schema>.

```bash
cd examples/teams-dm-bot/manifest

# Replace placeholders. The make-zip.sh guard refuses to build a zip while
# {{BOT_APP_ID}} or {{BOT_NAME}} are still present.
sed -i.bak \
  -e "s/{{BOT_APP_ID}}/$APP_ID/g" \
  -e "s/{{BOT_NAME}}/MyTeamsDMBot/g" \
  manifest.json && rm manifest.json.bak

./make-zip.sh                            # writes bot.zip
```

Upload `bot.zip` via Teams desktop or web: **Apps → Manage your apps →
Upload an app → Upload for me or my teams** (the wording varies by Teams
client version). Sideload rules: Microsoft Learn —
<https://learn.microsoft.com/microsoftteams/platform/concepts/deploy-and-publish/apps-upload>.

Open the bot chat and send the literal text `hi`. While the message is in
flight, the receiver should log a `POST /api/messages` with status 200 and
write the conversation reference to KV / Table Storage. If the Teams client
refuses to upload the app, see gotcha #6 below.

### Step 4 — Capture the conversation reference

`fetch-conv-ref.sh` reads the cached reference from the receiver (using
`SETUP_SECRET` as a shared bearer) and writes it to
`~/.config/teams-dm/conv-ref.json` with mode 600.

Run this from the repo root (or adjust the relative path — Step 3 left you in
`examples/teams-dm-bot/manifest/`):

```bash
cd <repo-root>
WORKER_URL="https://my-bot.<account>.workers.dev" \
SETUP_SECRET="<the value you set>" \
  examples/teams-dm-bot/bin/fetch-conv-ref.sh
```

For the Functions option, `WORKER_URL` is `https://my-bot-fn.azurewebsites.net`
— same `/conv-ref` route.

Then write the env file that `send-dm.sh` sources at runtime:

```bash
cat > ~/.config/teams-dm/env <<'EOF'
BOT_APP_ID=<app id from Step 1>
BOT_APP_SECRET=<client secret from Step 1>
<credential-env>=<tenant id>
EOF
chmod 600 ~/.config/teams-dm/env
```

### Step 5 — Send your first DM

```bash
examples/teams-dm-bot/bin/send-dm.sh "Claude says hi"
examples/teams-dm-bot/bin/send-dm.sh --markdown "**deploy** finished in _42s_"
```

The first invocation calls the AAD token endpoint and caches the result
(token plus absolute expiry epoch) at `${TMPDIR:-/tmp}/teams-dm-token`. The
cache file is mode 600 and guarded by an `mkdir`-based lock so concurrent
invocations don't stampede the token endpoint. On a 401 the script busts the
cache and retries once.

## How it works under the hood

Each send is a Bot Framework REST POST. The script does three things:

1. **Acquire an access token via AAD client credentials.** POST to
   `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token` with
   `grant_type=client_credentials`, `client_id` = the bot's app id,
   `client_secret` = the bot's client secret, and `scope` =
   `https://api.botframework.com/.default`. The scope is the load-bearing
   bit — it must be `api.botframework.com/.default`, NOT a Graph scope.
   Reference: Microsoft Learn —
   <https://learn.microsoft.com/azure/bot-service/rest-api/bot-framework-rest-connector-authentication>.
2. **Read `conversationId` + `serviceUrl` from the cached reference.** Never
   construct either of these from training-data assumptions. The
   `conversationId` is opaque (looks like `a:1abc...`) and the `serviceUrl`
   is regional (e.g. `https://smba.trafficmanager.net/amer/`). Both come
   from the activity envelope the bootstrap message produced.
3. **POST the activity.** `POST {serviceUrl}/v3/conversations/{conversationId}/activities`
   with `Authorization: Bearer {access_token}` and a JSON body containing
   `type: "message"`, `text`, and `textFormat` (`plain` or `markdown`).

The receiver's job during bootstrap is symmetric: validate the inbound JWT
(signature against the Bot Framework JWKS published at
`login.botframework.com/v1/.well-known/openidconfiguration`, issuer match,
audience = your bot's app id, `exp` not in the past), bind the token to
`activity.serviceUrl` (the `serviceurl` claim — when present — must match
the activity value, and `activity.serviceUrl` itself must resolve to a
trusted Bot Connector host), and only on `type=message` or
`conversationUpdate` activities persist the captured `conversationId` /
`serviceUrl` / `tenantId` / `from` block to KV (or Table Storage). The
outbound-only bot returns HTTP 200 with an empty body — no echo, no
adaptive card, nothing.

## Wiring into Claude Code

Three small patterns; pick what fits your workflow. None of them are
required — `send-dm.sh` is a standalone shell helper.

- **Stop hook.** Configure Claude Code's `Stop` hook to call `send-dm.sh`
  when a session ends, so long-running sessions ping you when they finish.
  Pass the session title or last commit subject as the message body.
- **Custom slash command.** Add a `~/.claude/commands/dm.md` whose body is
  `bash <path-to>/send-dm.sh "$ARGUMENTS"`. Then `/dm "deploy done"` in any
  session pings you in Teams.
- **Inline bash.** Ask Claude to run `bash <path>/send-dm.sh "msg"` directly
  from a session. Useful for one-offs and for testing the wiring.

All three rely on the env file and `conv-ref.json` being readable by the
process that invokes the script. They don't otherwise touch Claude Code
state.

## Gotcha catalog

Each entry is a real failure mode with the symptom, the cause, and the fix.
Sources cite Microsoft Learn URLs where applicable — this runbook is
publishable, so no internal paths.

1. **"Bot is not installed in user's personal scope" when sending.** Symptom:
   `send-dm.sh` returns HTTP 403 with that exact message from the Bot
   Connector. Cause: the bootstrap "hi" never happened — the bot has no
   conversation thread to address. Fix: sideload the app (Step 3), open the
   chat, send `hi`, then re-run `fetch-conv-ref.sh`. Reference:
   <https://learn.microsoft.com/microsoftteams/platform/bots/how-to/conversations/send-proactive-messages>.

2. **Service URL must be the regional Trafficmanager URL — never hardcode.**
   Symptom: sends succeed for one user but fail with 404 / "Conversation not
   found" for another. Cause: someone pasted a `serviceUrl` from a sample
   into the script. The real `serviceUrl` varies by region
   (`smba.trafficmanager.net` plus a regional suffix like `/amer/` or
   `/emea/`). Fix: always read `serviceUrl` from the cached conversation
   reference — `send-dm.sh` already does this. If you wrote your own send
   helper, mirror that pattern.

3. **Wrong token scope.** Symptom: 401 from the Bot Connector even though
   the token endpoint returned 200. Cause: the script requested a Graph
   scope (`https://graph.microsoft.com/.default`). Fix: use
   `https://api.botframework.com/.default`. Reference:
   <https://learn.microsoft.com/azure/bot-service/rest-api/bot-framework-rest-connector-authentication>.

4. **Single-tenant vs multi-tenant.** Symptom: AAD token endpoint returns
   "AADSTS50194: Application '...' is not configured as a multi-tenant
   application" or vice versa. Cause: the app's `sign-in-audience` doesn't
   match what the token request is asking for. Fix for a personal-use bot:
   pin single-tenant explicitly with
   `az ad app update --id <app-id> --sign-in-audience AzureADMyOrg`, and
   use your own tenant id in the token request.

5. **AAD provider not registered → 403 on `az bot create`.** Symptom:
   `az bot create` fails with "The subscription is not registered to use
   namespace 'Microsoft.BotService'". Cause: the subscription has never
   provisioned a Bot resource. Fix:
   `az provider register --namespace Microsoft.BotService --wait`, then
   retry.

6. **Sideload rejected.** Symptom: Teams shows "Your IT admin hasn't enabled
   uploading custom apps" or similar. Cause: tenant app-setup policy.
   Diagnostic: **Teams Admin Center → Teams apps → Setup policies →
   Global** and confirm "Upload custom apps" is **Allowed**. If you don't
   own the tenant policy, ask the tenant admin to allow custom app upload
   for your account (org-wide is overkill — a custom policy assigned to you
   is sufficient). Reference:
   <https://learn.microsoft.com/microsoftteams/platform/concepts/deploy-and-publish/apps-upload>.

7. **Messaging endpoint missing `/api/messages` suffix.** Symptom: every
   inbound "hi" gets a 404 from the receiver; `wrangler tail` shows nothing.
   Cause: the Bot Service messaging endpoint is set to your bare worker /
   function URL. Fix:
   `az bot update --endpoint "https://.../api/messages"` — the path is part
   of the contract, the receiver only listens there.

8. **Incomplete JWT validation.** Symptom: receiver accepts any token,
   including unsigned or spoofed ones; bot is a forwarding target for
   arbitrary inbound traffic. Cause: a custom validator that checks only
   one or two claims. Fix: the validator must check (a) signature against
   the Bot Framework JWKS, (b) issuer matches the JWKS-published value,
   (c) audience matches your bot app id, (d) `exp` is in the future, AND
   (e) `activity.serviceUrl` resolves to a trusted Bot Connector host plus
   (when the token carries a `serviceurl` claim) that claim matches
   `activity.serviceUrl` exactly. The shipped Worker (`validateBotFrameworkToken`
   in `worker/index.js`) and Function (`_validate_bf_token` in
   `function_app.py`) implement all five — use them as references.
   Reference: <https://learn.microsoft.com/azure/bot-service/rest-api/bot-framework-rest-connector-authentication>
   "Step 4: Verify the serviceurl claim".

9. **F0 SKU message quotas.** Symptom: sporadic 429s during a burst, or a
   month-end "you've exceeded your free tier" notice. Cause: the F0 Bot
   Service tier caps messages per channel; Teams counts as a standard
   channel. Quotas have changed over time, so don't memorize a number —
   check the current limit at
   <https://azure.microsoft.com/pricing/details/bot-services/>. For
   personal-use DM bursts the F0 cap is generally fine; high-volume use
   cases need the S1 SKU.

10. **Markdown rendering.** Symptom: sending `**bold**` shows the literal
    asterisks in Teams. Cause: `textFormat` defaults to `plain`. Fix: set
    `textFormat: "markdown"` on the activity body. `send-dm.sh --markdown`
    does this for you.

11. **`isNotificationOnly: true` breaks bootstrap.** Symptom: after enabling
    the optional-hardening setting that hides the user's input box, the
    bootstrap "hi" no longer works on first install. Cause: the input box
    is what the user needs to deliver the bootstrap activity; if it's
    hidden, there's no way to produce one. Fix: leave `isNotificationOnly`
    omitted (the shipped manifest does) until AFTER you've captured a
    conversation reference, then optionally add it and re-sideload. The
    cached reference survives the manifest update because conversation IDs
    are tied to the app id, not the manifest version.

## Troubleshooting flow

Work top-down. The first failure on the list is the most common.

```
Send fails (non-2xx from POST .../activities)
│
├── 401 Unauthorized?
│     ├── Token endpoint returned 200 but BF says 401?  → gotcha #3 (wrong scope)
│     ├── Token endpoint returned 4xx?                  → check client_id/secret/tenant
│     └── Worked yesterday, fails today?                → client secret expired; rotate
│
├── 403 Forbidden?
│     ├── "Bot is not installed in user's personal scope"  → gotcha #1 (re-bootstrap)
│     └── tenant policy or disabled bot resource           → gotcha #6 / prereq #4
│
├── 404 / 410 on the conversation?
│     ├── Did you reinstall the app or wipe the chat?  → re-bootstrap (gotcha #1)
│     └── Stale conv-ref.json? Check capturedAt        → re-run fetch-conv-ref.sh
│
└── 5xx?
      └── Bot Connector outage or regional issue        → check Azure status, retry
```

If the bootstrap "hi" itself doesn't reach the receiver:

```
No `POST /api/messages` in receiver logs after "hi"
│
├── Messaging endpoint missing /api/messages?  → gotcha #7
├── Sideload silently failed?                  → gotcha #6
├── Teams channel not enabled on Bot resource? → `az bot msteams create ...`
└── Worker / Function not deployed?            → re-run deploy step
```

## What's NOT in this guide

This is a one-way DM bot. It is not a chat agent. The following are
deliberately out of scope:

- **Bidirectional chat.** The receiver returns empty 200s and never echoes.
  Building a chat agent on top of this requires routing inbound activities
  to a model and crafting reply activities — different problem.
- **@mentions inside replies.** Mentioning the user in a Teams message
  requires adding an `entities` array with `mentionedUser` payloads and
  matching `<at>...</at>` tags in the text. Not difficult, but not done
  here.
- **Adaptive Cards.** The shipped send helper produces text activities. Cards
  require a different body shape (`attachments` array with
  `contentType: "application/vnd.microsoft.card.adaptive"`).
- **Multi-user fan-out.** The receiver stores a single conversation
  reference. Supporting multiple users means keying the cache by user
  (e.g. `from.aadObjectId`) and changing the fetch / send helpers to
  accept a target.
- **SSO / on-behalf-of flows.** This bot speaks as itself, not on behalf of
  the user. SSO requires a different auth dance and is not relevant for
  outbound notification use cases.

## Extending

Short pointers for the common asks above.

- **Adding bidirectional chat.** Route inbound `type=message` activities to
  whatever handler you want (model call, command parser, etc.) and reply by
  POSTing back to the same `{serviceUrl}/v3/conversations/{conversationId}/activities`
  endpoint with the bot's access token. The receiver code already validates
  the JWT — you're adding a response branch.
- **Posting Adaptive Cards.** Change the body in `send-dm.sh` to wrap the
  card payload in an `attachments` array. Use the Adaptive Cards designer
  (<https://adaptivecards.io/designer/>) to author the JSON, then paste
  it as the `content` field.
- **Mentioning the user.** Pull `from.name` and `from.id` from the cached
  conversation reference (they're already captured). Add an `entities`
  array to the activity body with a `mentionedUser` entry, and inline
  `<at>{name}</at>` in the `text`.
- **Multiple users.** Change the receiver to write one row per
  `from.aadObjectId` (key the KV / Table Storage by user). Change the
  fetch + send helpers to accept a `--user` argument and look up the
  per-user reference.

## Resolved issues / known traps

Log new quirks here as you hit them. Each entry: date, symptom, root cause,
fix.

| Date | Symptom | Root cause | Fix |
|---|---|---|---|
| _none yet_ | | | |
