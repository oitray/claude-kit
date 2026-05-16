# GitHub Actions OIDC for Azure

> **Owner:** <your-name> | **Last verified:** 2026-05-05

Migration pattern from legacy `AZURE_CREDENTIALS` JSON secret → OIDC federated credentials. No long-lived secrets, no rotation overhead.

## Why migrate

- `AZURE_CREDENTIALS` SP secrets expire silently. CI fails with `AADSTS700016: Application not found in '<your-org>' tenant`.
- OIDC tokens are short-lived (1 hour) and federated to a specific repo + branch/PR subject. No rotation.
- Modern `azure/login@v2` action uses OIDC by default.

## Reuse the existing <your-org> SP

The <your-org> automations SP `gh-orchestrator-automations` (appId `<azure-uuid>`) is already federated for `<your-org>/automations` and `<your-org>/CloudieMcCloudieBot`. To federate a new repo:

```bash
APP_ID=<azure-uuid>
APP_OBJ_ID=$(AZURE_CONFIG_DIR=~/.azure-admin az ad app show --id "$APP_ID" --query id -o tsv)
NEW_REPO=<your-org>/<repo>

# main branch
cat > /tmp/fed-main.json <<EOF
{
  "name": "github-${NEW_REPO//\//-}-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${NEW_REPO}:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
AZURE_CONFIG_DIR=~/.azure-admin az ad app federated-credential create \
  --id "$APP_OBJ_ID" --parameters /tmp/fed-main.json

# pull_request from any branch (CI on PR)
cat > /tmp/fed-pr.json <<EOF
{
  "name": "github-${NEW_REPO//\//-}-pr",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${NEW_REPO}:pull_request",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
AZURE_CONFIG_DIR=~/.azure-admin az ad app federated-credential create \
  --id "$APP_OBJ_ID" --parameters /tmp/fed-pr.json || true
```

Verify SP perms on the target resource group + ACR:
```bash
SP_OBJ_ID=$(AZURE_CONFIG_DIR=~/.azure-admin az ad sp show --id "$APP_ID" --query id -o tsv)
SUB=<azure-uuid>

AZURE_CONFIG_DIR=~/.azure-admin az role assignment list --assignee "$SP_OBJ_ID" \
  --scope "/subscriptions/$SUB/resourceGroups/<rg>" -o table
```

If missing Container Apps Contributor / AcrPush, grant via `az role assignment create` per usual.

## Set GH secrets in the new repo

```bash
SUB_ID=<azure-uuid>
TENANT_ID=$(AZURE_CONFIG_DIR=~/.azure-admin az account show --query tenantId -o tsv)
CLIENT_ID=$APP_ID

gh secret set <credential-env> -R <your-org>/<repo> --body "$CLIENT_ID"
gh secret set <credential-env> -R <your-org>/<repo> --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID -R <your-org>/<repo> --body "$SUB_ID"
gh secret delete AZURE_CREDENTIALS -R <your-org>/<repo> 2>/dev/null || true
```

## Update the workflow

```yaml
# Workflow-level permissions REQUIRED for OIDC
permissions:
  id-token: write
  contents: read

# Replace any azure/login@v1 + creds: AZURE_CREDENTIALS with:
- uses: azure/login@v2
  with:
    client-id: ${{ secrets.<credential-env> }}
    tenant-id: ${{ secrets.<credential-env> }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

Verify the next workflow run shows `Azure CLI login succeeds by using OIDC` in the login step. ACR login + `az containerapp update` work as before.

## When OIDC isn't available (legacy fallback)

If a workflow target requires the legacy JSON-SP shape (some old actions don't support OIDC), create a NEW SP per repo (don't reuse the federated automations SP) and pin its expiry < 90d so it's rotated regularly. <your-org> has no current example of this — OIDC is the default.

## Last verified

2026-05-05 — migrated `<your-org>/CloudieMcCloudieBot` (PR #51).
