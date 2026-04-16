# GitHub API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-15

## Auth

- **Method:** GitHub CLI OAuth (`gh`) for interactive; Personal Access Token for MCP + orchestrator agent
- **MCP server:** `github` — full repo, PR, issue, and code search tools
- **Repo:** `<your-org>/automations` (private)
- **Actions secrets:** Managed via `gh secret set` or repo settings UI

### Token inventory

| Name | Vault | Used by | Scope |
|------|-------|---------|-------|
| `GITHUB-PERSONAL-ACCESS-TOKEN` | `<credential-vault>` | MCP server, local dev (`fetch-secrets.sh github`) | broad user PAT |
| `github-pat-orchestrator` | `<credential-vault>` | Azure Container App agent for `git fetch` of pinned SHAs | repo R/W on `<your-org>/automations` |
| `github-webhook-secret` | `<credential-vault>` | Functions `/api/github` HMAC validation | n/a |

### PAT provisioning (no web UI)

GitHub's fine-grained PAT create API requires 2FA + browser — it cannot be scripted. Options, ranked:

1. **Reuse `gh` CLI OAuth token** (`gho_*`, scopes: `repo, workflow, read:org, delete_repo, gist`). Programmatic, tied to the logged-in user. Good for bootstrap; rotate before production.
   ```bash
   TOK=$(gh auth token)
   AZURE_CONFIG_DIR=~/.azure-admin az keyvault secret set \
     --vault-name <credential-vault> \
     -n github-pat-orchestrator \
     --value "$TOK" \
     --tags purpose="orchestrator agent" origin="gh CLI OAuth" rotate-by="<YYYY-MM-DD>"
   ```
2. **Fine-grained PAT via web UI** (required for least-privilege production). Settings → Developer settings → Fine-grained tokens → New. Resource owner: `<your-org>` (needs org approval), repository: `automations`, permissions: Contents RW, Pull requests RW, Issues RW, Metadata R. Expiration: 90 days. Then `az keyvault secret set` as above.
3. **GitHub App** (v2). Long-term replacement; install on `<your-org>/automations` and exchange app JWT for installation tokens inside the agent. Out of scope for phase 0.

### Using the PAT in a git fetch

```bash
set +x  # do NOT echo the cmdline once secrets load
git init /work && cd /work
git config --global credential.helper '!f() { echo "username=x-access-token"; echo "password=$GITHUB_PAT"; }; f'
git remote add origin https://github.com/<your-org>/automations.git
git fetch --depth 1 origin "$PINNED_SHA"
git checkout FETCH_HEAD
```

PAT passed via credential helper, never embedded in URL. Works for arbitrary commit SHAs (unlike `clone --branch`).

### Rotation

- **Cadence:** 90 days for PATs, auto-refresh for GitHub App installations.
- **Procedure:** `az keyvault secret set` with the new value. Container App picks up new value on next cold start (`az containerapp revision restart` if urgent).
- **Audit:** Tag every secret write with `rotate-by=<YYYY-MM-DD>`; a future reconcile Function will DM when rotations are due.

## Common Operations

### Via API / CLI

#### Pull Requests

```bash
gh pr create --title "Title" --body "Description"
gh pr list --state open
gh pr view 123
gh pr merge 123 --squash
gh pr checks 123
```

#### Issues (disabled on this repo — use ClickUp instead)

```bash
gh issue list --repo <your-org>/automations  # returns nothing, issues disabled
```

#### Releases & Tags

```bash
gh release list
gh release create v1.0.0 --title "Release" --notes "Description"
```

#### Repo Secrets

```bash
gh secret set SECRET_NAME --body "value" --repo <your-org>/automations
gh secret list --repo <your-org>/automations
```

#### View PR Comments (API)

```bash
gh api repos/<your-org>/automations/pulls/123/comments
```

### Via MCP

| Operation | MCP Tool |
|-----------|----------|
| Get file contents | `mcp__github__get_file_contents` |
| Search code | `mcp__github__search_code` |
| Create PR | `mcp__github__create_pull_request` |
| Get PR status | `mcp__github__get_pull_request_status` |
| List commits | `mcp__github__list_commits` |
| Create/update file | `mcp__github__create_or_update_file` |
| Add issue comment | `mcp__github__add_issue_comment` |

## GitHub Actions Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `apex-lint.yml` | PR | Apex static analysis |
| `secret-scan.yml` | Push | Blocks committed secrets |
| `weekly-metadata-sync.yml` | Cron (weekly) | Retrieves SF org metadata |
| `announce-to-teams.yml` | Push to `docs/announcements.md` | Posts staff announcement |
| `teams-notify.yml` | Push to main | Changelog to Teams |
| `auto-fix.yml` | PR | Automated lint fixes |
| `auto-merge.yml` | PR | Auto-merge approved PRs |
| `validate-commands.yml` | PR | Validates `.claude/commands/` |

### Re-run a failed workflow

```bash
gh run list --workflow=apex-lint.yml --limit 5
gh run rerun 12345678
```

### View workflow logs

```bash
gh run view 12345678 --log
```

## <your-org>-Specific IDs

| Resource | Value |
|----------|-------|
| Primary repo | `<your-org>/automations` |
| Teams webhook secret | `TEAMS_WEBHOOK_URL` (repo secret) |
| Task tracking | ClickUp (not GitHub Issues) |

## Gotchas

- **Issues are disabled** on this repo. All tasks go in ClickUp A&E list `<clickup-list-id>`.
- **`gh` auth expires** — re-auth with `gh auth login` if you get 401s.
- **Rate limits:** 5,000 requests/hour for authenticated API calls. MCP tools count toward this.
- **Secret scan** runs on every push — will block commits containing API keys, tokens, or credentials.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `gh` returns 401 | Token expired. Re-auth: `gh auth login` |
| `gh` returns 403 rate limit | 5,000 req/hr limit. Check `gh api rate_limit` or wait |
| Secret scan blocks push | Remove secret from commit. `git rebase -i` to amend, or `git filter-branch` if already pushed |
| MCP github tools fail | `GITHUB-PERSONAL-ACCESS-TOKEN` missing or expired. Re-fetch via `fetch-secrets.sh github` |
| `gh issue list` returns empty | Issues are disabled on this repo — use ClickUp A&E list `<clickup-list-id>` instead |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
