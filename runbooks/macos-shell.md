# macOS Shell Portability

> **Owner:** <your-name> | **Last verified:** 2026-05-08

bash 3.2 vs newer-bash pitfalls and Python SSL gotchas that show up only at runtime on macOS.

## bash 3.2 default

macOS ships bash 3.2 by default (`/bin/bash`); GNU bash 4+ is only present if Homebrew installed it. Common 3.2-vs-newer pitfalls:

- **Empty-array expansion with `set -u`**: `"${arr[@]}"` errors as "unbound variable" when `arr=()` is empty. Use `${arr[@]+"${arr[@]}"}` instead — that form works on every bash version and is empty-safe.
- **`mktemp -t` template differences**: BSD `mktemp -t prefix` returns `$TMPDIR/prefix.NNNNN` (no template syntax). GNU `mktemp -t prefix.XXXXXX` substitutes the X's. The portable approach is `mktemp -d -t prefix` to get a temp directory, then use your own filename: `tmpf="$tmpdir/file.${ext}"`.
- **`sed -i`** without an argument fails on BSD (needs `sed -i ''`); GNU accepts both.
- **`date -d`** and **`xargs -r`** are GNU-only; not in BSD coreutils.
- **`find -newermt "@<epoch>"`** is a GNU/bfs extension — macOS `/usr/bin/find` (BSD) rejects it with `find: Can't parse date/time: @<epoch>` and exits 1. Convert epoch → human format once at startup: `ts_str=$(date -r "$epoch" "+%Y-%m-%d %H:%M:%S")` (BSD) with GNU fallback `date -d "@$epoch" "+%Y-%m-%d %H:%M:%S"`, then pass `$ts_str` to `find -newermt`. Caught <clickup-task-id> Phase 2.5 — codex review and a subagent's own empirical probe both missed it because Claude Code's Bash tool shadows `find` with `bfs 4.1.1` which DOES accept `@<epoch>`; the live LaunchAgent under `/usr/bin/find` failed at boot.
- **`case` with bare alternation patterns inside `$(...)` command substitution** is misparsed by bash 3.2 — use POSIX `(pattern1|pattern2)` form (leading paren) instead of bare `pattern1|pattern2)`. Inside a function body (not `$(...)`) the bare form works fine. Caught <clickup-task-id> Phase 3 in the `cca-selector` `sessions_lines` prefix matcher.

If the script's shebang is `#!/usr/bin/env bash`, you cannot assume which version will run. Either pin to a known-newer bash explicitly or stick to bash-3.2-safe constructs.

## Python 3.13 framework build has no system trust store

`urllib.request.urlopen` against any HTTPS endpoint raises `ssl.SSLCertVerificationError: unable to get local issuer certificate`. The python.org installer ships an `Install Certificates.command` but it doesn't always run, and Python upgrades reset state.

**Workaround:** use `requests` (bundles `certifi`'s CA root). All scripts under `scripts/voip-research/` use `requests` for this reason. Symptom looks like an auth or network error — it isn't; it's a Python SSL config issue.
