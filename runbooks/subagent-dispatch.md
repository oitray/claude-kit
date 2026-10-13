# Subagent Dispatch (Interactive Sessions)

> **Owner:** <your-name> | **Last verified:** 2026-10-06

Conventions for spawning Anthropic-API subagents via the `Agent` tool from an interactive Claude Code session. Owns the prompt-construction rules, model-selection guidance, and parent-side verification responsibilities.

## Minimal-context principle

When spawning subagents via the `Agent` tool, follow Anthropic's minimal-context principle: **never inherit session history; construct exactly what the agent needs.**

**Include in the prompt:**
- Focused task spec (goal + acceptance criteria)
- File paths for context the agent should read itself
- Expected output format + concrete examples
- Constraints + non-goals

**Omit from the prompt:**
- Conversation history or prior context from this session
- Full file contents (agent has file tools and can read)
- Unrelated background or architecture
- Uncertainty or open questions — make a decision and brief the agent with it

**Every brief carries the process-kill rule:** "Never `pkill -f`, `pkill --full`, `killall`, `kill $(pgrep …)`, or `pgrep … | xargs kill` — they match other agents' processes. Stop your own background task with `TaskStop <task-id>`, or `kill` only a PID you launched (captured `$!`) after verifying its exact argv." The one exception is the codex hang-recovery ladder (`docs/runbooks/codex-review.md` "Hang recovery"), run only by the session that dispatched the hung review: it kills a stale codex broker/app-server PID verified by argv and elapsed time. Precedent <clickup-task-id> (2026-10-05): one pattern kill took out the <clickup-task-id> dispatch, another killed four sibling subagents' pollers. The `~/.claude/hooks/broad-kill-guard.sh` PreToolUse hook blocks these forms (exit 2); `# allow-broad-kill` as a shell comment is <your-name>'s manual bypass; the hook ignores it in subagents (`agent_id` in the hook payload) and orc dispatches (`OCC_DISPATCH=1`).

**The hook is a guardrail, not a security control.** It catches *accidental* broad kills by cooperative agents (both 2026-10-05 incidents were honest `pkill -f` calls); a text denylist cannot stop a determined adversary, so do not extend it into a bypass arms race. Covered: `pkill` (any flags), `killall`/`killall5`, `kill $(pgrep|pidof|lsof|ps …)`, `pgrep|ps … | xargs kill`, loops over finder output, `kill -<PGID>`/`-1`/`0` — including path-prefixed names, `sudo`/`env`/`command`/`nohup`/`timeout`/`xargs` wrappers, a single `$(echo|printf|which|command -v|type -p …)` substitution that prints the name, and `sh -c`/`eval` strings. **Not covered: a command name held in a variable.** `p=pkill; $p poller`, `p=killall; $p node`, `${p}` and `"$p"` all pass (exit 0). `$p -f …`, `$p --full …` and `$p 0` block only because any `$var` followed by `-f`/`--full` or by a kill target the hook treats as broad (`0`) blocks whatever the variable holds (`x=ls; $x -f poller` and `x=ls; $x 0` block too); the hook does not resolve the variable (empirical (2026-10-06): live hook replayed with each form as a PreToolUse payload). Live since <your-username>/<config-repo>#284 and #286 (<clickup-task-id>; #274 was superseded and closed unmerged): a finder lookup stops pairing with an unrelated literal-PID or `%job` kill (`pgrep -f x; kill 12345` passes; dynamic targets and `xargs kill` still pair); a quoted `"$(…)"` command name or `-"$(…)"` PGID target blocks like its unquoted form; quoted strings in an interpreter heredoc body are scanned only from the redirect line to the delimiter line, so a quoted string after the delimiter (a commit message naming `killall`) passes; a subshell or process substitution together with an interpreter makes only its own statement's quoted strings strict (a statement ends at `;`, `&`, `&&`, `||` or a newline outside parens; the `&` of a redirect such as `2>&1` does not end one); a `case`/loop/`if`/`{ }` block or a `name()` function definition plus an interpreter likewise makes only its own statement strict, and only compounds that do not balance (a stray `done`/`fi`/`esac`/`}`) make every quoted string strict, so `(cd repo && bash x.sh); git commit -m "… killall …"` and `if true; then bash x.sh; fi; git commit -m "… killall …"` pass and `(echo '…') | bash` is still scanned. Bare command lines inside any heredoc body are scanned as commands either way. Known out of scope: commands written to a file and then executed; aliases or functions defined in an earlier Bash call; command names held in a variable (`p=pkill; $p x`) unless followed by `-f`/`--full` or a broad target such as `0`, or built at runtime beyond a single printing substitution; interpreters run on a script file rather than a quoted string; signals sent from other languages or tools; kill targets printed by a substitution at runtime, such as `kill "$(printf -- -1)"` or `kill $(cmd)` when `cmd` prints `-1`, `0` or `-<PGID>` (blocking these would also block `kill $(cat pidfile)`); kill text inside a quoted string that no interpreter runs, such as `echo 'pkill -f x'` in a `cat <<E` body. Fail mode: a checker error (bad JSON, parse error) blocks; a missing `python3` allows with a stderr warning so a broken interpreter cannot brick every session.

