# GitHub API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-12

## Auth

- **Method:** GitHub CLI OAuth (`gh`) for interactive; Personal Access Token for orchestrator agent
- **Repo:** `<your-org>/automations` (private)
- **Actions secrets:** Managed via `gh secret set` or repo settings UI

### Token inventory

| Name | Vault | Used by | Scope |
|------|-------|---------|-------|
| `GITHUB-PERSONAL-ACCESS-TOKEN` | `<credential-vault>` | local dev (`fetch-secrets.sh github`) | broad user PAT |
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

## Branch Protection / Rulesets

`main` is protected by repository ruleset `main-required-checks`. Source of truth: `scripts/ci/ruleset-apply.sh`. Created 2026-05-12 per ClickUp <clickup-task-id>.

### Required checks

| Required check (context string) | Source workflow / job | Skip semantics |
|---|---|---|
| `Apex tests + delta coverage gate` | `.github/workflows/apex-test.yml` job `apex-test` | Non-SF PRs: the internal `changes` job sets `sf=false`, the `apex-test` job's `if:` evaluates false, the job is skipped. **docs-confirmed:** [GitHub Actions — using conditions to control job execution](https://docs.github.com/en/actions/using-jobs/using-conditions-to-control-job-execution) — "If a job uses an `if` conditional that evaluates to false, the job is skipped, and the job is considered successful." Reinforced by [About status checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/about-status-checks) and [About rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets) — skipped required jobs satisfy required status checks. |

### Re-apply / update the ruleset

```bash
bash scripts/ci/ruleset-apply.sh
# REPO=<your-org>/automations bash scripts/ci/ruleset-apply.sh  # override repo
```

### Inspect current state

```bash
# List all rulesets on the repo
gh api repos/<your-org>/automations/rulesets

# Show one ruleset's full rule list
gh api repos/<your-org>/automations/rulesets/<id>

# Confirm a specific check is required
gh api repos/<your-org>/automations/rulesets/<id> \
  | jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks'
```

### Gotchas

- **Required-check `context` string must match exactly.** The string is the `name:` value of the workflow job — currently `Apex tests + delta coverage gate`. Verify the bare job name is what GitHub reports by running `gh api repos/<your-org>/automations/commits/<PR-head-sha>/check-runs --jq '.check_runs[].name'` on any PR where the workflow ran. Renaming the job silently breaks branch protection (the check no longer matches any required context, so the rule has no effect). Always grep for the string after editing `apex-test.yml`.
- **Workflows with workflow-level `paths:` filters do NOT skip cleanly under required-check rules** — the check never runs, never reports, and the PR hangs in `BLOCKED` indefinitely. Use a `changes` job + per-job `if:` instead. Pattern documented inline in `apex-test.yml` (the `changes` job is the reference example).
- **`bypass_actors: []` means NO bypass — including for repository admins.** Unlike legacy branch protection, rulesets do NOT grant admins an implicit override. `gh pr merge --admin` will be rejected if it conflicts with an active ruleset and your account is not in `bypass_actors`.

  **Emergency override — preferred path** (single-field PATCH; simple revert):
  ```bash
  RULESET_ID=$(gh api repos/<your-org>/automations/rulesets --jq '.[] | select(.name=="main-required-checks") | .id')
  gh api -X PATCH repos/<your-org>/automations/rulesets/$RULESET_ID -f enforcement=evaluate   # disable enforcement
  gh pr merge <N> --admin --squash --delete-branch                                          # land merge
  gh api -X PATCH repos/<your-org>/automations/rulesets/$RULESET_ID -f enforcement=active      # restore
  ```

  **Avoid** the `bypass_actors[]` mutation path: gh API `PUT` REPLACES the entire ruleset resource, requiring a full snapshot → modify → PUT-replay → restore-PUT cycle. Empirically (<clickup-task-id>, 2026-05-16) the first PUT attempt failed because only `bypass_actors[]` was sent and `rules` + `conditions` were dropped; required a `python3` payload-builder against the snapshot to succeed. The `enforcement=evaluate` PATCH path is a 2-line revert by comparison.

  **Only use either override when the failing check is known-broken outside the PR's scope** (e.g. `apex-test` gate regression tracked at <clickup-task-id>, 2026-05-15+). Don't bypass for genuinely failing checks.
- **The `pull_request` rule blocks direct pushes to `main`.** Verified 2026-05-12: all recent commits on `main` arrive via PR squash-merge (sample: 20/20 most-recent commits end with `(#NNN)`). If a future automation needs direct push, it must be added to `bypass_actors` first.
- **Removing the ruleset requires `gh api -X DELETE repos/<repo>/rulesets/<id>`** — there is no `gh ruleset delete` command at time of writing.

## <your-org>-Specific IDs

| Resource | Value |
|----------|-------|
| Primary repo | `<your-org>/automations` |
| Teams webhook secret | `TEAMS_WEBHOOK_URL` (repo secret) |
| Task tracking | ClickUp (not GitHub Issues) |

## Gotchas

- **Issues are disabled** on this repo. All tasks go in ClickUp A&E list `<clickup-list-id>`.
- **`gh` auth expires** — re-auth with `gh auth login` if you get 401s.
- **Rate limits:** 5,000 requests/hour for authenticated API calls.
- **Secret scan** runs on every push — will block commits containing API keys, tokens, or credentials.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `gh` returns 401 | Token expired. Re-auth: `gh auth login` |
| `gh` returns 403 rate limit | 5,000 req/hr limit. Check `gh api rate_limit` or wait |
| Secret scan blocks push | Remove secret from commit. `git rebase -i` to amend, or `git filter-branch` if already pushed |
| API calls fail with 401 | `GITHUB-PERSONAL-ACCESS-TOKEN` missing or expired. Re-fetch via `fetch-secrets.sh github` |
| `gh issue list` returns empty | Issues are disabled on this repo — use ClickUp A&E list `<clickup-list-id>` instead |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|

<!-- <clickup-task-id> skip-probe — verifies ruleset skip semantics; safe to remove -->
