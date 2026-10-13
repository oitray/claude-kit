# ClickUp API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-10-07

## Auth

- **Method:** Personal API token (n8n + direct REST), MCP (OAuth2 on demand)
- **Vault:** `<credential-vault>`
- **Secret name:** `CLICKUP-API-KEY` (personal API token — use this for everything). Note: `CLICKUP-API-TOKEN` (`pk_...`) is STALE — returns `OAUTH_025`, do not use.
- **Env var:** `$CLICKUP_API_KEY`, `$CLICKUP_TEAM_ID`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh clickup)"` — for direct REST use: `AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv`
- **n8n credential:** API token, credential ID `<credential-id>` ("Clickup API - <your-name>"), type `clickUpApi`. Legacy OAuth2 credential `<credential-id>` still exists but is short-lived and unreliable — do not use for scheduled workflows.
- **Direct API:** `https://api.clickup.com/api/v2/` with `Authorization: <token>` header

## Common Operations

### Via API / CLI

```bash
# Resolve list IDs (canonical source: <credential-vault>)
AE_LIST=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name CLICKUP-AE-LIST-ID --query value -o tsv)
INFRA_LIST=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name CLICKUP-INFRA-LIST-ID --query value -o tsv)

# Get a task
curl -s "https://api.clickup.com/api/v2/task/TASK_ID" \
  -H "Authorization: $CLICKUP_TOKEN"

# Create a task (pick target list per audience rule)
curl -s -X POST "https://api.clickup.com/api/v2/list/$AE_LIST/task" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Task name", "status": "backlog"}'

# Update task status
curl -s -X PUT "https://api.clickup.com/api/v2/task/TASK_ID" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "planning"}'

# Get tasks in a list (iterate both for dual-list views)
for LID in "$AE_LIST" "$INFRA_LIST"; do
  curl -s "https://api.clickup.com/api/v2/list/$LID/task" \
    -H "Authorization: $CLICKUP_TOKEN"
done

# Add a comment to a task (enrich an existing task)
curl -s -X POST "https://api.clickup.com/api/v2/task/TASK_ID/comment" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"comment_text": "🔁 Recurred …"}'
```

**Custom-field value types on read (empirical, 2026-08-05).** `GET /task/<id>` returns a
**checkbox** as the STRING `'true'`/`'false'`, not a JSON boolean, and a **dropdown** as its
integer `orderindex` (not the option UUID) — resolve the label via `type_config.options`. An
unset field is **absent from `custom_fields` entirely** rather than present with a null value.
A verification asserting `value is True` therefore fails on a correctly-ticked checkbox; compare
`str(v).lower() == 'true'` and treat absence as unset. (Cost: one false FAIL on an otherwise
passing <clickup-task-id> smoke.)

**Comment ordering + authorship (empirical, 2026-08-05).** `GET /task/<id>/comment` returns
**newest-first** — `comments[0]` is the most recent (verified on `<clickup-task-id>`, n=6; a
single-comment task cannot establish ordering). ⚠️ You **cannot** tell a bot comment from a human
one by author: automation authenticating with a personal API token posts *as that person*, so the
orchestrator's own comments return `user.username = "<your-name>"`. Any "was this ours?" check must
key on a machine-shaped body — see the poller's `⏸ Skipped: …` annotator (<clickup-task-id>).

### Enrich-an-existing-task pattern (reopen-if-closed + comment)

