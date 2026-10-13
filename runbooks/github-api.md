# GitHub API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-10-08 (nightly full suite; <clickup-task-id>)

## Auth

- **Method:** GitHub CLI OAuth (`gh`) for interactive; Personal Access Token for orchestrator agent
- **Repo:** `<your-org>/automations` (private)
- **Actions secrets:** Managed via `gh secret set` or repo settings UI

### Token inventory

| Name | Vault | Used by | Scope |
|------|-------|---------|-------|
| `GITHUB-PERSONAL-ACCESS-TOKEN` | `<credential-vault>` | local dev (`fetch-secrets.sh github`) | broad user PAT |
| `github-pat-orchestrator` | `<credential-vault>` | local poller `git fetch` of pinned SHAs (`scripts/orchestrator/local-poller-wrap.sh:64`) | repo R/W on `<your-org>/automations` |
| `github-webhook-secret` | **retired** | was Functions `/api/github` HMAC validation | n/a |

⚠️ **`<credential-vault>` no longer exists** — the vault was removed with the cloud
orchestrator and its DNS name does not resolve, so a command targeting it fails with a
name-resolution error rather than a permissions error. The two rows above moved: the PAT to
`<credential-vault>`, and `github-webhook-secret` to nothing (no vault holds it and no code
reads it). (empirical (2026-08-16), <clickup-task-id> — `socket.getaddrinfo('<credential-vault>.vault.azure.net',443)`
→ `gaierror [Errno 8]` while `<credential-vault>` resolves to `20.42.64.44`; `<credential-vault>/github-pat-orchestrator`
returns a 40-char value; `github-webhook-secret` is absent from `<credential-vault>` (216 secrets)
and `<credential-vault>` (43 secrets), with zero repo consumers. Per `docs/runbooks/azure-keyvault.md:252`,
a DNS-resolution failure is the one classifier outcome that proves vault absence rather than
an access problem.)

**App installation tokens are the preferred credential for Actions** — see the App inventory
under "<your-org>-Specific IDs" and the migration note at the end of "GraphQL point-bucket exhaustion".
The PATs above remain as fallbacks during the rollout (card <clickup-task-id>).

### PAT provisioning (no web UI)

GitHub's fine-grained PAT create API requires 2FA + browser — it cannot be scripted. Options, ranked:

1. **Reuse `gh` CLI OAuth token** (`gho_*`, scopes: `admin:org, gist, repo, workflow` — empirical (2026-10-06), `gh auth status`). Programmatic, tied to the logged-in user. Good for bootstrap; rotate before production.
   ```bash
   TOK=$(gh auth token)
   az keyvault secret set \
     --vault-name <credential-vault> \
     -n github-pat-orchestrator \
     --value "$TOK" \
     --tags purpose="orchestrator agent" origin="gh CLI OAuth" rotate-by="<YYYY-MM-DD>"
   ```
   Note the missing `AZURE_CONFIG_DIR=<azure-config-dir>` prefix: that SP has get/list on
   `<credential-vault>` but no `setSecret`, so a prefixed write returns `Forbidden`. Writes run
   under the default `<your-email>` login (`docs/runbooks/azure-keyvault.md:113`).
2. **Fine-grained PAT via web UI** (required for least-privilege production). Settings → Developer settings → Fine-grained tokens → New. Resource owner: `<your-org>` (needs org approval), repository: `automations`, permissions: Contents RW, Pull requests RW, Issues RW, Metadata R. Expiration: 90 days. Then `az keyvault secret set` as above.
3. **GitHub App installation token** — the current direction, not a future one. Three Apps are
   registered and installed all-repos (inventory under "<your-org>-Specific IDs"); an installation
   token carries its own rate-limit bucket and still fires `on: push`, which is what makes it a
   valid `PROJECT_TOKEN` replacement where `GITHUB_TOKEN` is not. In Actions, mint it with
   `actions/create-github-app-token@v2` from the `CI_APP_ID` / `CI_APP_PRIVATE_KEY` repo/org
   secrets; outside Actions, mint an App JWT from the Key Vault copy and exchange it at
   `POST /app/installations/{id}/access_tokens`. Migration tracked on card <clickup-task-id>.

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

## REST first — always (standing instruction, 2026-08-20)

**Use `gh api` for every GitHub operation.** `gh api <endpoint>` is REST; nearly all `gh`
porcelain — `gh pr create|list|view|merge|edit|checks`, **with or without `--json`** —
routes through **GraphQL**.

This is a default, not a recovery path. The GraphQL bucket is 5,000 *points*/hr **per
user**, pooled across every PAT, OAuth app, GitHub App, daemon and interactive session,
with no per-credential accounting (see "Rate limits" below). REST is a separate 5,000
*requests*/hr `core` bucket that is almost always healthy. Reaching for porcelain first
means every task is one exhausted bucket away from stalling mid-flight — which is exactly
how it fails, after the work is done and while the PR is being opened.

| Instead of | Use |
|---|---|
| `gh pr create --title T --body-file F` | `gh api -X POST repos/<o>/<r>/pulls --input payload.json` |
| `gh pr view <n> --json ...` | `gh api repos/<o>/<r>/pulls/<n> --jq '...'` |
| `gh pr list --state open` | `gh api repos/<o>/<r>/pulls --jq '...'` |
| `gh pr edit <n> --body-file F` | `gh api -X PATCH repos/<o>/<r>/pulls/<n> --input payload.json` |
| `gh pr merge <n> --squash` | `gh api -X PUT repos/<o>/<r>/pulls/<n>/merge -f merge_method=squash` |
| `gh pr checks <n>` | `gh api repos/<o>/<r>/commits/<sha>/check-runs --jq '...'` |
| `gh pr comment <n> --body B` | `gh api -X POST repos/<o>/<r>/issues/<n>/comments -f body=B` |

Two mechanics worth knowing before you hit them:

- **Build bodies as a JSON file and pass `--input`.** `-f body=...` mangles multi-line
  markdown; `--input` sends it verbatim.
- **`check-runs` takes a commit SHA, not a branch name.** A branch ref returns
  `HTTP 422 No commit found for SHA: <branch>`. Resolve with
  `gh api repos/<o>/<r>/git/ref/heads/<branch> --jq .object.sha` first.

