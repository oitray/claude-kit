# Maestro Local Dispatch Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-03

## Auth

- **Method:** `DefaultAzureCredential` — launchd plist sets `AZURE_CONFIG_DIR=/Users/<your-username>/.azure-admin`
- **Vault:** `<credential-vault>` (same as cloud orchestrator)
- **Pattern:** Daemon runs as a user LaunchAgent. `DefaultAzureCredential` picks up the admin config dir from the env var; no manual `az login` needed after initial `~/.azure-admin` setup.
- **Precedent:** Matches `services/maestro-mcp/com.oit.maestro-mcp.plist:18-25` and `docs/runbooks/maestro.md:18`.

## Architecture Overview

All dispatch flows from the Mac Studio `local-poller` daemon directly to the executor wrappers. There is no cloud Function or Service Bus subscription anymore. See `docs/runbooks/orchestrator.md` for full architecture.

## Blocker DM body contract (Phase 1, 2026-05-16)

<internal-bot> "🛑 Blocker — needs input" cards include three body blocks when the executor provides them:

| Block | Source | Purpose |
|---|---|---|
| `reason` (required) | Short one-line failure label, e.g. `[executor=<executor>] <orchestrator-cli> exited 1`. | What broke. |
| `detail` (optional) | Secondary context — preflight reason, exception type+message, validation summary. | Why it broke. |
| `executor_tail` (optional) | Last ~30 lines / 4 KB of executor stdout+stderr (monospace block, front-truncated with `(truncated)` marker if over cap). | Evidence — actual log lines, traceback, model output. |

**Signature:**

```python
cloudie_dm.emit_blocked(
    task_id, task_name, executor, reason,
    *,
    detail: str = "",
    executor_tail: str = "",
)
```

Production callers route through `common.emit_event_dm("blocked", ...)`. Pass new fields as kwargs:

```python
common.emit_event_dm(
    "blocked",
    task_id=task_id,
    task_name=task_name,
    executor=executor_hint,
    reason=f"<orchestrator-cli> exited {rc}",
    detail="<secondary context>",      # optional
    executor_tail=result.tail,         # optional
)
```

**Capacity caps** (enforced in `~/.claude/bin/lib/teams_dm.py:_build_escalation_card`):

| Field | Cap | Behavior on overflow |
|---|---|---|
| `reason` | 2000 chars | Truncated to `2000 - len("… (truncated)")` + suffix |
| `detail` | 2000 chars | Same as reason |
| `executor_tail` | 4096 bytes | Front-truncated (oldest dropped), `(truncated)\n` prefix prepended, line-boundary-aligned where possible |

Module constants in `teams_dm.py`: `_REASON_CHAR_CAP`, `_DETAIL_CHAR_CAP`, `_TAIL_BYTE_CAP`, `_TRUNCATION_MARKER`, `_TAIL_TRUNCATION_PREFIX`. Total card body stays well under the ~25 KB Bot Framework Adaptive Card limit even at worst-case fill.

**Capturing the tail in executors.**

For subprocess-fork executors (`local_claude`, `local_hermes` once wired), use `common.run_with_tail`:

```python
result = common.run_with_tail(argv, env=env, max_tail_lines=30, max_tail_bytes=4096)
# result.returncode, result.tail
```

Helper at `~/.claude/bin/exec/_common.py:run_with_tail`. Streams stdout+stderr through a `deque(maxlen=N)` ring buffer; pipe combined with `stderr=subprocess.STDOUT` to preserve causal order. `text=True, errors="replace"` guards against non-UTF-8 bytes that would otherwise deadlock the pipe.

For executors that stream stderr line-by-line (`local_codex`), declare a ring inside the run function:

```python
from collections import deque
_stderr_ring: deque[str] = deque(maxlen=30)
for line in proc.stderr:
    _stderr_ring.append(line.rstrip())

# Pass at every blocker emit site:
executor_tail="\n".join(_stderr_ring)
```

For pure-Python executors (`local_mlx_*`, `_common.validate_paths_or_reject`), use in-scope context:

- Exception handlers → `executor_tail=traceback.format_exc()[-4096:]`
- Validation rejections → `executor_tail="\n".join(f"  {r.path}: {r.reason}" for r in rejections)[-4096:]`
- Pre-condition failures with no useful evidence → `executor_tail=""` (card omits the monospace block)

**Backwards compatibility.** Legacy callers (reason-only) keep working — both new kwargs default to `""` and the card builder omits the corresponding block when empty.

**AST regression guard.** `~/.claude/bin/tests/test_cloudie_dm.py::test_all_blocker_emit_sites_pass_executor_tail` walks `local_mlx_classify.py`, `local_mlx_patch.py`, `local_mlx_review.py`, `_common.py` and fails if any `emit_event_dm("blocked", ...)` call is missing the `executor_tail` kwarg. A parallel test exists per file for `local_codex.py`. Future executor edits land a missing `executor_tail` at red-CI time, not in production.

## Peak-Window Source of Truth

Single config in `~/.claude/bin/lib/peak_window.py`. Exports `is_peak(now: datetime) -> bool` and `next_off_peak(now: datetime) -> datetime`.