When a recurring signal maps to an already-filed card, **enrich it instead of duplicating**: detect closed via `task.status.type ∈ {"closed","done"}` (see Status buckets below), reopen with `PUT /api/v2/task/{id} {"status":"backlog"}`, then `POST /api/v2/task/{id}/comment {"comment_text":"…"}`. Source the `task_id` + comment text from one upstream decision step so the reopen and the comment share the same target (the reopen call only flips status — never source the comment's id from its response).

Consumers:
- **<internal-bot> triage update-existing** — live n8n `<internal-bot>-triage-action-update-existing.json` ("CU: Post Comment").
- **RevOps Investigate enrich-not-duplicate** (<clickup-task-id>) — bot-handler `PVnzaPuSCtSGyMsB` branch `Investigate — Enrich Decide` → `Investigate — Was Closed?` → `Investigate — Reopen Card` (PUT) → `Investigate — Add Comment` (POST). Dedup key dropped `runTs` so recurrences converge on one card.

## Time in status (empirical, 2026-07-07)

`GET /api/v2/task/{id}/time_in_status` returns how long a task has spent in
each status it's ever occupied, including its current one:

```json
{
  "current_status": {
    "status": "qa",
    "color": "#e67e22",
    "total_time": {"by_minute": 34276, "since": "1781394433459"}
  },
  "status_history": [
    {"status": "backlog", "type": "open", "total_time": {"by_minute": 217, "since": "..."}, "orderindex": 0},
    {"status": "qa", "type": "custom", "total_time": {"by_minute": 34275, "since": "1781394433459"}, "orderindex": 5}
  ]
}
```

`current_status.total_time.by_minute` is the exact minute-count since the
task entered its current status — `current_status.total_time.since` is the
epoch-ms timestamp of that transition. **Empirical (2026-07-07):** probed
`GET /task/<clickup-task-id>/time_in_status` while auditing stale `qa` cards for
<clickup-task-id> — 200 OK, `current_status.status == "qa"` with `by_minute=34276`
(≈23.8 days), matching the card's actual dispatch history. No bulk/batch
variant exists — `GET /team/{id}/time_in_status/task?task_ids[]=...` 404s
(probed 2026-07-07); each card needs its own call. Consumer:
`ClickUpClient.get_time_in_status_hours` (`scripts/orchestrator/lib/
clickup_poller.py`), used by `QaStaleTick` (`docs/runbooks/orchestrator.md`
"Stale QA notifier") to classify card age without a second per-status API
that carries duration directly.

## Dependencies schema (empirical, 2026-05-16)

`GET /api/v2/task/{id}` returns a `dependencies` array. ClickUp stores each dep edge as TWO entries — one on the dependent's task, one on the blocker's task — both bearing the SAME `chain_id`.

**Probe (live)** — task `<clickup-task-id>` (B) `depends_on` `<clickup-task-id>` (A):

```json
// GET /task/<clickup-task-id> (the dependent)
"dependencies": [
  {"task_id": "<clickup-task-id>", "depends_on": "<clickup-task-id>", "type": 1, "chain_id": "93ec..."},  // B blocked by A
  {"task_id": "<clickup-task-id>", "depends_on": "<clickup-task-id>", "type": 1, "chain_id": "3d82..."}   // C blocked by B (inverse edge stored on B too)
]
// GET /task/<clickup-task-id> (the blocker)
"dependencies": [
  {"task_id": "<clickup-task-id>", "depends_on": "<clickup-task-id>", "type": 1, "chain_id": "93ec..."}   // same edge, stored on A as well
]
```

**Parsing rule** — to extract a task's blockers (the things IT waits on), filter to `entry.task_id == self.id and entry.depends_on != None`. This rejects:
- The inverse edge (B's record contains the C→B edge where `task_id=C`)
- The mirror copy on the blocker (A's record contains the B→A edge where `task_id=B`)
- Any malformed entry with missing `depends_on`

`type=1` consistently means "blocked by" in the empirical data; `type=2` is undocumented in any payload observed so far. Filter by `task_id` rather than `type` to be schema-defensive.

**Setting a dependency:**

```bash
curl -X POST "https://api.clickup.com/api/v2/task/<dependent-id>/dependency" \
  -H "Authorization: $CLICKUP_API_KEY" -H "Content-Type: application/json" \
  -d '{"depends_on": "<blocker-id>"}'
```

The mirror edge on the blocker is auto-populated server-side; no second call needed.

**Used by:** `scripts/orchestrator/lib/clickup_poller.py:_to_candidate` (CandidateTask.blocked_by_ids) — feeds `check_dependencies_clear()` for the local-poller's dep-aware skip. See `docs/runbooks/local-poller.md` "Dependency-aware skip".

## Epic Phase-Card Fan-Out

`scripts/clickup/fan-out-epic.sh` auto-creates one ClickUp child card per `## Phase X` block in a `plan_kind: epic` markdown plan and wires their dependency edges. Pure bash + curl + jq + awk — portable across any synced Mac without Python / certifi / `SSL_CERT_FILE` setup.

```
fan-out-epic.sh <plan-path> [--dry-run]
```

**Preflight:** `command -v jq curl az` — `/usr/bin/jq` is Apple-shipped on macOS 14+; no Homebrew dependency. **empirical (2026-05-28):** `jq-1.7.1-apple` available on this fleet machine.

### Tag contract — idempotency key

Each child card carries a deterministic tag `epic-phase:<epic-id>:<X>` where `<epic-id>` is the `clickup:` frontmatter value of the epic plan and `<X>` is the phase letter/number (e.g. `A`, `B`, `2`).

The tag is used as the primary idempotency key on every fan-out run:

| Existing tags matching `epic-phase:<epic-id>:<X>` | Action |
|---|---|
| 0 matches | Create new child card via `clickup-create-or-find` with `--parent <epic-id>` |
| 1 match | Reuse existing card — zero API writes for this phase |
| >1 matches | Reuse the card with the earliest `date_created`; emit WARN to stderr naming all duplicates |

This makes fan-out safe to re-run after partial failures without creating duplicate cards.

### Dependency edge wiring

After cards are created/found, the engine wires dependency edges per each phase's `**Depends on:**` line:

```bash
# Wire phase B to depend on phase A (B is blocked by A)
curl -X POST "https://api.clickup.com/api/v2/task/<phase-B-id>/dependency" \
  -H "Authorization: $CLICKUP_API_KEY" -H "Content-Type: application/json" \
  -d '{"depends_on": "<phase-A-id>"}'
```

The engine skips edges that are already wired (idempotent). Per-card existing-dep detection filters the `dependencies[]` array per `task_id == self.id AND depends_on != null` to ignore the mirror inverse edge stored on the same task. The mirror edge on the blocker's task is auto-populated server-side per the Dependencies schema above.

### Two-pass architecture

Fan-out runs in exactly two ordered passes — no partial state is possible:

1. **Pass 1 — validate-all (zero API writes):** Parse the plan, resolve all `**Depends on:**` references, collect any errors (missing `**Depends on:**` lines, unknown phase IDs). If any errors → exit 1, zero API calls.
2. **Pass 2 — create + wire (only if Pass 1 clean):** Create cards, wire edges, emit summary.

### Dry-run mode

`--dry-run` asserts zero API mutations. Parses the plan and reports what would be created/wired without any network calls. Output is byte-exact equivalent to the previous Python implementation — locked by `scripts/clickup/test-epic-fan-out.sh` (case 1: golden diff vs `scripts/clickup/tests/fixtures/golden/fan-out-dry-run.txt`).

### Auth

Token fetched via Azure Key Vault at runtime — not from env or `.env` files:

```bash
AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show \
  --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv
```

`CLICKUP_API_KEY` env var overrides the vault fetch (used by the test harness).

### Plan requirements (gate 14)

Every `## Phase X` block in an epic plan MUST include a `**Depends on:**` line. Plans missing this line fail plan-audit gate 14 (BLOCKING) before fan-out is attempted. Use `**Depends on:** none` for phases with no blockers.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Validation error or API failure |
| 2 | Usage / preflight failure (missing arg, bad flag, missing `jq`/`curl`/`awk`) |
| 3 | Auth failure — could not fetch CLICKUP-API-KEY |

## Epic Lifecycle State (`epic-state.sh`)

`scripts/clickup/epic-state.sh` is the lifecycle brain: status classifiers, phase ordering, rollup, next-phase selection, parallel-dispatch readiness. Pure bash + curl + jq (no Python).

```
epic-state.sh detect      <epic-id>   # True/False — does this epic have tagged phase cards?
epic-state.sh phases      <epic-id>   # phase_id  card_id  bucket  status (one per phase)
epic-state.sh next-phase  <epic-id>   # next card_id OR reason token
epic-state.sh rollup      <epic-id>   # in progress | qa | completed
epic-state.sh available   <epic-id>   # multi-line card_ids of unclaimed phases with deps-done
epic-state.sh epic-of      <card-id>   # epic id for any card (parent, else bounded dep-walk) or empty
epic-state.sh next-sibling <card-id>   # next ready sibling "<id>|<name>|<status>" when a child completes, or empty
```

### Status buckets (5)

Per-child classification, in priority order. Single source of truth for `phases`, `next-phase`, `rollup`, `available`:

| Bucket | Trigger |
|---|---|
| `done` | `task.status.type ∈ {"closed", "done"}` |
| `qa` | raw `status == "qa"` |
| `blocked` | raw `status == "blocked"` |
| `claimed` | raw `status == "in progress"` |
| `unclaimed` | else |

### `next-phase` reason tokens

| Output | Conditions |
|---|---|
| `<card_id>` (single line, no prefix) | First unclaimed phase whose every `depends_on` resolves to a card in `done_set` |
| `all-done` | empty phases OR all phases bucket==done |
| `waiting-qa` | no unclaimed, ≥1 qa, no claimed, no blocked |
| `all-blocked` | no unclaimed AND any blocked, OR no blocking_ids accumulated |
| `all-blocked (blocking_ids=['<id>', '<id2>'])` | unclaimed phases exist but all deps unmet — Python `repr(list[str])` byte shape preserved exactly (single quotes, comma+space, brackets) |

### `rollup` priority

| Output | Condition |
|---|---|
| `in progress` | empty phases OR any blocked OR any unclaimed/claimed |
| `qa` | no unclaimed/claimed/blocked, ≥1 qa, rest done |
| `completed` | all done |

### `available` semantics

Multi-line output (one card_id per line) of unclaimed phases whose every `depends_on` is in the done-set. Empty stdout when nothing is ready. Use case: orchestrator parallel-dispatch — every printed card_id is safe to dispatch concurrently because no in-flight blocker stands between it and the foundation.

### `epic-of` / `next-sibling` (card-scoped, <clickup-task-id>)

Both take a **card** id (not an epic id) and exist for ad-hoc epics — children linked by
`parent` and/or a cross-list dependency chain, with no `epic-phase:<eid>:<X>` tag.

- `epic-of <card>` — resolves the epic: `top_level_parent`/`parent` if set, else a bounded
  transitive dependency walk (both directions, hop cap 6, visited-set dedup) to the first
  neighbor carrying a parent; else empty. One GET per visited card. Always exit 0.
- `next-sibling <completed>` — `epic-of` the completed card, then union{ dep-successors
  (from the completed card's own `dependencies[]` where `depends_on == completed`) ∪ same-epic
  children (`?include_subtasks=true`) }, filter open + all-blockers-resolved (blocker parse per
  the Dependencies schema above), order dep-topology then `priority.orderindex`, print the first
  `<id>|<name>|<status>` or empty. Always exit 0.

**The bidirectional walk is load-bearing.** ClickUp mirrors the inverse dependency edge onto
the blocker's own card, so a cross-list chain member whose only link is `{task_id: <other>,
depends_on: <me>}` resolves ONLY via the successor direction. A blocker-only walk silently
fails the real case (empirical 2026-07-23: `<clickup-task-id>` carries `{task_id: <clickup-task-id>,
depends_on: <clickup-task-id>}` on its own card and has `parent: null`).

**`next-sibling` treats the just-completed card as a satisfied blocker.** Its successor is by
definition blocked by it, and `/done` moves the card to `qa` (status type `custom`, not
`closed`) — so re-reading the completed card's live status filtered out its own successor and
returned empty, killing the primary linear-chain case (empirical 2026-07-23, fixed + locked by
the `next-sibling completed-card-is-satisfied-blocker` harness case).

Both **always exit 0 and never emit an error to stdout**, so `/start-task` step 8.5 and `/done`
§4 never block on epic-resolution failure. Consumers: `~/.claude/commands/start-task.md` step 8.5
(status-bar epic label) and `~/.claude/commands/done.md` §4 (chain offer).

The degrade is **scoped to what became unknowable** — it is not a blanket "any error → empty":

| Failure | `next-sibling` behavior |
|---|---|
| Missing token | empty (both subcommands) |
| Completed card's own GET fails | empty — no trustworthy dep edge and no epic |
| `resolve_epic` finds no epic | empty |
| Epic-children GET fails | **still offers a valid dep-successor** — only the secondary child-candidate source is lost |
| A candidate's own GET fails | that candidate skipped |
| A candidate's blocker GET fails | that candidate treated as still-blocked (fail-safe) |

A candidate is only ever printed if its OWN GET succeeded and every blocker resolved, so a
partial-failure result never carries wrong data. Failing the whole call closed on an
epic-children blip would suppress a correct offer — the failure the feature exists to prevent.
Both directions are pinned by harness cases (`epic-GET-404 still offers dep-successor`,
`completed-card GET fails`).

Worked example (empirical 2026-07-23, epic `<clickup-task-id>`) — feeding each result back in walks the
whole chain across both lists:

```
<clickup-task-id> -> <clickup-task-id> -> <clickup-task-id> -> <clickup-task-id> -> <clickup-task-id> -> (empty)
```

### Auth

Same vault pattern as `fan-out-epic.sh`; `CLICKUP_API_KEY` env var override accepted.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | API error |
| 2 | Usage / preflight failure |
| 3 | Auth failure — could not fetch CLICKUP-API-KEY |

### N+1 API pattern

`list_phases` does 1 GET on `task/<epic-id>?include_subtasks=true` for the subtask list, then a per-card GET on `task/<card-id>` for the real `dependencies[]` array (the parent GET returns subtasks with `dependencies: []` — empirical quirk preserved).

## <your-org>-Specific IDs

| Resource | ID |
|----------|-----|
| **Workspace** | `24555569` |
| **Space:** Office of the CEO | `48531289` |
| **List:** Automations & Engineering (A&E) — SF / VoIP business automations | `<clickup-list-id>` (KV: `CLICKUP-AE-LIST-ID`) |
| **List:** Automation Infrastructure — <internal-bot>/<internal-bot>/orchestrator/MCP/skills/runbooks/CI | `<clickup-list-id>` (KV: `CLICKUP-INFRA-LIST-ID`) |
| **List:** Meeting Inbox | `<clickup-list-id>` |
| **List:** Office of the CEO | `374710674` |
| **List:** Chief of Staff | `900600138445` |

### Assignees

| Person | User ID |
|--------|---------|
| <your-name> | `42469271` |
| Cez Gonzales | `42473716` |

### A&E + Infra List Statuses (shared custom override)

`backlog` → `planning` → `implementation` → `queued` → `in progress` → `qa` → `completed` (+ `blocked` side-channel)

Both lists share the identical workflow so orchestrator dispatch logic is list-agnostic.

### Space Statuses (other lists)
`new` → `scheduled` → `in progress` → `requires revisions` → `waiting client response` → `waiting vendor` → `on hold` → `cancelled` → `completed`

### Custom Fields (shared by A&E + Infra)

ClickUp custom fields are workspace-scoped — same UUID, attached to both lists. Orchestrator code that reads fields by ID works on tasks from either list unchanged.

| Field | ID | Type |
|-------|----|------|
| Task Owner | `<azure-uuid>` | text |
| Requestor UPN | `<azure-uuid>` | short_text |
| Time Saved (hrs) | `<azure-uuid>` | number |
| Plan File | `<azure-uuid>` | url |
| Plan Reviewed | `<azure-uuid>` | checkbox |
| Codex Reviewed | `<azure-uuid>` | checkbox |
| Claude Reviewed | `<azure-uuid>` | checkbox |
| Human Approved | `<azure-uuid>` | checkbox |
| Plan Updated Post-Codex | `<azure-uuid>` | checkbox |
| Scope Validated | `<azure-uuid>` | checkbox |
| Override Gates | `<azure-uuid>` | checkbox |
| Dispatch Lock | `<azure-uuid>` | short_text |
| Preset | `<azure-uuid>` | drop_down |
| Executor | `<azure-uuid>` | drop_down |
| Window | `<azure-uuid>` | drop_down |
| Human Hours | `<azure-uuid>` | number (precision 2) |
| AI Cost (USD) | `<azure-uuid>` | number (precision 2) |
| Contributors | `<azure-uuid>` | text |
| R&D Qualifying | `<azure-uuid>` | checkbox |

The last four (R&D Credit Reporting — IRC §41 effort/cost substantiation, epic `<clickup-task-id>`) were created via `POST /list/<clickup-list-id>/field` (A&E) on 2026-06-10, then **promoted to the "Office of the CEO" space (48531289) via the UI** so the same UUIDs attach to A&E + Infra + Sandbox. API-created fields are list-scoped only — space-sharing is UI-only (see "Creating Custom Fields via API" below). Creator: `scripts/rnd-credit/create_fields.sh` (idempotent GET-before-POST + read-back verify).

### Setting Custom Fields via API

Custom fields require individual POST calls (not bulk via task update):

```bash
# Set a URL field (Plan File)
curl -s -X POST "https://api.clickup.com/api/v2/task/TASK_ID/field/FIELD_ID" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": "https://example.com"}'

# Set a checkbox field (Plan Reviewed, Codex Reviewed)
curl -s -X POST "https://api.clickup.com/api/v2/task/TASK_ID/field/FIELD_ID" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": true}'
```

Empty `{}` response = success. Custom fields cannot be set via the task update endpoint (`PUT /task`).

### Priority Values
`urgent` | `high` | `normal` | `low`

### Tags

> Tags are assigned at scoping time, not at task creation. Tasks without a scope block should have no type/app tags.

**Type** (required, pick exactly one): `bug`, `enhancement`, `chore`, `audit`, `documentation`, `review`

Legacy `feat` tag is deprecated — maps to `enhancement`. `scripts/audit-backlog.py` migrates stragglers.

**Type** (required after scoping, pick one): `bug`, `enhancement`, `chore`, `audit`, `documentation`, `review`

**App** (required after scoping, one+): `salesforce`, `<internal-bot>`, `n8n`, `occ`, `<knowledge-base>`, `clickup`, `teams`, `calendly`, `apollo`

**Executor** (optional): `interactive` (held for human dev — blocks auto-dispatch)

**Environment** (optional): `local` (historical tag; no longer gates dispatch — all dispatch is local-poller on Mac Studio since <clickup-task-id>)

**Complexity** (optional, Anthropic presets only): `lite` (haiku), `complex` (opus)

**Team** (optional, reporting only): `engineering`, `support-ops`, `sales-ops`, `revenue-ops`

**Audience** (optional): `sales`, `support`, `client-success`, `managers`, `marketing`, `revenue-ops`, `hr`, `external`

**Cross-cutting** (optional): `bots`

**System** (managed automatically, do not add/remove manually):
- `waiting` — task is blocked by a dependency; maintained by `/sf-case-fix`
- `scope-needed` — missing valid scope block; dispatch blocked until scope Q&A completes
- `classify-needed` — task scoped but missing type/app/executor tags; dispatch blocked until classification complete
- `cloud` — (deprecated/historical) was auto-added by the cloud orchestrator post-dispatch; Wave 1.5c bulk-stripped this tag from open tasks; cloud orchestrator retired in <clickup-task-id>; tag no longer added
- `rate-limited`, `rate-limited-abandoned`, `urgent`, `budget-paused`, `plan` — pipeline state

### Preset Custom Field

**Field ID:** `<azure-uuid>`

Values currently live in the dropdown: `dev`, `planner`, `triage`, `docs-update`, `support`, `quick`, `code-review`.

The `local-summarize` / `local-classify` / `local-review` / `local-patch` presets were removed 2026-09-28 with the local models (<clickup-task-id>); do not add them.

Resolution order: Preset field → tag_mapping → default `dev`

Set explicitly when a task has multiple mapped app tags.

**Dropdown options cannot be edited via API.** The ClickUp v2 API does not expose an endpoint for adding options to an existing dropdown field. Verified empirically (2026-05-03 — `POST /api/v2/list/{list_id}/field/{field_id}/option`, `PATCH /api/v2/list/{list_id}/field/{field_id}`, `PATCH /api/v2/workspace/{workspace_id}/field/{field_id}` all return 404) and cross-referenced against `developer.clickup.com/reference/setcustomfieldvalue` + `getaccessiblecustomfields` (no mutation endpoint documented for dropdown options). Workarounds: (a) add via ClickUp UI on each list; (b) automate the UI add with Browser Use Cloud per `.claude/rules/browser-automation.md`; (c) recreate the field with the full option list in a single `POST /api/v2/list/{list_id}/field` (destructive — would orphan existing field-value references on prior tasks).

### Executor Custom Field

**Field ID:** `<azure-uuid>`

Values: `local-claude` (orderindex 0), `local-codex` (1), `local-mlx` (2), `local-<retired-executor>` (3).

**`local-mlx` and `local-<retired-executor>` are retired (2026-09-28, <clickup-task-id>)** but remain as dropdown options, because options cannot be removed via the API (see the Preset field note above). Remove them in the ClickUp UI if wanted. The local-poller refuses any card carrying either: it comments the reason and sets the card `blocked`.

Set on tasks to declare which Mac Studio executor the `<launchd-label>` daemon should hand off to. The `cloud` option and Maestro `sub-local` subscription were retired in <clickup-task-id> (Wave 4.6). All dispatch is now local-poller — there is no cloud path to bypass. Full daemon reference: `docs/runbooks/local-poller.md`.

### Window Custom Field

**Field ID:** `<azure-uuid>`

Values: `now`, `extended` (default), `off-peak-only`

Meaningful only when `Executor=local-claude`. Ignored for other executors. Controls Anthropic Max plan off-peak scheduling.

### Creating Custom Fields via API

```bash
# Create a dropdown field on a list
CLICKUP_TOKEN=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv)
curl -s -X POST "https://api.clickup.com/api/v2/list/${LIST_ID}/field" \
  -H "Authorization: ${CLICKUP_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "FieldName",
    "type": "drop_down",
    "type_config": {
      "options": [
        {"name": "option1", "orderindex": 0},
        {"name": "option2", "orderindex": 1}
      ]
    }
  }'
```

**⚠️ `POST /list/{id}/field` creates a LIST-scoped field — it does NOT auto-attach workspace-wide.** (Empirical (2026-06-10, epic <clickup-task-id>): created `Human Hours`/`AI Cost (USD)`/`Contributors`/`R&D Qualifying` on A&E `<clickup-list-id>`; read-back confirmed on A&E but `GET /list/{infra}/field` + `GET /list/{sandbox}/field` showed them absent. The 3 lists share space 48531289 but sit in different folders.) The existing "shared by A&E + Infra" fields (`Dispatch Lock`, `Preset`, etc.) appear on every list because they were created/promoted at the **Space** level via the UI — `GET /space/{id}/field` under-reports those (returns only the 2 true workspace-level fields, `Task Owner` + `Time Saved`), which is why they look list-local in the API.

**To make a created field shared across lists, promote it to the Space in the UI** (field settings → "Where to use this field" → the Space) — this keeps the same UUID. There is **no API to create or promote a field at Space/Folder/Workspace scope** (docs-confirmed: `developer.clickup.com/reference/getaccessiblecustomfields` documents only the list-level GET; no space/folder create endpoint). Likewise **you cannot add options to an existing dropdown via API** — create the full option list at field-creation time, or use the ClickUp UI to add options later.

### Creating New Tags

Tags must already exist in the space before they can be assigned to tasks. To create a new tag:

```bash
AZURE_CONFIG_DIR=<azure-config-dir> TOKEN=$(az keyvault secret show --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv)
curl -s -X POST "https://api.clickup.com/api/v2/space/48531289/tag" \
  -H "Authorization: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tag":{"name":"TAG_NAME","tag_fg":"#FFFFFF","tag_bg":"#7C3AED"}}'
