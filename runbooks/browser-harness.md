# browser-harness Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-21 (Phase 5 — <internal-bot> DM /browser)

## Purpose

browser-use/browser-harness is a Chrome DevTools Protocol (CDP) harness for driving real browser sessions. <your-org> uses it to automate tasks that require a logged-in browser — Salesforce Lightning UI QC after deploys, Pax8 portal exports, M365 admin tasks that have no Graph API surface. The submodule is pinned at a specific SHA; all <your-org> skills live in `scripts/browser-harness-skills/`.

## Auth

- **Method:** Chrome profile (persistent cookies/sessions per environment) + optional cloud API key for browser-use hosted runs
- **Vault:** `<credential-vault>`
- **Secret name:** `<api-key-secret>` (Phase 4 copies this to `<credential-vault>` for n8n; that copy is out of scope for Phase 1)
- **Env var:** `$BROWSER_USE_API_KEY` after fetch
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh browser-harness)"` (catalog entry added Phase 4)
- **MCP server:** N/A

These are **not** your personal profile and **not** a prod admin account. First launch creates the profile; subsequent launches restore the prior session.

## Bootstrap

```bash
# 1. Initialize the submodule after a fresh clone
git submodule update --init scripts/browser-harness

# 2. Install browser-harness dependencies
cd scripts/browser-harness
pip install -r requirements.txt   # or uv pip install -r requirements.txt

# 3. Launch Chrome for your target environment
scripts/browser-harness-skills/start-chrome.sh --env sandbox

After Chrome launches, capture the websocket URL and export as `BU_CDP_WS` before invoking `browser-harness` (see Gotchas → Custom profile + BU_CDP_WS).

# 4. Run a skill
cd scripts/browser-harness
python run.py "open https://test.salesforce.com"
```

## Mutation skills — confirmation contract

All Phase 3+ skills that write to a live system share a common safety contract implemented in `scripts/browser-harness-skills/lib/`.

### Dry-run first

Every mutation skill accepts `--dry-run`. In dry-run mode the skill renders a diff of intended changes without performing any browser mutations. The audit log records each action with `status: "dry-run"`. Dry-run is always safe to run without the double-confirm requirement.

### Confirm prompt

Each mutation action calls `lib/confirm.py::confirm(action, target, run_id, dry_run=False)`. The function:

- Prints `Confirm <action> on <target>? [y/N]` to stderr.
- Records the outcome in `~/.browser-harness/audit.log` regardless of the answer.
- Returns `True` only when the user types exactly `y`. Any other input (including Enter) declines.

### Hard caps — `lib/guard.py::Guard`

Instantiate with per-skill defaults:

| Parameter | `fls-grant` default | `teams-phone-admin` default | Effect |
|-----------|--------------------|-----------------------------|--------|
| `max_actions` | 50 | 30 | `ActionBudgetExhausted` raised when exceeded |
| `action_timeout_secs` | 30 | 45 | `ActionTimeout` raised via SIGALRM if a single action exceeds this |
| `nav_allowlist` | skill-declared hostnames | skill-declared hostnames | `NavViolation` raised on unexpected hostname |

- **`nav_allowlist`** — Each skill declares the exact hostnames it expects to visit (e.g. `login.salesforce.com`, `oit.lightning.force.com`). Any navigation to a hostname outside the allowlist aborts the run immediately and logs `status: "aborted: nav-violation"`.
- **Panic-stop** — `Guard.install_panic_handler(cleanup)` registers a SIGINT handler. `Ctrl-C` logs `status: "panic: SIGINT received"`, calls the cleanup callback (closes Chrome), then calls `os._exit(130)`.

### Single-attach rule

Mutation skills call `reset-profile.sh` at the start of each run. The launcher (`start-chrome.sh`) refuses to start if `lsof -i :9222` returns any listener — only one CDP consumer may attach at a time. If `:9222` is already bound when a mutation skill starts, the skill aborts.

### Environment separation and double-confirm

| Environment flag | Double-confirm requirement |
|-----------------|---------------------------|
| `--env prod` (Salesforce) | Type the full prod org URL twice before mutations begin |
| `--env m365` | Type the target UPN twice before mutations begin |
| `--env sandbox` / other non-prod | Single confirm per action; no double-entry required |

The double-confirm is enforced in the skill preamble before any `Guard.start_action()` call.

### Audit log

