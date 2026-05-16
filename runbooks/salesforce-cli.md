# Salesforce CLI Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-16

## Sourcing discipline

Every claim in this runbook about SF behavior — API capability, limit, recalc cadence, schema rule, deploy quirk — must cite one of:

- **docs-confirmed:** `help.salesforce.com`, `developer.salesforce.com`, `architect.salesforce.com`, or `trailblazer.salesforce.com/issues_view` (Known Issues). Link the URL.
- **empirical (YYYY-MM-DD):** verified against a live org. Note org + date + command.
- **contradicts-docs / pending / deploy-verified:** per `.claude/rules/runbook-citation.md`.

**Do not repeat community lore (Trailblazer Community threads, partner blogs, Salesforce Stack Exchange) as fact.** SF documentation IS authoritative — but only what SF actually publishes counts as `docs-confirmed`. If a number or behavior shows up in third-party sources and you can't find SF's own page on it, source-label as **community** or **empirical** (after probing), not docs-confirmed.

**Real precedent (2026-05-14, this runbook):** the "DataStorageMB recalculates every ~24h" figure had been cited across multiple plans and audit docs as fact. SF's actual docs say only "asynchronous" — no cadence. The 24h figure traces to Trailblazer Community + partner blogs, never first-party docs. Five days of plans were built on unsourced lore before the discrepancy was caught. See "Storage recalc timing (asynchronous)" below for the corrected entry shape.

## Auth

- **Method:** Browser-based OAuth (`sf org login web`)
- **Vault:** N/A — `sf` CLI manages its own token refresh
- **Secret name:** N/A
- **Env var:** N/A
- **Fetch creds:** N/A — authenticate via: `sf org login web --set-default --alias <your-email>`
- **MCP server:** N/A — use `sf` CLI directly
- **CLI binary:** `/opt/homebrew/bin/sf`
- **Default org:** `<your-email>` (Production)
- **API version:** 66.0
- **Re-auth:** `sf org login web --set-default --alias <your-email>`

## Common Operations

### Via API / CLI

#### Validate in qa first

For any deploy that mutates schema, Apex, or metadata-that-activates-flows, run it against `qa` BEFORE prod validate:

```bash
cd salesforce && sf project deploy start --target-org qa --source-dir <path> \
  --test-level RunSpecifiedTests --tests EmailAddressNormalizer_Test
```

**Required for:**

- New or modified Apex classes / triggers (deploy compile + test results may differ between orgs if dependent metadata drifted)
- Destructive deploys (`/retire-field` Phase 0 — see `docs/runbooks/salesforce-field-retirement.md` Phase 0)
- Metadata changes that activate flows (a Draft flow deploys clean against validate but only fails at activation time)

**Not required for:**

- Declarative changes (page layouts, permission set assignments, list views) — visually tested in qa already or trivially reversible in prod
- Read-only Tooling queries

**qa target-org alias:** `qa` (username `<your-email>.qa`). Wired via `sf` CLI; no extra auth.

**Refresh-interval lock implication:** the lock blocks `SandboxInfo` PATCH but NOT `sf project deploy` against the sandbox. See `docs/runbooks/sandbox-refresh-playbook.md` "Refresh-interval lock (Partial 5d / Full 29d)" for the canonical empirical reference.

**Test-level rationale:** `EmailAddressNormalizer_Test` is the documented sentinel (see "Recommended pattern for flow-only / metadata-only deploys in prod" below). `RunLocalTests` hits the known-broken `LeadReplenishmentServiceTest` (ClickUp <clickup-task-id>). **(empirical (2026-05-13): sentinel pattern works identically against qa and prod orgs.)**

#### Deploy & Validate

```bash
# Validate (dry run — no changes applied)
sf project deploy validate --source-dir force-app --target-org <your-email> --test-level RunLocalTests

# Deploy
sf project deploy start --source-dir force-app --target-org <your-email> --test-level RunLocalTests

# Quick-deploy a previously-validated job (no re-test, no metadata re-upload)
sf project deploy quick --job-id <validation-job-id> --target-org <your-email>

# Destructive deploy (remove metadata)
sf project deploy start --manifest deploy-package.xml \
  --post-destructive-changes destructiveChangesPost.xml \
  --target-org <your-email>

# Check deploy status
sf project deploy report
```

**`--test-level` valid values:** `RunAllTestsInOrg`, `RunLocalTests`, `RunSpecifiedTests`, `RunRelevantTests`. The Metadata API `deploy()` `testLevel` enum accepts `NoTestRun`, but **production orgs reject it at the API level** with `INVALID_OPERATION: testLevel of NoTestRun cannot be used in production organizations`. **(empirical (2026-05-09): `--test-level NoTestRun` rejected by `<sf-org-id>`.)**

**Recommended pattern for flow-only / metadata-only deploys in prod:**

```bash
sf project deploy start \
  --source-dir force-app/main/default/flows/<file>.flow-meta.xml \
  --target-org <your-email> \
  --test-level RunSpecifiedTests --tests EmailAddressNormalizer_Test
```

`EmailAddressNormalizer_Test` is the documented sentinel — 16/16 pass, ~324ms, pure Apex with no DML, stable across recent deploys. Satisfies the prod test-execution gate without triggering the broken `LeadReplenishmentServiceTest` (MIXED_DML_OPERATION at `setupTestData` line 49 — see ClickUp <clickup-task-id> to fix). Verify the sentinel still passes before relying on it: `sf apex run test -n EmailAddressNormalizer_Test -o <your-email> --result-format human --synchronous`.

**`RunRelevantTests` against flow-only changes runs 0 tests** — and a Job ID from a zero-test validate is **ineligible for quick-deploy** (`INVALID_ID_FIELD: Source validate did not run tests in the org`). Use `RunSpecifiedTests` for both validate and deploy when you want the validate→quick-deploy split.

**Quick-deploy after validate:** validate returns a `Job Id` (`0AfU...`). Use it for `sf project deploy quick --job-id <id>` to deploy without re-running tests or re-uploading metadata. Saves ~80s on repeat deploys of the same change. Two failure modes:
- `INVALID_ID_FIELD: There have been deploys in the org since the source validate happened` — other prod deploys invalidated the Job ID. Re-validate.
- `INVALID_ID_FIELD: Source validate did not run tests in the org` — validate used `RunRelevantTests` against changes with no Apex relevance. Re-validate with `RunSpecifiedTests`.

#### UNKNOWN_EXCEPTION at bundle-prep on whole-dir CustomMetadata deploys

`sf project deploy validate --source-dir force-app/main/default/customMetadata` can fail at the server-side "Preparing" stage with `UNKNOWN_EXCEPTION: An unexpected error occurred. Please include this ErrorId if you contact support: <id>`. The ErrorId names no record. The failure is **pre-compile, pre-test** — Salesforce cannot construct the deploy bundle.

**empirical (2026-05-16):** observed on qa+prod with all 94 records in `force-app/main/default/customMetadata/`. Bisected to 5 `Email_CC_Skip_Rule` records (Bounces, Mailer_Daemon, NoReply, NoReply_Hyphen, Postmaster) whose `Notes__c` `<value>` block was written as `<value xsi:type="xsd:null"/>` — an invalid XSD type. The canonical XSD form for a nil value is `<value xsi:nil="true"/>`. ErrorIds captured during bisect: `182968283-40163`, `1463500985-318381`, `607269782-273066`, `1463500985-318401`, `2138595426-46482` (qa). Patched at PR #<TBD>. Introduced in PR #394 (CC-preservation foundation) at commit `2bb8854`.

**`sf` CLI flag gotcha:** `sf project deploy validate` v2.132.14 does NOT accept `--test-level NoTestRun` — only `RunAllTestsInOrg | RunLocalTests | RunSpecifiedTests | RunRelevantTests`. Default is `RunLocalTests`. For fast-fail bisect rounds use `sf project deploy start --dry-run --test-level NoTestRun` instead — same server-side bundle-prep code path, no actual deploy, tests skipped.

**How to bisect:**

```bash
cd salesforce
mkdir -p .bisect-quarantine
# Per round — halve the files, probe, restore.
# Move-out half (substitute the glob for the current candidate set):
for f in force-app/main/default/customMetadata/<half-pattern>; do
  git mv "$f" ".bisect-quarantine/$(basename "$f")"
done

# Probe (fast-fail bundle-prep path):
sf project deploy start --dry-run -o qa \
  --source-dir force-app/main/default/customMetadata \
  --test-level NoTestRun --json \
  | python3 -c "
import sys, json
raw = sys.stdin.read(); i = raw.find('{'); d = json.loads(raw[i:])
r = d.get('result', {}) or {}
err = r.get('errorStatusCode')
print('PASS' if not err and d.get('status') == 0 else 'FAIL', '-', (r.get('errorMessage','') or '')[:120])
"

# Restore for the next round:
for f in .bisect-quarantine/*.md-meta.xml; do
  git mv "$f" "force-app/main/default/customMetadata/$(basename "$f")"
done
```

A round that PASSes means the offender is in the moved-out half. A round that FAILs means the offender is in the remaining half. Multiple offenders are naturally handled: find one, fix locally, re-bisect from the new baseline. **empirical (2026-05-16):** 94 records, 8 effective rounds, 1 hypothesis-verify probe.

**How to diagnose once converged:**

1. Read the offender's XML. Scan for invalid XSD types — `xsi:type="xsd:null"` is the known smoking gun; valid forms are `xsi:type="xsd:string"`, `xsi:type="xsd:boolean"`, `xsi:type="xsd:int"`, etc., and `xsi:nil="true"` for a nil value (no `xsi:type` needed).
2. Retrieve a fresh copy from prod by wildcard (the targeted-record retrieve may return empty `files: []` despite the record existing — `CustomMetadata:<Type>.*` works reliably):
   ```
   sf project retrieve start --metadata "CustomMetadata:<Type>.*" \
     -o <your-email> --target-metadata-dir /tmp/cmt-retrieve
   unzip -o /tmp/cmt-retrieve/unpackaged.zip -d /tmp/cmt-retrieve/
   diff -u force-app/main/default/customMetadata/<Type>.<Record>.md-meta.xml \
           /tmp/cmt-retrieve/unpackaged/customMetadata/<Type>.<Record>.md
   ```
