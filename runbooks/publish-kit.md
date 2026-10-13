# publish-kit Runbook

> **Owner:** <your-name> | **Last verified:** 2026-10-13

Sanitizes allowlisted skills, commands, personas, runbooks and examples and force-pushes them to the public mirror `<your-username>/claude-kit`.

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
PUBLISH_KIT_REAL_PUSH=1 bash scripts/publish-kit/publish.sh --push --non-interactive
# add --force when the dry-run reports the drift gate (>5 changed files)
```

Every split target in the allowlist is already in the last manifest, so no `--approve-split` is needed. A new `split:` entry needs `--approve-split <target>` on its first push.

### Publishing is manual

There is no auto-sync. The PostToolUse hook and `scripts/publish-kit/post-commit-hook.sh` from `91f57c31c` stayed on branch `fix/publish-kit-auto-sync` and never reached `main` (empirical (2026-10-13): `git merge-base --is-ancestor 91f57c31c origin/main` → not an ancestor; no `publish-kit` entry in any `settings*.json`). There is also no `/publish-kit` slash command. Run the dry-run, review the diff, then the manual push above.

## Allowlist categories

| Key | Source (first found wins) | Published to |
|---|---|---|
| `skills` | `.claude/publish-kit/public/skills/<name>` → `~/.claude/skills/<name>` | `skills/<name>/` |
| `commands` | `.claude/publish-kit/public/commands/<name>.md` → `~/.claude/commands/<name>.md` | `commands/<name>.md` |
| `personas` | `.claude/publish-kit/public/personas/` → `.claude/personas/` → `~/.claude/personas/` | `personas/` |
| `runbooks` | `.claude/publish-kit/public/runbooks/` → `docs/runbooks/` | `runbooks/` |
| `examples` | `examples/<dir>/` in this repo (dir walk, dotfiles + symlinks skipped) | `examples/<dir>/` |

**Public variants.** `.claude/publish-kit/public/<category>/` holds hand-written public copies of items whose private original is too coupled to internal tooling for sanitize or a transform. A variant overrides the private source of the same name; the original is never read. Current variants: `commands/session-handoff.md`, `commands/session-pickup.md` (originals live in `<your-org>/<config-repo>` `commands/` and stay private: ClickUp scope lookup, Key Vault, tmux/iTerm renaming, stop-hook and `/sweep` coupling). The variants keep the core contract — write/read `docs/handoffs/<scope>.md` with goal, state, in-flight reasoning, blockers, next step, key context and history — with the scope taken from an explicit slug or the branch name. When an original changes behavior, update its variant by hand.

**Commands** must carry YAML frontmatter with `description` (frontmatter validator, doc type `command`).

**Personas:** none publish. The five legacy personas (flo-rivers, holly-helpdesk, paige-turner, stan-dardson, stella-fullstack) were retired 2026-04-28; they, the `stella-consolidate` transform and its internal-refs exemptions were removed 2026-10-13 (<clickup-task-id>). Their names stay in `internal-refs.yml` `tools:` as leak detectors.

**Runtime output dirs are never copied.** Directory sources (skills) are copied with `copy_tree`, which drops dotfiles/dot-dirs and any directory named in `DEFAULT_EXCLUDE_DIRS` (`working`, `__pycache__`, `node_modules`) or the allowlist's top-level `exclude_dirs:` list, at any depth. `toolreview` writes `working/<tool>-review.md` beside its `SKILL.md`; before this, that file reached the snapshot and failed the frontmatter validator on every run.

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
3. **Transform** — `split:` entries run `transforms/<name>.py` (e.g. `maestro-local-dispatch-generic.py` keeps only its listed H2 sections, so sections added to the private runbook later stay private until reviewed)
4. **Delink** — `delink.py` turns relative links whose target is not in the snapshot (private plans, specs, unpublished runbooks) into plain text and logs each one as `delink: <file> -> <href>`
5. **Validate** — `frontmatter.py` + `internal_refs.py` linters
6. **Scan** — `scan.py` post-sanitize leak detector (detectors + `deny.txt`); fails on hit
7. **Manifest diff** — compare against `.last-manifest.json`; no-op if unchanged
8. **Drift gate** — abort if >5 files changed unless `--force`
9. **Changelog** — `CHANGELOG.md` at the repo root is regenerated from the manifest diff each run (it lists `commands/` like any other path); `README.md` is not generated — the remote copy is preserved
10. **Clone + overlay** — clone `<your-username>/claude-kit`, strip published dirs, overlay snapshot; preserves `README.md`, `LICENSE`, `.github/`
11. **Force-push** — single squashed commit as `publish-kit@local`

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
| 2026-10-13 | Dry-run failed on `skills/toolreview/working/powershell-docs-review.md` (no frontmatter); 5 retired personas → `source not found`; `salesforce-cli.md` links to private plans/specs failed the link check; `maestro-local-dispatch` gained internal sections after its first publish (internal-refs hits); `slack-api.md` carried a personal admin mailbox (scan deny-list hit) | `cp -R` copied runtime output; allowlist never pruned after the 2026-04-28 persona retirement; the transform was a strip-list | `copy_tree` exclusion + `exclude_dirs`; personas + `stella-consolidate` removed; `delink.py` stage; maestro transform switched to a keep-list; `personal-family-email`/`-domain` sanitize rules (v8); v9 rules for the isolated Azure CLI config dir, internal launchd labels, sister-org names, the retired executor, private config-repo names, brand/org tokens inside identifiers, staff handles, tenant subdomains and long task IDs; `commands` category + public variants (<clickup-task-id>) |
| 2026-10-13 | Owner first name still public in three runbooks (upper-case approval banner, email sub-address, vault flag) plus an AAD constant and a field name | The v3 first-name rule is case-sensitive and word-bounded, so it missed upper-case, flag, sub-address and underscore forms | sanitize v10: dedicated owner-name rules for each form (all in the v10 block of `sanitize.yml`), first-name rule now skips the medical term; tests for each plus false-positive words (<clickup-task-id>) |
| 2026-05-26 | Link extraction was regex-based (false-flagged links inside code fences; missed reference-style links) | `LINK_RE` scanned raw text incl. code blocks | Replaced with markdown-it-py CommonMark AST walk (`extract_links`); links in code fences/inline-code no longer flagged, reference links now covered, images excluded by token type, `%`-encoded paths unquoted before resolution (<clickup-task-id>). The publish python must satisfy `scripts/publish-kit/requirements.txt` (`pip install -r`) — `markdown-it-py` is now required by the Validate stage. |