**Genuine exceptions — no REST equivalent exists:** `enablePullRequestAutoMerge` and
`markPullRequestReadyForReview`. Both are CI-side (the auto-merge workflow), not
hand-run, so they should not come up in normal work. If one does, say so rather than
silently falling back to GraphQL.

**Never retry a throttled call.** The retry is more of the load that pinned the bucket.
Go straight to the REST equivalent. (empirical (2026-08-20), <clickup-task-id> — `gh pr create`
died on `GraphQL: API rate limit already exceeded`; `gh api -X POST .../pulls --input`
succeeded immediately on the same token.)

## Common Operations

### Via API / CLI

#### Pull Requests

Default: combine same-epic PRs that touch the same files into one PR. Coordinate the shared scope before opening a PR, then apply the existing collision, review and required-check gates to the combined diff.

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
| `apex-test.yml` | PR, workflow_dispatch, nightly (07:00 UTC) | Targeted PR validate with conservative `RunLocalTests` fallback; full suite only nightly/manual, with failures alerting A&E. Main pushes no longer validate qa. Same `sf-qa-validate` queue, `cancel-in-progress: false`, `queue: max`; required `gate` unchanged. Flow mapping: named/direct API references, then object-trigger tests, tests for classes referenced in stripped trigger bodies, and invoked-Apex tests; unmapped flows or flows exceeding `APEX_TEST_MAX_FLOW_TESTS` (default `25`) fall back. Details: `salesforce-cli.md` "CI validate against qa" |
| `qa-apex-sync.yml` | Main push touching `salesforce/**`, sandbox refresh, manual | Deploy merged source to qa without tests (push: changed-only plus all Apex; refresh/manual: full `force-app`); preserve AE rehearsal configuration. Details: `salesforce-cli.md` "qa-apex-sync.yml" |
| `secret-scan.yml` | Push | Blocks committed secrets |
| `weekly-metadata-sync.yml` | Cron (weekly) | Retrieves SF org metadata |
| `announce-to-teams.yml` | Push to `docs/announcements.md` | Posts staff announcement |
| `teams-notify.yml` | Push to main | Changelog to Teams |
| `auto-fix.yml` | PR | Automated lint fixes |
| `auto-merge.yml` | PR | Auto-merge approved PRs |
| `validate-commands.yml` | PR | Validates `.claude/commands/` |
| `orchestrator-tests.yml` | PR touching `scripts/orchestrator/**` | Advisory (not required). macOS + Python 3.13: `pytest scripts/orchestrator`, every `tests/*.sh` + `test-*.sh`, `bats tests/*.bats`. Sets `OCC_CI_HERMETIC=1`: suites that need `~/.claude` (<config-repo> tree), a Studio LaunchAgent, or live ClickUp/Key Vault print `SKIP` and exit 0 |
| `<voip-mcp>-ingest-tests.yml` | PR touching `integrations/voip_ingest/**` | Advisory (not required). Python 3.13 `pytest integrations/voip_ingest/tests` |

### `Apex validate (qa)` and production-only profile entries (<clickup-task-id>)

