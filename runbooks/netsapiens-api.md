# NetSapiens API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-10-05

## Auth

- **Method:** Bearer token
- **Vault:** `<credential-vault>`
- **Secret name:** `NETSAPIENS-API-TOKEN`, `NETSAPIENS-API-URL`
- **Env var:** `$NETSAPIENS_API_TOKEN`, `$NETSAPIENS_API_URL`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh <voip-mcp>)"`
- **Base URL:** `https://<your-netsapiens-host>`

## Common Operations

### Via API / CLI

#### Global phone number lookup (v1 API — cross-domain)

```bash
curl -X POST "https://<your-netsapiens-host>/ns-api/?object=phonenumber&action=read" \
  -H "Authorization: Bearer $NETSAPIENS_API_TOKEN" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "format=json&dialplan=DID+Table&matchrule=sip:13059676756@*"
```

**Parameters:**
- `dialplan` — `DID Table` (contains all <DID-table-size> numbers)
- `matchrule` — Exact: `sip:1NPANXXXXXX@*`
- `matchrule_LIKE` — Partial: `%305%` (uses `%` wildcards, NOT `*`)
- `dest_domain` — Optional domain filter

**Response fields:** `matchrule`, `to_host` (destination domain), `to_user`, `plan_description`, `enable`

#### Call Detail Records (CDR) — v2 API

```bash
VOIP_V2_KEY=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name <VOIP-BRAND>-V2-API-KEY --query value -o tsv)
curl "https://<your-netsapiens-host>/ns-api/v2/domains/<your-sip-domain>/cdrs?limit=50&datetime-start=2026-04-01T00:00:00&datetime-end=2026-04-30T23:59:59" \
  -H "Authorization: Bearer $VOIP_V2_KEY"
```

The v2 endpoints use the `<VOIP-BRAND>-V2-API-KEY` secret (`<credential-vault>`, read via the OCC Orchestrator SP in `<azure-config-dir>`), not `NETSAPIENS-API-TOKEN`. The ingest (`integrations/voip_ingest/run.py`) reads the same secret and refuses one containing whitespace or control characters.

**Endpoint:** `GET /ns-api/v2/domains/<domain>/cdrs` (full row shape, honors the time window; `GET /ns-api/v2/cdrs` is `contradicts-docs:` unusable, see the probe note below; NOT the v1 `?object=cdr&action=read` POST form — v1 returns 200 with empty body for CDR lookups; v2 is the working path).

**Query parameters:**
- `<domain>` — path segment, <your-org> = `<your-sip-domain>`
- `datetime-start` / `datetime-end` — `YYYY-MM-DDTHH:MM:SS`, UTC (empirical 2026-10-05: all rows within the window)
- `limit` + `start` (offset) — pagination; a page shorter than `limit` is the last
- `contradicts-docs:` (empirical 2026-10-05) `/cdrs?domain=&user=&start_time=&end_time=` ignores the time window (942 rows from 2026-08-05..2026-10-01 for a one-day window) and returns a reduced row shape (`uid`, `number`, `call-orig-to-uri`, no `call-orig-user`/`call-term-user`/`call-direction`). `/domains/<d>/users/<ext>/cdrs` honors the window but is also reduced-shape. Filter by extension client-side

**Response:** JSON array of CDR objects. Field naming is **kebab-case** (`call-orig-user`, `call-term-user`, `call-disposition`, `call-orig-from-name`, `call-disconnect-reason-text`, `call-direction` — see the direction note below; the earlier 1=inbound 2=outbound mapping was wrong).

**Key fields for skill consumption:**
- `id` — opaque CDR ID (40-char hex)
- `domain` — `<your-sip-domain>`
- `call-orig-user` / `call-term-user` — internal extension on either leg (null if external↔external relay)
- `call-orig-from-user` / `call-orig-to-user` — DID (E.164 11-digit int) of caller / callee
- `call-orig-from-name` — caller display name
- `call-answer-datetime` / `call-disconnect-datetime` — UTC ISO with `+00:00`
- `call-talking-duration-seconds` — talk (connected) duration; the ingest writes this to `Task.CallDurationInSeconds`
- `call-batch-total-duration-seconds` / `call-total-duration-seconds` — total call duration including ring time, not talk time
- `call-direction` — `contradicts-docs:` the earlier "1=inbound, 2=outbound" is wrong. empirical (2026-10-05, 200 rows for one AE extension): 0 (144 rows) = orig-user is the extension = Outbound; 1 (37) and 2 (19) = term-user is the extension = Inbound. Derive direction from which leg carries the extension, not from the code alone.
- `call-disposition-reason` — SIP code (200 OK, 302 redirect, 486 busy, etc.)
- `call-disconnect-reason-text` — `"Orig: Bye"`, `"Cancel"`, etc.