```

### Removing Tags From Tasks

**empirical** (used in `scripts/audit-backlog.py:290`, `scripts/backfill-workflow-triage.py:462`, `scripts/orchestrator/strip-cloud-tags.sh:32`):

```bash
AZURE_CONFIG_DIR=<azure-config-dir> TOKEN=$(az keyvault secret show --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv)
curl -s -X DELETE "https://api.clickup.com/api/v2/task/<task-id>/tag/<tag-name>" \
  -H "Authorization: $TOKEN"
```

| HTTP | Meaning |
|---|---|
| 200 | Returned unconditionally on every well-formed DELETE — whether the tag exists in the space, is on the task, or neither. Treat as success. |
| 401 | Token expired or wrong vault |
| 5xx | ClickUp transient; retry once |

**empirical** (2026-05-16): DELETE returns 200 even for tag names that have never existed in this space — the endpoint never returns 404 for missing tags. Probed against `<clickup-task-id>` with both an already-removed tag and a fictional name `nonexistent-tag-12345xyz`; both 200. Defensive code may still branch on 404 for forward-compatibility, but the branch is dead in practice.

Tag names with spaces must be URL-encoded (e.g. `failed%20run`).

The `scope-needed` tag is the canonical use case: set by `/start-task` for free-text intents, stripped by `scripts/clickup/strip-scope-needed-tag.sh` once a plan is finalized (<clickup-task-id>). The same helper also strips `classify-needed` — a finalized + reviewed plan settles BOTH scope and classification, and `<orchestrator-cli>`'s scope_preflight + `evaluate_cascade_promote` (clickup_poller.py) bail/SKIP on EITHER tag, so leaving `classify-needed` on stalls the epic-phase cascade in `blocked` exactly like a stale `scope-needed` would (<clickup-task-id>; precedent: n8n epic <clickup-task-id> Phase 3 fired the daily Phase-orphan alert).

## n8n Workflows (ClickUp integrations)

| Workflow | ID | Purpose |
|----------|----|---------|
| <internal-bot>: Automation Request Intake | `TiOTn452CSO2X4EU` | Creates tasks in A&E list (public intake stays A&E per audience rule) |
| <internal-bot>: Task Close Notifier | `fT7AYkSCWMGALhKH` | ClickUp webhook `<azure-uuid>` (space `48531289`, `taskStatusUpdated` → `/webhook/<internal-bot>-task-close`, `responseMode: onReceived`). On `completed` for a staff-requested A&E card it reports back once: Teams channel thread link (`Source URL` field `4005be55-…`, else the first `teams…/l/message/` URL in the description) → <internal-bot> replies in that thread (direct Bot Framework) and @mentions the requester, who must have posted in the thread (Graph root post and replies → roster id; item 8); no link → ClickUp comment documenting the resolution, no mention. Never a 1:1 DM. See "Task Close Notifier" below (<clickup-task-id>) |
| <internal-bot>: Request Status Check | `7wUVFqAi935BVURl` | Queries A&E list |
| Daily Task List | `FXWCMmKyJoyoNaMt` | Weekdays 8 AM ET: <your-name>'s assigned + watched open tasks as a card in <internal-bot> Digest (direct Bot Framework channel post, <clickup-task-id>). Also lists open A&E cards tagged `source-url-missing` (no Teams link in the Source URL field; tag set by Auto-Triage) under **Missing Teams link**, and posts even when <your-name> has nothing else. A failed tag fetch shows a warning line instead of dropping the section (<clickup-task-id>; `n8n/_tests/patch_daily_digest_source_missing.mjs`, tests `daily_digest_source_missing.test.mjs`) |
| OCC: Auto-Triage on Task Creation | `OgLFf54BpJGGxJnq` | Two list-scoped `taskCreated` webhooks (A&E + Infra, `filters.listId`); skips research-log/fleet cards and orchestrator review/waiver cards (`pr-review`, `pr-waiver`, `review-of:*`; <clickup-task-id>); never sets Preset on planned/queued cards; flags A&E requests with no Source URL (`source-url-missing`). Details: `n8n-api.md` "Auto-triage classifier taxonomy" (<clickup-task-id>) |

## Task Close Notifier (<clickup-task-id>)

Workflow `fT7AYkSCWMGALhKH`, source `n8n/<internal-bot>-task-close-notifier.json`, tests `node --test tests/n8n/<internal-bot>-task-close-notifier.test.mjs`.

1. **Trigger + authentication.** ClickUp webhook `3b459604-…` → `POST /webhook/<internal-bot>-task-close`, `responseMode: onReceived` (ClickUp gets 200 at once for every status change) with `options.rawBody: true`. `Verify ClickUp Signature` recomputes the hex HMAC-SHA256 of the raw body with `$vars.CLICKUP_TASK_CLOSE_WEBHOOK_SECRET` (n8n Variable `SXCsNusj0fgpTIGb`, value = the webhook's ClickUp `secret`, which `GET /team/24555569/webhook` returns and `PUT /webhook/{id}` keeps) and compares it to `X-Signature` in constant time. A missing secret, missing or wrong signature, unparseable body or malformed `task_id` drops the event. Code nodes cannot read n8n Credentials, so a Variable is the only store a Code node can use (same posture as `<credential-env>`). After `Fetch Task` the workflow acts only on API data: the card's API status must be `completed`. If the webhook is ever re-created (DELETE + POST), write its new secret to the Variable or every event is dropped.
2. **Who gets a report-back (`Decide Report-Back`).** A&E list only. Skipped: tags `orchestrator`, `fleet`, `sf-fault`, `plan`, `scratch`, `research-log`, `workflow-error`, `audit-error`, `alert-fault`, `sweep:*`, `epic-phase:*`; children of the AE epic `<clickup-task-id>`; any card with a ClickUp comment containing `<internal-bot> report-back` (idempotency marker, also on the 55 backfilled cards).
3. **Thread path.** Link source: the `Source URL` field `<azure-uuid>` **only**. Intake stamps that field from Bot-Framework-verified ids (#1616). A Teams link that appears only in the description is client- or LLM-controlled text, so it never picks a thread; that card gets the comment (<clickup-task-id>). Only channel ids (`19:…@thread.tacv2|@thread.skype`) with a numeric message id, a `groupId` team GUID and (when present) `tenantId` = <your-org> qualify — chat links never get a post. The link is editable card text, so a Teams post happens only when Graph (app-only, <your-org> tenant) returns that exact root post (`id` matches, no `replyToId`) with `channelIdentity` equal to the link's team + channel, and the root author, when it is a user, is an <your-org> user; otherwise the card gets the resolution comment instead. Reply target = `parentMessageId` (unless `0`), else the id in the URL path. `Get Thread Root Post` (Graph `ChannelMessage.Read.All`) verifies the thread and gives the root author; a request from <your-name> is not a staff request and gets nothing. `Get Mention Member` (`GET {serviceUrl}/v3/conversations/{channelId}/members/{aadObjectId}`, once, for the requester only) gives the roster id `29:1…` used in the mention entity. A Graph failure, a failed member lookup or a requester mismatch means no Teams post; the card gets the comment instead (item 8). `Post Thread Reply` → then a ClickUp audit comment with the marker. A failed thread post (non-2xx) falls back to the resolution comment, with the HTTP status appended.
4. **Comment path.** No channel link but a staff requester signal (non-<your-name> `Requestor UPN`, `**Requester:**`/`**Requestor:**` line, `Reporter:` line, non-<your-name> `reporter:*` tag, `intake`/`revops-request` tag) → ClickUp comment with the resolution, no mention. No signal at all → nothing.
5. **Resolution text.** Haiku (`claude-haiku-4-5`, `anthropicApi` cred) writes 1–2 plain sentences from the title, description and the last 8 comments, fenced in `<card_data>` as untrusted data. URLs, HTML tags and `@` are stripped from the output and it is capped at 400 characters; on any failure the text is "This request has been completed.". The card title is capped at 200 characters, and every card- or Graph-derived string is HTML-escaped in the Teams message. PR links (`github.com/<org>/<repo>/pull/N`) come from comments/description by regex.
6. **Security smoke (2026-10-05 22:43Z, same probe).** Unsigned POST and a zero signature: executions 297437/297438 stopped at `Verify ClickUp Signature` with 0 items. Correctly signed events: 297439 (thread, Graph-verified, 201, real mention) and 297440 (comment). Tests: 56 node:test cases incl. negative paths; six security assertions mutation-verified.
6. **Smoke (2026-10-05, probe clone `kbf8o1dcCHoye6R0` on `/webhook/<internal-bot>-task-close-probe-<clickup-task-id>`).** Non-completed event → HTTP 200 in 0.27 s (exec 297403 stopped at `Is Completed?`). Thread card `<clickup-task-id>` (Source URL = Playground thread `1787060282214`) → 201, Graph shows a real mention (`mentions[0].mentioned.user.displayName = <your-name>`). Comment card `<clickup-task-id>` → resolution comment with PR line. Re-firing a reported card → `route: skip, reason: already reported back`.
7. **Error path.** `errorWorkflow` = Error Notifier `bM0t0vPZKlD3deAo`.
8. **Requester must have posted in the thread (<clickup-task-id>, 2026-10-05; widened by <clickup-task-id>, 2026-10-07).** The thread link is editable card text, so Graph confirming the thread exists is not enough. The requester is the author of the first message that describes the problem: usually the root post, but the reply that raised the issue when the root is a standup/check-in prompt or bot-authored. So the card's requester must be **any <your-org> user who posted in the thread**, not only the root author.
   1. `Check Prior Reply` lists the distinct <your-org>-tenant user authors of every reply (`repliers`, all pages, no cap).
   2. `Get Requester User` (new, after `Check Prior Reply`) resolves the card's `Requestor UPN` to an AAD id once: `GET https://graph.microsoft.com/v1.0/users/{upn}?$select=id,userPrincipalName,displayName` with the same Graph app token as the root read. **Probe: UPN to id** (`GET /users/<user-upn>?$select=id,userPrincipalName,displayName` with the <internal-bot> SP cert token). Captured: 2026-10-07T15:16:29Z. Output: `HTTP 200`, `id` = `<azure-uuid>` (= `RAY_AAD`); an unknown UPN returned `HTTP 404`.
   3. `Select Requester` (was `Expand Participants`; between `Get Bot Token` and `Get Mention Member`) emits exactly one item. Its `aadId` is the requester's id when that id is the root author or any reply author, else `none` (unresolved lookup, or the requester has not posted). There is no participant cap and no per-participant roster fan-out, so a requester who posted late in a long thread is found.
   4. `Get Mention Member` looks that one id up on the roster and returns its `userPrincipalName`. `Build Thread Reply` posts only when that equals the card's `Requestor UPN`, and mentions that person.

   The card requester is the `Requestor UPN` field only. A description `**Requester:**` line never counts for the thread match. Each of these routes to the ClickUp comment, with the reason appended and no Teams post:
   1. The card has no requester.
   2. Graph cannot resolve the `Requestor UPN` to a user.
   3. The requester has not posted in the thread (root author or any reply author).
   4. The requester's roster lookup fails.
   5. The thread root was written by a user from another tenant.

   Only `userPrincipalName` is compared (never `email`). A bot-authored root is allowed now, because the requester is then a replier. **<your-name> is excluded first.** `Build Thread Reply` checks the card's `Requestor UPN` (`<your-email>`) and the id from `Get Requester User` (`RAY_AAD`) before any thread, match or comment logic, so <your-name>'s requests get neither a post nor a comment even when the roster lookup fails or the thread is long (the claim is withdrawn); a thread <your-name> opened but a staff member replied in is a normal report-back to that member. The filing-ack binding (item 12.1) still applies, so the card must have been filed from this thread by <internal-bot>.
   Intake stamps `Requestor UPN` with the same person by the same rule (`<internal-bot>: Stamp Request Source`, `vjbJ8WwH5wVc1g4i`; `<internal-bot>-request-intake.md` "Source URL + requester on every Teams-origin card"), so a correctly filed card matches.
   **Deployed 2026-10-07 21:34Z (PM-authorized).** `PUT` via `scripts/n8n/safe-put.sh`: notifier `fT7AYkSCWMGALhKH` versionId `d4d3d647-…` → `<azure-uuid>`, stamp `vjbJ8WwH5wVc1g4i` `ff3fb72b-…` → `<azure-uuid>`. In both, `activeVersion` equals the draft, and the draft matches the repo node by node (credentials included). Pre-deploy exports: `n8n/_backup/<internal-bot>-task-close-notifier-pre-<clickup-task-id>-requester-rule.json`, `n8n/_backup/<internal-bot>-stamp-request-source-pre-<clickup-task-id>-requester-rule.json`. Live-click smoke (test-class-matrix "n8n workflow — handler branch/routing"), Playground thread `1780873255671` (root by <your-name>, reply by a staff member), with a <internal-bot> `📝 Filed:` ack posted per card:
   1. Exec `305629`: requester = the replier, who is not the root author. `Select Requester` `participant:true` → `Get Mention Member` 200 → `Build Thread Reply` `action:post` → `Post Thread Reply` 201. Graph shows a real mention of the requester. No comment-path node ran.
   2. Exec `305632`: requester is a channel member who never posted. `Select Requester` `aadId:none` → `Get Mention Member` 404 → `action:comment`, reason "requester has not posted in the thread". `Post Thread Reply` did not run, and nothing was posted in Teams.
   3. Stamp execs `305642` (root not generic: `requesterSource:thread_root`) and `305662` (root opens "Good morning team": `rootGeneric:true`, `requesterSource:caller`) came from `tests/playwright/<clickup-task-id>-playground-log-request.spec.ts`. Both ran version `750f5bd2-…`.
   A `scratch` tag makes `Decide Report-Back` skip the card, so a smoke card must drop that tag before it is completed.
