# Firecrawl Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-17

## Auth

- **Method:** API key (Bearer token)
- **Vault:** `<credential-vault>`
- **Secret name:** `FIRECRAWL-API-KEY` (starts with `fc-`)
- **Env var:** `$FIRECRAWL_API_KEY`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh firecrawl)"`
- **Dashboard:** https://firecrawl.dev/app
- **API base:** `https://api.firecrawl.dev/v1`

## Plan & Limits

| Field | Value |
|-------|-------|
| Plan | Hobby ($9/mo) |
| Credits/month | 3,000 |
| Concurrency | 5 |
| Rate limit | 20 req/min |

### Credit Costs

| Operation | Credits |
|-----------|---------|
| Scrape (1 page) | 1 |
| Search (10 results) | 2 |
| Browser (per min) | 2 |
| Agent run | 5 free/day, then dynamic |
| Crawl | 1 per page crawled |
| Map | 1 |
| Extract | 5 |

## Common Operations

### Via API / CLI

```bash
# Scrape a page to markdown
curl -X POST https://api.firecrawl.dev/v1/scrape \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com", "formats": ["markdown"]}'

# Search the web
curl -X POST https://api.firecrawl.dev/v1/search \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "fortigate sip alg disable", "limit": 5}'

# Extract structured data with schema
curl -X POST https://api.firecrawl.dev/v1/scrape \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com/pricing",
    "formats": ["json"],
    "jsonOptions": {
      "schema": {
        "type": "object",
        "properties": {
          "plans": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "name": {"type": "string"},
                "price": {"type": "string"},
                "features": {"type": "array", "items": {"type": "string"}}
              }
            }
          }
        }
      }
    }
  }'

# Check credit usage
curl https://api.firecrawl.dev/v1/team/credit-usage \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY"
```

## <your-org>-Specific IDs

| Resource | Value |
|----------|-------|
| API key vault secret | `FIRECRAWL-API-KEY` in `<credential-vault>` |
| OCC catalog key | `firecrawl` |
| Dashboard | https://firecrawl.dev/app |

## Gotchas

- **`onlyMainContent: true`** is recommended for most scrapes — without it you get nav bars, footers, sidebars mixed into the markdown
- **JS-rendered SPAs** may return empty content — use `waitFor: 5000` (ms) to let JS execute before scraping
- **JSON extraction returns empty?** The page is likely an SPA. Try `waitFor: 10000` first, then fall back to markdown format
- **Credit monitoring** — no built-in alerts. Check `v1/team/credit-usage` endpoint or dashboard manually. At 3,000/mo on Hobby, a full site crawl can burn through credits fast
- **Rate limit is 20 req/min** — batch scrape or crawl operations handle this internally, but rapid sequential `firecrawl_scrape` calls from n8n workflows may hit it
- **Crawl is async** — `POST /v1/crawl` returns a job ID immediately. Poll `GET /v1/crawl/{id}` to get results. Don't assume instant completion.
- **`formats` is an array** — pass `["markdown"]` not `"markdown"`

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Scrape returns empty/minimal content | Page is likely an SPA. Add `waitFor: 5000` (or 10000) to let JS render |
| JSON extraction returns empty | SPA issue. Try `waitFor: 10000` first, then fall back to markdown format |
| 429 Too Many Requests | Rate limit is 20 req/min. Space requests or use batch operations |
| Credits burned unexpectedly | Full site crawls consume 1 credit/page. Check `v1/team/credit-usage` endpoint |
| 401 Unauthorized | Token expired. Re-fetch via `fetch-secrets.sh firecrawl` |
| Markdown contains nav/footer junk | Set `onlyMainContent: true` |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
