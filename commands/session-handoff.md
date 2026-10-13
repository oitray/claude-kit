---
allowed-tools: Bash, Read, Write
description: Save in-flight session context to docs/handoffs/ so a fresh session can pick up where this one left off
---

# Session Handoff

Save the current session's in-flight reasoning, state, and next step to `docs/handoffs/<scope>.md` in the project repo, structured so a fresh session (run `/session-pickup`) can read it and continue without losing context.

A handoff fills the gap between long-term memory (durable preferences and patterns), plan files (forward-looking declarative plans) and your issue tracker (work scope). None of those capture *mid-investigation reasoning*: what has been tried, what has been ruled out, and what the immediate next step is. That is the handoff file's job.

## Input: $ARGUMENTS

- **No argument** → handoff to the auto-detected scope (Step 2).
- **`<slug>`** → use this 2-5 word slug as the scope.
- **`--from-jsonl`** → synthesize from the session transcript instead of the live conversation. Use when the conversation is long and earlier context may have been compacted.
- **`--done`** → delete the handoff file for the detected scope. Idempotent (silent no-op if no file matches). Use when the work finished, was abandoned, or was scoped out.

## Step 1 — Resolve project root

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$PROJECT_ROOT" ]; then
  echo "/session-handoff: not in a git repo. Aborting." >&2
  exit 1
fi
HANDOFF_DIR="$PROJECT_ROOT/docs/handoffs"
mkdir -p "$HANDOFF_DIR"
```

## Step 2 — Resolve scope

Apply this order and state the detected scope to the user before continuing.

1. **Explicit slug** — a non-flag word in `$ARGUMENTS`.
2. **Current branch** — when not on the default branch, use the branch name with any `<type>/` prefix removed (`feat/123-login-retry` → `123-login-retry`). Issue IDs in branch names carry through automatically.

   ```bash
   BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "")
   DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
   DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
   if [ -n "$BRANCH" ] && [ "$BRANCH" != "$DEFAULT_BRANCH" ]; then
     SCOPE="${BRANCH#*/}"
   fi
   ```

3. **Fallback** — ask the user for a 2-5 word slug. Abort if none is given. Do not silently date-stamp.

Sanitize the slug into a filename:

```bash
sanitize() {
  printf '%s' "$1" \
    | LC_ALL=C tr -d '\000-\037"' \
    | LC_ALL=C tr ':.' '--' \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -c 'a-z0-9-' '-' \
    | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' \
    | head -c 50
}
SLUG=$(sanitize "$SCOPE")
TARGET="$HANDOFF_DIR/$SLUG.md"
```

## Step 3 — `--done` short-circuit

If `$ARGUMENTS` contains `--done`:

```bash
if [ -f "$TARGET" ]; then
  rm "$TARGET"
  echo "Removed handoff: $TARGET"
else
  echo "No handoff file at $TARGET (already removed or never created)."
fi
exit 0
```

## Step 4 — Compose handoff content

**Primary path: the live conversation.** Synthesize the sections below from the active conversation. Be concrete: cite paths and line numbers, and quote command output where it is load-bearing. Do not pad; an empty section is fine when there is genuinely nothing to record.

**Transcript path (`--from-jsonl`, or when earlier context may have been compacted).** Claude Code stores each session as JSONL under `~/.claude/projects/<encoded-repo-path>/`. Sessions are logged under the **main checkout's** path even when you work in a linked worktree, so resolve that first:

```bash
MAIN_REPO=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")
[ -z "$MAIN_REPO" ] || [ "$MAIN_REPO" = "." ] && MAIN_REPO="$PROJECT_ROOT"
SESSION_DIR="$HOME/.claude/projects/$(printf '%s' "$MAIN_REPO" | sed 's|[^a-zA-Z0-9]|-|g')"
JSONL="$SESSION_DIR/${CLAUDE_CODE_SESSION_ID:-none}.jsonl"
[ -f "$JSONL" ] || JSONL=$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -1)

if [ -n "$JSONL" ] && [ -f "$JSONL" ]; then
  python3 - "$JSONL" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    msg = rec.get("message") or {}
    role = msg.get("role")
    content = msg.get("content")
    if role not in ("user", "assistant") or not content:
        continue
    if isinstance(content, list):
        content = "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
    if content.strip():
        rows.append(f"[{role}] {content.strip()[:2000]}")
print("\n\n".join(rows[-200:]))
PY
else
  echo "/session-handoff: no transcript found under $SESSION_DIR; using the live conversation." >&2
fi
```

Read the output and synthesize from it. Do **not** paste raw turns into the handoff file.

### The sections (fixed order)

1. **`## Goal`** — one paragraph: what the work is trying to accomplish overall.
2. **`## State`** — terse bullets derivable from git state: commits (short SHA + subject), pull requests opened, files touched, services configured.
3. **`## In-flight reasoning`** — the load-bearing section. Hypotheses tried, what worked, what did not, and **why** options were ruled out. No other system captures this.
4. **`## Open questions / blockers`** — bullets; each names what is needed to resolve it.
5. **`## Next step`** — the exact first action for the next session. One paragraph or a short ordered list.
6. **`## Key context`** — files, paths, IDs and commands the next session needs at hand. Cite paths with line ranges (e.g. `src/worker.py:120-145`) instead of dumping files. If the project keeps plan files (for example under `docs/plans/`), link the active one here.
7. **`## History`** — managed by this command. Do not write it yourself.