9. **Failure handling (<clickup-task-id>).**
   1. `Get Graph Token` and `Get Bot Token` have `onError: continueRegularOutput`. A token failure makes the Graph read fail, and the card gets the comment.
   2. ClickUp API failures (claim, re-read, finalize) fail the run, and the workflow's `errorWorkflow` (Error Notifier `bM0t0vPZKlD3deAo`) raises an A&E alert.
   3. A claim left `in progress` by a failed run blocks only for 10 minutes. The `Report-Back Sweep` (item 12.4) then re-delivers it; the card does not need to complete again.
10. **One report-back per card, even with overlapping deliveries (<clickup-task-id>).**
    1. `Claim Report-Back` writes the marker comment `<internal-bot> report-back (<clickup-task-id>): in progress` before anything is posted.
    2. `Re-read Comments` and `Won Claim?` let only the earliest live claim proceed, ordered by `date`, then by `id`. A live claim is the run's own claim or one younger than 10 minutes. If any final report-back exists, the run stops.
    3. Any other claim goes to `Withdraw Claim` (`DELETE /comment/{id}`).
    4. Before posting, `Get Thread Replies` (Graph `…/messages/{root}/replies?$top=50`, n8n pagination on `@odata.nextLink`, max 20 pages) is read, and `Check Prior Reply` collapses the pages into one decision. If any page fails, or the page limit is hit, the history is unverified and the card gets the comment instead (no Teams post). empirical (2026-10-05, probe `$top=2` on the Playground thread): n8n returns one item per page (`{statusCode, body, headers}`), and the last page has no `@odata.nextLink`. If a reply from <internal-bot>'s own app (`from.application.id` = `<azure-uuid>`) is a report-back for this card (body starts `✅ Your request <strong>`, optionally after `<div>` and the `<at>` mention, and has `href="https://app.clickup.com/t/<id>"`), nothing is posted and the claim is finalized as "already replied". <internal-bot>'s intake ack does not count (<clickup-task-id>). This closes the duplicate left by a successful send whose finalize PUT failed, after its claim expired (fleet review round 1).
    5. The winner's final text replaces its claim with `PUT /api/v2/comment/{id}` `{comment_text, resolved:false}` (`Finalize Report-Back Comment`). empirical (2026-10-05): the PUT returns `200 {}` and the comment text is replaced in place.