## Model selection

| Use case | Model |
|---|---|
| Mechanical 1-2 file changes, renames, simple edits | Haiku |
| Integration work, multi-file refactors, API changes | Sonnet |
| Architecture, code review, complex debugging | Opus |

## Verification responsibility (parent side)

Subagent self-reported SUCCESS is not sufficient evidence for production-touching work. Before committing code from a subagent that:

- Activates production workflows (n8n, GH Actions)
- Deploys metadata to prod
- Modifies live integrations

…the parent session MUST run an end-to-end smoke against the live target — not just trust the subagent's smoke report. Common failure modes seen in past sessions:

- Subagent's smoke test used a payload that bypassed the buggy code path
- Subagent silenced HTTP errors via `Continue On Fail` and called the run a success
- Subagent confused "200 OK from webhook" with "writeback succeeded" (the SF API call had actually 404'd on a typo'd hostname)

Verify outcomes (data landed in SF, downstream system reflects the change) — not just transport-level success codes.

## Runbook-edit accuracy

When a subagent edits a runbook, the orchestrator must spot-check the actual text before accepting. Common failure mode: agents write tense as if a deferred manual step (e.g. "added via UI on 2026-05-03") had been performed when it had not. The runbook is now wrong, and a future session reading it will trust the false claim. Read the changed lines and verify each factual claim against the live system before moving to the next phase.

## Grep before adding new sections

Before adding a new top-level (`##`) section to a runbook, the subagent must grep the file for related anchors (e.g. `grep -n "DLQ\|drain" file.md`) and report what already exists. If a near-duplicate section is present, extend it inline rather than adding a parallel section. Parallel sections that overlap >50% with existing content get reverted on review.

## "Pre-existing failure" claims need proof

When a subagent reports test failures as "pre-existing and unrelated", it must include the proof in its DONE message: the exact `pytest` invocation run against `origin/main` (or another known-clean ref) showing the same failure. The parent treats unproven claims as the subagent's claim, not as truth — and runs the verification itself before accepting. This catches cases where the "pre-existing" failure was actually introduced by an earlier commit on the same branch or a missing test fixture from the agent's own changes.

## DONE_WITH_CONCERNS is a re-check trigger

If a subagent reports `DONE_WITH_CONCERNS`, the orchestrator must read the changed files for the concern surface area before marking the task complete. The concern is the agent's own pre-emptive flag that something deserves a second look — it is not a free pass to advance.

## Subagent permission narrowing (Layer 10 / Multi-agent rules)

Today subagents inherit the parent session's `bypassPermissions`. This is the wrong default for a "review" subagent that should not have write access to production code, OR for a "research" subagent that should not have shell access to sensitive directories.

**Pattern:** dispatch every subagent with explicit `--allowed-tools` scoped to its task surface. The parent specifies the minimum tool set; the subagent inherits no more.

Examples:

| Subagent role | Allowed tools |
|---|---|
| Code reviewer (read-only) | `Read,Bash(git diff*),Bash(git show*),Grep,Glob` |
| Spec compliance reviewer | `Read,Grep,Glob` |
| Documentation writer | `Read,Write(docs/**),Edit(docs/**),Glob` |
| n8n workflow author | `Read,Write(n8n/**),Edit(n8n/**),Bash(curl*),Bash(jq*)` |
| Test runner (CI-style) | `Read,Bash(npm test*),Bash(pytest*),Bash(sf project*)` |

**Anti-pattern:** dispatching with default permissions ("bypass all") for tasks that don't need write access. A "review this PR" subagent that has Write/Edit could silently rewrite production code mid-review.

**Kill-switch (separate from narrowing):** parent invokes `TaskStop` when subagent exceeds 20-min wall, emits 3+ consecutive errors without progress, or attempts to write outside its allowed-tools scope. See "Multi-agent rules" in `~/.claude/orchestrator/autonomous-mode-contract.md`.
