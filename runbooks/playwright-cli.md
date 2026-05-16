# Playwright CLI Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-17

## Auth

- **Method:** None — no API keys or auth required
- **Vault:** N/A
- **Secret name:** N/A
- **Env var:** N/A
- **Fetch creds:** N/A
- **CLI binary:** `playwright-cli` (npm: `@playwright/cli`)

## Why CLI over MCP

| Dimension | CLI (`@playwright/cli`) | MCP (`@playwright/mcp`) |
|-----------|------------------------|------------------------|
| Token efficiency | Higher — concise shell commands, no schemas forced into context | Lower — loads accessibility trees per call |
| Reliability | Direct shell execution, no protocol layer | MCP transport (stdio) can timeout or drop state |
| Session management | Named sessions, persistent profiles | Persistent context maintained by MCP server |
| Monitoring | `playwright-cli show` visual dashboard | Depends on client |
| Maturity | v0.1.6 (newer, actively pushed by Microsoft) | v0.0.70 (more established, 3M weekly downloads) |

Microsoft recommends CLI for coding agents, MCP for long-running autonomous workflows.

## Installation

```bash
npm install -g @playwright/cli
npx playwright install chromium
```

Verify: `playwright-cli --version`

## Common Operations

### Via CLI

```bash
# Open a URL in browser
playwright-cli open https://example.com

# Navigate to URL in existing session
playwright-cli goto https://example.com -s=mysession

# Take a screenshot
playwright-cli screenshot -s=mysession --output screenshot.png

# Save page as PDF
playwright-cli pdf -s=mysession --output page.pdf

# Get page snapshot (accessibility tree)
playwright-cli snapshot -s=mysession

# Click an element
playwright-cli click "text=Submit" -s=mysession

# Fill a form field
playwright-cli fill "input[name=email]" "user@example.com" -s=mysession

# Type text (keystroke by keystroke)
playwright-cli type "search input" "query text" -s=mysession

# Press a key
playwright-cli press Enter -s=mysession

# Evaluate JavaScript
playwright-cli eval "document.title" -s=mysession

# List active sessions
playwright-cli list

# Close a session
playwright-cli close -s=mysession

# Close all sessions
playwright-cli close-all

# Visual dashboard (live screencast of all sessions)
playwright-cli show
```

### Session Management

```bash
# Named session (reusable across commands)
playwright-cli open https://example.com -s=research
playwright-cli goto https://other.com -s=research
playwright-cli close -s=research

# Persistent profile (saves cookies, localStorage)
playwright-cli open https://example.com --persistent

# Set default session via env var
export PLAYWRIGHT_CLI_SESSION=default
```

### Tab Management

```bash
# List tabs
playwright-cli tab-list -s=mysession

# Open new tab
playwright-cli tab-new https://example.com -s=mysession

# Switch tab
playwright-cli tab-select 2 -s=mysession

# Close tab
playwright-cli tab-close -s=mysession
```

## <your-org>-Specific IDs

| Resource | Value |
|----------|-------|
| CLI package | `@playwright/cli` v0.1.6 |
| Browser cache | `~/Library/Caches/ms-playwright/` |

## Gotchas

- **CLI is v0.1.6** — early release, may have rough edges.
- **Sessions are ephemeral by default** — use `-s=name` for named sessions or `--persistent` for saved state (cookies, localStorage).
- **`playwright-cli show`** opens a visual dashboard — requires a display. Won't work over headless SSH.
- **Browser binaries:** `npx playwright install chromium` installs the browser needed by the CLI.
- **Selectors:** CLI uses the same selector engine as Playwright: `text=`, `css=`, `role=`, `data-testid=`. If unsure, use `snapshot` first to see the accessibility tree.
- **`codegen` is on the core `playwright` package**, not `@playwright/cli`. Use `npx playwright codegen https://example.com` to record and generate code.
- **Verify <internal-bot> changes via Playwright, not manually.** After deploying n8n workflow changes that affect bot responses (RAG, routing, features), write a Playwright spec in `tests/playwright/` to send messages and verify responses. Use `waitForNewBotBubble` from `helpers/teams.ts`. Delete the test file after verification.
- **ONLY target <your-name>'s DM for <internal-bot> tests.** Always use `CLOUDIE_CONVO_URL` from `tests/playwright/.env`. Never construct conversation URLs from user IDs or navigate to other chats — test messages have been accidentally sent to other users' DMs in the past.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `playwright-cli: command not found` | Install: `npm install -g @playwright/cli` |
| Browser launch fails | Install browsers: `npx playwright install chromium` |
| `playwright-cli show` hangs over SSH | Requires a display. Won't work headless |
| CLI command fails unexpectedly | v0.1.6 is early release. Check `playwright-cli --version` and update if needed |
| `codegen` not found on `playwright-cli` | `codegen` is on core `playwright` package: `npx playwright codegen https://example.com` |
| Empty selector match | Use `snapshot` first to see accessibility tree, then target with `text=`, `role=`, or `data-testid=` |

## Cloudflare Turnstile

Cloudflare Turnstile flags any Playwright-launched Chromium as automation, regardless of `--user-data-dir`, `channel: 'msedge'`, or `headless: false`. The hidden `input[name="cf-turnstile-response"]` never gets a token, the form rejects with "Please complete the verification challenge", and even a subsequent human click on the checkbox often fails.

**Workaround: CDP attach mode.**

```bash
# 1. User launches Edge with debug port (NOT Playwright-launched)
"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/playwright-edge-cdp

# 2. Script attaches via CDP — Edge has no automation flags
const browser = await chromium.connectOverCDP('http://localhost:9222');
const ctx = browser.contexts()[0];
const page = ctx.pages()[0] ?? await ctx.newPage();
```

**Detection: poll for the token, never auto-click.**

```typescript
const tokenIsValid = async () => {
  const v = await page.locator('input[name="cf-turnstile-response"]').first()
    .evaluate((el: any) => el.value);
  return typeof v === 'string' && v.length > 20;
};
// Poll up to 5 min — token usually appears within 0–2s on CDP-attached Edge
while (Date.now() - start < 300000) {
  if (await tokenIsValid()) break;
  await sleep(1500);
}
```

**Anti-pattern:** `page.mouse.click(x, y)` on the checkbox before the token appears. Cloudflare scores the synthesized click as automation and refuses to issue a token even on a subsequent human click. Empty out any auto-click logic — let the page sit and either Turnstile auto-passes (CDP mode) or the human clicks (Playwright-launched mode).

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