11. **Stopgap switch.** To stop all Teams posts without touching anything else, set `Has Teams Channel Thread?`'s condition to `={{ false }}`. Every report-back then becomes a ClickUp comment. This was used 23:31Z–fix-deploy on 2026-10-05 (<clickup-task-id>). Pre-stopgap export: `n8n/archive/fT7AYkSCWMGALhKH-pre-<clickup-task-id>-stopgap-20261005T233141Z.json`. Used again from 2026-10-06 03:41Z until the <clickup-task-id> fix deployed; pre-stopgap export `n8n/archive/fT7AYkSCWMGALhKH-pre-<clickup-task-id>-stopgap-20261006T034108Z.json`.
12. **Post-merge review fixes (<clickup-task-id>, 2026-10-06).**
    1. **The card must be bound to the thread by a <internal-bot> filing ack.** The `Source URL` and `Requestor UPN` fields are both editable, so matching the thread's root author to the UPN field alone let anyone who edited both redirect a report-back into another staff member's thread. `Check Prior Reply` now also returns `bound`. `Build Thread Reply` posts only when `bound` is true; otherwise the card gets the comment "<internal-bot> did not file this card from that thread". `bound` needs a reply in the thread that meets all five conditions:
       1. It is from <internal-bot>'s own app (`<azure-uuid>`).
       2. It links `href="https://app.clickup.com/t/<id>"`.
       3. It was posted between 5 minutes before and 7 days after the card was created (`taskCreatedMs` from `Decide Report-Back`).
       4. Its plain text (tags and HTML comments stripped, `&amp;` decoded) starts with one of <internal-bot>'s filing-ack templates:
          1. `📝 Filed:` / `📎 Filed:` … `Issue logged. ID: <this card id>`, from bot-handler `Post Intake Reply` and `<internal-bot>-intake` `Format Filed`.
          2. `✅ A&E card created:`, from RevOps audit `create_card`.
          3. `✅ Got it, <name>! Your automation request has been logged in ClickUp.`, from `/request` `Format Confirmation`.
          4. `🔎 Investigation filed:`, from bot-handler `Post Investigate Reply`.

       5. **Every** ClickUp card link in the ack points at this card. An ack for another card whose title or root-cause text links this card does not bind. For `Filed:`, the end-anchored `Issue logged. ID: <id>` line must be this card (fleet review round 4).

       A <internal-bot> answer that merely echoes a card link, `📎 Already filed:`, or the RevOps `link_existing` reply `📌 Logged — tracking this under:` never binds. The last one links a thread to an **existing** card that was not filed from it; cards whose only <internal-bot> message in the thread is that reply get the ClickUp comment, not a Teams post (<clickup-task-id>). empirical (2026-10-06, Graph replies on the threads of <clickup-task-id>, <clickup-task-id>, <clickup-task-id>, <clickup-task-id>, <clickup-task-id>): each holds such an ack from `CloudieMcCloudieBot-Fresh`. The RevOps `📌 Logged` ack arrives about 24 h after the card; the others within 10 s. A new filing-ack template must be added to `isFilingAck` in `Check Prior Reply`, or its cards fall back to the ClickUp comment.
    2. **Only <internal-bot>'s report-back suppresses a post.** Before this fix, any app reply containing the card URL counted as "already replied", including <internal-bot>'s own intake ack, which every thread-filed card has. So every thread report-back became a ClickUp comment. Now only a <internal-bot>-app reply in report-back shape counts (item 10.4).
    3. **Every comment page is read.** ClickUp returns the newest 25 comments per page. `Fetch Comments` and `Fetch Sweep Comments` page with `start`/`start_id` from the oldest comment of the previous page, until a page has fewer than 25 comments, up to 20 pages. `Decide Report-Back` merges the pages, so an old final report-back still blocks a second one. Only a last page shorter than 25 proves the history complete. If the 20-page cap is reached, `Decide` skips with "comment history incomplete (page cap reached)" and the sweep does not retry that card (fleet review round 1).
    4. **Stale claims are retried.** The sweep runs `Report-Back Sweep` (schedule, every 30 min) → `List Recently Completed` → `Split Completed` (de-duplicated) → `Fetch Sweep Comments` → `Select Stale Claims` → `Re-send Completion`.
       1. `List Recently Completed` lists A&E cards with `statuses[]=completed`, updated in the last 3 days. It pages with `page`, up to 10 pages.
       2. `Select Stale Claims` groups comment pages per card; a card with a failed page is skipped. A card qualifies when it has no final report-back, fewer than 3 claims, and its newest `in progress` claim is older than 10 minutes.
       3. Each qualifying card gets a completion event signed with `$vars.CLICKUP_TASK_CLOSE_WEBHOOK_SECRET`, POSTed to this workflow's own `/webhook/<internal-bot>-task-close`, so the normal pipeline re-checks everything.
       4. Re-sends are capped at 3 per card, at least 25 minutes apart. The count lives in workflow static data (`reportBackSweep`), is pruned after 4 days, and clears when a final report-back exists. A card that never writes a new claim therefore stops after 3 sends.
       5. Cards older than 3 days are out of scope.
    5. Tests: `tests/n8n/<internal-bot>-task-close-notifier.test.mjs`, 107 cases. The 25 new cases were checked against 18 mutants, all red. Plan: `docs/superpowers/plans/2026-10-06-<clickup-task-id>-notifier-trust.md`.