**Current constants (2026-05-03):** weekdays 05:00–11:00 PT. Time math uses `zoneinfo.ZoneInfo('America/Los_Angeles')` (DST-aware). Source URL and last-verified date are pinned in the module docstring.

**Quarterly verification required** — Anthropic moved the window once (March 2026). Before each quarter, re-check the source URL in `peak_window.py`'s docstring and update the constants + last-verified date if the window changed.

`extended` window (default for `<executor>`):
- Weekday outside 05:00–11:00 PT → fire immediately
- Weekend → fire immediately
- Weekday 05:00–11:00 PT → defer until 11:00 PT; daemon emits `deferred` <internal-bot> DM with wake-time

`now` → fire immediately regardless of clock. `off-peak-only` → all weekday hours treated as peak (fires weekends only).

## `<orchestrator-cli> --fg` Contract

`--fg` forces foreground/synchronous execution (reserves a slot immediately and runs). Without it, `<orchestrator-cli>` enqueues to `<queue-cli>` and returns without running anything (`scripts/orchestrator/<orchestrator-cli>:59,106,204-227,252,263`).

Daemon invocation shape:
```bash
<orchestrator-cli> <preset> --fg --task <task-id> --source maestro-local "<prompt>"
```

The `--fg` flag is load-bearing. Wrapper at `~/.claude/bin/exec/local_claude.py` does NOT export `ANTHROPIC_API_KEY` and does NOT bypass `<orchestrator-cli>`'s built-in rate-limit detection.

## Dispatch Lock value formats

The Dispatch Lock custom field (`<azure-uuid>`) is a coordination point with multiple writers. Recognize four claim formats and one passive marker:

| Value pattern | Writer | Meaning |
|---|---|---|
| `local-routed:<uuid>` | cloud Function `_route_local` | published to maestro-events; daemon owns next |
| `local:<host>:<run_id>:<iso>` | local daemon | actively executing |
| `human:<host>:<uuid>:<iso>` | `/start-task` step 7 | human session claimed; do not auto-dispatch |
| `cloud:<...>` | reserved for cloud agent | future use |
| bare ISO-8601 (e.g. `2026-05-04T17:57:54.312Z`) | n8n queue-runner workflow | passive observation marker; NOT a claim |

`_set_dispatch_lock` at `orchestrator/functions/function_app.py` raises `RuntimeError` only when the existing value matches a known claim prefix. Bare strings (the n8n marker) are logged + overwritten — verified empirically 2026-05-04 during <clickup-task-id> (PR #361). Without that fix, n8n races the cloud Function on every queued event and wins, causing local routing to silently fall back to `_enqueue` (cloud queue).

When debugging a `local_routing_failed dispatch_lock already held` log line, check whether the held value carries a claim prefix. If it does, two orchestrator invocations are racing and the second one's bail-out is correct. If it's a bare string, you've hit a regression of #361.

## Message Lifecycle

1. Cloud Function publishes `DispatchRequestEvent` to `maestro-events` topic with application property `pool='local'` and sets `Dispatch Lock = local-routed:<event_id>` on the ClickUp task.
2. `sub-local` subscription routes the message to the Studio daemon (SQL filter applied broker-side).
3. Daemon receives one message (prefetch=0; only receives when an executor slot is free).
4. **Daemon writes checkpoint** to `~/.claude/orchestrator/local-tasks/<task-id>.json` before touching the SB lock.
5. **Daemon completes the SB message immediately** — never holds the Service Bus lock while sleeping for a window. All scheduling is local after this point.
6. Daemon replaces Dispatch Lock with `local:<host>:<run_id>:<iso>`, advances task to `in progress`, spawns executor subprocess.
7. Executor streams stderr; daemon emits <internal-bot> DMs per state (see DM Event Set below).
8. On terminal state: daemon clears Dispatch Lock, advances task to `qa` (success) or back to `queued` on retryable failure.

**Never sleep while holding the SB lock** — the lock TTL is 1 minute (max 30-min auto-renew). The pattern above avoids this by completing immediately.

## DM Event Set

Daemon uses `~/.claude/bin/lib/cloudie_dm.py` (thin adapter over `orchestrator/agent/teams_dm.py` named methods).

| Event | Trigger | Throttle |
|---|---|---|
| `accepted` | Daemon accepted a `dispatch_request` | once per task |
| `deferred` | Task accepted but waiting for off-peak window | once per task; includes wake-time |
| `started` | Window opened, executor spawned | once per task |
| `phase-transition` | Long-running task changed phase | per phase |
| `heartbeat` | Task still running | 1 per 5 min per task |
| `blocked` | Task hit a blocker | once per blocker; reason included |
| `question` | Subagent asked user a question | once per question; verbatim |
| `rate-limit-hit` | Executor reported rate limit | once per occurrence; offers switch-executor or wait |
| `completed` | Task finished cleanly | once per task; ClickUp comment URL |

DM format follows the cloud pattern with an added `Executor:` line.

## Backpressure

Daemon caps concurrent in-flight tasks at 4. `prefetch_count=0`. Receiver is slot-aware — only calls `receive_messages()` when a slot is free. When all 4 slots are full, receiver pauses (does NOT receive). Service Bus broker retains undelivered messages until the daemon resumes. The daemon does NOT receive-then-abandon (that decrements delivery count toward DLQ after 5 attempts).