**Pagination:** `limit` + offset; large windows benefit from page loops. Empty `[]` is a valid response (no calls in window — verify against UI before assuming bug).

## Audit log, CDR history & data recovery (empirical 2026-07-14)

Learned recovering DIDs for a **deleted reseller** — Knosys Holdings, territory `05577.service` (reseller == territory in NS; interchangeable). ~19 sub-domains (`*.05577.service`) were deleted; the reseller shell stayed `active` but empty (`domains:0, users:0`). Scripts + outputs: `~/Projects/knosys-recovery/`.

### There is NO usable audit-log API on this platform
- v1 `object=audit` → **404** (no route). `object=auditlog` → the object routes, but **`action=read` returns HTTP 500 "An Internal Error Has Occurred." for every parameter combination tried** (`domain`, `start_date`/`end_date`, `datefrom`/`dateto`, `start`/`end`, `uid`, `user`, `category`, `server`, `raw=yes`, `format=json|xml|csv`, GET + POST). `action=count` → 400. Misspellings (`audit_log`, `AuditLog`) → 404.
- v2 has no audit route: `/ns-api/v2/audit-log`, `/audit-logs`, `/auditlog`, `/domains/{d}/audit-logs` all → 404 `No Route Found [92]`.
- **Conclusion:** not retrievable via API. To get it: escalate to the NetSapiens platform team (enable/fix the `auditlog` object, or DB pull), or use the manager-portal Audit Log UI via browser.

### Deleting a domain wipes its DID→domain mapping from the live DID table
- `object=phonenumber&action=read` `dialplan=DID Table` returns the **global** routing table (34,321 rows; row `domain='admin-only'`; DID is in `match_from`/`matchrule` as `sip:1NPANXXXXXX@*`; `to_host` = destination domain). `dest_domain=<domain>` filters by `to_host` on **read** only — `action=count` ignores filters (always returns the full 34,321).
- When a domain is deleted its numbers are released: `to_host` / `domain_owner` / `dialrule_domain` cleared. Grepping the whole table for the reseller returned **zero** live mappings. **Cannot reconstruct a deleted domain's DIDs from live inventory.**
- `reseller=` / `territory=` are NOT valid `phonenumber` filters — silently ignored, return the global table.

### CDR history SURVIVES domain deletion — the real recovery source
- Use `object=cdr2&action=read` (NOT v1 `object=cdr`, which is empty). Returns history for **deleted** domains. Filter by `domain=` OR `territory=<NNNNN.service>` (territory scan covers every sub-domain in one query and auto-discovers domains/misspellings).
- **`limit` caps at 5000 and `offset` is IGNORED.** Page by **date windows** — recurse and split whenever `action=count` > ~4500 (≈1h floor).
- **`raw=yes` does NOT flatten** — the full field set is always nested under `CdrR`. Read from `rec["CdrR"]`: `orig_domain`, `term_domain`, `by_domain`, `orig_from_user`, `orig_to_user`, `orig_req_user`, `by_id`, `orig_id`, `term_id`, `orig_from_name`, `orig_sub`/`term_sub`/`by_sub`, `time_start` (epoch), `time_insert`, `by_action`, `term_to_uri`.
- Retention ≈ **12 months** (nothing before ~Aug 2025). CDR reconstruction is **usage-based** — misses idle DIDs.
- A domain's OWN DIDs (high confidence): number it **presents** — `orig_from_user` where `orig_domain==dom`, `by_id` where `by_domain==dom` — plus inbound-dialed `orig_req_user` where `term_domain==dom`, ranked by recurrence. **Exclude** far-end parties and find-me/follow-me forward legs (they inflate with external numbers).

