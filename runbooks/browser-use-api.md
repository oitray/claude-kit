# Browser Use Cloud API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-25

AI-powered browser automation. Submit a natural-language task; Browser Use's hosted stealth Chromium agent executes it and returns structured results. Use for portal-only flows where SF/Graph/CLI APIs don't exist (vendor admin consoles, SaaS dashboards without APIs, login-walled scrapes).

## Auth

- **Method:** API key header `X-Browser-Use-API-Key: bu_...`
- **Vault:** `<credential-vault>`
- **Secret name:** `BROWSER-USE-API`
- **Env var:** `BROWSER_USE_API_KEY`
- **Fetch creds:**
  ```bash
  export BROWSER_USE_API_KEY=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show \
    --vault-name <credential-vault> --name BROWSER-USE-API --query value -o tsv)
  ```
- **MCP server:** installed (user-scope, `mcp__browser-use__*` tools — see Integrations below)
- **Base URL:** `https://api.browser-use.com/api/v3`

> **v3 only.** v2 is legacy with different method names — never use for new code.

## Common Operations

### Run a one-shot task (curl)

```bash
curl -X POST https://api.browser-use.com/api/v3/sessions \
  -H "X-Browser-Use-API-Key: $BROWSER_USE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"task": "Go to news.ycombinator.com and list the top 5 story titles"}'
```

Response includes `session.id`. Poll `GET /sessions/{id}` until `status` ∈ `{idle, stopped, error, timed_out}`, then read `output`.

### Python SDK

```bash
pip install --upgrade browser-use-sdk
```

```python
import asyncio
from browser_use_sdk.v3 import AsyncBrowserUse
from pydantic import BaseModel

class Story(BaseModel):
    title: str
    points: int

class HN(BaseModel):
    stories: list[Story]

async def main():
    client = AsyncBrowserUse()  # reads BROWSER_USE_API_KEY
    result = await client.run(
        "Top 5 HN stories with points",
        model="claude-sonnet-4.6",
        output_schema=HN,
    )
    for s in result.output.stories:
        print(s.title, s.points)

asyncio.run(main())
```

### TypeScript SDK

```bash
npm install browser-use-sdk@latest zod@4
```

```typescript
import { BrowserUse } from "browser-use-sdk/v3";
import { z } from "zod";

const client = new BrowserUse();
const Schema = z.object({ stories: z.array(z.object({ title: z.string(), points: z.number() })) });
const result = await client.run("Top 5 HN stories with points", {
  model: "claude-sonnet-4.6",
  schema: Schema,
});
console.log(result.output.stories);
```

### Multi-task session (reuse browser/cookies)

```python
session = await client.sessions.create()
await client.run("Go to amazon.com, search laptops, open first result", session_id=session.id)
await client.run("Extract reviews", session_id=session.id)
await client.sessions.stop(session.id)
```

### Cancel running task (keep session alive)

```python
await client.sessions.stop(session_id, strategy="task")  # session returns to idle
```

### Manual polling loop

```python
cursor = None
while True:
    msgs = await client.sessions.messages(session.id, after=cursor, limit=100)
    for m in msgs.messages:
        cursor = m.id
    s = await client.sessions.get(session.id)
    if s.status.value in ("idle", "stopped", "error", "timed_out"):
        break
    await asyncio.sleep(2)
```

## Models

| Model string | Input $/M | Output $/M | Notes |
|---|---|---|---|
| `claude-sonnet-4.6` | $3.60 | $18.00 | **Default — recommended** |
| `claude-opus-4.6` | $6.00 | $30.00 | Hardest reasoning |
| `gpt-5.4-mini` | $0.90 | $5.40 | Cheapest |

## Browser Capabilities

- **Stealth Chromium fork** — bypasses most bot detection
- **Residential proxies in 195+ countries** — on by default
- **Live preview/recording** — embeddable iframe of agent's browser
- **CDP attach** — connect Playwright/Puppeteer/Selenium to a Browser Use session for hybrid scripted+agent flows
- **Profiles** — persistent cookies/localStorage; log in once, reuse
- **Profile sync** — push local browser cookies up to cloud
- **Human-in-the-loop** — pause for human approval/2FA/payment in the live browser
- **Workspaces** — upload files for agent to read; download files agent creates

## Integrations

| Surface | Use when |
|---|---|
| **REST API / SDK** | Python or Node service, custom orchestration — default choice |
| **MCP server** | Want to invoke from Claude Code interactively (`docs.browser-use.com/cloud/guides/mcp-server`) |
| **n8n** | HTTP node in workflows (`docs.browser-use.com/cloud/tutorials/integrations/n8n`) |
| **Webhooks** | Async monitoring, fire on task complete (`docs.browser-use.com/cloud/guides/webhooks`) |

## When to Use vs. Existing Tools

See `.claude/rules/browser-automation.md` for the canonical decision rule (auth ladder → Axis A surface → Axis B invocation → anti-patterns). Don't duplicate the table here.

## Gotchas

- **v3 only.** SDK imports must be `browser_use_sdk.v3` / `browser-use-sdk/v3`. v2 has different method names and silently produces wrong shapes.
- **Zod v4 required** for TypeScript structured output. v3 of zod is incompatible.
- **`result` is only available after iterator finishes.** Breaking early from `async for` leaves the task running — call `stop(strategy="task")` first.
- **Never send the API key to any host other than `api.browser-use.com` or `cloud.browser-use.com`.**
- **Cost is real.** Each agent step makes LLM calls. For repeat scrapes, use deterministic rerun (`cache-script`) — first run trains, subsequent runs are $0 LLM.
- **Proxies on by default** — disable only when target requires direct IP (rare).

## Troubleshooting

| Symptom | Resolution |
|---|---|
| `401 Unauthorized` | Key missing/wrong header. Must be `X-Browser-Use-API-Key` (not `Authorization`); key prefix `bu_`. |
| Task hangs at login wall | Use Profiles (one-time human login) or HITL pattern |
| Structured output validation fails | Schema too strict — start with looser types, tighten after first successful run |
| TS error "zod schema not assignable" | Upgrade to `zod@4` |
| Ran out of credits | Check dashboard `cloud.browser-use.com`; switch model to `gpt-5.4-mini` for cost-sensitive tasks |

## Resolved Issues

| Date | Issue | Root Cause | Fix |
|---|---|---|---|
| — | — | — | — |

## Reference Links

- llms.txt (this index): https://docs.browser-use.com/cloud/llms.txt
- llms-full.txt (every code example inline): https://docs.browser-use.com/cloud/llms-full.txt
- OpenAPI v3 spec: https://docs.browser-use.com/cloud/openapi/v3.json
- Dashboard: https://cloud.browser-use.com
- Quickstart: https://docs.browser-use.com/cloud/quickstart
- Chat UI tutorial (best end-to-end example): https://docs.browser-use.com/cloud/tutorials/chat-ui