## A&E Dashboard & Views

**Dashboard:** A&E Ops Console — `https://app.clickup.com/24555569/dashboards/qdc1h-7111` (dashboards are UI-only — no v2 API for create/configure).

| View | ID | Type | Config |
|------|----|------|--------|
| Backlog Board | `qdc1h-118251` | board | Group by status |
| By Domain | `qdc1h-118271` | board | Group by tag |
| Bugs & Issues | `qdc1h-118311` | list | Filter: tag = bug |
| Docs & Audits | `qdc1h-118331` | list | Filter: tag = documentation OR audit |
| Recently Completed | `qdc1h-118291` | list | Show closed tasks |
| SF + Inbound Requests | `qdc1h-118771` | list | Filter: tag ANY [`salesforce`, `intake`] |

### Views API

**empirical** (2026-05-13): views ARE programmable via v2 — `GET/POST/PUT/DELETE /api/v2/list/{list_id}/view` and `/api/v2/view/{view_id}/task`. Earlier "UI-only" assumption was wrong; verified by creating `qdc1h-118771` from a single `curl POST`.

```bash
# List views on a list
curl -sS "https://api.clickup.com/api/v2/list/<clickup-list-id>/view" \
  -H "Authorization: $CLICKUP_API_KEY"

# Get tasks rendered by a view (honors its filters + sort)
curl -sS "https://api.clickup.com/api/v2/view/qdc1h-118771/task?page=0" \
  -H "Authorization: $CLICKUP_API_KEY"

# Create a list view — tag-filter, group-by-status, priority/dateCreated sort
curl -sS -X POST "https://api.clickup.com/api/v2/list/<clickup-list-id>/view" \
  -H "Authorization: $CLICKUP_API_KEY" -H "Content-Type: application/json" \
  -d '{
    "name": "SF + Inbound Requests",
    "type": "list",
    "parent": { "id": "<clickup-list-id>", "type": 6 },
    "grouping": { "field": "status", "dir": 1, "collapsed": [], "ignore": false, "single": false },
    "divide": { "field": null, "dir": null, "collapsed": [] },
    "sorting": { "fields": [
      { "field": "priority",    "dir": -1, "idx": 0 },
      { "field": "dateCreated", "dir": -1, "idx": 1 }
    ]},
    "filters": {
      "op": "AND",
      "fields": [
        { "field": "tag", "op": "ANY", "determinor": null, "idx": 0, "values": ["salesforce","intake"] }
      ],
      "search": null, "search_custom_fields": false, "search_description": false,
      "search_name": true, "show_closed": false
    },
    "columns": { "fields": [] },
    "team_sidebar": { "assignees": [], "group_assignees": [], "assigned_comments": false, "unassigned_tasks": false },
    "settings": { "show_subtasks": 1, "show_assignees": true, "show_empty_fields": false }
  }'

# Delete a view
curl -sS -X DELETE "https://api.clickup.com/api/v2/view/{view_id}" \
  -H "Authorization: $CLICKUP_API_KEY"
```

