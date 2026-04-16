# Credential Vault Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-15

A **credential vault** is whatever managed secret store your environment uses to hold API keys, tokens, and client secrets for MCP servers, CLI tools, and automations. This runbook describes the generic pattern — pick a backend from the "Supported backends" table and substitute its CLI / SDK where noted.

## Supported backends

| Backend | Auth | Read command (shape) | Write command (shape) |
|---------|------|----------------------|------------------------|
| Azure Key Vault | `az login` (OAuth / SP) | `az keyvault secret show --vault-name <vault> --name <secret> --query value -o tsv` | `az keyvault secret set --vault-name <vault> --name <secret> --value <value>` |
| AWS Secrets Manager | `aws configure` / IAM role | `aws secretsmanager get-secret-value --secret-id <secret> --query SecretString --output text` | `aws secretsmanager put-secret-value --secret-id <secret> --secret-string <value>` |
| HashiCorp Vault | `vault login` (token / OIDC) | `vault kv get -field=value secret/<path>` | `vault kv put secret/<path> value=<value>` |
| 1Password CLI | `op signin` (biometric / service account) | `op read "op://<vault>/<item>/<field>"` | `op item edit "<item>" "<field>=<value>"` |

Pick one, stick with it for a given environment, and document the choice in your catalog or team runbook.

## Auth

- **Method:** backend-native (OAuth, IAM, token, biometric — see table above)
- **Vault:** `<credential-vault>` (one per user / env), plus separate vaults for bot or shared credentials as needed
- **Secret name:** stored in the vault itself — this IS the credential source
- **Env var:** N/A at the vault layer; each fetched secret is exported to its own env var
- **Fetch creds:** `AZURE_CONFIG_DIR=<your-config-dir> az login` (one-time) for Azure, or the equivalent bootstrap for your chosen backend
- **MCP server:** N/A — access via the backend CLI / SDK directly
- **Vault config:** `~/.claude/.vault-config.json` (or equivalent) — records which vault name to use per environment

## The fetch-secrets helper

**Location:** `~/.claude/scripts/fetch-secrets.sh` (suggested path)

Fetches secrets for a given MCP server at startup. Outputs `export KEY=value` lines so the caller can `eval` them.

### Usage

```bash
eval "$($HOME/.claude/scripts/fetch-secrets.sh <server-name>)"
```

### How it works

1. Reads `catalog.json` to find which secrets the server needs
2. Resolves vault name from `~/.claude/.vault-config.json` or a `$USER_VAULT` env var
3. Fetches each secret via the backend CLI / SDK
4. Outputs `export` statements for eval

### Catalog resolution order

1. `$CATALOG` env var
2. `repo` field in `~/.claude/.vault-config.json` → `{repo}/catalog.json`
3. Script's parent directory → `catalog.json`
4. `~/.claude/catalog.json`

### Vault resolution order

1. `userVault` field in `~/.claude/.vault-config.json`
2. `$USER_VAULT` env var
3. Backend-native default (e.g. `az account show` username → `<credential-vault>`)

## Common Operations

### Read a secret directly

```bash
# Azure Key Vault
az keyvault secret show --vault-name <credential-vault> --name SECRET-NAME --query value -o tsv

# AWS Secrets Manager
aws secretsmanager get-secret-value --secret-id SECRET-NAME --query SecretString --output text

# HashiCorp Vault
vault kv get -field=value secret/SECRET-NAME

# 1Password CLI
op read "op://<credential-vault>/SECRET-NAME/value"
```

### List all secrets in a vault

```bash
# Azure
az keyvault secret list --vault-name <credential-vault> --query "[].name" -o tsv

# AWS
aws secretsmanager list-secrets --query "SecretList[].Name" --output text

# HashiCorp
vault kv list secret/

# 1Password
op item list --vault <credential-vault>
```

### Set a secret

```bash
# Azure
az keyvault secret set --vault-name <credential-vault> --name SECRET-NAME --value "the-value"

# AWS
aws secretsmanager put-secret-value --secret-id SECRET-NAME --secret-string "the-value"

# HashiCorp
vault kv put secret/SECRET-NAME value="the-value"

# 1Password
op item create --category=password --title=SECRET-NAME --vault=<credential-vault> password="the-value"
```

## Secret naming convention

**Vault secret names are UPPERCASE-HYPHEN** — the same case as the env var name, with underscores converted to hyphens. Examples:

| Env var | Vault secret |
|---------|--------------|
| `API_TOKEN` | `API-TOKEN` |
| `CLICKUP_API_KEY` | `CLICKUP-API-KEY` |
| `HELPJUICE_API_KEY` | `HELPJUICE-API-KEY` |

The fetch script handles the `_` → `-` substitution. The `catalog.json` maps each MCP server to its required secrets (env var names).

## Runtime vault fetch from automation tools (n8n example)

Automation platforms that need per-execution secrets can call the backend API directly using a service principal / IAM role / app credential:

```
# Azure example — obtain access token, then fetch the secret
POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
  grant_type=client_credentials
  client_id={SP_CLIENT_ID}
  client_secret={SP_CLIENT_SECRET}
  scope=https://vault.azure.net/.default

GET https://<credential-vault>.vault.azure.net/secrets/{SECRET-NAME}?api-version=7.4
  Authorization: Bearer {token}
```

Equivalents exist for each backend (AWS STS AssumeRole + Secrets Manager, Vault AppRole, 1Password service accounts). **Never cache fetched secrets in workflow static data** — fetch per execution.

## Gotchas

- **Backend login required** before any vault operations. Sessions expire — re-login when you get auth errors.
- **No `.env` fallback.** All MCP server secrets come from the vault. If the vault is unreachable, the server won't start.
- **Secret names != env var names.** The catalog maps vault secret names to env var names (e.g. vault `API-TOKEN` → env `API_TOKEN`). Underscores in env vars become hyphens in vault names; case is preserved.
- **Isolate CLI configs for concurrent sessions.** For Azure, use `AZURE_CONFIG_DIR=<your-config-dir>`; AWS uses `AWS_PROFILE`; Vault uses `VAULT_ADDR` + `VAULT_TOKEN`. Don't let concurrent sessions stomp on each other's default config.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Vault CLI returns auth error | Session expired. Re-login with the backend-native command |
| Fetch script outputs nothing | Verify login, verify `catalog.json` has the server entry |
| `WARNING — KEY not found in vault` | The secret doesn't exist, OR the catalog's env var name produces a hyphen-name that doesn't match the vault. List actual names and compare |
| Concurrent sessions stomp each other's config | Always use an isolated config dir / profile — never bare login |
| Bot / shared vault access denied | Grant the correct role (Azure: `Key Vault Secrets User`; AWS: `secretsmanager:GetSecretValue`; etc.) to the service principal / role |

## Resolved Issues

> Log fixes here when a vault call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-15 | Initial generic runbook | Derived from an Azure-Key-Vault-specific runbook | Parameterized for any supported backend |