qa is a weekly-refreshed Partial sandbox and lacks some production features (Dev Hub, AI Workbench,
consumption tags, external email). Before validate, `apex-test.yml` strips the entries named in
`scripts/sf_coverage/qa_unavailable.json` from the CI checkout's changed profiles and permission sets;
source and production deploys are untouched. Mechanics, exit codes and how to add an entry (each needs
a prod-has / qa-lacks probe): `scripts/sf_coverage/README.md` "`qa_unavailable.py`".

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
| `Apex tests + delta coverage gate` | `.github/workflows/apex-test.yml` job `gate` (aggregator; the heavy qa validate is job `apex-test`, named `Apex validate (qa)`) | Never skipped: `gate` has `if: always()` and no concurrency, so it reports on every PR — success when the `changes` job sets `sf=false`, otherwise exactly `needs.apex-test.result` (a `cancelled` validate fails the gate; re-run the workflow). The `sf-qa-validate` concurrency group lives on the `apex-test` **job**, never at workflow level: a workflow-level group cancels superseded *pending* runs before any job starts, so the required check never appears and green PRs sit at `mergeable_state=blocked` (empirical (2026-10-05), <clickup-task-id>: PRs #1452/#1453/#1455/#1458-#1461 — `GH_APP_SHIM=0 gh api repos/<your-org>/automations/actions/workflows/apex-test.yml/runs` showed each head's run `cancelled` with zero jobs while run 37336500063 held the group). Do not make `gate` skippable: a skipped required job counts as passing. Contract: `scripts/sf/tests/test_apex_required_check_reports.py`. |
| `pr-body-lint` | `.github/workflows/pr-body-lint.yml` job `lint` (`name: pr-body-lint`) | Runs on every PR (`opened`/`edited`/`reopened`/`synchronize`); no `if:`, so never skipped. Added 2026-06-15 per <clickup-task-id>. The context string is the job's `name:` value — renaming the job silently de-couples it from the required context (same gotcha as the Apex check). |
| `No new live alert-fault gaps` | `.github/workflows/alert-fault-gate.yml` (`name: No new live alert-fault gaps`) | See the workflow header: no `paths:` filter, so it reports on every PR. |
| `fleet-review` | Commit status (not a check run) from `.github/workflows/fleet-review-gate.yml`, `ReviewDispatchTick`, and `scripts/orchestrator/fleet-review-waive.sh` | `success` with `gate off` / `not a fleet PR` / `plan-only`; otherwise `pending` until the cross-provider review posts a verdict. `auto-merge.yml` re-verifies any success with `fleet_review_verify.py`. Added 2026-10-05 per <clickup-task-id>. |

**App binding (<clickup-task-id>, applied 2026-10-05).** The three CI contexts carry `integration_id: 15368` (GitHub Actions), so only an Actions check run satisfies them — a commit status a token holder posts with the same context name does not. `fleet-review` is unbound on purpose: the tick and the waive script post it with a user token, and binding it to Actions would block every fleet PR. `strict_required_status_checks_policy=false`, `bypass_actors=[]`. empirical (2026-10-05): `GH_APP_SHIM=0 gh api repos/<your-org>/automations/commits/65143e5d/check-runs` → all three contexts reported by app id 15368 (`github-actions`); `GH_APP_SHIM=0 gh api repos/<your-org>/automations/rulesets/16300909` after the PUT shows the four contexts above, `updated_at 2026-10-05T19:05:12-04:00`.

### pr-body-lint close-keyword gate (<clickup-task-id>)

`.github/workflows/pr-body-lint.yml` runs `scripts/pr-body-lint/lint.py` and fails a PR on either of two shapes:

1. **Bare close-keyword ID** — `Closes: <clickup-task-id>` (bare, not URL/`#`) does not match `clickup-close-on-merge.yml`'s regex, so the card silently stays open on merge. Use `Closes: https://app.clickup.com/t/<id>` or `Fixes #<id>`.
2. **Branch-id coverage** — a PR whose head branch is `<type>/<id>-<slug>` MUST carry a close-keyword line (URL/`#` form) covering that `<id>`. Catches the epic-phase orphan class (a phase PR that merges without closing its own card → card stuck → dependents blocked → epic cascade stalls; precedent PR #1049 / <clickup-task-id>). Branch id is parsed from `github.event.pull_request.head.ref` (passed via `PR_HEAD_REF` env, never interpolated into `run:`).

**Opt-out** for an intentionally non-closing PR (plan-only, epic-shell, multi-phase referencing the epic by plain URL): add `<!-- no-close: <reason> -->` to the body. Non-convention branches (dependabot/release/etc.) are exempt automatically (nothing to enforce). Self-test harness: `scripts/pr-body-lint/test_lint.sh` (44 cases) — runs as the workflow's first step, locking the regex contract.

This check is in the `main-required-checks` ruleset's `required_status_checks` (source of truth `scripts/ci/ruleset-apply.sh`), so auto-merge waits for it. **Sequencing caveat:** GitHub only enforces a required context it has *seen report* — the context must merge to main and report once before `ruleset-apply.sh` is run, else open PRs deadlock on "Waiting for status to be reported" (see the script header).

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

  **Only use either override when the failing check is known-broken outside the PR's scope** (i.e. an upstream infra/gate regression that an open ClickUp card is already tracking). Don't bypass for genuinely failing checks.
- **The `pull_request` rule blocks direct pushes to `main`.** Verified 2026-05-12: all recent commits on `main` arrive via PR squash-merge (sample: 20/20 most-recent commits end with `(#NNN)`). If a future automation needs direct push, it must be added to `bypass_actors` first.
- **Removing the ruleset requires `gh api -X DELETE repos/<repo>/rulesets/<id>`** — there is no `gh ruleset delete` command at time of writing.

## Org Member Management

Inviting a user to `<your-org>` (orgs can't "create users" — you invite an existing
or new GitHub account by email; GitHub sends the signup/accept email).

**Required scope:** `admin:org` (write). None of the vault PATs carry it (see Gotchas).
Add it to the `gh` CLI token interactively — additive, one browser approval:

    gh auth refresh -h github.com -s admin:org

**Send the invite** (use `--input -` with a JSON body — `gh api -F 'team_ids[]=N'`
mixed with `-f` produced a malformed request in testing):

    echo '{"email":"<service-email>","role":"admin","team_ids":[3053618]}' | \
      gh api -X POST /orgs/<your-org>/invitations \
        -H "Accept: application/vnd.github+json" --input -

- `role`: `direct_member` (standard) or `admin` (org owner). Default to `direct_member` (least privilege).
- `team_ids`: optional array of team IDs to add on invite (see <your-org>-Specific IDs).

**List members / pending invites:**

    gh api "/orgs/<your-org>/members?per_page=100" --jq '.[].login'
    gh api "/orgs/<your-org>/invitations?per_page=100" --jq '.[] | {login, email, role}'

**Cancel a pending invite** (frees a seat; reversible — can re-send):

    gh api -X DELETE /orgs/<your-org>/invitations/<invitation_id>

**Seats are not addable via API.** Plan/seat count is UI-only
(Org → Settings → Billing and licensing). If the org's prepaid seats are full,
the invite fails 422 "No seats are available" — see Troubleshooting.

## Secret Scanning + Push Protection (<clickup-task-id>)

**State (empirical (2026-10-06), `GH_APP_SHIM=0 gh api /repos/<o>/<r> --jq .security_and_analysis`):**

| Scope | Secret scanning + push protection |
|---|---|
| Org default for new repos (`/orgs/<your-org>`) | on — `secret_scanning_*_for_new_repositories` were already `true`; unchanged |
| <your-org> public repos (43, all non-archived) | on — 42 enabled 2026-10-06, 1 already on. Free on public repos |
| <your-org> private, non-archived (88) | 78 on (72 enabled 2026-10-06, 6 already on); 10 left **off** — see Billing |
| <your-org> archived (5) | unchanged — archived repos are read-only |
| `<your-username>/<config-repo>` | **not available** — `PATCH` returns 422 "Secret scanning is not available for this repository." (user-owned private repo; Secret Protection is org-only) |

**Billing.** Private-repo secret scanning is GitHub **Secret Protection**, metered at **$19 per active committer per month** (`GET /organizations/<your-org>/settings/billing/usage`, SKU `Secret Protection`, `pricePerUnit` 19). A user is billed once if anyone pushed a commit they authored to any enabled private repo in the last 90 days (docs-confirmed: https://docs.github.com/en/billing/concepts/product-billing/github-advanced-security). Billed committers before and after the 2026-10-06 change: 5 (`<staff-username>, <staff-username>, <staff-username>, <your-username>, <staff-username>`), via `GET /orgs/<your-org>/settings/billing/advanced-security?advanced_security_product=secret_protection`. The change enabled only private repos whose 90-day committers were already billed. The 10 repos left off would each add a committer:

| Repo | New billable committer |
|---|---|
| `CDR-Processing`, `Exchange-Scripts` | `<staff-username>` |
| `mpp-migration`, `team-resources`, `<internal-name>`, `sms-intermediary`, `claude-seat-failover`, `<internal-bot>-figurine-development`, `<internal-bot>-figurine` | `blaineyeager` |
| `mysql_table_compare` | `<staff-username>` |

Enabling all ten adds three committers, about $57 per month. Any commit authored by a user who is not yet billed adds $19 per month once it is pushed to an enabled private repo.

**Enable one repo** (needs repo admin, org owner, or security manager; the `gh` token, which has `repo` + `admin:org` under an org owner, worked on 2026-10-06):

    echo '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}' |
      gh api -X PATCH /repos/<your-org>/<repo> --input -

Read state with `GH_APP_SHIM=0`; the shim's App token may not return the admin-only `security_and_analysis` block.

**Rollback.** Before 2026-10-06, every repo enabled that day had `secret_scanning` and `secret_scanning_push_protection` both `disabled`. To restore one, send the same `PATCH` with `"status":"disabled"` for both keys. 114 repos were enabled that day (42 public + 72 private). They are every non-archived <your-org> repo now on, minus the 7 that were already on: `<voip-mcp>-mcp-server` (public), `mpp_dev`, `ucdata`, `product-department-feature-planning`, `claude-plugin-salesforce-case-quality`, `<config-repo>` and `<internal-name>`. Rebuild the target list before a rollback, because repos created after 2026-10-06 inherit the org default: `GH_APP_SHIM=0 gh api --paginate "/orgs/<your-org>/repos?per_page=100" --jq '.[] | select(.archived|not) | .name'`. Drop the 7 pre-enabled repos, the 10 left off, and anything created after 2026-10-06. The org-level defaults were not changed.

    echo '{"security_and_analysis":{"secret_scanning":{"status":"disabled"},"secret_scanning_push_protection":{"status":"disabled"}}}' |
      gh api -X PATCH /repos/<your-org>/<repo> --input -

## <your-org>-Specific IDs

| Resource | Value |
|----------|-------|
| Primary repo | `<your-org>/automations` |
| Teams webhook secret | `TEAMS_WEBHOOK_URL` (repo secret) |
| Task tracking | ClickUp (not GitHub Issues) |
| Org | `<your-org>` (plan: Team, 9 prepaid seats; verify live — `gh api /orgs/<your-org> --jq '.plan'`) |
| Team: <your-org> | id `3053618`, slug `<your-org>` (empirical 2026-05-27) |
| Team: product | id `16679558`, slug `product` (empirical 2026-05-27) |

### CI GitHub Apps (reference only — never paste these ids into a runnable command)

One App per account: an org-owned App set to "Only on this account" cannot be installed
elsewhere, so consolidation is not available. All three carry the same permission set —
`contents:write pull_requests:write workflows:write checks:read statuses:read metadata:read`.

| Account | App | App ID | Installation ID | Repos |
|---|---|---|---|---|
| `<your-org>` | `<internal-name>` | `4541820` | `152533820` | all (empirical 2026-08-10, `GET /orgs/<your-org>/installations`) |
| `<your-username>` | `<your-username>-automations-ci` | `4541980` | `152536991` | all (empirical 2026-08-10; user-owned Apps are not publicly listable — a 404 on `/apps/<slug>` is expected) |
| `<your-other-org>` | `<your-other-org>` | `4542030` | `152537497` | all (empirical 2026-08-10, `GET /orgs/<your-other-org>/installations`) |

Discover the installation id at runtime rather than reading it from this table —
`GET /app/installations` under the App's own JWT is authoritative and survives a reinstall:

```bash
python3 scripts/github-app/verify-app-keys.py            # mints from KV, prints ids + core.limit
```

**Credential storage.** Each App's private key lives in **two** stores that no single probe can
compare, and the distinction matters when CI breaks:

| Store | Names | Readable? |
|---|---|---|
| Key Vault `<credential-vault>` | `CI-APP-ID{,-<your-username>,-<your-other-org>}` / `CI-APP-PRIVATE-KEY{,-<your-username>,-<your-other-org>}` | yes — this is the only copy a human or a local script can read (pending — created by card <clickup-task-id> R0.3; absent as of 2026-08-16) |
| GitHub Actions secrets | `CI_APP_ID` / `CI_APP_PRIVATE_KEY` on `<your-org>/automations`, `<your-username>/<config-repo>`, and as `<your-other-org>` org secrets | **no** — Actions secrets are write-only via every API, `gh`, and the UI (empirical 2026-08-10, `gh secret list` shows names + timestamps only) |

A key that verifies from Key Vault says nothing about the bytes in the Actions secret: they are
different stores, and only a real CI run reads the second one. After rotating an Actions secret,
prove it with a no-op PR through live auto-merge **before** deleting the superseded key in the
GitHub UI. Private-key generation and deletion are UI-only — there is no REST route (empirical
2026-08-10: `GET /app` → 401 with all three candidate key-creation POST routes → 404).

## Gotchas

- **Issues are disabled** on this repo. All tasks go in ClickUp A&E list `<clickup-list-id>`.
- **`gh` auth expires** — re-auth with `gh auth login` if you get 401s.
- **Rate limits:** 5,000 requests/hour for authenticated API calls.
- **🚨 `--search` has a SECOND, invisible limit.** `gh pr list --search …` / `gh search prs` route through GitHub's GraphQL `search()` connection, which carries a **secondary** rate limit that `gh api rate_limit` does not expose. When it fires, `gh` prints `GraphQL: API rate limit already exceeded for user ID <n>` while `gh api rate_limit` reports everything healthy — so the obvious diagnostic says "nothing is exhausted" and misleads. **The failing request's own response headers DO expose it** — re-run the throttled command under `GH_DEBUG=api` and read `X-Ratelimit-Used` / `-Limit` / `-Reset` off *that* response rather than off `rate_limit`. The signature that distinguishes it from primary exhaustion: the counter reads **over its own limit with a reset timestamp in the past**. (empirical (2026-08-09), <clickup-task-id> — a throttled `gh pr list --search` returned `X-Ratelimit-Used: 5258 / Limit: 5000 / Resource: graphql / Reset: 1786308584` = 20:49:44Z, ~3h stale, while a plain `gh pr list` seconds later on the same token returned `Used: 27 / Remaining: 4973 / Reset: 23:49:51Z`.) It is **user-level, not token-level**: it reproduces identically under a different PAT belonging to the same user, so a daemon and an interactive `gh` session share one budget. Prefer plain `gh pr list --state <s> --limit <n>` over the `--search` form and narrow locally — it avoids the *secondary* search throttle. **But it is NOT REST-backed** (an earlier revision of this line claimed it was, and that claim was wrong): `gh pr list` routes through GraphQL in **every** form, with and without `--json`, so it dies alongside everything else once the *primary* GraphQL bucket empties. The only genuinely REST paths are `gh api <endpoint>` and `gh api search/issues?q=…`. (empirical (2026-08-18), <clickup-task-id> — with `graphql.remaining: 0`: `gh pr list --json …` → `GraphQL: API rate limit already exceeded`; `gh pr list` bare → same error; `gh api repos/<your-org>/automations/pulls` → 200 with rows. The false claim had been steering Phase B's REST-swap work.) **Never retry a throttled search**: the retry is more search volume, which is what keeps the account pinned. (empirical (2026-08-05), <clickup-task-id> — 15,316 throttled warnings in one day; probe + numbers below.)
- **🚨 GraphQL exhaustion breaks auto-merge repo-wide — and the merge step is the only thing that notices.** `gh pr merge` is a **GraphQL** call and GitHub's GraphQL bucket is **per USER**, so a PAT-driven CI merge shares one budget with every interactive `gh` call and every agent session. When it empties, `Auto-Merge PRs` fails on every open PR at once with `GraphQL: API rate limit already exceeded for user ID <n>`, and PRs sit at `mergeable_state: blocked` with all required checks green. **This is the PRIMARY bucket, not the secondary `search()` throttle above — they print the same error string but need opposite diagnoses.** Tell them apart with `gh api rate_limit --jq .resources`: primary exhaustion reports `graphql.remaining: 0`; the secondary throttle reports everything healthy. REST carries a **separate** `core` 5,000/hr allowance and is typically untouched, so the merge falls back to `PUT /repos/{owner}/{repo}/pulls/{n}/merge`. Manual recovery for a single stuck PR: `gh api -X PUT repos/<your-org>/automations/pulls/<n>/merge -f merge_method=squash`. (empirical (2026-08-07), <clickup-task-id> — `graphql.remaining 0 / used 6689` while `core.remaining 4997`; PRs #1249/#1263/#1264/#1265 all stalled; REST merge succeeded immediately.)
- **`GITHUB_TOKEN` has its OWN rate-limit bucket — a PAT does not.** The Actions-provided `GITHUB_TOKEN` is an app-installation token, so steps using it are unaffected by PAT-owner exhaustion. In the <clickup-task-id> incident the `Auto-approve PR` step (`GITHUB_TOKEN`) succeeded in the same job where the `Enable auto-merge` step (`PROJECT_TOKEN`) died on the rate limit. **But do not "fix" a rate limit by swapping a merge to `GITHUB_TOKEN`:** a merge performed with `GITHUB_TOKEN` does **not** fire `on: push` workflows (GitHub anti-recursion), which would silently disable the six push-triggered workflows on `main` (`qa-apex-sync`, `teams-notify`, `apex-lint`, `announce-to-teams`, `secret-scan`, `sandbox-refresh`). Keep the PAT and add a REST fallback instead.
- **⚠️ A `run:` block runs under `bash -e {0}` — `set -uo pipefail` does NOT clear errexit.** GitHub Actions invokes every `run:` step as `/usr/bin/bash -e {0}` (visible in any run log's step header), so errexit is already on before your first line. A script that opens `set -uo pipefail` and then assigns `CODE=$(gh api ... | head -1 | awk ...)` **dies on the first HTTP ≥ 400**, because `gh api` exits non-zero on error statuses and `pipefail` propagates it — any retry loop below becomes dead code that runs exactly one iteration. Write an explicit `set +e` when you intend to inspect a failing command's status. `shell: bash` is NOT a workaround: it expands to `bash --noprofile --norc -eo pipefail {0}`, which still carries `-e`. (empirical (2026-08-07), <clickup-task-id> — `/bin/bash -e` with `set -uo pipefail` reports `$- = ehuB`; the same poll loop ran 0 iterations under `-e` vs 3 without it. Caught in review; the first draft of the REST fallback shipped this defect and passed every grep-based test.)
- **The REST merge fallback's safety depends on ruleset `16300909` staying `enforcement: active` with `bypass_actors: []`.** `PUT /pulls/{n}/merge` is gated by branch rules exactly like the UI merge button (405 when blocked), so the fallback cannot land code whose required checks have not passed — but only while no bypass actor covers the PAT owner. If you ever add a bypass actor, re-audit `.github/workflows/auto-merge.yml`. Probe: `gh api repos/<your-org>/automations/rulesets/16300909 --jq '{enforcement,bypass_actors}'`.
- **A workflow-level `concurrency` group can leave a required check permanently ABSENT.** GitHub queues at most **one** pending run per group, so a third PR's queued run evicts the second's. At workflow level the evicted run ends `cancelled` with zero jobs, the required check never reports, and the PR blocks with no failure to point at. (empirical (2026-08-07), <clickup-task-id> — 3 `cancelled` apex-test runs at 21:58–22:07 on the exact branches that stalled; again 2026-10-05, <clickup-task-id>, #1452–#1461.) `apex-test.yml` now holds `sf-qa-validate` (`cancel-in-progress: false`, qa is one shared sandbox) on the `apex-test` **job**, and the always-reporting `gate` job carries the required context. An evicted validate now shows as the gate **failing** with `Apex validate (qa) result: cancelled`. Recovery: re-run the workflow (`gh run rerun <run-id>`). Contract: `scripts/sf/tests/test_apex_required_check_reports.py` (`test_no_workflow_level_concurrency`, `test_required_job_is_never_cancelled_or_skipped`).
- **Secret scan** runs on every push — will block commits containing API keys, tokens, or credentials.
- **Vault GitHub PATs lack `admin:org`.** `GITHUB-PAT-<your-org>`, `GITHUB-PERSONAL-ACCESS-TOKEN`, and `github-pat-orchestrator` all carry `delete_repo, gist, read:org, repo, workflow` only. The fine-grained `AUTO-MERGE-PAT-<your-org>` has no org-members permission. For org admin writes (invites, role changes, security settings) use the `gh` token, which carries `admin:org` (empirical (2026-10-06), `gh auth status`); if a re-login drops it, `gh auth refresh -h github.com -s admin:org`. `GITHUB-PAT-<your-org>` scopes re-confirmed 2026-10-06 via the `X-OAuth-Scopes` response header. Read endpoints (`read:org`) work for org owners even without `admin:org`, so a read returning 200 does NOT mean a write will succeed.
- **No API to add/purchase billing seats.** Seat count and plan changes are UI-only. Billing REST/GraphQL endpoints are read-only (`/organizations/<org>/settings/billing/usage` reports metered Actions/GHAS usage; seat licenses don't appear there because they're a fixed subscription). The Enterprise-only `/orgs/<org>/settings/billing/seats` endpoint 404s on a Team-plan org.

## The `gh` App-token shim (the standing fix — <clickup-task-id>)

`~/.claude/scripts/gh` is a shim that fronts the real `gh` binary (that directory
already precedes `/opt/homebrew/bin` on PATH and already held the `codex` shim).
It routes **read-heavy** gh traffic onto the target org's **App installation
token**, which carries its own rate-limit bucket, so reads stop draining the
shared per-user counter.

| Org | Installation bucket |
|---|---|
| <your-org> | 10,600/hr |
| <your-username> | 5,700/hr |
| <your-other-org> | 5,000/hr |

**Why this and not a REST port.** Porting individual callers to REST fixes the
callers you know about. The per-user counter is drained by *every* session under
`<your-username>` — including work in other orgs entirely (TerpTrakker, Focally) that no
automations-side change can reach. The credential-layer fix covers every repo,
every session, and every future consumer without per-caller edits.

**What is routed:** `search *`, `pr|issue list|view|status|checks|diff`,
`run|workflow|release|repo|cache list|view`, and `gh api` **reads**.

**What is NOT routed (deliberate):** every write — `pr create|merge|review`,
`issue create`, and `gh api` with `-X/--method` POST/PUT/PATCH/DELETE (all
spellings: separated, attached `-XPOST`, and `--method=PUT`). Writes keep your
own credentials because PR authorship and review attribution are load-bearing;
a bot must not stand in for the human author.

**Fail-open contract.** Unresolvable org, missing minter, Key Vault down, or a
failed mint all fall through to the real `gh` with the caller's credentials
untouched. The shim must never be the reason a gh command fails.

    GH_APP_SHIM=0        disable for one call / one shell
    GH_APP_SHIM_DEBUG=1  print routing decisions to stderr
    GH_TOKEN=<tok>       caller-supplied token is respected, never overridden

**The App has no Actions permission — the shim turns Actions reads into 403s.** Any read the
shim routes to the App installation token that touches the Actions API fails with
`Resource not accessible by integration (HTTP 403)`: `gh api .../actions/workflows/<wf>/runs`,
`gh run view --log-failed`, and `gh pr view --json statusCheckRollup` (whose GraphQL resolves
`checkSuite.workflowRun`). That reads like a permission wall; it is only the routing. Bypass
per call:

    GH_APP_SHIM=0 gh api "repos/<your-org>/automations/actions/workflows/<wf>.yml/runs?per_page=5"
    GH_APP_SHIM=0 gh run view <run-id> --repo <your-org>/automations --log-failed

(empirical (2026-09-21), <clickup-task-id>: a card carried "Blocker: run log unreadable (Actions API
403)" for a week; `GH_APP_SHIM=0` returned the failing step log on the first call, and the root
cause was in it.) For PR check status, use `gh api repos/<o>/<r>/commits/<sha>/check-runs`.

Token minting + caching: `~/.claude/bin/lib/gh_app_token.py` (0600 cache file in
a 0700 dir, re-mints inside a 5-minute expiry margin). Verify the App keys
themselves with `scripts/github-app/verify-app-keys.py`.

Staff-facing writeup: [Why gh Commands Stopped Hitting Rate Limits](<internal-url>)
(internal). Companion: [How Pull Requests Get Merged: the CI GitHub App Token](<internal-url>)
covers the same credential model on the CI/auto-merge side.

**`gh api` parameter flags are an implicit POST.** `gh api --help`: *"The default
HTTP request method is GET normally and POST if any parameters were added."* So
`gh api <endpoint> -f k=v` is a **write** even with no `-X` on the line. Any
classifier that keys off `-X/--method` alone will mis-handle it — the shim
therefore refuses to route on any of `-f/-F/--field/--raw-field/--input`.
(empirical (2026-08-18), <clickup-task-id> — caught by codex review as a BLOCKING defect
before it shipped.)

**Measured (empirical (2026-08-18), <clickup-task-id>):** five `gh pr list` calls through
the shim left the personal bucket at `6000/5000` **unchanged** and landed on the
<your-org> installation bucket at `6/10600`. Contract locked by 33 pytest cases plus
an 8-mutation harness (`bin/tests/test_gh_app_shim_mutations.sh`) in which all 8
injected defects were detected and 0 assertions proved vacuous.

## GraphQL point-bucket exhaustion (continuous-consumer diagnosis)

**GraphQL has its own quota, separate from REST.** REST is 5,000 **requests**/hr; GraphQL is 5,000 **points**/hr (cost per query complexity), tracked under `gh api rate_limit | jq '.resources.graphql'`. REST staying healthy while GraphQL is dead is normal — they're different buckets.

**Symptom of a *continuous* consumer:** the personal-PAT GraphQL bucket sits pinned at `remaining: 0` across **multiple hourly refills** (days, not the usual sub-hour lull). Since the bucket refills 5k every hour, a multi-day pin means something drains each refill the moment it lands. This breaks every GraphQL op under the personal token: `gh pr merge --auto` (`enablePullRequestAutoMerge`), PR draft↔ready toggles (`markPullRequestReadyForReview`), native auto-merge.

**What still works while it's exhausted** (different buckets / no GraphQL):
- REST PR merge: `gh api -X PUT /repos/<owner>/<repo>/pulls/<n>/merge -f merge_method=squash`.
- PR creation, issue comments, all reads.
- The repo's **auto-approve-and-merge Actions workflow** — it runs under the `github-actions` token, a separate bucket. So opening a PR **non-draft** still gets it auto-merged even when your PAT's GraphQL is dead. (Un-drafting a *draft* has no REST path — open non-draft, or recreate on a copy branch.)

**Sample the bucket for FREE.** `gh api graphql -f query='{rateLimit{used}}'` costs **0 points** — a `rateLimit`-only query is unbilled, so you can poll it once a second without perturbing what you're measuring (`gh api rate_limit` is likewise exempt). Note macOS has **no `timeout` binary**; use `curl --max-time` instead, or the sampler silently emits empty rows. (empirical (2026-08-09), <clickup-task-id> — `used` held flat across 13 consecutive one-second samples.)

**⚠️ Burn can be BURSTY — size the observation window to the burst period, not the other way round.** A consumer that fires periodically will read as a flat "N pts/min" only if the window spans several periods. Windows shorter than the period land between bursts and produce a confident, wrong negative. (empirical (2026-08-09), <clickup-task-id> — a `+10` fire every ~32s (~1,125/hr) *plus* multi-hundred-point sweeps: one ~990 pts in ≈1s, and `used` going 3,024 → 5,099 in five minutes. Two prior sessions had "conclusively excluded" local origin from a 40s socket census and a 76s `ps` sampler — both shorter than the observed sweep interval, so neither exclusion was established.)

**Diagnostic method (measure → find → PROVE by correlation):**
1. Snapshot `gh api rate_limit` across a `reset` boundary; confirm `graphql.remaining` re-pins to ~0 right after each refill and estimate the burn (pts/min). Prefer several paired windows minutes apart over one long window — see the bursty-burn warning above.
2. Grep for GraphQL emitters under the personal token: `gh api graphql`, `gh pr merge --auto`, `enablePullRequestAutoMerge`, `markPullRequestReadyForReview`, raw `/graphql` — across `~/.claude/` (daemons, hooks, Routines) and `scripts/orchestrator/`.
3. **SIGSTOP-correlation** (the proof, not inference): `kill -STOP <suspect-pid>` for one refill cycle, watch the bucket recover, `kill -CONT` after. Recovery = smoking gun.

**Precedent (<clickup-task-id> / <clickup-task-id> / <clickup-task-id>, 2026-08-07):** the burner was the orchestrator's `phase_cascade` **re-fetching every merged PR every 60s** (~1,270 pts/hr ≈ 25% of the bucket, indefinitely) — proven by SIGSTOP correlation. Fixed with a **merged-only TTL cache** (PRs #1270/#1271; burn 46→20 pts/min; bucket recovered to ~4,980 and holds). A `graphql.remaining` **detector** now surfaces the next one in minutes. A residual ~20 pts/min GraphQL-only consumer remained unidentified at close (non-urgent, ~24% quota, detector watching).

**🚨 You cannot attribute point-spend to a credential. Stop looking.** GitHub docs, *Rate limits for the REST API*: *"Primary rate limits for GitHub App **user access tokens** (as opposed to installation access tokens) are dictated by the primary rate limits for the authenticated user. This rate limit is **combined with any requests that another GitHub App or OAuth app makes on that user's behalf** and any requests that the user makes with a personal access token."* Every authorized GitHub App, every authorized OAuth app, and every PAT pool into **one** per-user counter with **no per-credential accounting**. There is no API for it (`/user/audit-log`, `/user/security-log`, `/user/installations` all 404/403 from a `gh` OAuth token; org audit-log is Enterprise-only and 404s on a Team-plan org), and the UI's `settings/applications` "Last used within the last <week|2 weeks|months>" is far too coarse to resolve an hour. Candidate-elimination against this surface cannot converge — go to the durable fix instead. (empirical (2026-08-09), <clickup-task-id> — three sessions spent on attribution; the credential inventory was 1 dormant PAT, 24 OAuth apps, 13 GitHub Apps, none resolvable to the live burn.)

**Durable fixes** once the burner is found — **or once you accept it can't be named**: rate-limit-aware backoff (check `graphql.remaining` before each call, sleep to `reset`); move the caller to a **GitHub App installation token**; or port the call to REST (e.g. auto-merge → REST `PUT …/merge`, card <clickup-task-id>).

The **installation-token** path is the one that survives a *new* consumer appearing, and both halves are docs-confirmed:
- **Own bucket** — *Rate limits for the REST API*: 5,000/hr minimum, **+50/hr per repository above 20** and **+50/hr per user above 20**, capped at **12,500/hr** (15,000 flat on Enterprise Cloud). **None of our installations reach that cap, and one sits at the bare floor** — the win is a *separate* bucket, not a bigger one. Measured against live installation tokens (empirical (2026-08-16), <clickup-task-id> — mint App JWT → `POST /app/installations/<id>/access_tokens` → `GET /rate_limit`):

  | Installation | `core.limit` | Why |
  |---|---|---|
  | <your-org> | 10,600 | 132 repos → 5,000 + 50×112 |
  | <your-username> | 5,700 | 34 repos → 5,000 + 50×14 |
  | <your-other-org> | **5,000** | 5 repos → below the 20-repo threshold, so no bonus at all |

  Do **not** write a check that asserts an installation limit *exceeds* 5,000: a small
  installation legitimately equals it, and the token is still on its own counter rather than
  the shared per-user one. `scripts/github-app/verify-app-keys.py` asserts `>= 5,000` for
  exactly this reason.
- **Still fires `on: push`** — *Triggering a workflow*: *"you can use a GitHub App installation access token or a personal access token instead of `GITHUB_TOKEN` to trigger events that require a token."* This is what makes it a valid replacement for the `PROJECT_TOKEN` PAT in `auto-merge.yml`, where `GITHUB_TOKEN` is NOT an option (it would silently stop the six `on: push` workflows on `main`).

  **Now empirically confirmed, not just docs-confirmed** (empirical (2026-08-16), <clickup-task-id> /
  <clickup-task-id>). `<your-other-org>/uc-migrator#10` was merged by an installation token and a
  `push`-event run fired on the merge commit:

  ```
  merged_by: <your-other-org>[bot]   merge_sha: dd9e99b
  gh run list --json event,headSha,workflowName,conclusion | jq 'select(.headSha=="dd9e99b…")'
    -> [{"event":"push","workflowName":"CI","status":"completed","conclusion":"success"}]
  step "Mint App installation token" -> success
  ```

  This was the epic's riskiest untested assumption — every phase depends on it, and until this
  run it rested on a docs sentence alone. **What the run does NOT answer:** whether an
  App-*submitted approval* satisfies a required-approval rule. `uc-migrator`'s ruleset does not
  require one, and `<your-org>/automations` keeps its approve step on `GITHUB_TOKEN`, so that
  question stays open until something actually approves under an App token.

Migration tracked on card <clickup-task-id>.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `gh` returns 401 | Token expired. Re-auth: `gh auth login` |
| `gh` returns 403 rate limit | 5,000 req/hr limit. Check `gh api rate_limit` or wait |
| `GraphQL: API rate limit already exceeded for user ID <n>` **but `gh api rate_limit` looks healthy** | Secondary throttle on GraphQL `search()`. It has no visible bucket, so `rate_limit` is not a valid check here. Drop `--search` and use `gh pr list --state <s> --limit <n>` + local filtering; if you must search, stop retrying and back off for minutes. User-level — switching PATs for the same user does not help. See the `--search` gotcha above (<clickup-task-id>) |
| `GraphQL: API rate limit already exceeded for user ID <n>` **and `gh api rate_limit` shows `graphql.remaining: 0`** | Primary GraphQL bucket genuinely exhausted (per-user, shared with every agent + interactive `gh`). Distinct from the secondary `search()` throttle above. `core` is usually untouched — use the REST equivalent. For a stuck PR: `gh api -X PUT repos/<owner>/<repo>/pulls/<n>/merge -f merge_method=squash`. Auto-merge now falls back to REST automatically (<clickup-task-id>) |
| PR blocked, all checks green, `Auto-approve and merge` red | Auto-merge hit the GraphQL limit. Confirm via the run log; merge via REST (row above). Fixed repo-side by the REST fallback in `auto-merge.yml` (<clickup-task-id>) |
| `Auto-approve and merge` red with `::error::PR #<n> has a merge conflict, needs rebase` | The PR is `mergeable_state=dirty`. A conflicted PR answers the REST merge with 405 like a PR still waiting on checks, so on 405 the step reads `mergeable_state` and stops at the first attempt on `dirty`. Re-running the job cannot help: rebase onto main, or, for a frozen branch, supersede it (`.claude/rules/pr-and-deploy.md`) (<clickup-task-id>) |
| `Auto-approve and merge` red with `::error::REST merge failing with HTTP <code>` | The merge path itself is broken — **not** blocked checks. `401`/`403`/`404` = `PROJECT_TOKEN` expired, lost `repo` permission, or was removed; `none` = no HTTP status at all (transport/CLI failure). The workflow deliberately fails after 3 such attempts rather than exiting green next to an unmergeable PR. Re-provision the PAT per **PAT provisioning** above, then `gh pr close <n> && gh pr reopen <n>` to re-fire. A merely *blocked* PR logs `not mergeable yet (HTTP 405)` and exits green instead (<clickup-task-id>) |
| PR blocked and a required check is **missing entirely** (not failed) | A workflow-level `concurrency` group evicted the queued run before any job started. `apex-test.yml` keeps its group at job level, so the gate always reports there; check other workflows for a workflow-level group. `gh pr close <n> && gh pr reopen <n>` re-fires `pull_request` (<clickup-task-id>) |
| `Apex validate (qa)` fails a profile/permset PR with `Unknown user permission: X`, `no CustomApplication named X` or `no CustomObject named X` | Probe whether production has X and qa lacks it (`scripts/sf_coverage/README.md` "`qa_unavailable.py`"). Prod has it, qa lacks it → add an entry with that probe to `scripts/sf_coverage/qa_unavailable.json`. Missing in both → stale source: remove it from the XML (<clickup-task-id>) |
| `Apex tests + delta coverage gate` fails with `Apex validate (qa) result: cancelled` | A newer run evicted this validate from the `sf-qa-validate` job queue. `gh run rerun <run-id>` (<clickup-task-id>) |
| Secret scan blocks push | Remove secret from commit. `git rebase -i` to amend, or `git filter-branch` if already pushed |
| API calls fail with 401 | `GITHUB-PERSONAL-ACCESS-TOKEN` missing or expired. Re-fetch via `fetch-secrets.sh github` |
| `gh issue list` returns empty | Issues are disabled on this repo — use ClickUp A&E list `<clickup-list-id>` instead |
| Invite 403 "must be an admin to create an invitation" | Token lacks `admin:org` write scope (read worked because owner+`read:org` suffices). `gh auth refresh -h github.com -s admin:org` |
| Invite 403 "Resource not accessible by personal access token" | Fine-grained PAT lacks org-members write permission. Use the `gh` OAuth token with `admin:org` instead |
| Invite 422 "No seats are available" | Org's prepaid seats are full. Add a seat in the billing UI (no API), or cancel a pending invite / remove an inactive member to free one |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-08-07 | Auto-merge failed repo-wide — PRs #1249/#1263/#1264/#1265 all stalled at `mergeable_state: blocked` with required checks green and `Auto-approve and merge: failure` | `gh pr merge --auto` is a **GraphQL** call running under `PROJECT_TOKEN` (a user PAT), and the per-USER GraphQL bucket was exhausted by agent + interactive usage (`graphql.remaining 0 / used 6689`, `core.remaining 4997`). The `Auto-approve PR` step survived because `GITHUB_TOKEN` is an app-installation token with its own bucket, so only the merge step failed | Ported the hardened <your-other-org> workflow into `.github/workflows/auto-merge.yml`: `gh pr merge --auto` first, then a REST `PUT /pulls/<n>/merge` fallback (separate `core` budget) polled ~5 min with `sha=` as a TOCTOU guard, plus anti-fork / draft / `hold`-label guards. PAT deliberately retained — a `GITHUB_TOKEN` merge would stop the 5 `on: push` workflows on main. Contract locked by `scripts/auto-merge/test_workflow.sh` + a mutation harness. <clickup-task-id> |
| 2026-08-05 | 15,316 `API rate limit already exceeded` warnings from 6 ClickUp cards; `gh api rate_limit` showed `graphql 2642/5000`, `search 30/30`, `core 4998/5000` — nothing exhausted | Secondary throttle on GraphQL `search()` (no visible bucket, user-level). `phase_cascade` issued one `gh pr list --search <card-id>` per (card, repo) every 60s and **retried each throttled call 3×**, tripling the volume that caused it | Dropped `--search` for one plain `gh pr list --state <s> --limit <n>` per (repo, state) per tick + local head-branch filtering; throttle classifier that never retries; cooldown breaker. Measured on `<your-org>/automations`: full merged list = 1,136 rows, 19–22 GraphQL points, ~4.4–5.6s. <clickup-task-id> |

<!-- <clickup-task-id> skip-probe — verifies ruleset skip semantics; safe to remove -->