Path: `~/.browser-harness/audit.log` (JSONL, append-only).

Each line is a JSON object with:

| Field | Values / notes |
|-------|---------------|
| `ts` | ISO 8601 UTC timestamp |
| `run_id` | UUID generated at skill start; threads all events for one run |
| `skill_name` | e.g. `<vendor>/<mutation-skill>` |
| `action` | Human-readable action label |
| `target` | Object being acted on (permset name, UPN, etc.) |
| `status` | `dry-run` \| `confirmed` \| `declined` \| `aborted:<reason>` |
| `before` / `after` | Present for mutations that capture state diff |

## n8n integration

Sub-workflow: `<internal-workflow>.json`. Invoked via Execute Workflow node from other n8n workflows. Provides allowlist enforcement, concurrency gating, and structured output for browser-use cloud sessions.

### Import workflow JSON

```bash
# Import via n8n REST API
eval "$(~/.claude/scripts/fetch-secrets.sh n8n)"

curl -s -X POST "$N8N_API_URL/workflows" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d @<internal-workflow>.json
```

After import, note the assigned workflow ID from the response.

### Substitute credential ID

The workflow JSON ships with placeholder `__BROWSER_USE_CRED_ID__` in both HTTP Request nodes (`POST /sessions` and `GET /sessions/{id}`). Replace it with the real credential ID before or after import:

```bash
# Get the workflow JSON with the assigned ID
eval "$(~/.claude/scripts/fetch-secrets.sh n8n)"
WORKFLOW_ID="<id from import response>"

# Fetch current JSON
curl -s "$N8N_API_URL/workflows/$WORKFLOW_ID" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" > /tmp/browser-harness-wf.json

# Substitute the credential ID (use awk — BSD sed has no \U; awk handles replacements cleanly)
CRED_ID="<your credential ID>"
awk -v id="$CRED_ID" '{ gsub(/__BROWSER_USE_CRED_ID__/, id); print }' \
  /tmp/browser-harness-wf.json > /tmp/browser-harness-wf-patched.json

# Strip non-PUT-safe keys and PUT
python3 - <<'PY'
import json, subprocess, os

key = os.environ['N8N_API_KEY']
url = os.environ['N8N_API_URL']
wf_id = os.environ['WORKFLOW_ID']

wf = json.load(open('/tmp/browser-harness-wf-patched.json'))
allowed_settings = {'executionOrder', 'callerPolicy', 'saveDataErrorExecution',
                    'saveDataSuccessExecution', 'timezone', 'errorWorkflow'}
payload = {
    'name': wf['name'],
    'nodes': wf['nodes'],
    'connections': wf['connections'],
    'settings': {k: v for k, v in wf.get('settings', {}).items() if k in allowed_settings},
    'staticData': wf.get('staticData'),
}
import urllib.request
req = urllib.request.Request(f"{url}/workflows/{wf_id}",
    data=json.dumps(payload).encode(),
    headers={"X-N8N-API-KEY": key, "Content-Type": "application/json"},
    method="PUT")
with urllib.request.urlopen(req) as r:
    print(r.read().decode()[:200])
PY
```

After PUT, verify both HTTP Request nodes show the credential name `Browser Use API Key` in the n8n UI.

### Activate

Sub-workflows must be activated before parent workflows can call them:

```bash
eval "$(~/.claude/scripts/fetch-secrets.sh n8n)"
curl -s -X PATCH "$N8N_API_URL/workflows/$WORKFLOW_ID" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"active": true}'
```

If activation fails, there is a structural error in the workflow. Check node connections — do NOT retry activation without fixing the error first.

### Concurrency behavior

- Hard cap: **2 concurrent executions** (keeps 1 browser-use cloud free-tier slot free for interactive use).
- Implemented via `$getWorkflowStaticData('global').concurrentRuns` in the `Code: concurrency gate` node.
- If cap is reached, the workflow throws immediately with error message starting `BROWSER_USE_CAPACITY_EXHAUSTED`.
- **Caller (Phase 5 <internal-bot>) MUST NOT retry on `BROWSER_USE_CAPACITY_EXHAUSTED`** — retrying amplifies the problem. Surface to user with a backoff message instead.
- Counter is decremented in the `Code: decrement counter` tail step on the success path.
- Error paths that incremented the counter (session-create-failed) will leak the slot until the next successful decrement or process restart resets static data. This is acceptable for Phase 4 volume.

