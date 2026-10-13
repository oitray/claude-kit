# macOS Shell Portability

> **Owner:** <your-name> | **Last verified:** 2026-05-08

bash 3.2 vs newer-bash pitfalls and Python SSL gotchas that show up only at runtime on macOS.

## bash 3.2 default

macOS ships bash 3.2 by default (`/bin/bash`); GNU bash 4+ is only present if Homebrew installed it. Common 3.2-vs-newer pitfalls:

- **Empty-array expansion with `set -u`**: `"${arr[@]}"` errors as "unbound variable" when `arr=()` is empty. Use `${arr[@]+"${arr[@]}"}` instead — that form works on every bash version and is empty-safe.
- **`set -u` fails OPEN inside `$(...)`, not closed.** A command substitution runs in a subshell; when a `set -u` unbound-variable error (or any error) fires *inside* `x=$(cmd)`, it aborts only the subshell — `x` gets the empty string and the parent script keeps going. So `tags=$(curl -s ... | jq ...)` that errors returns `""`, and a caller that reads `""` as "this record has no tags" silently misclassifies instead of failing. Two consequences: (1) `curl | jq` pipelines in `$(...)` need an explicit HTTP-status check + `rc` propagation (`body=$(fetch); rc=$?; [ $rc -eq 0 ] || return $rc`) — you cannot rely on `set -u`/`set -e` to halt them; (2) a helper that must fail-closed should `return <code>` (which survives the subshell as a distinguishable rc) rather than `exit <code>` (which only kills the subshell and collapses to an indistinguishable non-zero). Caught <clickup-task-id> (2026-07-24): `plan-phases.sh derive` classified a phase `author` and exited 0 while every ClickUp read was failing — green unit tests all passed; only a codex review + a `curl`-shadowing exploit surfaced it.
- **`mktemp -t` template differences**: BSD `mktemp -t prefix` returns `$TMPDIR/prefix.NNNNN` (no template syntax). GNU `mktemp -t prefix.XXXXXX` substitutes the X's. The portable approach is `mktemp -d -t prefix` to get a temp directory, then use your own filename: `tmpf="$tmpdir/file.${ext}"`.
- **`sed -i`** without an argument fails on BSD (needs `sed -i ''`); GNU accepts both.
- **`date -d`** and **`xargs -r`** are GNU-only; not in BSD coreutils.
- **`find -newermt "@<epoch>"`** is a GNU/bfs extension — macOS `/usr/bin/find` (BSD) rejects it with `find: Can't parse date/time: @<epoch>` and exits 1. Convert epoch → human format once at startup: `ts_str=$(date -r "$epoch" "+%Y-%m-%d %H:%M:%S")` (BSD) with GNU fallback `date -d "@$epoch" "+%Y-%m-%d %H:%M:%S"`, then pass `$ts_str` to `find -newermt`. Caught <clickup-task-id> Phase 2.5 — codex review and a subagent's own empirical probe both missed it because Claude Code's Bash tool shadows `find` with `bfs 4.1.1` which DOES accept `@<epoch>`; the live LaunchAgent under `/usr/bin/find` failed at boot.
- **`case` with bare alternation patterns inside `$(...)` command substitution** is misparsed by bash 3.2 — use POSIX `(pattern1|pattern2)` form (leading paren) instead of bare `pattern1|pattern2)`. Inside a function body (not `$(...)`) the bare form works fine. Caught <clickup-task-id> Phase 3 in the `cca-selector` `sessions_lines` prefix matcher.

If the script's shebang is `#!/usr/bin/env bash`, you cannot assume which version will run. Either pin to a known-newer bash explicitly or stick to bash-3.2-safe constructs.

## Python 3.13 framework build has no system trust store

`urllib.request.urlopen` against any HTTPS endpoint raises `ssl.SSLCertVerificationError: unable to get local issuer certificate`. The python.org installer ships an `Install Certificates.command` but it doesn't always run, and Python upgrades reset state.

**Workaround:** use `requests` (bundles `certifi`'s CA root) or shell out to `curl` (uses the system keychain). All scripts under `scripts/voip-research/` use `requests` for this reason. Symptom looks like an auth or network error — it isn't; it's a Python SSL config issue.

**Permanent fix.** The stdlib `ssl` module on the python.org framework build looks for its CA bundle at `/Library/Frameworks/Python.framework/Versions/3.13/etc/openssl/cert.pem`. The installer's post-install `Install Certificates.command` step (which creates that link to `certifi`'s bundle) often never runs, so the link is missing — stdlib `urllib` / `http.client` / `ssl` then fail `CERTIFICATE_VERIFY_FAILED`, while `curl` (system keychain) and `requests` (uses `certifi` directly) keep working. Create the missing link:

```bash
# etc/openssl/ is group-admin writable — no sudo needed
ln -sf "$(python3 -m certifi)" /Library/Frameworks/Python.framework/Versions/3.13/etc/openssl/cert.pem
# verify
python3 -c "import urllib.request; print(urllib.request.urlopen('https://api.github.com').status)"  # → 200
```

Equivalent to running the official `/Applications/Python 3.13/Install Certificates.command`. **Caveat:** a Python 3.13 reinstall/upgrade can wipe the symlink — re-run the fix after.

**Bulletproof alternative.** `pip install truststore` then call `truststore.inject_into_ssl()` at process start — stdlib `ssl` then uses the macOS keychain directly, surviving Python upgrades with no `cert.pem` link to maintain.

Applied + verified on the Mac Studio (empirical (2026-06-06): symlink created, `urllib.request.urlopen('https://api.github.com')` returned `200`).

## zsh `echo` interprets backslash escapes — never pipe JSON through it

The user's shell is zsh, whose builtin `echo` expands `\n`, `\t`, etc. **by default**
(unlike bash's). Piping a JSON literal containing an escape through `echo` corrupts it
before the parser sees it:

```
$ echo '[["a\nb","c","d"]]' | python3 -c 'import json,sys; json.load(sys.stdin)'
json.decoder.JSONDecodeError: Invalid control character at: line 1 column 5 (char 4)
```

The `\n` became a real newline inside a JSON string, which is illegal.

Use a **quoted heredoc**, which performs no expansion at all:

```bash
cat <<'EOF' | python3 script.py
[["old\nline","new","label"]]
EOF
```

Same rule for any payload with escapes — `curl -d`, `jq` filters, mutation specs.
For file-bound payloads prefer `--input <file>` / `-d @<file>` over inline strings.

(empirical (2026-08-20), <clickup-task-id> — a mutation-harness spec whose anchor spanned two
lines failed to parse until moved from `echo` to a quoted heredoc.)
