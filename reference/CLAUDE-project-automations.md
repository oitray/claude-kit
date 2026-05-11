# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Salesforce workspace for <your-org>'s VoIP business operations. Production org: `<your-email>`, API version 66.0.

| Directory | Purpose |
|-----------|---------|
| `salesforce/force-app/` | Core metadata — Apex, flows, objects, reports, permissions |
| `salesforce/scripts/` | Utilities: `health-check.sh`, `generate_lead_flow.py`, `sharepoint-upload.py` |
| `salesforce/destructive-deploy/` | Destructive change manifests for metadata removal |
| `n8n/` | Workflow JSONs (SolHub doc request, WLP training sync) |
| `docs/` | Plans, changelogs, design docs, announcements |
| `docs/runbooks/` | API/CLI quick-reference per service (auth, endpoints, <your-org> IDs) |
| `.claude/personas/` | Active: <internal-bot>, <internal-bot>. 5 legacy personas retired 2026-04-28 |
| `.claude/rules/` | Path-scoped rules (brand, Lightning, SF dev patterns) |
| `services/<internal-bot>/` | <internal-bot> EA bot — Python FastAPI core (Claude API, Supabase memory/audit) |
| `services/<internal-bot>-teams/` | <internal-bot> Teams adapter — TypeScript Bot Framework handler |
| `services/<internal-bot>-connector/` | <internal-bot> Claude.ai connector — Streamable HTTP MCP (Phase 7) |
| `infra/<internal-bot>/` | <internal-bot> Bicep — ACA, Key Vault (`<credential-vault>`) |
| `services/hermes/` | Hermes Agent runtime (<internal-bot> persona) — local Mac orchestrator (Phase 1+) |
| `scripts/lead-dedup/` | `/lead-dedup` skill — transfer Contact+Account data to matching Lead, delete source records |
| `scripts/publish-kit/` | Sanitize + publish pipeline for public `<your-username>/claude-kit` mirror |
| `.claude/publish-kit/` | Allowlist, sanitize rules, deny patterns, internal-refs config |

Deployment commands → `docs/runbooks/salesforce-cli.md`.

## Production Safety

**NEVER deploy without explicit user confirmation.** This is a live production org.

- Validate before deploy (`sf project deploy validate`)
- Don't modify: SLA fields (`First_New_to_RFD__c`, `First_RFD_to_InProgress__c`, `SLA_Risk_Score__c`), timezone automation (`UniversalTimezoneService`)
- Avoid major deployments 9 AM - 5 PM EST
- Rollback: `sf project deploy report` → retrieve previous version from Git → redeploy

### Risk Audit Before Production Data-Writes

Any plan that bulk-inserts or bulk-updates production records (Cases, EmailMessages, Accounts, etc.) MUST include an empirical risk audit BEFORE presenting the plan. Procedure + per-surface query table + severity classification: `docs/runbooks/salesforce-cli.md` "Risk Audit Before Production Data-Writes".

## Apex Architecture

Apex classes follow consistent naming patterns:

| Suffix | Purpose |
|--------|---------|
| `Controller` | LWC/Aura backend |
| `Service` | Business logic |
| `Queueable` | Async processing |
| `Scheduler` | Scheduled jobs |
| `Batch` | Bulk operations |
| `Invocable` | Flow-callable |
| `Action` | Trigger actions (@future) |
| `Test` | Test class (paired 1:1) |

CI/CD workflows → `docs/runbooks/github-api.md`.

## PR Workflow

The user-scope `~/.claude/commands/commit-push-pr.md` supersedes `commit-commands:commit-push-pr`. It auto-injects ClickUp task IDs into PR bodies, enabling `clickup-close-on-merge.yml` to close tasks on merge.

### Branch Naming Convention

All branches must follow: `<type>/<clickup-id>-<slug>`

