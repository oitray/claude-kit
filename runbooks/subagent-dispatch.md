# Subagent Dispatch (Interactive Sessions)

> **Owner:** <your-name> | **Last verified:** 2026-05-08

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
