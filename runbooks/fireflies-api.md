# Fireflies.ai Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-28

## Auth

- **Method:** API key (Bearer token)
- **Vault:** `<credential-vault>`
- **Secret name:** `FIREFLIES-API-KEY`
- **Env var:** `$FIREFLIES_API_KEY` after fetch
- **Fetch creds:** `AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name FIREFLIES-API-KEY --query value -o tsv`
- **MCP server:** N/A

## Common Operations

### Via API (GraphQL)

All requests go to `https://api.fireflies.ai/graphql` as POST with `Authorization: Bearer $KEY`.

```bash
# Get current user info and active integrations
curl -s -X POST "https://api.fireflies.ai/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FIREFLIES_API_KEY" \
  -d '{"query":"{ user { name email integrations } }"}'
```

```bash
# Get recent transcripts with action items
curl -s -X POST "https://api.fireflies.ai/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FIREFLIES_API_KEY" \
  -d '{"query":"{ transcripts(limit: 5) { id title date participants summary { action_items short_summary } } }"}'
```

```bash
# Get single transcript with full detail
curl -s -X POST "https://api.fireflies.ai/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FIREFLIES_API_KEY" \
  -d '{"query":"{ transcript(id: \"TRANSCRIPT_ID\") { title date participants summary { action_items overview notes keywords } } }"}'
```

```bash
# Introspect any type
curl -s -X POST "https://api.fireflies.ai/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FIREFLIES_API_KEY" \
  -d '{"query":"{ __type(name: \"Transcript\") { fields { name type { name kind ofType { name } } } } }"}'
```

## Key Types

| Type | Notable Fields |
|------|---------------|
| `User` | `user_id`, `email`, `name`, `integrations`, `is_admin`, `num_transcripts` |
| `Transcript` | `id`, `title`, `date` (epoch float), `participants` (email array), `summary`, `apps_preview`, `host_email`, `duration` |
| `Summary` | `action_items` (string, markdown with `**Name**` headers), `overview`, `notes`, `keywords`, `short_summary`, `bullet_gist` |
| `AppOutput` | `transcript_id`, `app_id`, `title`, `prompt`, `response` |

## Action Items Format

Fireflies returns `summary.action_items` as a markdown string with person headers:

```
**All Staff**
Task description here (timestamp)

**<your-name>**
Another task here (timestamp)

**Chris**
Task for Chris (timestamp)
```

The ClickUp integration pushes ALL action items as tasks under the authenticated user's account, regardless of the `**Name**` header. Ownership filtering must happen downstream.

## <your-org>-Specific IDs

| Resource | Value |
|----------|-------|
| User email | `<your-email>` |
| Active integrations | `salesforce`, `onedrive`, `clickup`, `notion` |
| ClickUp target list | Meeting Inbox (`<clickup-list-id>`) |

## n8n Workflows

| Workflow | ID | Purpose |
|----------|-----|---------|
| Daily Task List | `FXWCMmKyJoyoNaMt` | Daily 8AM digest of assigned + watched tasks across all ClickUp spaces |

## Salesforce integration — design decisions (<clickup-task-id>, 2026-05-28)

Design rationale captured during the configure-and-deploy planning for the Fireflies-native Salesforce integration. Source documents: `docs/superpowers/specs/2026-05-28-fireflies-sf-integration-design.md` and `docs/superpowers/plans/2026-05-28-fireflies-sf-integration.md`. Empirical findings here ground both files; future redesigns should start by re-reading this section.

### Three-layer defense (no Salesforce metadata change)

| Layer | Mechanism | Where |
|---|---|---|
| L1a | Match-only ON + Create-Leads OFF + Fred-fallback OFF | Fireflies admin → Integrations → Salesforce → workspace toggles |
| L1b | Integration Rule: `Type = External` AND `Title Doesn't Contain [blocklist]` | Fireflies admin → Integrations → Salesforce → Rules |
| L2 | Recording Rules with same title blocklist on admin/exec accounts | Per-user Fireflies → Settings → Recording Rules |

`Type = External` is Fireflies-derived from participant domains — Fireflies marks a meeting Internal when all participants share the company domain, External otherwise. This sidesteps the "138 `@<your-org>` SF Contacts could be matched" leak vector without needing a participant-filter rule.

### Why "Log notes under Fireflies Notetaker (Fred)" is OFF

Fred is a **Salesforce Contact** (`fred@fireflies.ai`, already present in the <your-org> org as "Fireflies AI"), **not a Salesforce User**. The toggle attaches unmatched-meeting Tasks to Fred's Contact as a fallback pool when no real participant matches.

**Doc-confirmed text (when toggle is ON):** *"Fireflies will log the notes under Fred's Contact or Lead (fred@fireflies.ai) if it exists."*

**empirical (2026-05-28):**
- `SELECT Id FROM User WHERE Name LIKE '%Fred%' OR Username LIKE '%fireflies%'` → 0 rows (no SF user)
- `SELECT Id, Email FROM Contact WHERE Email LIKE '%fireflies%'` → 1 row: `fred@fireflies.ai | Fireflies AI`

**Why OFF + match-only ON is the correct pair:** match-only ON drops unmatched meetings entirely, so the Fred fallback never fires. Turning Fred OFF too is belt-and-suspenders against config drift. The practical effect of both: *"unmatched meeting → nothing happens in Salesforce."*

**Anti-pattern to avoid (the misreading that caused a brainstorming detour):** treating the Fred toggle as if it controls the `CreatedById` on synced Tasks — i.e., assuming Fred is the SF user identity that "posts" Tasks when the toggle is ON. It does not. The toggle controls the `WhoId` (Contact attachment target), not the `CreatedById`. The CreatedById is whatever SF user the workspace OAuth was authorized as (verifiable at Phase A of the rollout — see plan).