| Segment | Values | Example |
|---------|--------|---------|
| `type` | `feat`, `fix`, `chore`, `docs`, `refactor` | `feat` |
| `clickup-id` | ClickUp task ID (7+ lowercase alphanumeric chars) | `<task-id>` |
| `slug` | Lowercase letters, digits, hyphens | `multi-session-hygiene` |

Full example: `feat/<task-id>-multi-session-hygiene`

A `PreToolUse` hook (`~/.claude/hooks/enforce-branch-name.sh`) blocks branch creation that violates this pattern. To bypass: add `# skip-name-check` to the command.

### Squash Merge Gotcha

When GitHub squash-merges a PR, any commits pushed to the source branch AFTER the merge are orphaned — they don't land on main and the branch will conflict if reused. After a squash-merge, always cherry-pick any remaining commits onto a fresh branch from main. Never reuse the original branch for follow-up PRs.

**Default rule (auto-merge in this repo):** treat any pushed branch as **frozen the moment the PR opens**. Auto-merge can land it within seconds. Any follow-up work — including responding to "also do X" mid-task — should start with `git fetch origin main && git checkout main && git pull && git worktree add <new-path> -b <new-branch> main` BEFORE the first edit. If you've already made a follow-up commit on the old branch and the push is rejected ("stale info" / non-fast-forward), don't force-push — the PR is merged. Cherry-pick the orphan commit onto a fresh branch from main and open a new PR.

**Dispatched orc PRs:** run codex against the local branch BEFORE `gh pr create` (auto-merge fires on `opened`, not `ready_for_review`). See `.claude/rules/dispatch-completion.md`.

### Plan PR + ClickUp close-on-merge

`clickup-close-on-merge.yml` closes any task referenced via a GitHub-style close keyword in the merged PR body. The supported forms (case-insensitive):

    Closes: https://app.clickup.com/t/<id>
    Fixes #<id>
    Resolves https://app.clickup.com/t/<id>

Plain URL mentions like `Companion to <url>`, `Source ClickUp card: <url>`, or a runbook prose link to `https://app.clickup.com/t/<id>` do NOT close the task — only the keyword form does. `commit-push-pr` injects the `Closes:` line automatically for tasks the PR is meant to close. Plan-only / docs PRs simply omit the keyword and may reference the task by URL freely.

The contract is locked by `scripts/clickup-close-regex/test_regex.sh` (positive + negative cases). Any change to the workflow regex must keep that harness passing.

### Resumed Branches Need a Rebase Check

A branch created hours/days ago (via `/start-task` during planning, or any worktree that survived intervening merges) may be behind main if other PRs landed in the interim. Before pushing or opening the PR, check:

    git -C <worktree> fetch origin main
    git -C <worktree> rev-list --left-right --count origin/main...HEAD
    # output: <behind>\t<ahead>

If `behind > 0`, rebase before push:

    git -C <worktree> rebase origin/main
    git -C <worktree> push --force-with-lease

Otherwise `git diff main --stat` (and the GitHub PR view) shows every intervening file as a deletion, which reads as a massive revert and hides the actual scope of the PR.

## Bash Tool Gotchas

cwd persistence, parallel-failure cascade, and guard-hook literal-string match: `docs/runbooks/claude-code-bash.md`.

## macOS Shell Portability

bash 3.2 vs newer-bash pitfalls + Python 3.13 SSL trust-store workaround: `docs/runbooks/macos-shell.md`.

## macOS LaunchAgents

PATH inheritance + `EnvironmentVariables` requirement for daemons reaching Homebrew CLIs: `docs/runbooks/launchd.md`.

## Orchestrator pytest cross-directory caveat

Pytest stub-conflict between `orchestrator/agent/tests/` and `orchestrator/functions/tests/` — run separately: `docs/runbooks/orchestrator.md` "pytest cross-directory caveat".

## Worktree Gotchas