### Rate limit and retry semantics

- HTTP Request nodes retry on network errors and 5xx: **3 tries, 1000ms backoff**.
- 429 (rate limit) is treated the same as other transient errors — up to 3 total retries. The plan specified "max 1 retry on 429" but n8n's built-in retry does not discriminate by status code without a Code node; 3 retries is the acceptable conservative cap for free-tier volume.
- `onError: continueErrorOutput` on `POST /sessions` routes HTTP errors to the `Set: error session-create-failed` branch rather than killing the execution.

### Cost ceiling

- Free tier: no card on file. browser-use cloud does not charge when no payment method is attached.
- Each session response includes `totalCostUsd` — passed through in `Set: output`.
- Cost aggregation and alerting is Phase 5's responsibility.
- If you add a payment method in future, set a spend alert at the minimum available threshold before enabling production workflows.

### Execution data

- Success runs: **save nothing** (`saveDataSuccessExecution: "none"`). This prevents bearer token exposure in the n8n execution store, even though the Generic Header Auth credential is stored in the credential object (not the node body).
- Error runs: **save all** (`saveDataErrorExecution: "all"`). Needed for debugging failed browser sessions.
- To inspect error executions: `GET $N8N_API_URL/executions/{id}?includeData=true` — should NOT contain the literal API key. The credential value is in the n8n encrypted credential store, not injected into the node body.

### Smoke test curl (read-only skill via Execute Workflow node in a test workflow)

```bash
# This tests the sub-workflow's input validation directly via n8n manual execution
eval "$(~/.claude/scripts/fetch-secrets.sh n8n)"

# Trigger a manual execution with test input
curl -s -X POST "$N8N_API_URL/workflows/$WORKFLOW_ID/run" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "workflowData": {},
    "runData": {},
    "startNodes": [],
    "destinationNode": null
  }'
```

Full end-to-end smoke test (browser session actually running) deferred to Phase 5 activation — requires the workflow to be called from a parent workflow with populated inputs.

## Gotchas

- **OneDrive xattr on `scripts/`:** If `ls -la@ scripts/` shows `com.apple.fileprovider.*` xattrs, OneDrive's FileProvider has the directory in a dataless-stub state. Resolve via `mv` rename trick before running the submodule (see `reference_onedrive_unstick_rename.md` memory entry). `com.apple.provenance` is expected and harmless.
- **CDP :9222 single-attach rule:** Only one process may connect to CDP at a time. `start-chrome.sh` refuses to launch if `lsof -i :9222` returns any listener. Kill any prior Chrome debug session before starting a new one.
- **Profile separation:** Never sign into a prod admin account in a `browser-harness-sandbox` profile (or vice versa). Profiles persist cookies across runs. If you suspect cross-contamination, delete the profile directory and re-authenticate.
- **First launch:** Chrome may prompt for OS keychain access on first launch. Allow it; subsequent launches are silent.
- **No headless mode:** These skills drive a visible Chrome window. Don't close or interact with the window while a skill is running.

### Custom profile + BU_CDP_WS

The harness auto-discovers `DevToolsActivePort` by scanning default Chrome user-data-dirs (e.g. `~/Library/Application Support/Google/Chrome`). Our launcher uses a custom profile path (`…/browser-harness-<env>`), which auto-discovery does not scan, so the daemon will fail with `fatal: DevToolsActivePort not found`.

**Fix:** pass the websocket URL explicitly:

```bash
WS_URL=$(curl -s http://localhost:9222/json/version | python3 -c "import sys,json; print(json.load(sys.stdin)['webSocketDebuggerUrl'])")
BU_CDP_WS="$WS_URL" uv run browser-harness <<'PY'
new_tab("https://example.com")
PY
```

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `CDP port 9222 already in use` | `lsof -i :9222` to find the PID, kill it, retry |
| `Google Chrome not found` (exit 4) | Install Chrome to `/Applications/` or add `google-chrome` to PATH |
| Submodule dir is empty after clone | `git submodule update --init scripts/browser-harness` |
| SF login loops / session lost | Delete profile: `rm -rf ~/Library/Application\ Support/Google/Chrome/browser-harness-sandbox` and re-auth |
| `com.apple.fileprovider.*` xattr on scripts/ | Use `mv` rename to unstick OneDrive stub; see OneDrive gotcha above |