**Filter operators** (empirical from existing views, 2026-05-13): tag filter uses `{ field: "tag", op: "ANY", values: [...] }` — multiple values within a single field = OR. Top-level `filters.op` combines fields (`AND` / `OR`). Other operators (`EQ`, `IS_SET`, `NOT_ANY`, etc.) are likely supported but not yet probed.

### R&D Credit views (empirical 2026-06-12)

Eight views created by `scripts/rnd-credit/views.py` via `POST /api/v2/list/{list_id}/view`:

| List | View name | View ID |
|---|---|---|
| A&E (<clickup-list-id>) | R&D — by Contributor | `qdc1h-119431` |
| A&E (<clickup-list-id>) | R&D — by Quarter | `qdc1h-119451` |
| A&E (<clickup-list-id>) | R&D — Qualifying only | `qdc1h-119471` |
| A&E (<clickup-list-id>) | R&D — by Epic | `qdc1h-119491` |
| Infra (<clickup-list-id>) | R&D — by Contributor | `qdc1h-119511` |
| Infra (<clickup-list-id>) | R&D — by Quarter | `qdc1h-119531` |
| Infra (<clickup-list-id>) | R&D — Qualifying only | `qdc1h-119551` |
| Infra (<clickup-list-id>) | R&D — by Epic | `qdc1h-119571` |

**Gotchas:**

- **Custom-field columns/sort/filter in a view payload use the `cf_<uuid>` token, not `{field: "custom_field", field_id: "..."}` (400 VIEWS_016).** Correct form: `{"field": "cf_c84b2ffd-2145-44d6-b674-f0b1c782884b"}`. (empirical 2026-06-12.)
- **Column-sum footers are UI-only.** No API key exists to set Calculate → Sum on a column — must be done in the ClickUp UI after view creation.
- **Sort field names are camelCase, not snake_case.** Passing `date_created` returns `VIEWS_016` validation error. Allowed values (per the error response, empirical 2026-05-13): `subcategory`, `assignee`, `priority`, `dueDate`, `commentCount`, `incompleteCommentCount`, `startDate`, `anyDate`, `timeLogged`, `timeLoggedRollup`, `timeEstimate`, `timeEstimateRollup`, `pointsEstimate`, `pointsEstimateRollup`, `dateCreated`, `dateUpdated`, `dateDone`, `duration`, `name`, `status`, `dateClosed`, `dateDelegated`, `createdBy`, `timeInStatus`, `linked`, `dependencies`, `pages`, `id`, `customItems`, `shadowTaskColor`, `shadowTaskLocation`. Sort `dir`: `-1` = desc, `1` = asc.
- **Pinning to left nav + Sharing visibility are NOT exposed via API.** Both require the UI's view ⋯ menu. Newly-created views default to `visibility: "public"` (org-wide) and unpinned. **pending** — no API endpoint probed yet for either; workaround is to edit in the UI after create.
- **Parent type for lists is `6`.** `{ parent: { id: <list-id>, type: 6 } }` (empirical 2026-05-13). Other parent types (folder / space / team) not yet probed from this codebase.
- **Deep-link format:** `https://app.clickup.com/{workspace_id}/v/li/{list_id}?pr={view_id}` — opens the list with the named view active.

## Gotchas

- **All tasks go in ClickUp**, never GitHub Issues. The single source of truth is split across two lists:
  - `CLICKUP-AE-LIST-ID` (`<clickup-list-id>`) — Salesforce / VoIP business automations
  - `CLICKUP-INFRA-LIST-ID` (`<clickup-list-id>`) — platform / dev-loop machinery (<internal-bot>, <internal-bot>, orchestrator, MCP, skills, runbooks, KV, CI, publish-kit)
  - Read both IDs from `<credential-vault>` rather than hardcoding.