`/start-task` race, mid-session worktree disappearance, stop-hook + intentional uncommitted files (daemon runtime, mid-session subagent commits, `docs/handoffs/`), and modify/delete conflict recovery: `docs/runbooks/git-worktrees.md`.

## Subagent Dispatch (Interactive Sessions)

Minimal-context prompt construction, model selection (Haiku/Sonnet/Opus), parent-side verification responsibility, runbook-edit accuracy, and DONE_WITH_CONCERNS handling: `docs/runbooks/subagent-dispatch.md`.

## External Service Workflow

All external service calls use direct API/CLI — no MCP servers (except context7, Notion, PAL).

1. **Check runbook** — Read `docs/runbooks/<service>.md` before any external API or CLI call. If no runbook exists, create from `docs/runbooks/_template.md`. **Also read at design time, not only execute time** — see `.claude/rules/runbook-citation.md`. Cite line refs inline when claiming API capability or limitation.
2. **Fetch credentials** — use `fetch-secrets.sh <service>` or `az keyvault secret show` per runbook auth section.
3. **Execute** — use the runbook's auth, endpoints, and patterns.
4. **On failure** — update the runbook with corrections, bump `Last verified`, retry — only report failure after that.

**Browser-tool selection** → `.claude/rules/browser-automation.md` (Playwright vs browser-harness vs Browser Use Cloud, once the auth ladder lands you in browser-land).

## Agent Runtime (Hermes/<internal-bot>)

Autonomous agents are dispatched by a Mac Studio `local-poller` daemon that polls ClickUp every 1s for `status=queued` tasks with `Executor=local-*`. No cloud surface; full architecture in `docs/runbooks/orchestrator.md`.

**Executors:**
- `Executor=local-claude` → Claude Code session via `<orchestrator-cli> --fg`
- `Executor=local-hermes` → Hermes Agent (<internal-bot> persona) via `python -m hermes <task-json>`; multi-instance role-routed model selection from `orchestrator/config/routing.yaml`; cost + wall cap enforced by `services/hermes/hermes/watchdog.py`; events reported to <internal-bot> Teams DM via HMAC-signed HTTPS. See `docs/runbooks/hermes.md` and `docs/runbooks/<internal-bot>-hermes-integration.md`.
- `Executor=local-codex` → Codex CLI via `codex exec --full-auto`
- `Executor=local-mlx` → local MLX model via `local-llm.sh` (text-in/text-out only)

**Dispatch triggers:**
- `plan` tag on a ClickUp task → planner preset
- Move task to `queued` status → dispatch per `Executor` field

**Safety gates:** Plan Reviewed + Codex Reviewed checkboxes (unchanged).

**Task status flow:** `backlog` → `planning` → `implementation` → `queued` → `in progress` → `qa` → `completed` (unchanged).

Full lifecycle → `docs/runbooks/orchestrator.md`.

All tasks in **ClickUp**, split across two lists by audience (`/todos` defaults to a combined view):

- **A&E** (`<clickup-list-id>`, KV `CLICKUP-AE-LIST-ID`) — Salesforce / VoIP business automations: flows, Apex, reports, triage, n8n business workflows, support/dev work tied to the live org. Public intake (rnd@<your-org>, <internal-bot> `/request`, `/request` slash) lands here.
- **Automation Infrastructure** (`<clickup-list-id>`, KV `CLICKUP-INFRA-LIST-ID`) — platform / dev-loop machinery: <internal-bot>, <internal-bot>, orchestrator, MCP servers, Claude skills/commands, runbooks, Key Vault, CI/CD, publish-kit. Manual-only intake.

Both lists share identical statuses + custom fields, so orchestrator + classifier code is list-agnostic. GH Issues disabled. ClickUp has no public Move Task endpoint — tasks stay where they're created.

Public mirror → `docs/runbooks/publish-kit.md`.

---

**Critical Reminder**: Production org. Prioritize safety, test thoroughly, get explicit confirmation before production changes.
