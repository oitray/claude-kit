---
allowed-tools: Bash, Read, Edit
description: Resume a paused session from a docs/handoffs/<scope>.md file — loads the goal, in-flight reasoning, and next step
---

# Session Pickup

Resume a session that was paused with `/session-handoff`. Reads the handoff file, primes the conversation with the goal and next step, checks the handoff is still current, and marks it resumed.

## Input: $ARGUMENTS

- **No argument** → load the most recently updated handoff.
- **`--list`** → print a table of available handoffs sorted by `updated` (newest first), then exit.
- **`<slug>`** → load the handoff whose filename matches: exact stem first (`login-retry` → `login-retry.md`), then `<slug>-*.md`, then any filename starting with the slug.

## Step 1 — Collect handoff dirs

A handoff can live in the main checkout's `docs/handoffs/` or in any linked worktree's `docs/handoffs/` (when it was written from a feature-branch worktree). Search all of them; on duplicate filenames the newest mtime wins.

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$PROJECT_ROOT" ]; then
  echo "/session-pickup: not in a git repo. Aborting." >&2
  exit 1
fi

HANDOFF_DIRS=$(
  {
    echo "$PROJECT_ROOT/docs/handoffs"
    git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2"/docs/handoffs"}'
  } | awk '!seen[$0]++'
)

