# teams-dm-bot — Claude DMs you in Microsoft Teams

A working skeleton: deploy → sideload → say "hi" → run a command → your message lands in Teams.

**Full guide:** `runbooks/teams-bot-dm.md` (read this first).

## What's here

| Path | Purpose |
|---|---|
| `manifest/` | Teams app manifest + icons + zip helper |
| `worker/` | Cloudflare Workers receiver (primary) |
| `functions/` | Azure Functions Python alternative (use one or the other) |
| `bin/fetch-conv-ref.sh` | One-shot: pull the cached conversation reference into `~/.config/teams-dm/` |
| `bin/send-dm.sh` | Send a DM from anywhere on your machine |

## 60-second quickstart

1. Read the runbook. Seriously — it explains *why* the bootstrap dance exists.
2. Create an Azure Bot resource (F0, free) + AAD app registration. Capture the App ID, tenant ID, and a client secret.
3. Deploy the Worker:
   ```bash
   cd worker
   wrangler kv:namespace create CONV_REF       # paste the id into wrangler.toml
   wrangler secret put BOT_APP_ID
   wrangler secret put BOT_APP_SECRET
   wrangler secret put <credential-env>
   wrangler secret put SETUP_SECRET            # any random string
   wrangler deploy
   ```
4. Point Bot Service messaging endpoint → `https://<your-worker>.workers.dev/api/messages`.
5. Edit `manifest/manifest.json` (`{{BOT_APP_ID}}`, `{{BOT_NAME}}`) → `manifest/make-zip.sh` → sideload in Teams (Apps → Manage your apps → Upload an app).
6. DM the bot once with "hi". Wrangler tail should show a 200.
7. Pull the conv reference + write env file:
   ```bash
   WORKER_URL=https://<your-worker>.workers.dev \
   SETUP_SECRET=<the value you wrangled> \
     ./bin/fetch-conv-ref.sh

   cat > ~/.config/teams-dm/env <<EOF
   BOT_APP_ID=<app id>
   BOT_APP_SECRET=<client secret>
   <credential-env>=<tenant id>
   EOF
   chmod 600 ~/.config/teams-dm/env
   ```
8. Send:
   ```bash
   ./bin/send-dm.sh "Claude says hi"
   ./bin/send-dm.sh --markdown "**deploy** finished in _42s_"
   ```

## When it doesn't work

See the runbook's gotcha catalog. The most common: messaging endpoint missing `/api/messages` suffix, `Microsoft.BotService` provider not registered in the subscription, tenant policy blocking custom app upload.

## Wiring it into Claude Code

Pick one:
- Shell hook: a Claude Code `Stop` hook that calls `send-dm.sh` when a session ends
- Slash command: a `/dm "..."` command that wraps `send-dm.sh`
- Inline: ask Claude to run `bash <path>/send-dm.sh "message"` directly

The send helper has no dependencies on Claude — it works from any process with `curl`, `python3`, and the env file readable.
