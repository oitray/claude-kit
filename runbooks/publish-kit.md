# publish-kit Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-15

Sanitizes internal skills, personas, and runbooks and force-pushes them to the public mirror `<your-username>/claude-kit`.

## Auth

- **Method:** GitHub CLI (`gh`) over HTTPS
- **Vault:** N/A — `gh auth login` must be done once per machine
- **Secret name:** N/A
- **Env var:** `PUBLISH_KIT_REAL_PUSH=1` required for actual push (dry-run is default)
- **Fetch creds:** `gh auth status` to verify before first push
- **MCP server:** N/A

## Common Operations

### Manual dry-run

```bash
bash scripts/publish-kit/publish.sh
# prints snapshot path + manifest diff, no push
```

### Manual push

```bash
# Slash command (wraps below)
/publish-kit --push

# Direct
PUBLISH_KIT_REAL_PUSH=1 bash scripts/publish-kit/publish.sh \
  --push --non-interactive --approve-split stella-fullstack
```

### Auto-sync (default)

Any `git commit` via Claude Code's Bash tool that touches a watched path triggers the PostToolUse hook in `.claude/settings.json`, which runs `scripts/publish-kit/post-commit-hook.sh`.

**Watched paths:**
- `.claude/personas/*.md`
- `docs/runbooks/*.md`
- `skills/*/SKILL.md`

Hook does NOT fire on GitHub PR merges — only on local `git commit`.

### Force full rebuild

```bash
bash scripts/publish-kit/publish.sh --push --force
# skips the drift gate (>5 file changes)
```

Bumping `.claude/publish-kit/sanitize.yml` `version:` auto-forces a full rebuild.

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| Public repo | `<your-username>/claude-kit` |
| Default branch | `main` (force-pushed) |
| Manifest cache | `~/.claude/publish-kit/.last-manifest.json` |
| Sanitize version cache | `~/.claude/publish-kit/.last-published-version` |
| Logs | `~/.claude/publish-kit/logs/YYYY-MM-DD.jsonl` |
| Snapshots (ephemeral) | `~/.claude/publish-kit/snapshots/<run-id>/` |

## Pipeline Stages

1. **Snapshot** — copy allowlisted sources into a temp dir
2. **Sanitize** — apply `sanitize.yml` regex rules (PII, internal URLs, product names)
3. **Scan** — `scan.py` post-sanitize leak detector; fails on hit
4. **Validate** — `frontmatter.py` + `internal-refs.py` linters
5. **Transform** — e.g. `stella-consolidate.py` merges 3 internal skills → 1 public persona
6. **Manifest diff** — compare against `.last-manifest.json`; no-op if unchanged
7. **Drift gate** — abort if >5 files changed unless `--force`
8. **Clone + overlay** — clone `<your-username>/claude-kit`, strip published dirs, overlay snapshot; preserves `README.md`, `LICENSE`, `.github/`
9. **Force-push** — single squashed commit as `publish-kit@local`

## Gotchas

- **Default remote is HTTPS**, not SSH. `gh` CLI uses HTTPS by default; SSH auth will fail.
- **Hook only fires on Claude Code Bash-tool commits**, not on `gh pr merge` or manual `git commit` in a normal terminal.
- **`--force` bypasses drift gate, not manifest idempotency.** To re-publish unchanged content, bump `sanitize.yml` version.
- **`--dry-run` mode cleans up RUN_TMP on exit.** Set `RUN_TMP_KEEP=1` to inspect snapshots after a dry run.
- **Scaffolding preservation** depends on remote clone succeeding. First-push to an empty repo falls back to `git init` and does not preserve anything.
- **Codex CLI review of sanitized output** tends to stall on stdin in `codex exec`. Use inline grep audits instead for deterministic review.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `Permission denied (publickey)` on push | Remote set to SSH — verify `PUBLIC_REMOTE` is HTTPS or unset to use default |
| `no changes since last publish — nothing to do` | Expected on idempotent run. Bump `sanitize.yml` version or change a watched source. |
| `drift gate triggered (N changes > 5)` | Intentional — review the diff; re-run with `--force` if intended |
| Scaffolding missing after push | Clone step failed silently — check network, re-run with `gh api repos/<your-username>/claude-kit` to restore files individually |
| Scanner fails with new PII hit | Add rule to `sanitize.yml`, bump `version:`, re-run |
| `Unterminated string` on Claude Code hook load | Hook JSON has an unescaped regex — hook body should call an external script, not inline |

## Rollback Procedure

```bash
# The public repo is force-pushed on every run. Previous state is lost.
# To recover: use GitHub's repo-level Restore Code feature, or push an older
# manifest snapshot from the local cache.

# View recent snapshots:
ls -la ~/.claude/publish-kit/snapshots/

# Manually restore a prior snapshot by setting manifest and re-running:
cp ~/.claude/publish-kit/snapshots/<run-id>/manifest.json \
   ~/.claude/publish-kit/.last-manifest.json
PUBLISH_KIT_REAL_PUSH=1 bash scripts/publish-kit/publish.sh --push --force
```

For complete rollback of the public repo to pre-publish state, the original scaffolding files are captured in git history via PRs #138 and #140 on `<your-org>/automations`.

## Resolved Issues

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-15 | Scaffolding (README, LICENSE, .github) wiped on force-push | `publish_to_remote()` used `git init` instead of cloning remote first | Clone-then-overlay pattern in PR #140 |
| 2026-04-15 | Hook caused `Unterminated string` JSON error | Inline regex with escapes in settings.json | Moved logic to `post-commit-hook.sh`, hook just calls the script |
| 2026-04-15 | Codex review of snapshots stalled indefinitely | `codex exec` blocks reading stdin | Switched to inline grep audits with `sanitize.yml` bumped to v4 |
| 2026-04-15 | Bare "<your-name>" leaked through v3 sanitizer | Only `<your-name>` full-name rule | Added `personal-firstname` + possessive + `<author>-voice` token rules |
