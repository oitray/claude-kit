# Claude Code Workflow Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-15

## Scope

How the iTerm2 + tmux + Claude Code stack composes into a single plan-mode workflow on <your-name>'s machine. Covers the Claude Code hook reference, plan-mode color/title flow, session-naming chain, and the `/start-task` end-to-end. For terminal/tmux base setup → `iterm-tmux.md`. For remote `occ`/`cca` shell functions → `remote-sessions.md`.

## Architecture

```
iTerm2 dynamic profile
  → zsh occ() function
     → tmux session (per-pane, named after task slug)
        → claude TUI
           ├── PreToolUse / PostToolUse / Stop / SessionStart hooks → ~/.claude/hooks/*.sh
           ├── /start-task (slash command) → ClickUp API + git worktree + iTerm color
           └── /color, /rename built-ins → AppleScript + tmux send-keys to surrounding context
```

Four name backends stay in lockstep: tmux session, tmux window, iTerm tab title, Claude TUI banner.

## iTerm2 Dynamic Profiles

Located at `~/Library/Application Support/iTerm2/DynamicProfiles/<harness-profiles>.json`. Each profile prompts for a session name, then drops into a named tmux session via `occ` or `cca`.

| Profile | Initial command |
|---------|-----------------|
| `OCC: Studio` | `source ~/.zshrc && vared -p 'Session name: ' -c _n && occ --studio --name "$_n"` |
| `CCA: Studio` | `source ~/.zshrc && vared -p 'Session name: ' -c _n && cca --studio --name "$_n"` |

The six plan phases map to iTerm tab colors via `~/.claude/hooks/iterm-phase.sh`:

| Phase | Color | When |
|-------|-------|------|
| `planning` | blue | `/start-task` enters plan mode |
| `review` | cyan | Codex review pass |
| `approval` | purple | Awaiting human ExitPlanMode |
| `implementing` | green | Worktree created, agents dispatched |
| `qa` | orange | Implementation complete, awaiting verification |
| `closed` | default | `/done` or completion |

Color is delivered by writing the iTerm2 tab-color OSC escape (`ESC ]6;1;bg;<red\|green\|blue>;brightness;<N> BEL`) directly to the iTerm2-owned client tty (resolved via `tmux display-message -p '#{client_tty}'` inside tmux, else `tty`). This bypasses tmux entirely — no `allow-passthrough` required — and works regardless of whether `ITERM_SESSION_ID` is stale from a tmux re-attach.

Sibling tools in the same OSC family: `~/.claude/hooks/iterm-group.sh` + the `/blocking` / `/blocked` / `/unblock` / `/blocks` slash commands paint tabs by blocker/blockee group so cross-session dependencies are visually paired. See that script's header for usage.

## tmux Config Highlights

`~/.tmux.conf` — the bits that matter for this workflow:

- `set -g mouse on` + drag-to-`pbcopy` keybindings for clipboard parity with macOS
- `tmux-resurrect` + `tmux-continuum` (15-min interval) for session persistence across reboots
- `status-left "[#S] "` shows the current session name in the status bar
- `set-hook -g session-created 'run-shell "~/.tmux/auto-cca.sh"'` auto-attaches new sessions

## Claude Code Hooks (~/.claude/hooks/)

Wired in `~/.claude/settings.json` under `SessionStart`, `Stop`, `UserPromptSubmit`, and `PreToolUse` keys.

| Hook | Event | Purpose |
|------|-------|---------|
| `cctc-session-start.sh` | SessionStart | Verifies `occ`/`cca` shell functions exist in `~/.zshrc` |
| `main-drift-rescue.sh` | SessionStart | Rescues dirty state in the `automations` main checkout (flock-guarded) |
| `cleanup-gone.sh` | SessionStart, Stop | `git fetch --prune` + `git worktree prune` |
| `in-flight-summary.sh` | SessionStart | Posts in-flight ClickUp + branch summary |
| `guard-main-checkout.sh` | PreToolUse (Write/Edit/Bash) | Blocks writes inside the main checkout outside `docs/superpowers/plans/` and `.worktrees/` (escape: `OCC_ALLOW_MAIN_EDIT=1`) |
| `enforce-branch-name.sh` | PreToolUse (Bash) | Blocks branch creation that violates `<type>/<clickup-id>-<slug>` (escape: `# skip-name-check`) |
| `dup-check.sh` | PreToolUse | Advisory duplicate-PR detector; never blocks |
| `check-deferred.sh` | PreToolUse | Deferred-tool gate |
| `rename-on-prompt.sh` | UserPromptSubmit | Mirrors `/rename TITLE` to tmux + iTerm via `rename-session.sh --no-tui` |
| `rename-session.sh` | utility | Renames tmux session, tmux window, iTerm tab, AND Claude TUI banner in lockstep. Per-pane single-flight via pidfile + token (handles rapid-fire calls) |
| `iterm-phase.sh` | utility | Sets iTerm tab color per plan phase, delegates rename to `rename-session.sh` (color-first sequencing) |
| `session-retrospective-prompt.sh` | Stop | Suggests `/learn` if a worktree exists |
| `stop-if-main-dirty.sh` | Stop | Blocks session end when the main checkout has non-plan dirty files (5-min throttle) |
| `push-reminder.sh` | Stop | Reminds about unpushed commits across multi-system repo list (30-min throttle) |