### Salesforce is the authoritative DID-lifecycle record
- CDRs miss idle/ordered DIDs. <your-org> telco/porting **Cases** are the real add/delete/port audit. Porting is a Case **RecordType** (`Porting`); telco spans Case **Type** values (`DID(s)`, `LNP (Local Number)`, `RESPORG (Toll Free)`, `CNAM`, `E911`, `MACD`, `Phone`). DIDs + domain often live in **Subject/Description**, not fields (`Case.Domain__c` was empty across the sample).

### Routing / user config is NOT recoverable via API after deletion
- Dial plans, answer rules, call queues, auto-attendants, time frames, VM PINs, device configs die with the domain and aren't in CDRs. Extensions can only be **inferred** from `*_sub` call legs. A true rebuild needs a NetSapiens-side backup/export.

## Gotchas

- **v2 API is domain-scoped.** `get_phone_numbers` requires knowing the domain first. For cross-domain lookups, use the v1 API above.
- **Phone format:** Raw digits won't match. Must use `sip:1NPANXXXXXX@*` format.
- **`get_domains` returns DID holding domains** (e.g., `0000.something`), not client domains like `<your-sip-domain>`.
- **`matchrule_LIKE` uses `%` wildcards**, not `*`.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Phone number lookup returns empty | Check format: must be `sip:1NPANXXXXXX@*`, not raw digits |
| v2 domain list returns `0000.*` domains only | v2 API returns DID holding domains, not client domains. Use v1 API for cross-domain lookups |
| `matchrule_LIKE` returns no results | Uses `%` wildcards, not `*`. Example: `%305%` not `*305*` |
| User search finds nothing | Requires a domain parameter. Use v1 domain list first or use v1 API |
| 401 on v1 API calls | Token expired or wrong. Re-fetch via `fetch-secrets.sh <voip-mcp>` |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-07-14 | Needed per-domain DID history for a deleted reseller (Knosys / `05577.service`) | NS exposes no working audit-log API (`object=auditlog` read 500s; `object=audit`/v2 routes 404); domain deletion clears DID-table mappings | Reconstruct from `cdr2` history by `territory=` (survives deletion, page by date windows, read `CdrR` nested fields); cross-reference Salesforce porting Cases for idle/ordered DIDs. See "Audit log, CDR history & data recovery". |

## API Docs

- JSON collection: `https://<your-netsapiens-host>/ns-api/webroot/apidoc/api_doc_collection.json`
- Web UI: `https://<your-netsapiens-host>/ns-api/webroot/apidoc/`

## API v2 (<VOIP-BRAND>-V2-API-KEY)

Used by the AE call ingest (`integrations/voip_ingest/`, see `docs/runbooks/ae-integrations.md`). The v1 `NETSAPIENS-API-TOKEN` is not used by it.