3. Pick the remedy:
   - **Local stale, prod clean (e.g. invalid `xsi:type`)** → text-replace in the local file or overwrite from `/tmp/cmt-retrieve`.
   - **Local has stale field reference, prod also stale** → destructive-deploy delete after `grep`'ing all Apex/Flow/LWC/Aura consumers for `<Type>.<Record>`, `<Record>`, and the record's `<label>`.
   - **Both clean but bundle still drifts** → escalate, file a SF support case with the captured ErrorId.
4. Re-validate qa with the full sentinel command, then prod (validate-only):
   ```
   sf project deploy validate -o qa --source-dir force-app/main/default/customMetadata \
     --test-level RunSpecifiedTests --tests EmailAddressNormalizer_Test
   sf project deploy validate -o <your-email> --source-dir force-app/main/default/customMetadata \
     --test-level RunSpecifiedTests --tests EmailAddressNormalizer_Test
   ```

#### Retrieve

```bash
sf project retrieve start --source-dir force-app --target-org <your-email>
sf project retrieve start --metadata ApexClass:MyClass --target-org <your-email>
```

#### SOQL Queries

```bash
sf data query --query "SELECT Id, Name FROM Account LIMIT 5" --target-org <your-email>
sf data query --query "..." --target-org <your-email> --result-format csv
```

#### REST API Requests (record create/update with custom headers)

Use `sf api request rest` when you need custom headers (e.g. duplicate rule bypass):

```bash
# Create a record (URL is POSITIONAL — not a --url flag)
sf api request rest /services/data/v66.0/sobjects/Lead \
  --method POST \
  --body '{"FirstName":"Jane","LastName":"Doe","Company":"Acme","Email":"jane@acme.com"}' \
  --header 'Sforce-Duplicate-Rule-Header: allowSave=true' \
  --target-org <your-email>

# Update a record
sf api request rest /services/data/v66.0/sobjects/Lead/<Id> \
  --method PATCH \
  --body '{"Phone":"555-1234"}' \
  --target-org <your-email>

# Body from stdin (avoids shell-quoting hell for nested JSON)
printf '{"FirstName":"%s","LastName":"%s","Company":"%s"}' "$first" "$last" "$company" \
  | sf api request rest /services/data/v66.0/sobjects/Lead --method POST --body - --target-org <your-email>

# Body from file
sf api request rest /services/data/v66.0/sobjects/Lead --method POST --body @payload.json --target-org <your-email>
```

**Flag pitfall (sf CLI 2.130.x):** the URL is **positional**, not `--url <path>`. The flag form is rejected with `Error: Nonexistent flag: --url`. **(empirical (2026-05-08): four invocations across one session — `--url` consistently rejected; positional form succeeded.)** The flag set is `[URL] [-X|--method] [-H|--header] [-b|--body file|-|@file] [-o|--target-org]`.

**Notes:**
- `sf record create` does NOT support custom headers — use `sf api request rest` instead
- Strip ANSI codes from output before JSON parsing: `re.sub(r'\x1b\[[0-9;]*m', '', output)`
- SOQL cannot filter on `Task.Description` — query all tasks, filter in code
- `PATCH /sobjects/<Type>/<Id>` and `DELETE /sobjects/<Type>/<Id>` return HTTP 204 No Content (empty body) on success — Python wrappers that always parse stdout as JSON will fail. Special-case `method in ("PATCH", "DELETE") and exit==0 and not stdout.strip()` → return empty dict.
- `sf api request rest --method DELETE` (current sf CLI 2.130.x) rejects with "add 'mode':'raw' | 'formdata' to your body" even when no body is needed. Fallback: anonymous Apex `Database.delete([SELECT Id FROM <Type> WHERE Id='...'])`.

#### Recycle Bin recovery (queryAll + Database.undelete)

Records are recoverable for 15 days after soft-delete. Standard `sf data query` only sees live records — use `queryAll` to inspect deleted/archived state, then anonymous Apex to undelete.

```bash
# Inspect deleted record (and its IsDeleted flag) via queryAll endpoint
sf api request rest \
  "/services/data/v66.0/queryAll/?q=SELECT+Id,Name,IsDeleted+FROM+Account+WHERE+Id='<sf-record-id>'" \
  --target-org <your-email>

# Inspect cascade-deleted children (FeedItems, ContentDocumentLinks, FeedAttachments)
sf api request rest \
  "/services/data/v66.0/queryAll/?q=SELECT+Id,IsDeleted+FROM+FeedItem+WHERE+ParentId='<sf-record-id>'" \
  --target-org <your-email>
```

Undelete via anonymous Apex (parent + cascade):

```apex
// undelete_account.apex
List<Account> a = [SELECT Id FROM Account WHERE Id='<sf-record-id>' ALL ROWS];
if (!a.isEmpty() && a[0].IsDeleted) {
    Database.UndeleteResult ur = Database.undelete(a[0].Id, false);
    System.debug('Account undeleted: ' + ur.isSuccess());
}
// Cascade-restore children that didn't come back automatically
undelete [SELECT Id FROM FeedItem WHERE ParentId='<sf-record-id>' ALL ROWS];
undelete [SELECT Id FROM ContentDocumentLink WHERE LinkedEntityId='<sf-record-id>' ALL ROWS];
```

```bash
sf apex run --target-org <your-email> --file undelete_account.apex
```

**Caveats:**
- 15-day Recycle Bin window — after that, `queryAll` returns nothing.
- Hard-deleted Contacts/Leads do not surface in `queryAll`. Lost.
- `EmailMessage.RelatedToId` does **not** accept Lead — when re-parenting emails to a Lead, insert `EmailMessageRelation { EmailMessageId, RelationId, RelationType }` instead. The Lead surfaces the email under Activity History via this relation; `RelatedToId` must stay on an Account-tier object.
- `EmailMessage.RelatedToId` accepts `null` — useful when the canonical Account parent must be deleted but the email should stay surfaced via `EmailMessageRelation` on a non-Account record (e.g., Lead). Empirically verified in v66.
- Some EmailMessages platform-lock `RelatedToId` against edits regardless of profile permissions — observed on `Status=3` (Replied) and `IsClientManaged=true` records. Both REST PATCH and anonymous Apex `Database.update` return `INSUFFICIENT_ACCESS_OR_READONLY: You cannot edit this field`. There is no documented bypass; the `EmailMessageRelation` row on the destination continues to surface the email regardless.
- Apex DML in admin context bypasses **some** REST-layer field locks (verified: `IsClientManaged=true` is editable via Apex but not REST). When REST returns `INSUFFICIENT_ACCESS_OR_READONLY`, the next ladder rung is anonymous Apex; only escalate to "platform-locked" after both fail.
- `FeedItem.ParentId` is `updateable=false`. To "move" a Chatter post to a different parent, copy as a new FeedItem on the destination and re-create any `ContentDocumentLink` rows for ContentPost attachments (see "Files" below for the CV→CD resolution step).
- `Note.ParentId` and `Attachment.ParentId` reject Lead. For Lead destinations, append note bodies to `Lead.Description` or skip with a logged warning.

Reference implementations: `scripts/lead-dedup/recover_geoff.py`, `scripts/lead-dedup/undelete_geoff_account.apex`.

#### Files: ContentVersion vs ContentDocument prefixes

Salesforce's file model has three ID types you'll encounter:

| Prefix | Object | Role |
|--------|--------|------|
| `068...` | ContentVersion | Specific version of a file (one per upload) |
| `069...` | ContentDocument | The file itself (many versions can hang off it) |
| `06A...` | ContentDocumentLink | Link between a record and a ContentDocument |

**The trap:** `FeedAttachment.RecordId` for a `Type='Content'` row is the `ContentVersion` ID (`068...`), NOT the `ContentDocument` ID. Inserting a `ContentDocumentLink` with a `068...` value fails:

```
FIELD_INTEGRITY_EXCEPTION: Content Document ID: id value of incorrect type: 068U100000fMzRwIAK
```

Resolve via SOQL before inserting CDLs:

```bash
sf api request rest \
  "/services/data/v66.0/query/?q=SELECT+Id,ContentDocumentId+FROM+ContentVersion+WHERE+Id+IN+('068...','068...')" \
  --target-org <your-email>
```

Then insert `ContentDocumentLink` with the resolved `ContentDocumentId` (`069...`):

```bash
sf api request rest "/services/data/v66.0/sobjects/ContentDocumentLink" \
  --method POST --target-org <your-email> \
  --body '{"LinkedEntityId":"00Q...","ContentDocumentId":"069...","ShareType":"V","Visibility":"AllUsers"}'
```

#### Describe Metadata

```bash
sf sobject describe --sobject Case --target-org <your-email>
sf org list metadata-types --target-org <your-email>
```

### Via MCP

N/A — Salesforce is accessed via `sf` CLI. No MCP server (do not use claude.ai/Zapier MCP for SF).

## Flow Test Framework

Salesforce Flow Test framework deploys `*.flowtest-meta.xml` alongside flows. Tests assert against in-flow state at named test points. Reference: https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_flowtest.htm (docs-confirmed).

### Anatomy

`*.flowtest-meta.xml` declares `<flowApiName>` + one or more `<testPoints>`, each containing:
- `<elementApiName>` — the flow element name to assert at
- `<parameters>` — input record data (for record-triggered flows, the `$Record` sobject)
- `<assertions>` — expected field values via `<leftValueReference>` + `<operator>` + `<rightValue>`

### Generating the first flowTest XML (recommended)

The exact element ordering and required-field shape varies by API version and is fragile to hand-roll. Build the first test in Setup, then retrieve and template the rest:

1. Salesforce Setup → Flow Builder → open target flow.
2. **Tests** tab → **Create Test**. Name it `<FlowApiName>_<scenario>` (e.g. `_HappyPath`).
3. Set trigger record values + assertions in the UI. Save.
4. Retrieve to local:

    cd salesforce  # sfdx-project.json lives here, NOT at repo root
    sf project retrieve start --target-org <your-email> --metadata "FlowTest:<FlowApiName>.<TestName>"

   The retrieved file lands under `salesforce/force-app/main/default/flowtests/`. If the metadata-name syntax differs in your CLI version, try `FlowTest:<TestName>` (no flow prefix) or `Flow:<FlowApiName>.<TestName>` (nested) — whichever lands a file IS the canonical shape for the org.

5. For additional tests on the same flow (or other flows), copy the retrieved file as a template; modify input record values and assertions; deploy.

### Deploy + run

    cd salesforce
    sf project deploy start --source-dir force-app/main/default/flowtests/<FlowApiName>.<TestName>.flowtest-meta.xml --target-org <your-email>
    sf flow run test --target-org <your-email> --tests <FlowApiName>.<TestName> --result-format human --synchronous

The command is `sf flow run test` (space, not hyphen). The flag is `--tests` (or `--class-names` for whole-flow runs), NOT `--flow-api-name`. Verified 2026-05-11 against `@salesforce/cli/2.132.14` (empirical).

### Constraints

- Flow tests do NOT exercise external HTTP callouts — assert on pre-callout state instead, OR pair with an Apex test that uses `HttpCalloutMock` if the callout is the behavior under test (docs-confirmed).
- Flow tests credit flow-element coverage but do NOT credit `@InvocableMethod` Apex coverage when the flow calls one — Apex methods invoked from flows still need direct Apex test coverage (see `.claude/rules/salesforce-dev.md`).

## CI coverage gate (`scripts/sf_coverage/`)

The `.github/workflows/apex-test.yml` workflow spins a per-PR scratch via
`salesforce/scripts/seed/setup-scratch.sh`, runs `sf apex run test
--code-coverage --json`, and feeds the result to
`scripts/sf_coverage/delta_gate.py`.

The gate asserts >= 85% line coverage on every Apex class that this PR adds,
modifies, copies, or renames. Renamed classes follow old→new path; deleted
classes are excluded.

### Local invocation

```bash
# Against a scratch you already have
sf apex run test \
  --target-org ccspike \
  --test-level RunLocalTests \
  --code-coverage \
  --wait 30 \
  --json > /tmp/sf-test.json

python -m scripts.sf_coverage.delta_gate \
  --test-result-json /tmp/sf-test.json \
  --base origin/main \
  --threshold 85
```

### Coverage source-of-truth fallback