EXISTING_DIRS=""
while IFS= read -r d; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  if ls "$d"/*.md >/dev/null 2>&1; then
    EXISTING_DIRS="${EXISTING_DIRS}${d}"$'\n'
  fi
done <<< "$HANDOFF_DIRS"

if [ -z "$EXISTING_DIRS" ]; then
  echo "/session-pickup: no handoffs found in docs/handoffs/ of the main checkout or any worktree." >&2
  exit 1
fi
```

## Step 2 — Resolve the target file

### `--list` mode

```bash
python3 - "$PROJECT_ROOT" "$EXISTING_DIRS" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1]).resolve()
dirs = [pathlib.Path(d).resolve() for d in sys.argv[2].splitlines() if d.strip()]
seen = {}
for d in dirs:
    for f in d.glob("*.md"):
        mtime = f.stat().st_mtime
        if f.name in seen and seen[f.name][1] >= mtime:
            continue
        raw = f.read_text(encoding="utf-8", errors="replace")
        fm = re.match(r"^---\n(.*?)\n---", raw, re.DOTALL)
        meta = {}
        if fm:
            for line in fm.group(1).splitlines():
                if ":" in line:
                    k, v = line.split(":", 1)
                    meta[k.strip()] = v.strip()
        seen[f.name] = (f, mtime, meta)

def location(p):
    wt = p.parent.parent.parent
    if wt == root:
        return "main"
    try:
        return f"wt:{wt.relative_to(root)}"
    except ValueError:
        return str(wt)

rows = sorted(seen.items(), key=lambda kv: kv[1][2].get("updated", ""), reverse=True)
print(f"{'FILE':<40}  {'STATUS':<8}  {'UPDATED':<22}  {'LOC':<32}  TITLE")
for name, (p, _m, meta) in rows:
    print(f"{name:<40}  {meta.get('status','?'):<8}  {meta.get('updated','?'):<22}  {location(p):<32}  {meta.get('title','(untitled)')}")
PY
exit 0
```

### Most-recent mode (no argument)

```bash
TARGET=$(
  while IFS= read -r d; do
    [ -n "$d" ] && find "$d" -maxdepth 1 -type f -name "*.md" -print0 2>/dev/null
  done <<< "$EXISTING_DIRS" | xargs -0 ls -t 2>/dev/null | head -1
)
```

### Explicit `<slug>` mode

Slash-command arguments arrive in `$ARGUMENTS`, not `$1`. An empty `$ARGUMENTS` means most-recent mode, never "match everything".

```bash
ARG="$ARGUMENTS"

search_dirs() {
  while IFS= read -r d; do
    [ -n "$d" ] && find "$d" -maxdepth 1 -type f -name "$1" 2>/dev/null
  done <<< "$EXISTING_DIRS"
}

# Dedupe by basename, keeping the newest mtime. python3 -c (not a heredoc)
# so stdin stays the piped list.
dedupe_newest() {
  python3 -c '
import os, sys
seen = {}
for line in sys.stdin:
    p = line.strip()
    if not p:
        continue
    mt = os.path.getmtime(p)
    name = os.path.basename(p)
    if name not in seen or seen[name][1] < mt:
        seen[name] = (p, mt)
for p, _ in seen.values():
    print(p)
'
}

pick_one() {
  local matches count
  matches=$(search_dirs "$1" | dedupe_newest)
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  if [ "$count" = "1" ]; then
    TARGET="$matches"
  elif [ "$count" -gt 1 ]; then
    echo "/session-pickup: multiple handoffs match '$ARG':" >&2
    printf '%s\n' "$matches" | sed 's|^|  |' >&2
    echo "Pass an unambiguous slug." >&2
    exit 1
  fi
}

TARGET=""
pick_one "${ARG}.md"
[ -z "$TARGET" ] && pick_one "${ARG}-*.md"
[ -z "$TARGET" ] && pick_one "${ARG}*.md"

if [ -z "$TARGET" ]; then
  echo "/session-pickup: no handoff matches '$ARG'." >&2
  exit 1
fi
```

## Step 3 — Read the handoff

Read `$TARGET` end to end. From the frontmatter take `title`, `scope`, `branch`, `worktree`, `created`, `updated` and `status`. Confirm the body has at least `## Goal` and `## Next step`; if either is missing, warn the user (a malformed handoff is still loadable).

## Step 4 — Freshness check

A handoff can go stale between write and pickup: the worktree may have been removed, the branch deleted, or the work merged by another session. Check before seeding so the user is not told to redo finished work.

```bash
WORKTREE_GONE=""
if [ -n "$WORKTREE" ] && [ "$WORKTREE" != "null" ] && [ ! -d "$WORKTREE" ]; then
  WORKTREE_GONE=1
fi

BRANCH_GONE=""
if [ -n "$BRANCH" ] && [ "$BRANCH" != "null" ]; then
  if ! git -C "$PROJECT_ROOT" rev-parse --verify --quiet "$BRANCH" >/dev/null \
     && ! git -C "$PROJECT_ROOT" rev-parse --verify --quiet "origin/$BRANCH" >/dev/null; then
    BRANCH_GONE=1
  fi
fi

DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
RECENT_MERGE=""
if [ -n "$SCOPE" ] && [ "$SCOPE" != "null" ]; then
  RECENT_MERGE=$(git -C "$PROJECT_ROOT" log "$DEFAULT_BRANCH" --since=14.days --oneline -i --grep="$SCOPE" 2>/dev/null | head -3)
fi
```

If any signal fires, print this block before the seed in Step 5. Do not block the pickup; the user may still want to resume (for example a follow-up on top of a merged change).

```
Handoff may be stale:
   - worktree no longer exists: <path>              (WORKTREE_GONE)
   - branch gone locally and on origin: <branch>    (BRANCH_GONE)
   - recent commits on the default branch mention <scope>:
       <sha> <subject>                              (RECENT_MERGE)

Verify the next step still applies before acting.
```

If the handoff names a worktree that still exists and the session is not in it, suggest `cd <worktree>`. Do not change directory yourself.

## Step 5 — Seed the conversation

Print, in this order:

1. `Resumed: <title>`
2. Frontmatter facts: `branch`, `worktree`, `created`, `updated`, `status`.
3. `Found in: <path>` when `$TARGET` is not under `$PROJECT_ROOT/docs/handoffs/`.
4. The `## Goal` paragraph, verbatim.
5. The `## Next step` section, verbatim.
6. Any `## Open questions / blockers`.

Read `## In-flight reasoning` for your own grounding; do not recap it to the user. Point to one or two of the most important `## Key context` entries instead of dumping the section.

## Step 6 — Mark it resumed

```bash
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python3 - "$TARGET" "$NOW_ISO" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
now = sys.argv[2]
raw = p.read_text(encoding="utf-8")
raw = re.sub(r"^status:\s*\S+", "status: resumed", raw, count=1, flags=re.MULTILINE)
if "\n## History" in raw:
    raw = raw.rstrip() + f"\n- [{now}] resumed\n"
else:
    raw = raw.rstrip() + f"\n\n## History\n\n- [{now}] resumed\n"
p.write_text(raw, encoding="utf-8")
PY
```

## Step 7 — Stop and wait

**Do not start the next step automatically.** End with: `Ready. Next step is queued — say go (or give different direction).`

## Notes

- **No deletion on pickup.** The file stays so a crashed resume is recoverable. Remove it when the work lands (`/session-handoff --done`, or `git rm` in the branch's final commit).
- **Idempotent.** Running pickup twice re-prints the seed and appends another `resumed` line to `## History`.
- **`--list` is read-only.** It does not change any file.