Write sections 1-6 to a temp body file:

```bash
BODY_PATH=$(mktemp -t handoff-body.XXXXXX)
cat > "$BODY_PATH" <<'BODY'
## Goal

<one paragraph>

## State

- <bullet>

## In-flight reasoning

<paragraphs / bullets>

## Open questions / blockers

- <bullet>

## Next step

<one paragraph or short ordered list>

## Key context

- <pointers>
BODY
```

## Step 5 — Secret scrub

Before the file is written, replace anything credential-shaped in the body with `<redacted>`:

```bash
python3 - "$BODY_PATH" <<'PY'
import re, sys, pathlib
patterns = [
    r"(?i)\bpassword\s*[:=]\s*\S+",
    r"(?i)\bsecret\s*[:=]\s*\S+",
    r"(?i)\btoken\s*[:=]\s*\S+",
    r"(?i)\bapi[_-]?key\s*[:=]\s*\S+",
    r"\bBearer\s+[A-Za-z0-9._-]{16,}",
    r"\bpk_(?:live|test)_[A-Za-z0-9]{16,}",
    r"\bsk-(?:proj-|ant-|live-|test-)?[A-Za-z0-9_-]{20,}",
    r"\bghp_[A-Za-z0-9]{30,}",
    r"\bgithub_pat_[A-Za-z0-9_]{40,}",
    r"\bxox[baprs]-[A-Za-z0-9-]{10,}",
    r"\bAKIA[0-9A-Z]{16}\b",
    r"\bASIA[0-9A-Z]{16}\b",
]
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
total = 0
for pat in patterns:
    text, n = re.subn(pat, "<redacted>", text)
    total += n
p.write_text(text, encoding="utf-8")
if total:
    print(f"Note: redacted {total} suspected credential(s) before writing.")
PY
```

## Step 6 — Write the handoff file (idempotent)

If `$TARGET` already exists, keep its `created` timestamp and `## History`, and replace everything else.

```bash
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WORKTREE=""
if [ "$(git rev-parse --absolute-git-dir)" != "$(git rev-parse --path-format=absolute --git-common-dir)" ]; then
  WORKTREE="$PROJECT_ROOT"
fi

python3 - "$TARGET" "$NOW_ISO" "$BRANCH" "$WORKTREE" \
  "${CLAUDE_CODE_SESSION_ID:-unknown}" "$PWD" "$SLUG" "$TITLE" "$BODY_PATH" <<'PY'
import os, re, sys, pathlib

target, now, branch, worktree, session_id, cwd, scope, title, body_path = sys.argv[1:10]
body = pathlib.Path(body_path).read_text(encoding="utf-8").rstrip() + "\n"

created = now
history = ""
if os.path.exists(target):
    raw = pathlib.Path(target).read_text(encoding="utf-8")
    m = re.match(r"^---\n(.*?)\n---\n", raw, re.DOTALL)
    if m:
        for line in m.group(1).splitlines():
            if line.startswith("created:"):
                created = line.split(":", 1)[1].strip()
    h = re.search(r"\n## History\n(.*)$", raw, re.DOTALL)
    if h:
        history = h.group(1).strip() + "\n"

frontmatter = (
    "---\n"
    f"title: {title or scope}\n"
    f"scope: {scope}\n"
    f"created: {created}\n"
    f"updated: {now}\n"
    f"origin_session_id: {session_id}\n"
    f"origin_cwd: {cwd}\n"
    f"branch: {branch or 'null'}\n"
    f"worktree: {worktree or 'null'}\n"
    "status: open\n"
    "---\n\n"
)
history += f"- [{now}] handoff written\n"
pathlib.Path(target).write_text(frontmatter + body + "\n## History\n\n" + history, encoding="utf-8")
print(f"Wrote handoff: {target}")
PY

rm -f "$BODY_PATH"
```

`$TITLE` is a short human-readable title for the work (for example the issue title); it falls back to the slug.

## Step 7 — Confirm

1. Print `Handoff saved: <path relative to the repo root>`.
2. Print a one-line summary: goal + next step.
3. Tell the user how to resume:
   - Same machine, fresh session: `/session-pickup` (most recent) or `/session-pickup <slug>`.
   - Another machine: commit and push the handoff (or copy it over) first, then pull.
4. **Do not auto-commit.** The user decides whether a handoff is worth committing.

## Notes

- **One handoff per scope.** Re-running against the same scope overwrites the body; `created` and `## History` are preserved.
- **Cleanup.** Delete the handoff when the work lands: `/session-handoff --done`, `rm`, or `git rm` in the final commit of the branch.
- **Keep handoffs out of automatic cleanup.** If you run hooks or scripts that stash or reset uncommitted files, exempt `docs/handoffs/` so a pending handoff is not swept away before pickup.