### Why L3 (SF custom field + Sharing Rule) was dropped

Earlier scope proposed a `From_Fireflies__c` checkbox on Task/Event + a Sharing Rule restricting Fireflies-attributed records to a Sales+CS Public Group. **Dropped during brainstorming review.** Reasoning:

- L1a + L1b prevent sensitive content from reaching Salesforce in the first place. There is nothing left to protect on the SF side.
- The "tail risk" L3 was guarding against (legit external client meetings whose Tasks contain commercially sensitive discussion) is a generic SF Task-visibility problem that exists regardless of Fireflies, and is not Fireflies' job to solve.
- The integration writes to standard Task/Event using the workspace OAuth identity. No custom field is needed to identify Fireflies-sourced records — `CreatedById = <workspace-OAuth-user>` (captured at Phase A), or `Subject LIKE 'Fireflies%'`, or `Description CONTAINS 'fireflies.ai'` — all filterable from any future Sharing Rule without new metadata.

**General lesson (applies to any future CRM-sync integration design):** before adding receive-side defenses (custom fields, Sharing Rules, Apex triggers) to handle content classification, verify the *source-side* configuration can prevent the unwanted content from arriving at all. If it can, receive-side work is scope-creep solving a problem that doesn't materialize.

### Integration Rules — what's actually configurable (Business plan)

<your-org> confirmed on Business plan via `rule_executions_by_meeting` returning 403 `paid_required: enterprise plan` (Enterprise-only feature). Business+ gives:

| Filter type | Operators | Notes |
|---|---|---|
| Meeting Title | Contains / Starts with / Equals / Doesn't Contain | Comma-separated keyword list (Phase A confirms exact UI shape) |
| Meeting Host | Equals / Not Equal | Single email or workspace user |
| Meeting Participants | Contains / Doesn't Contain | Domain-match shape (`@<your-org>` vs `<your-org>` vs full email) unverified — Phase A confirms |
| Meeting Type | Equals (Internal / External) | **Fireflies-derived from participant domains** — primary filter for <your-org>'s case |
| All Meetings | (no filters) | Default option |

Logic: AND / OR across conditions. Multiple rules supported. **Workspace-wide:** admin enables; members inherit settings. **Per-user OAuth status (open):** docs say *"Team members do not need to connect their Salesforce accounts individually"* but don't explicitly confirm whether the integration uses one shared OAuth or per-user. Phase A verifies in the UI; the design works either way (changes only who appears as `CreatedById`).

### Recording Rules vs Integration Rules

| | Integration Rules | Recording Rules |
|---|---|---|
| Plan tier | Business+ | All plans |
| Scope | Workspace-wide (admin sets) | Per-user only (each user sets their own) |
| Effect | Controls which meetings sync to Salesforce | Controls whether Fred joins to record at all |
| Defense layer | L1b | L2 |

Recording Rules are belt-and-suspenders. If Fred never joins, no transcript exists to sync to any integration regardless of Integration Rule state.

### Rules Engine (Enterprise — NOT available)

Mentioned for completeness only. Enterprise-only feature that provides programmatic actions on meetings (routing, visibility scoping, etc.). Probe to confirm absence: `{ rule_executions_by_meeting(limit:3) { meetings { meeting_id } } }` → 403 paid_required. Integration Rules above is a separate, less powerful Business-tier feature with a similar name.

## Gotchas

- **Action items are per-meeting, not per-person.** The ClickUp integration creates tasks for ALL action items under <your-name>'s account. Filter by the `**Name**` headers in the description if per-person routing is needed.
- **`summary.action_items` is a String**, not a structured array. Parse markdown headers to extract assignees.
- **Transcript `date` is an epoch float** (seconds, not milliseconds). Multiply by 1000 for JS `new Date()`.
- **`participants` is a flat email array**, not structured objects.
- **Speaker attribution (`integrations/voip_ingest/fireflies.py` `participants()`).** `speakers` carry names only, so `spoke` is set by a case/whitespace/punctuation-insensitive match of the attendee `displayName` (or, with no displayName, the email local part such as `jane.doe` to `Jane Doe`). A speaker that matches no attendee is unclaimed: it marks nobody `spoke=true` (no fallback for nameless external attendees), and every attendee that matched no speaker is stored with `spoke=null` (unknown) instead of `false`. `getFirefliesSuggestion` treats a non-<your-org> `spoke=null` as unknown and, absent a known external speaker, returns no Held/No show suggestion so the AE decides. When a speaker name matches more than one attendee (for example an internal and an external attendee both named Alex Smith), attribution is ambiguous: every attendee that name matched is stored `spoke=null` (unknown), so Apex gives no suggestion from them; unambiguous matches stay `spoke=true`. When all speakers are claimed, or there are no speakers, unmatched attendees stay `spoke=false`.
- **Integration settings are in the Fireflies web UI** (`app.fireflies.ai → Integrations → ClickUp`), not exposed via the API. The API cannot configure which tasks get pushed.
- **Rate limits:** Not documented, but API responds quickly. Use retry logic on HTTP 429.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `action_items` field not found on Transcript | Use `summary { action_items }` — it's nested under Summary type |
| Empty action items | Some meetings have no extractable action items; check `summary.overview` as fallback |
| GraphQL validation error | Introspect the type first: `__type(name: "TypeName") { fields { name } }` |

## Resolved Issues

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-13 | All Meeting Inbox tasks showed in digest regardless of assignee | Fireflies ClickUp integration creates all tasks under <your-name>'s account | Added `for_owner` field to AI classifier; restructured workflow to use team-wide ClickUp API with assignee/watcher filtering |