- **No public Move Task endpoint.** ClickUp v2 and v3 do not expose a programmatic way to move tasks between lists. Probed 10 endpoint variants on 2026-04-25 — all 404 or silently no-op. UI-only via `app.clickup.com/v1/...` internal API (browser session). Plan migrations accordingly: existing tasks stay where they are; only new tasks split per the audience rule.
- **No public endpoint to add options to existing dropdown fields.** Probed 2026-05-03: `POST /api/v2/list/{list_id}/field/{field_id}/option`, `PATCH /api/v2/list/{list_id}/field/{field_id}`, `PUT /api/v2/field/{field_id}`, `PATCH /api/v2/workspace/{workspace_id}/field/{field_id}` all return 404. Use the ClickUp UI to add options to existing dropdowns, OR create the field with all options in the initial `POST /api/v2/list/{list_id}/field` call.
- **Custom fields are workspace-scoped.** Same UUID across both lists; setting a value via `POST /task/{id}/field/{fieldId}` works regardless of which list the task lives on, *but* only if the field has been "shown on list" via the UI. Writes to non-attached fields silently no-op (200 OK with empty body, value dropped). The ClickUp API has no public endpoint to attach a field to a list — must be done via UI.
- **ClickUp node parameter names vary by resource.** `task` resource uses `id` for Task ID. `taskTag` resource uses `taskId`. Always check a working node's JSON before building programmatically.
- **After programmatic node updates:** Verify params stuck by fetching workflow JSON AND confirming in the n8n UI.
- **Fireflies integration** targets Meeting Inbox by list ID. Renaming the list is safe.
- **No native idempotency-key header.** `POST /list/{id}/task` does not accept an `Idempotency-Key` header — `developer.clickup.com/reference/createtask` lists no such option (docs-confirmed 2026-05-04). Identical sequential POSTs create separate tasks every time. Client-side dedup is required for at-least-once webhook scenarios. Canonical pattern: `docs/runbooks/<internal-bot>-request-intake.md` § Dedup behavior (n8n `staticData` + reservation pattern, ClickUp `<clickup-task-id>`).
- **Dropdown field reads return an int orderindex, not the option name.** When `GET /task/{id}` returns a `drop_down` custom field, `value` is the integer `orderindex` of the selected option (e.g. `Executor=local-claude` → `{"value": 1}`). Code that checks `if isinstance(val, str)` silently treats every dropdown selection as unset and falls through to defaults. Resolve via `field.type_config.options[].orderindex → name`. Verified empirically 2026-05-04 — three separate bugs surfaced from this pattern: `_should_route_local` (PR #357), `_task_priority_sort_key` (PR #359), and `local_claude.py:_get_custom_field_value`. Mirror the orderindex-resolution shape any time you read a dropdown field by code.
- **List-tasks excludes subtasks by default.** `GET /list/{id}/task` returns 0 subtasks unless `subtasks=true` is included in the query string — even when the subtask matches the `statuses[]` filter. **Empirical** (2026-05-12, this session): `curl ".../task?statuses[]=queued"` returned 0 while `GET /task/<subtask-id>` confirmed `status=queued`; adding `&subtasks=true` returned the task immediately. Caused a 2-day silent rot of the orchestrator's `local-poller` (memory: `reference_clickup_list_tasks_subtasks_filter.md`; umbrella discovery card: <clickup-task-id>; fix shipped via <clickup-task-id>). Always pass `subtasks=true` when polling for status across both parent and subtask cards.

## Webhooks (taskUpdated, taskCreated, taskCommentPosted, etc.)

ClickUp v2 webhooks are scoped to a team and optionally filtered by list/folder/space.

### Register

```bash
curl -X POST "https://api.clickup.com/api/v2/team/{team_id}/webhook" \
  -H "Authorization: $CLICKUP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "endpoint": "https://your-public-receiver.example.com/webhook",
    "events": ["taskUpdated"],
    "list_id": <clickup-list-id>
  }'
```

Response includes `id`, `webhook`, and **`secret`** (used to sign every delivered event via the `X-Signature` header). The secret is generated by ClickUp; clients cannot pre-set it. **Reconcile against your local secret store after registration.**

### Verify signature

ClickUp's `X-Signature` header is the **bare hex digest** — NO `sha256=` prefix.

```python
import hmac, hashlib
expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
# Compare: hmac.compare_digest(expected, request.headers["X-Signature"])
```

### Update, reactivate or delete

`PUT /api/v2/webhook/{webhook_id}` exists. Use it with `{"status":"active"}` to reactivate a suspended webhook; it keeps the existing secret (docs-confirmed: https://developer.clickup.com/docs/webhookhealth). To change the list/space scope, DELETE + POST a new one (new secret). n8n `clickUpTrigger` webhooks are owned by n8n: deactivating the workflow deletes the webhook and activating it registers a fresh one, so manage those through the workflow, not this API.

```bash
curl -X DELETE "https://api.clickup.com/api/v2/webhook/{webhook_id}" -H "Authorization: $CLICKUP_TOKEN"
```

### Health

GET `/api/v2/team/{team_id}/webhook` lists all team webhooks with `health.status` (`active`, `failing`, `suspended`) and `health.fail_count`. A delivery fails on a non-2xx response or a response slower than 7 s; after 100 failures the webhook is `suspended` and missed events are never replayed. Any n8n `Webhook` node that receives ClickUp events must use `responseMode: onReceived` — `lastNode` answers 500 "No item to return was found" whenever an IF filters the event out, which is how `<internal-bot>-task-close` was suspended on 2026-04-08 (<clickup-task-id>).

### <your-org> IDs

- Team ID: `24555569`
- A&E list ID: `<clickup-list-id>` (<retired-executor> retired 2026-09-28)
- Active <retired-executor>-bridge webhook: see `~/.claude/projects/<claude-project-token>/memory/reference_clickup_<retired-executor>_webhook_id.md` (recorded post-Phase-4)

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `OAUTH_025` error on API calls | Using stale `CLICKUP-API-TOKEN` (`pk_...`). Switch to `CLICKUP-API-KEY` |
| Tag assignment fails | Tag must already exist in the space. Create via REST API (see "Creating New Tags" above) |
| Filter returns 0 tasks but they exist | Check list ID and status filter. A&E + Infra lists share custom statuses (`backlog`, `planning`, `implementation`, `queued`, `in progress`, `qa`, `blocked`, `completed`), not space defaults. URL-encode `statuses[]=` as literal brackets in shell (`statuses\[\]=...`), not `%5B%5D` — the latter returns empty results |
| Custom field write returns 200 but value not stored | Field isn't "shown on list" — toggle the field's visibility on the target list in the UI. No API exists for this. |
| Want to move a task between lists | Not possible via API (probed 10 variants). Recreate-and-archive is the only API path; UI drag is the only "true move." |
| 401 on API calls | `CLICKUP-API-KEY` missing or expired. Re-fetch via `fetch-secrets.sh clickup` |
| `JSONDecodeError: Invalid control character` parsing `POST /task` response | Heredoc passed literal newlines inside a JSON string field (e.g. multi-line `description`). JSON strings can't contain raw `\n` bytes — only escaped `\\n`. Fix: build the payload via `python3 -c 'import json; print(json.dumps({...}))' > /tmp/payload.json` then `curl --data-binary @/tmp/payload.json`. `json.dumps` handles all escape requirements. (Observed <clickup-task-id>, 2026-05-22.) |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-05-05 | Doc described retired cloud dispatch + Maestro sub-local | Cloud orchestrator retired in <clickup-task-id>, Maestro retired in Wave 4.6 | Updated lines 134/148/171 to reflect local-poller-only dispatch |

## Idempotent card creation

For session-side card creation, use `~/.claude/bin/clickup-create-or-find` instead of raw `curl -X POST .../list/<id>/task`.

```bash
NEW_ID=$(~/.claude/bin/clickup-create-or-find <list-id> "<title>" "<body-md>" "tag1,tag2" [--status STATUS] [--parent PARENT_TASK_ID])
```

The helper computes `dedup:<sha-12>` from the normalized title (folded with parent-id when `--parent` is supplied), queries the tag-filter endpoint server-side, and short-circuits when a recent match exists:
- Hit within 2 min → returns existing id silently
- Hit 2min–24h → returns existing id + appends a "re-requested" comment
- No hit → POSTs with `dedup:<hash>` tag prepended for future invocations

**empirical (2026-05-19):** tag-filter is server-side, combinable with `date_created_gt`.

**Exit codes:** 0 success, 2 usage error, 3 auth failure, 4 API failure.

**Source:** `~/.claude/bin/clickup-create-or-find` (<your-username>/<config-repo>)

## Watcher management

ClickUp v2 has one — and only one — working endpoint shape for adding a watcher to a task. The other shapes documented in the wild are either not implemented (404) or silently dropped without a server-side error.

| Operation | Endpoint | Notes |
|---|---|---|
| Add watcher to existing task | `PUT /api/v2/task/{task_id}` body `{"watchers":{"add":[<int_user_id>]}}` | The only working method. User id MUST be the integer ClickUp user id; email addresses are silently dropped. |
| Add watcher at task create-time | n/a | `POST /api/v2/list/{list_id}/task` body `watchers: ["email"]` is silently dropped — the task is created without watchers. Add after create with the PUT above. |
| `POST /api/v2/task/{task_id}/watcher` | n/a | Returns 404 — endpoint does not exist. |

**Verified empirically** (3 endpoint variants probed against a throwaway test task, <clickup-task-id>, 2026-06-06; test task created + deleted during probe).

### Looking up the integer user id from an email

The watcher PUT requires an integer user id. The team listing endpoint exposes both:

```bash
KEY=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show \
  --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv)
curl -sS -H "Authorization: $KEY" "https://api.clickup.com/api/v2/team/24555569" \
  | jq '.team.members[] | select(.user.email == "<service-email>") | .user.id'
# → 87410042
```

Response root is singular `team` (not `teams`). Each member exposes `user.{id, email, username, role, …}`.

### End-to-end example

Add `<service-email>` as a watcher on task `<clickup-task-id>`:

```bash
KEY=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show \
  --vault-name <credential-vault> --name CLICKUP-API-KEY --query value -o tsv)
USER_ID=$(curl -sS -H "Authorization: $KEY" \
  "https://api.clickup.com/api/v2/team/24555569" \
  | jq '.team.members[] | select(.user.email == "<service-email>") | .user.id')
curl -sS -X PUT -H "Authorization: $KEY" -H "Content-Type: application/json" \
  -d "{\"watchers\":{\"add\":[${USER_ID}]}}" \
  "https://api.clickup.com/api/v2/task/<clickup-task-id>"
```

### Removing a watcher

Symmetrical to add: `PUT /api/v2/task/{task_id}` body `{"watchers":{"rem":[<int_user_id>]}}`. (docs-confirmed via the same family of endpoints; not exercised in <clickup-task-id> — note added here for completeness.)

