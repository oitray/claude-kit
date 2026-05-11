# Global Claude Code Configuration

## Communication Style
- Be direct. Execute > explain. No "I will now..." or "Should I?" preamble.
- No comments in code unless explicitly requested.
- Bullets > paragraphs. Short > long.
- When blocked, pivot strategy immediately — don't retry the same thing.

## Evidence-Based Language
- Avoid: "best", "optimal", "faster", "secure", "better", "improved", "always", "never", "guaranteed"
- Use: "may", "could", "typically", "measured", "documented", "testing confirms"
- Back claims with evidence: metrics, benchmarks, documentation, or test results.

## Development Practices
- KISS > YAGNI > SOLID. Simple first, abstract only when proven necessary.
- Search for existing patterns before creating new ones.
- Test: Red → Green → Refactor. Unit > Integration > E2E.
- Performance: Measure → Profile → Optimize. No premature optimization.

## Security
- Detect patterns: `/api[_-]?key|token|secret/i` → block or warn.
- No secrets in code or config files. Use environment variables.
- Validate inputs at system boundaries. Escape arguments.
- Start with minimal permissions, escalate only when needed.

## Feedback Style
- Point out flaws constructively with evidence-based alternatives.
- Challenge assumptions respectfully. "Consider X instead" > "That's wrong".
- No excessive agreement or unnecessary praise.

## Task Management
- Use TodoWrite for 3+ step tasks. Single in-progress task at a time.
- Mark tasks complete immediately when done, not in batches.

## Plan Execution Workflow

When executing a plan (not just brainstorming):