Some test runs return an empty `coverage.coverage` array (race condition with
the platform's coverage aggregator). The gate falls back to
`ApexCodeCoverageAggregate` SOQL when present:

```bash
sf data query \
  --target-org ccspike \
  --query "SELECT ApexClassOrTrigger.Name, NumLinesCovered, NumLinesUncovered FROM ApexCodeCoverageAggregate" \
  --json > /tmp/sf-soql.json

python -m scripts.sf_coverage.delta_gate \
  --test-result-json /tmp/sf-test.json \
  --soql-coverage-json /tmp/sf-soql.json \
  --threshold 85
```

### Sentinel-test ban

`EmailAddressNormalizer_Test` is banned as the sole test in a PR's apex run.
The only escape hatch is a `hotfix:` commit-message prefix; on `hotfix:`,
`sentinel_guard.py` auto-files a ClickUp follow-up card in A&E
(`<clickup-list-id>`) linking to the bypassing PR.

```bash
python -m scripts.sf_coverage.sentinel_guard \
  --tests EmailAddressNormalizer_Test,RealClassTest \
  --commit-msg "$(git log -1 --format=%B)" \
  --pr-number 42 \
  --pr-url https://github.com/<your-org>/automations/pull/42 \
  --commit-sha "$(git rev-parse HEAD)" \
  --parent-task <clickup-task-id>
```

## CI validate against qa (apex-test.yml)

The `apex-test.yml` GitHub Actions workflow validates SF-touching PRs against
the `qa` Partial Copy sandbox using `sf project deploy validate` (no-write,
runs Apex tests). Replaced per-PR scratch-org deploys on 2026-05-15 (see
plan `docs/superpowers/plans/2026-05-15-apex-test-gate-qa-sandbox.md`).

### Flag semantics

- `sf project deploy validate` does NOT accept `--code-coverage`
  (**empirical (2026-05-16):** sf CLI 2.132.14 returns
  `Error: Nonexistent flag: --code-coverage`).
- Coverage IS produced when `--test-level RunLocalTests` or
  `--test-level RunSpecifiedTests --tests <names>` runs Apex tests during
  the validate pass. The coverage rollup lands at
  `result.details.runTestResult.codeCoverage[]` with per-class fields
  `{name, numLocations, numLocationsNotCovered}`.
- This shape is different from `sf apex run test --code-coverage --json`,
  which produces `result.coverage.coverage[]` with
  `{name, totalLines, totalCovered, coveredPercent}`. The
  `scripts/sf_coverage/coverage_loader.py:load_from_validate_result`
  function adapts the validate shape for the delta-coverage gate.
- `--soql-coverage-json` fallback is unusable post-validate: the validate
  transaction rolls back, so `ApexCodeCoverageAggregate` does not reflect
  the proposed metadata's coverage.

### Auth secret rotation (SFDX_AUTH_URL_QA)

The workflow references `secrets.SFDX_AUTH_URL_QA`. Rotation cadence: ~90
days (sf auth-url TTL).

**Generation (initial + every rotation):**

    # 1. Interactive login to qa
    sf org login web --alias qa \
      --instance-url https://oit--qa.sandbox.my.salesforce.com

    # 2. Extract the sfdxAuthUrl
    sf org display --target-org qa --verbose --json \
      | python3 -c "
    import json, sys, re
    raw = sys.stdin.read()
    m = re.search(r'\\{', raw)
    print(json.loads(raw[m.start():])['result']['sfdxAuthUrl'])
    " > /tmp/qa-auth-url.txt

    # 3. Sanity-check the URL parses + length is reasonable (~250 bytes)
    wc -c /tmp/qa-auth-url.txt
    grep -q '^force://' /tmp/qa-auth-url.txt && echo "OK" || echo "BAD"

    # 4. Capture the previous secret's updated-at for rollback identification
    PREV=$(gh secret list --repo <your-org>/automations \
      | awk '$1=="SFDX_AUTH_URL_QA" { print $2 }')
    echo "previous SFDX_AUTH_URL_QA updated_at: ${PREV:-<not-set>}"

    # 5. Store the new secret
    gh secret set SFDX_AUTH_URL_QA --repo <your-org>/automations \
      < /tmp/qa-auth-url.txt
    rm /tmp/qa-auth-url.txt

    # 6. Verify it's there
    gh secret list --repo <your-org>/automations | grep -F SFDX_AUTH_URL_QA

**Validation (after rotation, before merging dependent PRs):**

Trigger one harmless workflow run that uses the secret. The smallest probe
is `apex-test.yml` against a no-op PR:

    gh workflow run apex-test.yml \
      --repo <your-org>/automations \
      --ref main

Watch the run: the `Authenticate to qa sandbox` step must exit 0. If it
fails with `INVALID_LOGIN` or `EXPIRED_AUTH`, the new auth-url is broken.

**Rollback (if rotation breaks CI):**

There is no "previous value" stored by GH secrets — once overwritten, the
old value is gone. Roll back by re-generating from a known-good source:

    # Option A: re-run web login + capture if you have an active CLI session
    sf org login web --alias qa-temp \
      --instance-url https://oit--qa.sandbox.my.salesforce.com
    sf org display --target-org qa-temp --verbose --json \
      | jq -r '.result.sfdxAuthUrl' \
      | gh secret set SFDX_AUTH_URL_QA --repo <your-org>/automations

    # Option B: hold a sealed copy in Azure Key Vault as the source of truth
    # (recommended cadence: capture once at rotation time, store in
    #  <credential-vault> under SFDX-AUTH-URL-QA, restore from there on
    #  rollback. Not currently mandatory; document as future work.)

### Concurrency + SLO

The workflow uses `concurrency.group: sf-qa-validate` (single global queue)
with `cancel-in-progress: false`. Cancelling a validate mid-test corrupts
the qa sandbox's `ApexTestRun` state for ~30 minutes.

**Steady-state queue depth (target SLO):**

- Validate runtime: ~2–4 min typical (16 tests in the empirical probe;
  full suite at qa scale will be 5–10 min).
- PR cadence: ~5–10 SF-touching PRs/week.
- Expected peak queue depth: 2–3 PRs (~15–30 min wait).

**Hung-validate playbook (if a run exceeds 20 min):**

1. Open the failing run in GH Actions; check the qa Apex Job queue:

       sf data query --target-org qa \
         --query "SELECT Id, Status, MethodName, ApexClass.Name, CreatedDate
                  FROM AsyncApexJob
                  WHERE JobType='TestApexType' AND Status IN ('Queued','Processing')
                  ORDER BY CreatedDate DESC LIMIT 20"

2. If the queue is empty but the run is still hung, the SOAP poll is the
   issue — cancel the workflow run from GH UI. Subsequent PRs will queue
   normally on the next push.

3. If the queue is backed up (>5 jobs queued), there's a real qa
   contention issue (likely Playwright UI smokes or ad-hoc dev work
   running concurrently). Slack the team to pause manual qa work; the
   workflow will drain naturally within ~10 min.

4. Never cancel a single validate via `sf` — it corrupts the test run
   state. Cancel only via the GH Actions UI which kills the parent
   workflow cleanly.

## Key SOQL Patterns

### Case number (users give partial numbers)
```sql
SELECT Id, CaseNumber, Subject FROM Case WHERE CaseNumber LIKE '%222448'
```

### Churn / cancelled accounts
```sql
SELECT Id, Name, Cancellation_Reason__c, Agreement_End_Date__c
FROM Account
WHERE Status__c = 'Cancelled'
  AND Agreement_End_Date__c >= 2026-01-01 AND Agreement_End_Date__c <= 2026-03-31
ORDER BY Agreement_End_Date__c
```

### MRR (Closed Won Opportunity Amount — highest per account)
```sql
SELECT Account.Name, Account.Agreement_End_Date__c, Amount, Name
FROM Opportunity
WHERE Account.Status__c = 'Cancelled' AND Amount != null AND Amount > 0
  AND StageName = 'Closed Won'
ORDER BY Account.Agreement_End_Date__c, Amount DESC
```

### Dynamic dashboards
```sql
SELECT Id, Title FROM Dashboard WHERE Type != 'SpecifiedUser'
```
Limits: Enterprise = 5, Performance/Unlimited = 10, Developer = 3.

### Account health fields
- `Partner_Engagement__c` — Red/Yellow/Green
- `Delinquency_Date__c`, `No_Support_Date__c`, `Renewal_Date__c`
- `Status__c = 'Cancelled'`, `Agreement_End_Date__c`

### Bulk pre-checks against N candidates — never per-record SOQL

Pre-sweep audit scripts that issue SOQL inside a per-candidate `for` loop (e.g. "for each of 63 leads, query for prior matches by domain") trip the synchronous Apex governor cap of **100 SOQL queries per execution** (`System.LimitException: Too many SOQL queries: 101`). 63 candidates × 3 tiers = 189 — fails on candidate #34 with no partial output.

**Pattern:** collect candidate keys into `Set<String>` per tier, issue one bulk SOQL per tier returning all eligible prior records, then bucket-match in Apex.

```apex
// WRONG — per-candidate query (governor cap at ~33 candidates with 3 tiers)
for (Lead l : candidates) {
  Integer matchCount = [SELECT COUNT() FROM Lead WHERE Email LIKE :pat ...];
  if (matchCount == 0) {
    matchCount = [SELECT COUNT() FROM Lead WHERE Website LIKE :pat ...];
  }
}

// RIGHT — bulk SOQL + Apex-side match (5 queries total regardless of candidate count)
Set<String> emailDomains = new Set<String>();
for (Lead l : candidates) emailDomains.add(extractDomain(l.Email));
List<Lead> priorWithEmail = [SELECT Id, Email, OwnerId FROM Lead WHERE OwnerId NOT IN :excludeOwnerIds AND IsConverted=false AND Email != null];
Map<String, Lead> emailFirstByDomain = new Map<String, Lead>();
for (Lead p : priorWithEmail) {
  String d = extractDomain(p.Email);
  if (emailDomains.contains(d) && !emailFirstByDomain.containsKey(d)) emailFirstByDomain.put(d, p);
}
// Now per-candidate eval is pure Apex — zero SOQL.
```

**(empirical (2026-05-08): per-candidate version of `apollo-sticky-precheck.apex` failed at candidate ~34 with `Too many SOQL queries: 101`; bulkified version completed 63 candidates in 1.5s with 2 SOQL out of 100 used.)** When the `Contains` substring tier is needed (Website match for sticky-assignment), invert the loop in Apex (`for prior; for dom: if(p.Website.indexOf(dom)>=0)...`) since SOQL `LIKE` doesn't bulkify across many distinct patterns in one statement.

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| Production org alias | `<your-email>` |
| API version | `66.0` |
| CLI path | `/opt/homebrew/bin/sf` |
| Repo | `<your-org>/automations` |
| Metadata directory | `salesforce/force-app/` |

## Risk Audit Before Production Data-Writes

Any plan that bulk-inserts or bulk-updates production records (Cases, EmailMessages, Accounts, etc.) MUST include an empirical risk audit BEFORE presenting the plan to the user. "Plan with open questions about risks" is not acceptable — research the answers first.

For Case + EmailMessage writes specifically, query the live org for:

| Surface | Query | What to do with the answer |
|---|---|---|
| AssignmentRule | `SELECT Id, DeveloperName FROM AssignmentRule WHERE SobjectType='Case' AND Active=true` (Tooling API) | If active, identify what reassigns OwnerId on insert |
| AutoResponseRule | `SELECT Id, DeveloperName FROM AutoResponseRule WHERE SobjectType='Case' AND Active=true` (Tooling API) | **CRITICAL** — if active, every Case insert may send an auto-ack email to the customer |
| EscalationRule | `SELECT Id, DeveloperName FROM EscalationRule WHERE SobjectType='Case' AND Active=true` (Tooling API) | If active, document escalation timers that start on insert |
| Active flows | grep `salesforce/force-app/main/default/flows/` for `<object>Case</object>` (or `EmailMessage`) + `<status>Active</status>` + `<recordTriggerType>Create</recordTriggerType>` | Read each flow's entry conditions; identify which fire for our records |
| Validation rules | `objects/<obj>/validationRules/` + Tooling API | Confirm no rule blocks our field values |
| Customer-facing alerts | `workflows/Case.workflow-meta.xml` `<alerts>` blocks | Verify each is gated on Status change, not Create |

For each finding, classify severity:

- **HIGH** — sends email/SMS/notification to external party (customer, partner, vendor) → must mitigate before write
- **MEDIUM** — internal-only side effect (Chatter post, queue routing, field auto-population) → acceptable, document it
- **LOW** — cosmetic or already-intended behavior

The plan presented to the user must list each surface with its severity + mitigation. "I'll figure out the risks during execution" is not the workflow — discover them during research.

**After-save flows on `EmailMessage` are a special trap:** when one throws an unhandled fault, the entire E2C transaction rolls back — no Case is created, no EmailMessage is saved. Took down all E2C in our org for ~3.5 hours on 2026-05-06. Smoke-test E2C end-to-end after deploying any new RecordAfterSave flow on `EmailMessage` (or on `Case` triggering on Create with related EmailMessage logic). Details: `docs/runbooks/case-email-cc-preservation.md` "Outage Recovery" + `.claude/rules/salesforce-dev.md` "Programmatic Write Gotchas".

## Gotchas

- **FLS after deploy:** `sf project deploy` does NOT grant Field-Level Security. After deploying custom fields, grant FLS via Apex `FieldPermissions` insert or deploy a profile XML alongside.
- **SOQL safety:** Use `WITH SECURITY_ENFORCED` in all Apex SOQL.
- **Test coverage:** Minimum 85%, bulk test with 200+ records.
- **Deploy timing:** Avoid major deploys 9 AM - 5 PM EST.
- **MRR is NOT on Account** — `AnnualRevenue` = company revenue, `Est_Revenue__c` = empty. Use Opportunity Amount.
- **`--source-dir` not `--source-path`:** The deploy/validate/retrieve flag is `--source-dir` (or `-d`). `--source-path` was deprecated and now errors with `Nonexistent flag`.
- **`--output-dir` must be inside project:** `sf project retrieve start --output-dir /tmp/...` fails with `OutputDirOutsideProjectError`. Use a subdirectory inside the project root, then clean up.
- **Deploy requires `sfdx-project.json` in cwd:** Running `sf project deploy` from a parent directory (e.g. `automations/`) fails with `InvalidProjectWorkspaceError`. Always `cd` into the SF project root (e.g. `salesforce/`) first.
- **LWC boolean `@api` properties can't initialize to `true`:** `@api myProp = true` throws LWC1503. Use `@api myProp = false` in JS and set `default="true"` in `*.js-meta.xml` for App Builder defaults.
- **LWC templates don't support ternary expressions:** `class={cond ? 'a' : 'b'}` throws LWC1058. Pre-compute class strings in JS and bind as properties.
- **LWC `lightning-input` onchange fires AFTER onkeydown:** If Enter keydown calls a handler that reads `this.inputValue`, it will be stale. Read `event.target.value` directly in the keydown handler, or query the DOM element in the send handler.
- **Permission Set — required CMT fields reject `fieldPermissions`:** Deploy fails with "cannot deploy to required field." Omit `fieldPermissions` for required Custom Metadata Type fields — public CMTs are accessible to all users anyway.
- **EACSettings is queryable via Tooling API:** `sf api request rest "/services/data/v66.0/tooling/query/?q=SELECT+IsActivityCaptureEnabled,SyncEmailToCoreActivity,S2XsvcAccEmail+FROM+EACSettings"` — 28+ fields. Don't assume EAC config is Setup-UI-only.
- **`Settings:EmailIntegration` is deployable via Metadata API:** Lightning Sync enable/disable can be pushed via `sf project deploy` using the `Settings:EmailIntegration` metadata type, not just Setup UI.
- **EmailMessage `RelatedToId` is polymorphic — subqueries fail:** `WHERE RelatedToId IN (SELECT Id FROM Opportunity ...)` errors on the polymorphic lookup. Use a two-step approach: query Opportunity IDs first, then query EmailMessage with an explicit ID list or `IN` clause.
- **Flow deploy creates Draft in prod — must activate via Tooling API:** `sf project deploy` (including validate+quick-deploy) creates a new Flow version as `Draft` even with `<status>Active</status>` in the XML. Activate with: `sf api request rest "/services/data/v66.0/tooling/sobjects/FlowDefinition/$DEFID" -X PATCH -b '{"Metadata":{"activeVersionNumber":N}}' -o <your-email>`. Get `$DEFID` from `FlowDefinitionView.DurableId` (or `FlowDefinition` via Tooling API). PATCH on `/tooling/sobjects/Flow/{versionId}` with `{"Status":"Active"}` fails with `REQUIRED_FIELD_MISSING`. **(empirical (2026-05-09): `sf api request rest -X PATCH` succeeds; `-m PATCH` is rejected with `Nonexistent flag: -m` — only `-X` or `--method` are valid in sf CLI 2.132.x.)**

- **Schedule-triggered flow `<startTime>` is org-local time, not UTC.** SF interprets `<startTime>HH:MM:SS.SSSZ</startTime>` as the desired hour in the org's default timezone (`America/New_York` for <your-org>) and ignores the `Z` suffix. The actual UTC fire time shows up in `CronTrigger.NextFireTime` after activation. Source XML `<startTime>14:00:00.000Z</startTime>` schedules at 2pm NY local (= `18:00:00Z` during EDT, `19:00:00Z` during EST), not 14:00 UTC. **(empirical (2026-05-09): `Lead_Manager_Parking_Lot_Daily.flow-meta.xml` with `<startTime>14:00:00.000Z</startTime>` produced `CronTrigger.NextFireTime = 2026-05-10T18:00:00Z` (= 2pm EDT); corrected to `<startTime>10:00:00.000Z</startTime>` produced `2026-05-10T14:00:00Z` (= 10am EDT).)** To target a specific NY-local hour, write that hour into `<startTime>HH:MM:SS.SSSZ</startTime>` and ignore the `Z`. Verify post-activation: `sf data query --query "SELECT NextFireTime FROM CronTrigger WHERE CronJobDetail.Name LIKE '%<flow-api-name>%'"`.

- **Validate Info warnings can harden into `WARNING_BLOCK_ACTIVATION` errors at FlowDefinition PATCH time.** The activation-time check is stricter than the validate-time check. Specifically, `$Record__Prior` references inside `<filterFormula>` may pass validate with an Info warning but reject the subsequent activation PATCH with `FORMULA_EXPRESSION_INVALID: ... isn't valid because "When to Run the Flow for Updated Records" in the Start element changed`. **(empirical (2026-05-09): `Lead_Manager_Parking_Lot_OnLogin` validated cleanly but PATCH returned `WARNING_BLOCK_ACTIVATION` for an Info-flagged `$Record__Prior.IsLoggedIn__c` reference; resolved by dropping the `$Record__Prior` clause and relying on `<doesRequireRecordChangedToMeetCriteria>true</doesRequireRecordChangedToMeetCriteria>` for edge-trigger semantics.)**
- **`FlowDefinition` SOQL is retired — use `FlowDefinitionView`:** `SELECT ... FROM FlowDefinition` returns `sObject type 'FlowDefinition' is not supported`. Use `FlowDefinitionView` instead: `SELECT DurableId, ActiveVersionId, LatestVersionId, ApiName FROM FlowDefinitionView WHERE ApiName = '...'`. The Tooling API REST PATCH endpoint (`/tooling/sobjects/FlowDefinition/{id}`) still works despite SOQL retirement.
- **`FlowVersionView` IDs are placeholders:** `FlowVersionView` returns `000000000000000AAA` for all `Id` values. To get real Flow version IDs, use the Tooling API: `curl "$INSTANCE_URL/services/data/v66.0/tooling/query/?q=SELECT+Id,VersionNumber,Status+FROM+Flow+WHERE+Definition.DeveloperName='...'"`

### Bulk API gotchas

- **`sf data update bulk` requires LF line endings throughout the CSV.** Bulk API 2.0 declares the input CSV with `lineEnding=LF` by default. CRLF anywhere in the file causes a hard error:

  ```
  ClientInputError : LineEnding is invalid on user data
  ```

  Python's `csv.DictWriter` (and `csv.writer`) defaults to `lineterminator="\r\n"` on ALL platforms when the underlying file is opened with `newline=""`. Pass `lineterminator="\n"` explicitly to fix:

  ```python
  import csv
  with open(out_path, "w", newline="") as out:
      writer = csv.DictWriter(out, fieldnames=fields, lineterminator="\n")
      writer.writeheader()
      for row in rows:
          writer.writerow(row)
  ```

  Alternative: pass `--line-ending CRLF` to `sf data update bulk` to tell the bulk job to expect CRLF instead. Both work; fixing the writer keeps the CSV portable for other tooling.

  Detection: `file <csv>` should report `LF line terminators` (not `CRLF`); `head -1 <csv> | xxd | tail -3` should show `0a` at end-of-line (not `0d 0a`). **empirical (2026-05-14):** caught during <clickup-task-id> qa dry-run; two failed bulk jobs (`750cZ00000DEAHpQAP`, `750cZ00000DE6NsQAL`) before the fix landed.

### Lead-specific gotchas

- **Converted Leads are read-only via API.** Once `IsConverted=true`, updates to `Status` (and most other Lead fields) fail with:

  ```
  CANNOT_UPDATE_CONVERTED_LEAD: cannot reference converted lead
  ```

  This is a platform restriction, not a validation rule or FLS gap. Gating is purely user-permission-based — there is NO separate org-level `LeadSettings` / `LeadConvertSettings` metadata flag for "Enable Edit Converted Leads". **empirical (2026-05-14):** verified the org has no metadata flag for "Enable Edit Converted Leads" (retrieved `LeadConvertSettings` from prod is empty of edit-converted fields); capability is solely gated by the user permission `AllowViewEditConvertedLeads`.

  **Temp-permset workaround** for one-off migrations:

  ```xml
  <userPermissions>
    <enabled>true</enabled>
    <name>AllowViewEditConvertedLeads</name>
  </userPermissions>
  ```

  Workflow: create a temp PermissionSet → deploy → assign to executing user → run update → unassign → destructive-delete the permset. Net change to org security posture: zero. **empirical (2026-05-14):** temp-permset path completed successfully — bulk job `750U100000k7PAWIA2`, lead `<sf-record-id>` migrated, permset deployed and reverted with zero net change.

  **Picklist deactivation note:** deactivating a Lead.Status picklist value (e.g. retiring "Meeting Held") does NOT require all records to clear the value first. Inactive picklist values remain readable on existing records — including converted Leads — but cannot be assigned to new records. So a converted Lead retaining a stale value after a migration phase does NOT block the subsequent picklist deactivation; the value lingers on that record's history forever but is otherwise inert.

  **Decision matrix:** plans that include a "migrate Lead.Status" step MUST include a pre-check for `IsConverted=true`. Recommendation: default to skip (and document the lingering value) unless cosmetic cleanup is important enough to justify the temp-permset workflow.

### Picklist `isActive=false` does NOT block API writes

Deactivating a picklist value via `StandardValueSet` or `CustomValue` with `<isActive>false</isActive>` only hides the value from UI pickers (Lightning Setup, record-edit dropdowns, list-view filters). It does **not** block direct API writes that explicitly set the field to the inactive value.

**empirical (2026-05-15):** verified end-to-end during <clickup-task-id> Phase 5 in qa. Deployed `StandardValueSet:LeadStatus` with `<isActive>false</isActive>` on `Meeting`. `sobject describe` returned only the 7 remaining active values. With the Phase 2.9 validation rule `Block_Meeting_Status_Write` **inactive**, this PATCH succeeded:

```bash
curl -s -X PATCH "$URL/services/data/v66.0/sobjects/Lead/$ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"Status":"Meeting"}' -w "\nHTTP %{http_code}\n"
# → HTTP 204 — write accepted, record now holds inactive value
```

With the VR re-activated, the same PATCH returned `HTTP 400 FIELD_CUSTOM_VALIDATION_EXCEPTION`. The picklist deactivation alone was not the gate.

**Practical implication:** when retiring picklist values, do NOT also retire the validation rule that gates API writes. Picklist UI-deactivation + an active VR are the **complementary** controls; neither alone is sufficient. The VR becomes permanent infrastructure, not a "retirement window" artifact.

**Exceptions:** if a field has `<restricted>true</restricted>` (only available on custom picklists, NOT standard fields like `Lead.Status`), the platform enforces strict picklist values at the API level too. For standard picklists this option does not exist — only the VR pattern works.

### Flow versions pin field deletions

When destructive-deploying a CustomField, Salesforce validates the field has no remaining consumers — INCLUDING Obsolete + Draft flow versions, NOT just Active versions.

**empirical (2026-05-15):** caught during <clickup-task-id> Phase 4 qa-first dry-run. The Phase 1 audit identified 4 Active-flow consumers and added them to the destructive manifest. Validation in qa still failed because 9 Obsolete + Draft versions across 6 unrelated flows ALSO held the field references. Resolution required Tooling-DELETE on each pinning version before the field destruction would validate.

**To enumerate all pinning versions of a field before a destructive deploy:**

The destructive-deploy validation error itself names the offending Flow Version IDs in the format `[3-char prefix] 301U... Flow.<DeveloperName> v<N> <Status>`. Capture them, then for each ID:

```bash
INSTANCE_URL=$(sf org display --target-org <org> --json | python3 -c "import json,sys,re; raw=re.sub(r'\x1b\[[0-9;]*m','',sys.stdin.read()); print(json.loads(raw)['result']['instanceUrl'])")
TOKEN=$(sf org display --target-org <org> --json | python3 -c "import json,sys,re; raw=re.sub(r'\x1b\[[0-9;]*m','',sys.stdin.read()); print(json.loads(raw)['result']['accessToken'])")

curl -X DELETE "$INSTANCE_URL/services/data/v66.0/tooling/sobjects/Flow/<flow-version-id>" \
  -H "Authorization: Bearer $TOKEN" -s -w "%{http_code}\n"
```

Expect HTTP 204 on each delete. 404 means already gone (idempotent retry).

**Note:** for Flow versions where the parent FlowDefinition has an Active version, deleting the Active version's predecessor Obsolete is generally allowed. The Active version itself cannot be Tooling-DELETEd directly — deactivate via PATCH `activeVersionNumber: null` first.

### Tooling-DELETE all versions of a Flow cascades to FlowDefinition

When the LAST version of a Flow is Tooling-DELETEd, Salesforce automatically deletes the parent FlowDefinition record. This makes any subsequent destructive-deploy manifest referencing the Flow by name fail with `No Flow named: X found` — treated as a hard validation error, not a warning.

**empirical (2026-05-15):** <clickup-task-id> Phase 4 in both qa + prod. We Tooling-DELETEd 36+ versions of `Log_a_Call_for_Leads`; after the last one, the FlowDefinition record was also gone. The destructive manifest's `<members>Log_a_Call_for_Leads</members>` Flow entry then surfaced as "No Flow named: Log_a_Call_for_Leads found" and the entire deploy failed.

**Practical implication for the cleanup-before-field-deletion pattern:** if you've Tooling-DELETEd all versions of a Flow to free up a CustomField for deletion, the Flow itself is also gone. Remove that Flow from any subsequent destructive manifest. Slim the manifest to deploy only the components that remain (typically listViews + CustomFields).

**The reverse is not true:** Tooling-DELETE of an Obsolete version while an Active version exists does NOT touch the parent FlowDefinition. Only when zero versions remain does the FlowDefinition get reaped. This complements (does NOT contradict) the 2026-04-30 entry above on `FlowDefinitionView` vs `FlowDefinition` SOQL behavior — those entries describe SOQL/REST surface differences for live FlowDefinitions; this entry describes lifecycle reaping when the last version is removed.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `ERROR: The org <your-email> is expired or doesn't exist` | Re-auth: `sf org login web --set-default --alias <your-email>` |
| Deploy succeeds but new fields aren't visible | FLS not granted. Deploy profile XML alongside, or insert `FieldPermissions` via Apex |
| `INVALID_SESSION_ID` in SOQL queries | Session expired. Re-auth with `sf org login web` |
| Test coverage below 85% | Check per-class: `sf apex run test --code-coverage --result-format human -n MyTestClass` |
| `sf project deploy start` reports success but fields missing from UI | Field Level Security not granted — profile XML must be deployed separately, or use FieldPermissions sobject |

## Bulk API v2 hardDelete

For storage-recovery sweeps, soft-delete is wrong: rows go to the Recycle Bin
and still count against `DataStorageMB` for 15 days. Hard-delete frees the
underlying storage immediately at the database level — but the **visible
storage meter is asynchronous and may lag**. See "Storage recalc timing
(asynchronous)" below before scheduling a follow-up snapshot.

**Permission required:** "Bulk API Hard Delete" on the running user's
profile. Verify before any automated sweep:

```bash
sf data query --query "SELECT PermissionsBulkApiHardDelete FROM Profile WHERE Id = '<profile-id>'" --target-org <your-email>
```

**Job submit (REST):**

```bash
curl -X POST "$INSTANCE_URL/services/data/v66.0/jobs/ingest" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"object":"FeedItem","operation":"hardDelete","contentType":"CSV","lineEnding":"LF"}'
```

**Upload IDs (CSV with single `Id` column):**

```bash
curl -X PUT "$INSTANCE_URL/services/data/v66.0/jobs/ingest/<job-id>/batches" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: text/csv" \
  --data-binary @ids.csv
```

**Close + poll:** PATCH `state=UploadComplete`, then GET `/jobs/ingest/<id>`
until `state=JobComplete` or `Failed`. Pull failures via
`/jobs/ingest/<id>/failedResults/`.

empirical (2026-05-14): probed against live prod <your-email> — ~322,600 FeedItem rows hardDeleted across 35 jobs; per-batch success path matches the spec; row-level failures populate `failedResults/` CSV as expected (see "Storage recalc timing" below for empirical recalc-lag evidence captured from the same run).

### Storage recalc timing (asynchronous)

Salesforce documents the storage meter as asynchronous but does **not** publish a fixed cadence. Treat the popular "~24h nightly batch" figure as community lore, not a vendor promise.

- **docs-confirmed**: storage is calculated asynchronously. [help.salesforce.com — Data and File Storage Allocations](https://help.salesforce.com/s/articleView?id=xcloud.overview_storage.htm): *"File storage and data storage are calculated asynchronously, so if you import or add a large number of records or files, the change in your org's storage usage isn't reflected immediately."* No specific timing is given.
- **docs-confirmed**: REST `/services/data/vXX.X/limits.DataStorageMB` does not match the Setup → Company Information → Used Data Space UI value. Salesforce known issue [a1p3A0000018B87QAE](https://trailblazer.salesforce.com/issues_view?id=a1p3A0000018B87QAE) reports ~4.75% drift between the two surfaces.
- **docs-confirmed**: no live or forced-recalc REST endpoint exists for data storage. Setup UI exposes a "Recalculate Data Usage Percentage" button next to **File** storage only; for data-storage recalc, the documented escalation is a Salesforce Support case.
- **empirical (2026-05-14)**: after hardDeleting ~322,600 FeedItem rows ending at 2026-05-14T23:14Z, `DataStorageMB.Remaining` read +162 MB via REST minutes later — essentially unchanged from the pre-rerun +164 MB. Confirms the meter is lagging but cannot quantify by how much from a single sample.

**Practical guidance:**
- Sample at multiple intervals (e.g. +2h / +6h / +12h / +24h) instead of assuming a single fixed-time snapshot is steady-state.
- Don't compare REST vs Setup UI values during the lag window — they can disagree by ~5% per the known issue.
- If the meter looks stuck >24-48h after a large delete, file a Support case (documented escalation).
- Plans citing "wait 24h for recalc" should source-label as **empirical**, not docs-confirmed — there is no 24h SLA from SF.

## FeedItem Type enumeration

The sweeper's default policy whitelists FeedItem `Type` values that are safe
to bulk-delete:

```
TextPost, TrackedChange, LinkPost, ContentPost, CreatedRecordEvent
```

New types arrive via Salesforce major releases. Unknown types are logged by
`sf_archive.sweeper` each pass; extend the policy deliberately. (pending —
production probe of `SELECT Type, COUNT(Id) FROM FeedItem GROUP BY Type`
captured 2026-05-10 by Phase 2.)

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-29 | `sf project deploy validate --source-path` → `Nonexistent flag` | Flag renamed to `--source-dir` in recent CLI versions | Use `--source-dir` (or `-d`) everywhere |
| 2026-04-29 | `sf project retrieve start --output-dir /tmp/verify` → `OutputDirOutsideProjectError` | CLI enforces output inside project root | Use a relative subdir (e.g. `verify-tmp/`), then `rm -rf` after diffing |
| 2026-04-29 | `sf project deploy` from `automations/` → `InvalidProjectWorkspaceError` | CLI requires `sfdx-project.json` in cwd | Run from `salesforce/` subdirectory |
| 2026-04-29 | LWC `@api autoRecommend = true` → LWC1503 | Boolean @api properties can't be initialized to `true` | Use `= false` in JS + `default="true"` in meta.xml |
| 2026-04-29 | `lightning-input` Enter sends empty query | `onchange` fires after `onkeydown`; tracked value is stale at keydown time | Read `event.target.value` in keydown handler + query DOM in send |
| 2026-04-29 | Assumed EAC config was Setup-UI-only | `EACSettings` is a Tooling API object with 28+ queryable fields | Query via `sf api request rest` against Tooling API |
| 2026-04-29 | EmailMessage SOQL subquery on `RelatedToId` fails | `RelatedToId` is polymorphic; SOQL rejects subqueries on polymorphic lookups | Two-step: query parent IDs first, then `EmailMessage WHERE RelatedToId IN (...)` |
| 2026-04-30 | Flow deploy succeeds but new version stays Draft | `sf project deploy` (all modes) creates Draft; `<status>Active</status>` in XML is ignored for prod activation | Tooling API PATCH on `/tooling/sobjects/FlowDefinition/{DurableId}` with `{"Metadata":{"activeVersionNumber":N}}` |
| 2026-04-30 | `SELECT ... FROM FlowDefinition` → `sObject type not supported` | `FlowDefinition` retired from SOQL | Use `FlowDefinitionView` for queries; Tooling API REST endpoint still works for PATCH |
| 2026-04-30 | `FlowVersionView` returns `000000000000000AAA` for all IDs | View returns placeholder IDs, not real record IDs | Use Tooling API query on `Flow` object: `SELECT Id,VersionNumber,Status FROM Flow WHERE Definition.DeveloperName='...'` |
| 2026-05-09 | `sf project deploy start --test-level NoTestRun` → `INVALID_OPERATION: testLevel of NoTestRun cannot be used in production organizations` | Production orgs enforce test execution at the Metadata API level, not just the CLI | Use `--test-level RunSpecifiedTests --tests EmailAddressNormalizer_Test` (sentinel: 16/16 pass, ~324ms, no DML) |
| 2026-05-09 | `sf project deploy quick --job-id <X>` → `INVALID_ID_FIELD: Source validate did not run tests in the org` | Validate ran with `RunRelevantTests` against flow-only changes — 0 tests; SF refuses quick-deploy when validate ran no tests | Re-validate with `RunSpecifiedTests --tests <stable-sentinel>` |
| 2026-05-09 | `sf project deploy quick --job-id <X>` → `INVALID_ID_FIELD: There have been deploys in the org since the source validate happened` | Other prod deploys invalidated the Job ID between validate and quick-deploy | Re-validate; only quick-deploy when no intervening prod deploys are expected |
| 2026-05-09 | Flow `<startTime>14:00:00.000Z</startTime>` fires at 2pm EDT, not 10am EDT | SF schedule-triggered flows interpret `<startTime>` as org-local time (`America/New_York`), ignoring the `Z` suffix | Set `<startTime>` to the desired NY-local hour; verify post-activation via `CronTrigger.NextFireTime` |
| 2026-05-09 | FlowDefinition PATCH activation rejected with `WARNING_BLOCK_ACTIVATION` despite clean validate | Activation check is stricter than validate check; `$Record__Prior` references in `<filterFormula>` can pass validate as Info-only and fail activation as Error | Drop the `$Record__Prior` clause; rely on `<doesRequireRecordChangedToMeetCriteria>true</doesRequireRecordChangedToMeetCriteria>` for edge-trigger semantics |
| 2026-05-09 | `sf api request rest -m PATCH ...` → `Nonexistent flag: -m` | `-m` shorthand is not supported in sf CLI 2.132.x; only `-X` or `--method` | Use `-X PATCH` or `--method PATCH` |
| 2026-05-09 | `LeadReplenishmentServiceTest` fails with `MIXED_DML_OPERATION` on default `RunLocalTests` validate in prod | Pre-existing test-class bug at `setupTestData` line 49 — not specific to current changes | Use `RunSpecifiedTests --tests EmailAddressNormalizer_Test` to skip; ClickUp <clickup-task-id> to fix the underlying test class |

## Sandbox Provisioning (Phase 4)

Three-tier dev/test environment shipped by Phase 4 (parent plan <clickup-task-id>). Operator details in `docs/runbooks/sandbox-refresh-playbook.md`.

| Tier | Type | Refresh throttle | Refresh cadence | Verified |
|---|---|---|---|---|
| `stage` | Full Copy | 29 days | Manual / release cron | empirical (2026-05-12): `sf org refresh sandbox --help` documents `--no-auto-activate` + standard polling flags |
| `qa` | Partial Copy | 5 days | Sunday 02:00 UTC weekly | empirical (2026-05-12): same |
| Per-PR scratch | Scratch | n/a | Per PR | docs-confirmed at https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_scratch_orgs.htm |

### Sandbox commands

```bash
# Create a new sandbox (first-time provisioning)
sf org create sandbox \
  --name qa --license-type Partial --alias qa \
  --target-org <your-email> --no-prompt --wait 240

# Refresh an existing sandbox (the orchestrator script picks this path automatically)
sf org refresh sandbox \
  --name qa --target-org <your-email> --no-prompt --wait 240

# Query last refresh date via Tooling API (used by create-sandbox.sh throttle gate)
sf data query --use-tooling-api \
  -q "SELECT Id, SandboxName, LastRefreshDate FROM SandboxInfo WHERE SandboxName='qa'" \
  --target-org <your-email> --json

# Storage limits (data + file)
sf org list limits --target-org <your-email> --json \
  | jq '.result[] | select(.name=="DataStorageMB" or .name=="FileStorageMB")'

# Scratch org janitor (Phase 2 + Phase 4 use this)
sf org list --all --json \
  | jq -r '.result.scratchOrgs // [] | .[] | select(.connectedStatus == "Expired") | .username' \
  | xargs -r -I{} sf org delete scratch --target-org {} --no-prompt
```

### Empirical constraints

These were verified against the live API on 2026-05-12 (round 3 codex review):

- Sandbox templates are **UI-only**. The Tooling API exposes no `SandboxTemplate*` sObject (verified: `SELECT QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName LIKE 'Sandbox%'` returns only `SandboxInfo`, `SandboxProcess`, `SandboxObserver2`, `SandboxRelayObserver`, `SandboxSettings`).
- Salesforce Data Mask is a **managed package with UI-defined policies**. There is **no `sf data mask` CLI plugin** (verified: `sf plugins inspect data-mask` → "not installed"; `@salesforce/plugin-data-mask` returns npm 404).
- Sandbox templates support **object include/exclude only**. No record-age filters, no per-object record-count limits.
- `sourceApiVersion >= 60.0` is required in `sfdx-project.json` for the Flow Test Framework (Phase 3 dependency; Phase 1 already bumped to 66.0).

### Orchestrator script

`salesforce/scripts/sandbox/create-sandbox.sh` wraps the create/refresh dispatch + 29-day throttle gate. Standard invocation:

```bash
# Auto-detect create vs refresh; gate on 29-day throttle for Full Copy
salesforce/scripts/sandbox/create-sandbox.sh \
  --name qa --license-type Partial --alias qa --source-org <your-email>

# Dry-run mode for testing (no live SF call)
salesforce/scripts/sandbox/create-sandbox.sh \
  --name stage --license-type Full --dry-run \
  --mock-last-refresh 2026-04-12T00:00:00Z
```

## Debugging Screen Flow faults

Screen flows that throw "An unhandled fault has occurred in this flow" in the UI write per-element trace to `FlowInterviewLog` + `FlowInterviewLogEntry`. These are queryable via SOQL and pinpoint the faulting element within seconds.

**Apex anon does NOT work for screen flows.** `Flow.Interview.<FlowName>(params).start()` errors with `Start can't be called on a flow with the process type Screen Flow` — even if the flow has `<status>Active</status>` and looks autolaunched in source. The `<screens>` element makes it a screen flow at runtime. Drive the UI to reproduce instead (see `.claude/rules/browser-automation.md` for the Playwright + frontdoor pattern).

### Login-As smoke testing as a non-admin user

Reproducing per-user / per-profile SF bugs from an admin session. Used by `/sf-smoke-as` (see `~/.claude/commands/sf-smoke-as.md`).

**Pattern.** Admin (`<your-email>`) authenticates via `sf org open --url-only --json` → captures the org's 15-char OrgId from `result.orgId.substring(0, 15)` → chains a one-time `frontdoor.jsp?otp=...&startURL=/servlet/servlet.su?oid=<orgId15>&suorgadminid=<target-15>&targetURL=<record-url>` URL → Salesforce exchanges admin's session for target user's session → redirects to the record. Playwright headless drives the resulting page and captures aura ERROR responses so the human-readable gack code surfaces instead of just "An internal server error has occurred".

**Empirical (<clickup-task-id> precedent, 2026-05-15; re-probed <clickup-task-id> Phase 0, 2026-05-16):**

- `oid=<15-char-orgId>` is **REQUIRED**. Omit it and `servlet.su` silently no-ops — the source admin's session is preserved with no Login-As executed and no audit-trail entry. Pull from `parseSfOrgOpenJson(result).orgId.substring(0, 15)` after the first `sf org open --url-only --json` call (the warmup that captures orgId for the second servlet.su URL).
- `suorgadminid` requires **15-char** User Id (`<id>.substring(0, 15)`). 18-char Ids redirect to `/login` (`?ec=301&startURL=...`).
- `targetURL` is URL-encoded exactly once (`%2F` not `/`). Encoding twice 302s to login.
- Frontdoor URLs are one-time-use; regenerate via `sf org open --url-only -p '...' --json` per attempt.
- The `--json` flag does NOT suppress the `›   Warning: @salesforce/cli update available` preamble (or its ANSI escapes). Parse with `JSON.parse(stdout.substring(stdout.indexOf('{')))`.
- **Playwright wait strategy matters.** `waitUntil: 'networkidle'` is too late — impersonated sessions on some profiles expire within ~10s of Login-As, so the page captured at `networkidle` may be the post-expiry `/login` view (false denial signal). Use `waitUntil: 'domcontentloaded'` then `page.waitForFunction(() => !/\/secur\/frontdoor\.jsp/.test(location.href), { timeout: 15000, polling: 250 })` to wait for the URL to stabilize off the frontdoor before reading state.

**Detecting Login-As denial.** A `servlet.su` chain the source admin can't perform redirects to `/login`. `/sf-smoke-as` exits 4 in that case based on a **heuristic multi-signal check**: final URL contains `/login`, `/secur/login`, or `?ec=301`; page title starts with `Login |`; OR a visible username/password input is rendered. This is intentionally NOT strict HTTP-302 capture — Playwright's `page.goto()` follows the redirect transparently and we'd lose the 302 status; the multi-signal approach trips on whichever signal the redirected page surfaces. The denial is also written to JSONL as a `login_as_denied` row with which signals fired.

**Audit trail.** Every successful Login-As is logged in Setup → Audit Trail (`SetupAuditTrail` SObject) under the source admin AND the target user's profile. The exact audit-trail row is `Logged in using Login-As access for <Target Name>`. Use this pattern for diagnosis, not routine masquerading. Programmatic-only no-ops (omitted `oid`) do NOT create audit-trail entries — useful for distinguishing "the URL was malformed" from "the URL succeeded but the page didn't render as I expected".

**LWS closed-shadow-DOM workaround** (future v2 reference — `--save` click-through is reserved for v2 in current v1):

```js
// Textareas: slot content is queryable, fill() works normally
await page.locator('textarea[placeholder*="Comments"]').fill('test note');

// Buttons under LWS-rejection: lightning-button rejects native .click() as "untrusted".
// Workaround: JS-focus the button + dispatch a real Enter via page.keyboard.
const saveBtn = page.locator('lightning-button[label="Save"]');
await saveBtn.evaluate(el => el.focus());
await page.keyboard.press('Enter');
```

**Lightning popup interception.** The Setup overlay near top-right intercepts mouse coordinates on certain pages. Prefer keyboard navigation (`Tab` + `Enter`) when click targets land near the top of the viewport.

**See also**

- `.claude/rules/browser-automation.md` — node_modules-bearing-dir requirement
- `docs/runbooks/playwright-cli.md` — Playwright runtime gotchas + Turnstile workaround
- `~/.claude/commands/sf-smoke-as.md` — the slash command

**Diagnostic queries** (empirical 2026-05-15, <clickup-task-id>):

```bash
# 1. Find the failed run by FlowDeveloperName + today
sf data query -o <your-email> -q "SELECT Id, InterviewStatus, FlowVersionNumber, InterviewStartTimestamp, InterviewDurationInMinutes FROM FlowInterviewLog WHERE FlowDeveloperName = '<flow-api-name>' AND CreatedDate = TODAY ORDER BY CreatedDate DESC LIMIT 5"

# 2. Per-element trace for the failed run (returns FlowStart → ScreenNext → Error rows)
sf data query -o <your-email> -q "SELECT LogEntryType, ElementApiName, ElementLabel, LogEntryTimestamp FROM FlowInterviewLogEntry WHERE FlowInterviewLogId = '<log-id-from-step-1>' ORDER BY LogEntryTimestamp" --result-format csv
```

The `Error` row's `ElementApiName` is the faulting element. If the element name isn't in the parent flow's XML, it's in a subflow — grep the subflow files (retrieve them via `sf project retrieve start -m "Flow:<SubflowApiName>" -o <alias> --target-metadata-dir /tmp/<dir> --unzip`).

**Also useful — auto-filed admin error emails:**

When a flow element has NO `<faultConnector>`, Salesforce auto-emails the admin (default `<service-email>` for <your-org>) with the FULL element trace AND the runtime values of each filter input. Query the EmailMessage table:

```bash
sf data query -o <your-email> -q "SELECT Id, Subject, TextBody, CreatedDate FROM EmailMessage WHERE Subject LIKE '%error occurred with your%' AND CreatedDate = TODAY ORDER BY CreatedDate DESC LIMIT 3"
```

The email body lists every element traversed before the fault + a clear `Error element X (FlowRecordLookup)` line with the exception message. This is the highest-signal debugging surface for any flow fault — strictly better than the modal text the user sees in Lightning, which is always the same generic "An unhandled fault has occurred."

**Trade-off when adding faultConnectors:** Adding `<faultConnector>` to a flow element suppresses the SF auto-error email for that element — the faultConnector routes execution to the recovery path instead. When adding faultConnectors, plan a replacement observability surface (Chatter post on the case, manual error-log via a custom object, follow-up faultConnectors on the Update_* recovery elements) in the same PR. Precedent: <clickup-task-id> Phase 1.6 added 4 emailSimple faultConnectors and explicitly carved out the observability replacement to follow-on card <clickup-task-id>.

## Flow fault observability via FlowFaultRecorder

When a flow needs explicit observability on its fault paths (because `<faultConnector>` suppresses the SF auto-error email — see "Trade-off when adding faultConnectors" above), wire the fault path through `FlowFaultRecorder.recordFault` instead of letting it fall through silently.

**Apex helper:** `salesforce/force-app/main/default/classes/FlowFaultRecorder.cls` (introduced <clickup-task-id> / PR pending). One generic `@InvocableMethod` callable from any flow's fault path. On each call:

1. Posts a Chatter `FeedItem` on the Case with `[<ts>] <flowName> fault at <elementName>: <faultMessage>`
2. Sets `Case.Flagged_for_Management_Review__c = true` (the existing `Flagged_for_Management_Review` record-triggered flow then fires the Teams cascade for free)
3. Appends the same line to `Case.Management_Notes__c` with `\n---\n` separator (preserves prior content)

Bulk-safe: the helper itself is 1 SOQL + 2 DML regardless of request count. Downstream cascade (FFM record-trigger → Teams webhook) adds ~3 more SOQL/DML; tests assert overall `<=10` to catch n+1 regressions without coupling to the cascade's exact cost.

**Flow XML shape — wrap each fault path:**

```xml
<actionCalls>
    <name>Record_Client_Email_Fault</name>
    <label>Record Client Email Fault</label>
    <actionName>FlowFaultRecorder</actionName>
    <actionType>apex</actionType>
    <connector>
        <targetReference>Update_Onboarding_Case</targetReference>  <!-- forward to original success destination so business logic continues -->
    </connector>
    <flowTransactionModel>CurrentTransaction</flowTransactionModel>
    <inputParameters>
        <name>caseId</name>
        <value><elementReference>Get_Onboarding_Notes.Onboarding_Case__c</elementReference></value>
    </inputParameters>
    <inputParameters>
        <name>flowName</name>
        <value><stringValue>Onboarding_Call_v2</stringValue></value>
    </inputParameters>
    <inputParameters>
        <name>elementName</name>
        <value><stringValue>Send_Client_Onboarding_Notes</stringValue></value>
    </inputParameters>
    <inputParameters>
        <name>faultMessage</name>
        <value><elementReference>$Flow.FaultMessage</elementReference></value>
    </inputParameters>
    <nameSegment>FlowFaultRecorder</nameSegment>
</actionCalls>
```

Then point the source element's `<faultConnector><targetReference>Record_*_Fault</targetReference></faultConnector>` at the new actionCall. The actionCall's own `<connector>` sends control forward to the original success destination so the business path still runs.

**`<actionName>` token convention** (verified empirically 2026-05-15 against `Flagged_for_Management_Review.flow-meta.xml`): use the Apex class name verbatim. No `apex-` prefix; no method suffix; case-sensitive (the `sendWebhookNotification` class is lowercase-first and its actionName matches verbatim).

### Flow XML element ordering — actionCalls must be contiguous

`<actionCalls>` blocks in a flow XML file MUST appear as a contiguous group; the Salesforce Metadata API rejects deploys where a non-actionCalls element interrupts the group with:

```
Error parsing file: Element actionCalls is duplicated at this location in type Flow (NNNN:NN)
```

When adding new actionCalls to an existing flow, insert them immediately AFTER the last existing `</actionCalls>` (typically near the top of the file, before `<assignments>` / `<constants>` / etc.) — NOT at the logical position near `<recordUpdates>` even when that's where they semantically belong. The `<connector>` references resolve by name regardless of source-file position.

Empirical 2026-05-15 (<clickup-task-id>): inserted 7 new actionCalls at line ~2080 (just before `<recordUpdates>`) — deploy rejected. Re-inserted after line 336 (last existing `</actionCalls>`) — deploy succeeded.

### Testing flow-fault Apex helpers under the FFM cascade

When an Apex helper sets `Case.Flagged_for_Management_Review__c = true` (e.g. `FlowFaultRecorder.recordFault`), the existing `Flagged_for_Management_Review` record-triggered flow fires and calls `sendWebhookNotification` Apex, which makes an HTTP callout to Teams. In test context this fails with:

```
Methods defined as TestMethod do not support Web service callouts
```

**Fix:** mock the callout at the start of every test method that triggers the cascade:

```apex
private class WebhookCalloutMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(200);
        res.setBody('1');
        return res;
    }
}

@IsTest
static void myTest() {
    Test.startTest();
    Test.setMock(HttpCalloutMock.class, new WebhookCalloutMock());
    // ... code that flips Flagged_for_Management_Review__c = true ...
    Test.stopTest();
}
```

Same trap will hit any future Apex helper that writes to `Flagged_for_Management_Review__c` — install the mock pre-emptively in every test method, not just one.

## SOQL date literals — `LAST_N_HOURS` is not supported

The platform date-literal set covers `TODAY`, `YESTERDAY`, `LAST_N_DAYS:n`, `LAST_N_WEEKS:n`, `LAST_N_MONTHS:n`, `LAST_N_QUARTERS:n`, `LAST_N_YEARS:n`, and `LAST_N_MINUTES:n`. **There is no `LAST_N_HOURS:n`** — empirical 2026-05-15 (CLI returns `unexpected token: 'LAST_N_HOURS'`). Use `LAST_N_MINUTES:60` for "last hour" or `CreatedDate >= <ISO-datetime>` (no quotes) for arbitrary windows. Same gotcha for `LAST_N_SECONDS`.

## `sf api request rest` body argument syntax

`sf api request rest` does NOT accept `--body <file-path>` directly — passing a path produces `JSON_PARSER_ERROR` because the CLI parses the path string as the JSON payload literally. Use one of:

- **Inline body (preferred for short payloads):** `-b '{"Metadata":{"activeVersionNumber":3}}'`
- **Heredoc to stdin:** version-dependent, not always reliable
- **Method flag:** `-X PATCH` (NOT `-m PATCH` — `-m` is rejected in 2.132.x with `Nonexistent flag`)

Empirical 2026-05-15 against the FlowDefinition PATCH used for Onboarding_Call_v2 activation (`/services/data/v66.0/tooling/sobjects/FlowDefinition/<id>`). First call failed with the file-path-as-body mistake; second call with `-b '<inline-json>'` returned the expected HTTP 204.

## Synthetic-data smoke cascade — probe → qa → prod

When smoking a Salesforce flow/Apex/process fix that mutates records, never use a real production record to verify. Build synthetic data through this cascade (<your-name>'s standing preference, <clickup-task-id> 2026-05-15):

**1. Probe.** Before creating any records, describe target objects + enumerate constraints:

```bash
# Object describe — required fields, picklist values, RTs
sf sobject describe -s <Object> -o <alias> --json | python3 -m json.tool | grep -A3 '"nillable": false'

# Active validation rules + formulas (Tooling REST — Metadata field needs per-Id fetch)
sf data query --use-tooling-api -o <alias> -q "SELECT Id, ValidationName FROM ValidationRule WHERE EntityDefinitionId = '<Object>' AND Active = true"
for ID in <vr-ids>; do
  sf api request rest "/services/data/v66.0/tooling/sobjects/ValidationRule/$ID" -o <alias> | jq '.Metadata.errorConditionFormula'
done

# Quick action / page layout entry point
sf data query --use-tooling-api -o <alias> -q "SELECT Id, DeveloperName, Type, SobjectType FROM QuickActionDefinition WHERE DeveloperName LIKE '%<keyword>%'"
```

Goal: know exactly which fields the flow consumes so synthetic records don't fault on missing data before reaching the patched element.

**2. Synthetic in qa.** Create records with `ZZZ_<task-id>_Smoke_DELETE_<ts>` naming. Drive the smoke via Playwright (frontdoor URL → headless Chromium → quick-action click — see `.claude/rules/browser-automation.md`). Iterate the data shape until the flow walks past the patched element. Use `ray+<purpose>@<your-org>` (sub-addressing) for recipient fields so emails route to <your-name>'s inbox.

**3. Synthetic in prod.** Once qa smoke proves the fix, replicate the synthetic shape in prod and re-drive. Be aware that prod may exercise downstream paths (record-changed flows, subflows, Order/Activation) that qa doesn't, so expect to iterate the data shape one more time.

**4. Cleanup.** Delete the synthetic records in reverse-dependency order: child records → LineItems → Case → Opp → Contact → Account.

**Why this order:**

- Probing first prevents the "create → fault on missing field → fix → fault on different missing field" loop.
- qa first surfaces obvious data shape gaps cheaply (no prod mutation).
- Prod second catches qa/prod environment drift — e.g. qa's `<your-org>` email domain is NOT verified for outbound, so any record-changed flow that fires an email on Status=Completed throws `CANNOT_EXECUTE_FLOW_TRIGGER` in qa but works in prod. Surfaces only when re-tested in prod.
- Real records are never disturbed — the original requester's onboarding continues uninterrupted.

**How to apply:**

- Trigger: any SF fix where smoke involves running the patched flow end-to-end against real-data shape.
- Present the synthetic-data design BEFORE creating anything in prod — <your-name> will pre-approve the shape.
- Save the synthetic Ids inline in the chat as you create them so cleanup at the end doesn't require a SOQL hunt.
- Capture the FlowInterviewLog Id of the proving run in the evidence file (`docs/superpowers/specs/evidence/<task-id>/prod-smoke-*.md` — `.md`, not `.log`, per `.claude/rules/plan-verification.md`).
