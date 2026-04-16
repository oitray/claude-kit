# Anthropic Messages API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-11

## Auth

- **Method:** API key (`x-api-key` header — NOT Bearer token)
- **Vault:** `<credential-vault>`
- **Secret name:** `ANTHROPIC-API-KEY` (verify: `az keyvault secret show --vault-name <credential-vault> --name ANTHROPIC-API-KEY`)
- **Env var:** `$ANTHROPIC_API_KEY`
- **Fetch creds:** Not in `fetch-secrets.sh` catalog — manual fetch: `export ANTHROPIC_API_KEY=$(AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret show --vault-name <credential-vault> --name ANTHROPIC-API-KEY --query value -o tsv)`
- **MCP server:** N/A — no Anthropic MCP server configured
- **n8n credential:** `Anthropic account` (type `anthropicApi`, ID `F9rrVNeo7Oa8gAjU`)
- **GitHub Actions secret:** `ANTHROPIC_API_KEY` (used in `auto-fix.yml`)

## Common Operations

### Via API / CLI

```bash
# Send a message (non-streaming)
curl -s https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 4096,
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'
```

```bash
# Send a message with system prompt
curl -s https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 4096,
    "system": "You are a helpful assistant.",
    "messages": [
      {"role": "user", "content": "Summarize this case."}
    ]
  }'
```

```bash
# Streaming response (SSE)
curl -s https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 4096,
    "stream": true,
    "messages": [
      {"role": "user", "content": "Write a haiku."}
    ]
  }'
```

```bash
# Multi-turn conversation
curl -s https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 4096,
    "messages": [
      {"role": "user", "content": "What is VoIP?"},
      {"role": "assistant", "content": "VoIP stands for Voice over Internet Protocol..."},
      {"role": "user", "content": "How does <your-org> use it?"}
    ]
  }'
```

```bash
# Extract text from response (jq)
curl -s https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "Say hello"}]
  }' | jq -r '.content[0].text'
```

```bash
# Check token usage from response
curl -s https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "Hi"}]
  }' | jq '.usage'
```

### Via MCP

N/A — no Anthropic MCP server configured. All calls go through direct HTTP requests (n8n HTTP Request node or curl).

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| API base URL | `https://api.anthropic.com/v1/messages` |
| Default model | `claude-sonnet-4-20250514` |
| API version header | `anthropic-version: 2023-06-01` |
| Typical max_tokens | `4096` |
| n8n credential name | `Anthropic account` |
| n8n credential ID | `F9rrVNeo7Oa8gAjU` |
| n8n credential type | `anthropicApi` (predefined) |
| GitHub Actions secret | `ANTHROPIC_API_KEY` |
| Azure Key Vault | `<credential-vault>` |

## Active Code Paths

| Location | Usage |
|----------|-------|
| `.github/workflows/auto-fix.yml` | Calls Messages API to generate code fixes for failed CI checks |
| `n8n/<internal-bot>-task-action-router.json` | "Call Anthropic (Task Parse)" node — parses ClickUp task content for routing |

## Gotchas

- **Auth header is `x-api-key`**, not `Authorization: Bearer`. Using Bearer will return 401.
- **`anthropic-version` header is required.** Omitting it returns 400. Current version: `2023-06-01`.
- **Streaming uses Server-Sent Events (SSE)**, not WebSocket. Set `"stream": true` in the request body and parse `data:` lines from the response.
- **Response structure:** Text is in `content[0].text`, not a top-level `text` field. Always access `.content[0].text`.
- **`max_tokens` is required** — the API does not have a default. Omitting it returns 400.
- **Rate limits** are per-API-key. The n8n credential and GitHub Actions secret use the same underlying key — high-volume n8n runs could affect CI.
- **In n8n**, use `predefinedCredentialType: anthropicApi` with the HTTP Request node. The credential automatically sets the `x-api-key` header, but you must still add `anthropic-version` and `Content-Type` as custom headers.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| 401 Unauthorized | Used `Authorization: Bearer` — Anthropic uses `x-api-key` header instead |
| 400 Bad Request on valid-looking request | Missing required header `anthropic-version: 2023-06-01` |
| 400 "max_tokens is required" | `max_tokens` has no default. Always specify (e.g., 4096) |
| Response parsing returns undefined | Text is in `content[0].text`, not a top-level `text` field |
| Rate limit affects CI and n8n | n8n and GitHub Actions share the same API key. High n8n volume can throttle CI runs |
| Streaming response not parsing | SSE format — parse `data:` lines, not JSON directly |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