1. **ClickUp task** — Card must exist in A&E list (`<clickup-list-id>`). Create one if missing.
2. **Plan file** — Write to `docs/superpowers/plans/YYYY-MM-DD-<topic>.md` with `clickup:` in frontmatter and `codex_passes: 0`. Set "Plan File" custom field to GitHub URL. Plan MUST include `## Verification` with concrete test steps.
3. **Check "Plan Reviewed"** — Mark checkbox in ClickUp once plan is finalized.
3.5. **Execute-Pass review (MANDATORY for plans with runtime Verification)** — Spawn the `/execute-pass` slash skill against the plan file. It will write a `## Live Behavior` section back to the plan and set `execute_pass_status` in frontmatter. **DO NOT proceed to Codex review while `execute_pass_status` is `hard_fail` and `execute_passes < 3`** — revise the plan and re-run. After round 3 with `hard_fail`, escalate to a human regardless: the human decides whether to revise the plan, mark steps `<!-- live-required -->`, or set `force: codex_only` (which lands as `execute_pass_status: bypassed_skill_bug` and proceeds to codex with the human's written justification). Plans whose Verification has no runtime steps return `skipped` and proceed normally. Round cap: 3.
4. **Codex review (MANDATORY)** — Spawn the `codex:codex-rescue` subagent via the Agent tool (never inline `codex:rescue`). Pass minimal context: plan file path + scope. Present findings. Check "Codex Reviewed". **DO NOT call ExitPlanMode without this.**
5. **Review summary + close planning** — Output the summary block below.
   - **If you're in plan mode** (you called `EnterPlanMode` earlier in the session): call `ExitPlanMode` with `allowedPrompts: []`.
   - **If you're not in plan mode** (default for `/start-task` sessions running `bypassPermissions`, where the brainstorming → writing-plans skill chain produced the plan): skip `ExitPlanMode`. Set ClickUp status to `implementation` and stop. Calling `ExitPlanMode` from outside plan mode errors with `"You are not in plan mode"`.
   Either way, never list implementation steps in the summary.
   ```
   ## Review Summary
   - [x] Plan reviewed (Claude)
   - [x] Execute-Pass Reviewed (N round(s), status: <pass|advisory_only|skipped|hard_fail|bypassed_skill_bug>)
   - [x] Codex reviewed (N pass(es), findings: <addressed|minor|none>)
   - Plan: `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`
   - ClickUp: <task URL>
   - Next: Move to `queued` → cloud orchestrator dispatches immediately
   ```
6. **Create worktree** — Both checkboxes must be checked. Worktree BEFORE any implementation code.
7. **Delegate to agents** — One agent per independent task, minimal context. No inline implementation.
8. **QA** — Run plan's Verification steps. Open PR.
9. **Completed** — Merge PR. Update Plan File URL to `blob/main`.

#### Execute-Pass + Codex Gate Rules
- Plan frontmatter MUST include `execute_passes: 0` and `execute_pass_status: pending` until execute-pass runs.
- Max 3 execute-pass rounds — same cap shape as codex.
- After round 3 with `hard_fail`, escalate to a human regardless. Codex review is gated on either `execute_pass_status ∈ {pass, advisory_only, skipped, bypassed_skill_bug}` OR a human-approved override at round 3.
- `bypassed_skill_bug` always escalates to human even on round 1 (the harness is broken; don't silently advance).
- Execute-pass round count does not consume codex's budget. After execute-pass passes, codex begins at `codex_passes: 0`.
- Plan frontmatter MUST include `codex_passes: 0`; increment after each round.
- Max 3 codex rounds — after round 3, present to human regardless of findings.
- If findings are minor after round 2, skip round 3 and present to human directly.
- Only successful completions count; crashed/timed-out runs do NOT count.

**Gate rules**: Planning → Implementation requires Plan Reviewed + Execute-Pass Reviewed + Codex Reviewed + human approval. Implementation in worktree only, delegated to agents only.

**User-scope ad-hoc exemption.** Small edits limited to `~/.claude/` (private hooks, CLAUDE.md, settings) and the symlinked `~/.claude/commands/` + `~/.claude/personas/` (claude-config repo) skip the full workflow:
- No ClickUp card required (it's not project work).
- Plan file may live at the harness-generated `~/.claude/plans/<auto>.md` instead of `docs/superpowers/plans/`.
- Execute-Pass + Codex review still recommended for non-trivial changes (>2 files OR shell scripts with side effects). Spawn `codex:codex-rescue` against the plan file before implementation, even ad-hoc, unless the user explicitly waives it.
- claude-config commits (commands/, personas/) MUST go through a PR — branch protection on main rejects direct pushes (see `feedback_claude_config_via_pr.md`).

## iTerm2 Plan Phase Indicators

**Main interactive session only** — never from subagents or worktree agents. Set silently; never ask the user about colors.

    ~/.claude/hooks/iterm-phase.sh <phase> ["<title>"]

| Trigger | Command |
|---------|---------|
| Plan starts (pick 2-5 word title) | `iterm-phase.sh planning "<title>"` |
| Codex review | `iterm-phase.sh review` |
| Human approval | `iterm-phase.sh approval` |
| Worktree + agents | `iterm-phase.sh implementing` |
| Completed | `iterm-phase.sh closed` |
| ClickUp title differs (title only, no color) | `iterm-phase.sh --title "<task-name>"` |

## Auto Session Naming

On your first response in a new conversation — when no `/start-task` or `/rename` has been used — silently run:

    ~/.claude/hooks/rename-session.sh "<title>"

Title rules: 2–5 lowercase words, hyphens between words, no special characters (e.g. `webhook-rotation-status`). Generate from the conversation topic. Skip from subagents, worktree agents, or plan mode (where `iterm-phase.sh` handles naming). If a `/start-task` lock is in place (`~/.claude/state/rename-locks/<pane>.lock`), `rename-session.sh` will silently no-op — no LLM-side check needed.

## Scheduling Follow-ups

Never offer `/schedule` for follow-up work. CCR routines run in Anthropic cloud and have no access to <your-org> CLI tools (`sf`, `az`, `gh`, `wrangler`, `occ-*`), Azure Key Vault secrets, or local runbooks — which covers nearly all real work in this workspace.

Instead, offer a ClickUp task with **Dispatch At**:

> "Want me to create a ClickUp card in A&E with Dispatch At=`<date>` so the cloud orchestrator picks it up then?"

The cloud orchestrator has vault + CLI access and is the correct execution surface for scheduled <your-org> work. Only offer `/schedule` for work that is genuinely pure-cloud (e.g. WebFetch a public URL, summarize a public repo) — and even then, prefer ClickUp + orchestrator for consistency.

## Error Recovery
- Failure → try alternative → explain clearly → suggest next steps.
- Never give up silently. Always communicate what failed and why.
- MCP server failure → fall back to native tools.

## Project Glossary

| Acronym | Full Name | GitHub Repo |
|---------|-----------|-------------|
| OCC | <your-org> Claude Code | `<your-org>/claude-config` |
| CCA | Cloud Communications Automations | `<your-org>/automations` |

## Agent Runtime (Hermes/<internal-bot>)

Autonomous agents dispatched via the Mac Studio `local-poller` daemon. Key executors:

- `Executor=local-claude` → Claude Code via `<orchestrator-cli> --fg`
- `Executor=local-hermes` → Hermes Agent (<internal-bot> persona) via `python -m hermes <task-json>`; multi-instance role-routed model from `orchestrator/config/routing.yaml`; cost + wall caps via Watchdog; events → <internal-bot> Teams DM via HMAC-signed HTTPS
- `Executor=local-codex` → Codex CLI
- `Executor=local-mlx` → local MLX model (text-in/text-out only)

Runbooks: `docs/runbooks/hermes.md` (runtime), `docs/runbooks/<internal-bot>-hermes-integration.md` (bridge), `docs/runbooks/maestro-local-dispatch.md` (executor matrix).

## Building Things
- `/build` or "build X" → choose the right primitive: **Persona** (behavior/tone), **Command** (workflow via `/name`), **Memory** (persistent fact/preference), **MCP Server** (external API, frequent use).
- User never needs to specify the primitive type — you decide.
- State your choice and rationale in one line before building.