## Session Naming Chain

User types `/rename "foo"` at the Claude TUI prompt:

1. Claude Code's built-in `/rename` updates the TUI banner.
2. `rename-on-prompt.sh` fires on `UserPromptSubmit`, regex-matches the prompt, and dispatches `rename-session.sh --no-tui "foo"`.
3. `rename-session.sh` updates tmux session name + window name + iTerm tab title (synchronous via AppleScript and tmux commands).

`/start-task` step 8.5 instead calls `iterm-phase.sh planning "<task name>"`:

1. `iterm-phase.sh` writes the iTerm2 tab-color OSC escape directly to the client tty (resolved via `tmux display-message -p '#{client_tty}'` under tmux, else `tty`). This is synchronous — three `printf` calls land before the next step.
2. `iterm-phase.sh` invokes `rename-session.sh "<task name>"`.
3. `rename-session.sh` updates tmux + iTerm immediately, then disowns a subshell that polls for an idle Claude prompt and types `/rename "<task name>"` once Claude is ready.

The disowned injector survives the parent's exit. Per-pane single-flight ensures rapid plan-phase transitions (planning → review → approval → implementing → qa → closed) cancel stale injectors so only the latest title reaches the TUI banner.

> **Historical note (pre-2026-05-15):** `iterm-phase.sh` previously typed `/color <name>` into the Claude pane via AppleScript, expecting a Claude Code built-in to recolor the tab. There is no such command (`/theme` exists; `/color` doesn't), so phase colors silently never rendered. ClickUp task [<clickup-task-id>](https://app.clickup.com/t/<clickup-task-id>) tracked the fix; the OSC-to-tty path documented above is the verified working mechanism. AppleScript session lookup via `ITERM_SESSION_ID` was also dropped — that var doesn't survive tmux re-attach.

## /start-task End-to-End

The `/start-task <ID>` slash command (defined in `~/.claude/commands/start-task.md`) runs:

1. **ClickUp fetch** — pulls task name, description, status, dependencies via REST.
2. **Phase detect** — planning vs dev mode based on status + presence of a plan file in `docs/superpowers/plans/`.
3. **Dependency check** — refuses to start if any blocker is unresolved (status type ≠ `closed`/`done`).
4. **Branch + worktree** — `<type>/<clickup-id>-<slug>` per the convention enforced by `enforce-branch-name.sh`. Worktree at `.worktrees/<type>/<id>-<slug>/`.
5. **ClickUp updates** — sets status to `in progress`, posts a comment, sets the Dispatch Lock custom field to `human:<host>:<uuid>:<iso8601>`.
6. **iTerm phase + rename** — `iterm-phase.sh` colors the tab and renames everything to the task name.
7. **Context gather** — task comments, plan file, branch git log, files-changed-vs-main, related open A&E tasks.
8. **Brief + dispatch** — planning mode invokes `superpowers:brainstorming`; dev mode enters the autonomous execution loop (TodoWrite → implementer subagents → spec + quality reviewers → streaming merge → final reviewer → PR).

## Gotchas

| Issue | Symptom | Fix |
|-------|---------|-----|
| Claude TUI prompt uses NBSP (U+00A0) | `^❯ ` regex in `prompt_is_idle()` silently fails | Match the glyph without asserting the trailing whitespace; strip NBSP via `${rest//$'\xc2\xa0'/}` |
| Disowned subshells outlive script edits | Stale `send-keys` fire after `rename-session.sh` is updated | `pkill -f rename-session.sh` between iterations during development |
| Bash 3.2 PID gotcha (macOS default) | `$$` inside `( ... ) &` returns parent PID, not subshell PID; `BASHPID` unset | Capture `$!` in the parent and have the parent write the pidfile |
| Squash-merge gotcha | Branch picks up phantom conflicts on files it never touched after a co-worker's PR squash-merges | Cherry-pick own commits onto a fresh branch from `origin/main`; supersede the old PR |
| Bash tool runs in zsh | `BASH_REMATCH` is empty in zsh; bash regex one-liners silently fail | Wrap in `/bin/bash -c '...'` |

## Cross-References

- `iterm-tmux.md` — base iTerm2 + tmux setup, SSH between machines
- `remote-sessions.md` — `occ`/`cca` shell functions, remote dispatch
- `salesforce-cli.md` — deploy commands invoked from worktrees
- `helpjuice-api.md` — <knowledge-base> publishing (mirror of this article lives there)
- `~/.claude/CLAUDE.md` — global communication style, evidence-based language, plan execution workflow
- `Projects/CLAUDE.md` — cross-project standards
- `automations/CLAUDE.md` — automations-specific (production safety, PR workflow, subagent rules)
