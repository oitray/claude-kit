# [Service Name] Runbook

> **Owner:** [name] | **Last verified:** [YYYY-MM-DD]

## Auth

- **Method:** [OAuth2 / API key / CLI login / bearer token / Basic Auth / etc.]
- **Vault:** [`<credential-vault>` / `<credential-vault>` / `<credential-vault>` / N/A]
- **Secret name:** [`EXACT-SECRET-NAME` in vault / N/A]
- **Env var:** [`$ENV_VAR_NAME` after fetch / N/A]
- **Fetch creds:** [`eval "$($HOME/.claude/scripts/fetch-secrets.sh <server>)"`] or [manual command / N/A — browser auth / n8n credential only]
- **MCP server:** [MCP server name if applicable, or N/A]

> **Convention:** Vault secret names are UPPERCASE-HYPHEN (env var underscores converted to hyphens, case preserved). The `fetch-secrets.sh` script handles this mapping automatically via `catalog.json`.

## Common Operations

[5-10 most frequent operations with exact commands/params]

### Via API / CLI

```bash
# example command
```

### Via MCP

| Operation | MCP Tool |
|-----------|----------|
| ... | `mcp__server__tool_name` |

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| ... | ... |

## Gotchas

- [Known issues, format quirks, auth pitfalls, things that silently fail]

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| [error message or observed behavior] | [exact fix — command, config change, or workaround] |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| YYYY-MM-DD | [exact symptom] | [why — config, API change, missing permission] | [command/change that fixed it] |