- **Base:** `https://<your-netsapiens-host>/ns-api/v2`; header `Authorization: Bearer <key>`.
- **Key:** `<VOIP-BRAND>-V2-API-KEY` in `<credential-vault>`, read via `AZURE_CONFIG_DIR=<azure-config-dir>` (OCC Orchestrator SP, the ingest's runtime identity; readable, so no copy to `<credential-vault>`). Rotation waived by <your-name> 2026-10-04 (accepted risk, owner <your-name>).

```bash
K=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name <VOIP-BRAND>-V2-API-KEY --query value -o tsv)
```

**Probe: CDR list and transcriptions missing-id** (`curl -H "Authorization: Bearer $K" "$B/cdrs?domain=<your-sip-domain>&start_time=2026-10-01T00:00:00&end_time=2026-10-05T00:00:00&limit=1"`; `curl .../domains/<your-sip-domain>/transcriptions`)

Captured: 2026-10-05T02:46:03Z

```
cdrs HTTP 200
list 1
keys 99
{"code":400,"message":"Bad request. Missing data 'id'."}
transcriptions(no id) HTTP 400
```

Endpoints (empirical 2026-10-05 unless noted):

1. `GET /domains/<d>/cdrs?datetime-start=YYYY-MM-DDTHH:MM:SS&datetime-end=...&limit=N&start=<offset>` returns 200, full-shape list inside the window (171 rows for 2026-10-01 UTC, 70 for ext 1045). `contradicts-docs:` `GET /cdrs?domain=..&user=<ext>&start_time=..&end_time=..` (the 99-key probe above) ignores the window and returns the reduced shape; do not use it.
2. List rows: `call-parent-cdr-id` is unique per call (200/200 unique in sample). `call-orig-call-id` / `call-term-call-id` are null in list rows (empirical 2026-10-05: 0/200 set). `GET /domains/<d>/cdrs/<call-parent-cdr-id>` returns full rows **with** those ids, but `contradicts-docs:` it **ignores the path id**: it returns up to 100 recent rows for the domain (or the rows inside `datetime-start`/`datetime-end` when given), so the first row is usually another call. Always pass a narrow window around the call's `call-start-datetime` and keep only the row whose `call-parent-cdr-id` equals the requested id (`nsapi.NetSapiens.cdr_rows`).

**Probe: `/cdrs/<id>` ignores the id** (`curl -H "Authorization: Bearer $K" "$B/cdrs/<id>"`, then with `?datetime-start=2026-09-29T14:00:00&datetime-end=2026-09-29T16:00:00`, filtering rows by `call-parent-cdr-id`)

Captured: 2026-10-05T12:53:44Z

```
cdrs/17906961295a88274b4f610e6a5fc86b7de4c5cf71              100 rows, matches 0, first-is-it False
cdrs/17906961295a88274b4f610e6a5fc86b7de4c5cf71?limit=1        1 row,  matches 0, first-is-it False
cdrs/<id>?datetime-start=..14:00..&datetime-end=..16:00..     30 rows, matches 1 (dir 0, orig/term call ids set), first-is-it False
recent id 1791056894d03ef7e6a2b463307c5b6ff5374c20e2: 100 rows, 100 distinct parent ids, requested present True, first row a different call
```
3. Direction (observed): see the `call-direction` note above. External number for outbound = `call-orig-to-user`.
4. Call intelligence on list rows: `call-intelligence-job-id`, `call-intelligence-percent-positive|neutral|negative`, `call-intelligence-topics-top` (comma string); 114/200 sampled rows had a job id. Some rows carry `prefilled-transcription-api`.
5. `GET /domains/<d>/transcriptions` requires `id` (intelligence job id), `date` (YYYYMM), `orig_callid`, `term_callid`. Missing id: 400 "Missing data 'id'". Missing date: 400 "Missing data 'date'". Empty callids: 403 "Invalid domain or callids". With callids: 200 dict with `call-intelligence-processing-status`, `-summary`, `-summary-status`, `-features-enabled` (transcription,sentiment,summary,topics), `-topics-top` (list), `-topics-all`, `-percent-*`, `-segments[]` {speaker, comment, sentiment, start-time, end-time}, and `call-id`.
6. `GET /domains/<d>/recordings/<callid>` with the call's correct orig/term call id returns 200 with a **signed** download link (`time=` and `auth=` query values regenerated on every request, so never store it); an unrecorded call returns 404 "The requested resource could not be found.". `GET /domains/<d>/users/<ext>/recordings`: 404 No Route Found. History: the 40/40 404s recorded on 2026-10-05 for PR #1414 used call ids from the first row of the unfiltered `/cdrs/<id>` response (endpoint 2), i.e. another call's ids. Also `contradicts-docs:` adding `limit` to `/cdrs/<id>` returns a reduced 28-29 key row **without** `call-orig-call-id` / `call-term-call-id` (with the ±2 min window and no `limit`: 100 keys, ids present).

**Probe: recordings with correct call ids** (`nsapi.cdr_detail(call_id, start)` then `GET /recordings/<orig|term>` over answered outbound calls, last 14 days)

Captured: 2026-10-05T13:13:30Z

```
1352 CDR rows / 936 outbound / 744 with talk time; sample 30 answered outbound
detail found 30/30, orig+term ids 30/30, recording found 28/30, transcription job id 27/30
earlier (13:02:21Z, 70 calls, limit dropped): recording HTTP {200: 70, 404: 1}, transcription status {finished: 70}
with limit=200 (13:01:29Z, same 70 calls): orig/term ids 0/70, no recording requests possible
```
7. `GET /domains/<d>/transcriptions/<id>`: 404 No Route Found.
