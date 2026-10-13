# Salesforce CLI Runbook

> **Owner:** <your-name> | **Last verified:** 2026-10-08 (nightly full suite and flow test mapping; <clickup-task-id>)

## Sourcing discipline

Every claim in this runbook about SF behavior — API capability, limit, recalc cadence, schema rule, deploy quirk — must cite one of:

- **docs-confirmed:** `help.salesforce.com`, `developer.salesforce.com`, `architect.salesforce.com`, or `trailblazer.salesforce.com/issues_view` (Known Issues). Link the URL.
- **empirical (YYYY-MM-DD):** verified against a live org. Note org + date + command.
- **contradicts-docs / pending / deploy-verified:** per `.claude/rules/evidence-discipline.md`.

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

### Durable auth: JWT bearer (no expiry) — prefer over browser-OAuth

`sf org login web` mints a **refresh token** (PlatformCLI connected app) that **expires**
(~90-day TTL — see "Auth secret rotation" below; the "sf CLI manages its own token refresh"
note above only holds until the refresh token itself dies). When it expires, the local alias,
the vaulted auth URL, AND the CI secret all die at once (same OAuth grant) — taking the Apex
gate red for **every** PR.

**Prod uses JWT bearer instead** (cert-based, mints a fresh token per call, never expires):

```bash
CK=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name SF-JWT-CONSUMER-KEY --query value -o tsv)
AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name SF-JWT-PRIVATE-KEY --query value -o tsv > /tmp/.sfjwt.key
sf org login jwt --client-id "$CK" --jwt-key-file /tmp/.sfjwt.key \
  --username <your-email> --instance-url https://login.salesforce.com --alias <your-email> --set-default
rm -f /tmp/.sfjwt.key
# verify: `sf org display -o <your-email> --json | jq .result.clientId` is the SF-JWT key, not "PlatformCLI"
```

> **`/tmp` is CI-only — a long-lived workstation needs a durable key path.** JWT auth
> re-reads the `--jwt-key-file` on **every token refresh** (that's how it mints a fresh token
> per call), and `sf org login jwt` persists the *path* into the auth record (macOS Keychain,
> `sfdx` service — `~/.sf/*.json` holds only config/cache, not the auth). The `/tmp/.sfjwt.key`
> + `rm -f` shape above is correct for **CI** (fresh checkout per run, key needed only at the
> login second) but **breaks on a persistent machine**: the cached access token eventually
> expires (or a reboot wipes `/tmp`), the next refresh opens the stored path, and the org goes
> `Unable to refresh session due to: ENOENT … '/tmp/.sfjwt.key'`. This also silently breaks the
> Claude Desktop `@salesforce/mcp` server, which refreshes the same prod auth record. For a
> local workstation, write the key to a **durable** path and leave it in place:
> ```bash
> CK=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name SF-JWT-CONSUMER-KEY --query value -o tsv)
> ( umask 077; AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name SF-JWT-PRIVATE-KEY --query value -o tsv > ~/.sf/sfjwt-prod.key )
> sf org login jwt --client-id "$CK" --jwt-key-file ~/.sf/sfjwt-prod.key \
>   --username <your-email> --instance-url https://login.salesforce.com --alias <your-email>
> # do NOT rm the key — refreshes re-read it. umask 077 → 0600, owner-only, persists across reboots.
> # verify the fix actually refreshes: `sf data query -q "SELECT Id FROM Organization LIMIT 1" -o <your-email>`
> ```
> The vault stays the source of truth; `~/.sf/sfjwt-prod.key` is a derived owner-only (0600)
> local artifact — no more exposed than the Keychain token it backs. (empirical 2026-06-24,
> <clickup-task-id>: prod org refresh failed with the `/tmp` ENOENT after a reboot, breaking the
> Claude Desktop SF MCP; re-auth against `~/.sf/sfjwt-prod.key` restored `Connected` + a live
> `Organization` query.)

**qa logs in through prod — there is no stored qa key** (<clickup-task-id>, 2026-09-14).
Sandboxes **regenerate every connected-app consumer key on refresh**, and qa refreshes weekly,
so no saved qa key stays valid. The key also cannot be pinned: a deploy that sets `<consumerKey>`
is rejected with `You cannot provide a Consumer Key`. `scripts/sf/qa-login.sh` therefore needs
only an authenticated **production** org — prod's `POST /tooling/sandboxAuth` issues a one-time
auth code for the sandbox admin user, which is exchanged for a qa session:

```bash
# session only (expires) — what CI uses
scripts/sf/qa-login.sh --prod-org <your-email> --alias qa

# non-expiring JWT auth — what sf-agent and a terminal alias use
scripts/sf/qa-login.sh --prod-org <your-email> --jwt --key-file ~/.sf/sfjwt-prod.key --alias qa
```

`--jwt` reads qa's **current** consumer key from the live org at call time (never a stored copy)
and establishes a JWT-bearer auth with the shared prod certificate. Full mechanism, safety
properties, and failure modes: `docs/runbooks/qa-sandbox-auth.md`.

CI (`.github/workflows/apex-test.yml` both jobs, `qa-apex-sync.yml`) authenticates to prod with
`SF_JWT_CONSUMER_KEY` + `SF_JWT_PRIVATE_KEY`, then calls `qa-login.sh`. **Retired 2026-09-19:**
GH secret `SF_JWT_CONSUMER_KEY_QA` and vault `SF-JWT-CONSUMER-KEY-QA` (2026-09-21) are deleted.
Nothing reads a stored qa key any more, and nothing needs rotating after a refresh.

**KV write caveat:** the default `<azure-config-dir>` identity (OCC Orchestrator SP) has KV
**GET only** — `az keyvault secret set`/`delete` returns `(Forbidden)`. Vault writes need an
identity with the Secrets Officer policy (<your-name>'s own `az login`, MFA current).

### Agent sessions: keychain-free auth store (`scripts/sf/sf-agent`)

**Symptom.** In a Claude Code / daemon shell, every stored org reads back invalid and
`sf org list` reports `No Orgs found`:

```
Warning: The auth file for <your-email> is invalid. Due to: Command failed with response:
 - security: SecKeychainItemCreateFromContent (<default>): User interaction is not allowed.
```

**This is not a locked keychain, and unlocking does not fix it.** The agent shell runs in a
security session detached from the GUI login session, so the keychain has no way to show the
allow-prompt there. `security find-generic-password -s sfdx` returns the item's *attributes*
but refuses `-w` (the secret) — that split is the tell. (empirical (2026-08-06): <your-name> ran
`security unlock-keychain` interactively; the agent shell still got
`SecKeychainCopySettings … User interaction is not allowed`.)

**Do NOT "fix" it by setting `SF_USE_GENERIC_UNIX_KEYCHAIN=true` alone.** The state folder is
hardcoded to `os.homedir()/.sfdx` (`@salesforce/core` `lib/global.js:64,85`) with no env var to
relocate it, so agent and interactive contexts share one auth file and each re-encrypts it with
a key the other cannot read. Observed thrashing in both directions on 2026-08-06: the agent's
workaround broke <your-name>'s CLI + the Claude Desktop SF MCP; <your-name>'s re-auth then broke the agent.

**Use the wrapper.** `SF_USE_GENERIC_UNIX_KEYCHAIN=true` selects the file keystore
(`lib/crypto/keyChain.js:24-43` — the path Linux CI already takes by default), and a separate
`HOME` gives the agent its own `.sfdx`, since Node's `os.homedir()` honors `$HOME`:

```bash
scripts/sf/sf-agent org list
scripts/sf/sf-agent data query -o <your-email> -q "SELECT Id FROM Organization LIMIT 1"
scripts/sf/sf-agent --relogin      # re-mint both orgs from the vaulted JWT creds
```

Store lives at `~/.sf-agent/.sfdx/`; both orgs authenticate via JWT bearer against the one prod
certificate key `~/.sf/sfjwt-prod.key` (qa's connected app carries the same certificate), so they
mint a fresh token per call and never expire. `--relogin` reaches qa through `scripts/sf/qa-login.sh`, which reads qa's consumer key from the
live org on each call, so it is correct immediately after a refresh with nothing to rotate.

#### qa JWT used to break every Sunday — fixed 2026-09-14 (<clickup-task-id>)

The qa sandbox **regenerates its connected-app consumer key on every refresh**, and nothing rotated
the stored copies, so from each Sunday refresh until someone rotated by hand every JWT path into qa
failed:

```
$ scripts/sf/sf-agent --relogin
sf-agent: authorized prod (<your-email>)
Error (JwtGrantError): ... client identifier invalid
sf-agent: jwt login failed for qa (<your-email>.qa)
```

(empirical (2026-08-11), <clickup-task-id>: two days after a Sunday refresh, `--relogin` minted prod fine
and failed qa with `client identifier invalid`; the vaulted key was the pre-refresh one. Prod
authorizing in the same run is the tell that this is **not** the keychain problem above — qa uses
the shared prod cert and only the consumer key differed.)

**There is no rotation procedure any more.** `scripts/sf/qa-login.sh` reaches qa through a prod
session and reads qa's key from the live org per call, so the stored copies were retired
(GH secret `SF_JWT_CONSUMER_KEY_QA` deleted 2026-09-19, vault `SF-JWT-CONSUMER-KEY-QA` deleted
2026-09-21). Re-auth after a refresh is:

```bash
scripts/sf/sf-agent --relogin     # agent store
scripts/sf/qa-login.sh --prod-org <your-email> --jwt --key-file ~/.sf/sfjwt-prod.key --alias qa
```

Mechanism and failure modes: `docs/runbooks/qa-sandbox-auth.md`.

#### Scratch orgs from a JWT-authed Dev Hub need the 1717 callback (<clickup-task-id>)

`sf org create scratch` sends the hub's client id plus `http://localhost:1717/OauthRedirect` as
`ConnectedAppCallbackUrl` (`@salesforce/core/lib/org/scratchOrgInfoGenerator.js:155`). The JWT app
`OCC_Orchestrator_Agent` must list that URL, or creation fails with
`INVALID_INPUT: The callback URL provided is not valid` (`fields: [ 'ConnectedAppCallbackUrl' ]`).
The callback was added 2026-10-06 (<your-name>-approved; prod deploy `0AfU1000002mhZNKAY`). A connected-app
edit takes a few minutes to propagate: the first create ~30s after the deploy still failed.
(empirical (2026-10-06): under an isolated `HOME` + `SF_USE_GENERIC_UNIX_KEYCHAIN=true`, JWT hub
`<your-email>` created scratch `<sf-org-id>` at 15:52Z, then deleted it with `sf org delete scratch`.)

```bash
H=$(mktemp -d)
(   # subshell: HOME/XDG overrides end with it; the real store is never touched
  export HOME=$H XDG_DATA_HOME=/Users/<your-username>/.local/share SF_USE_GENERIC_UNIX_KEYCHAIN=true
  sf org login jwt --client-id "$CK" --jwt-key-file /Users/<your-username>/.sf/sfjwt-prod.key \
    --username <your-email> --alias hub --set-default-dev-hub &&
  sf org create scratch -v hub -f salesforce/config/project-scratch-def.json -a mut -y 1 -w 20 &&
  # ...use the scratch org...
  sf org delete scratch -o mut --no-prompt
) || { rc=$?; echo "scratch step failed (rc=$rc); auth store kept at $H for cleanup" >&2; exit $rc; }
rm -rf "$H"
```

**A web login does not substitute.** `sf org login web` stores a user session in the *interactive*
keychain, which the agent auth store cannot read; an agent shell still sees
`No authorization information found for qa` while your own terminal works fine. Anything running
unattended (the poller, CI, `sf-agent`) needs the JWT path, so the rotation is not optional.

**Blast radius while stale:** every `sf project deploy validate --target-org qa` from an agent or
CI — which is the mandatory gate on all `salesforce/force-app/**` work per
`.claude/rules/plan-grounding.md` gate 4.

⚠️ **`XDG_DATA_HOME` must be pinned back to the real home**, which the wrapper does. oclif
auto-updates the CLI into `$XDG_DATA_HOME/sf/client` and prefers it over the base install;
moving `HOME` without the pin silently drops the agent onto the older base CLI —
(empirical (2026-08-06): `2.123.1` under a bare `HOME` override vs `2.143.6` with the pin).

| Context | Store | Keystore |
|---|---|---|
| <your-name>'s interactive terminal, Claude Desktop SF MCP | `~/.sfdx/` | macOS keychain |
| Claude Code / daemon shells (via `sf-agent`) | `~/.sf-agent/.sfdx/` | file (`key.json`) |

The two are independent — re-authing either one leaves the other alone. Verified 2026-08-06 by
destroying `~/.sf-agent`, running `--relogin`, and confirming `~/.sfdx/<your-email>.json` was
unchanged.

Staff-facing companion (per `.claude/rules/engineering-doc-dual-home.md`):
[Salesforce CLI in agent sessions — the keychain-free auth store](<internal-url>).

### Programmatic Lead inserts are re-routed — set Skip_Automation__c or Lead_Temperature__c

`Lead_Auto_Assign_to_SDR` (Active, `RecordAfterSave`, `CreateAndUpdate`) routes on
`Lead_Temperature__c`: Hot/Warm to the logged-in BDR (Peyton Boyd fallback); **Cold or null to the
`Unassigned Leads` queue with `Status='Unassigned'`**. An insert that specifies `OwnerId` and
`Status` will have BOTH silently overwritten when temperature is null.

```apex
// Suppress all Lead automation (6 flows honor this entry condition — batch imports)
new Lead(..., Skip_Automation__c = true, OwnerId = someUser, Status = 'Working')

// Or route deliberately by setting temperature
new Lead(..., Lead_Temperature__c = 'Hot')
```

A post-insert `update` DOES stick: the flow's `Still_Unassigned` decision is gated on
`$Record.OwnerId`, so it will not re-route an already-assigned lead. That is the recovery path if
you have already inserted.

Notification actions (`Send_BDR_Email`, `Send_Manager_Email_BDR`, the Peyton fallback + scheduled
variants) sit only on the Hot/Warm/fallback branches — the cold/queue path assigns silently, so a
bulk insert of temperature-less leads does not email anyone.

(empirical (2026-08-06), <clickup-task-id>: 3 leads inserted with explicit `OwnerId`/`Status` all landed
`Unassigned / Unassigned Leads`; post-insert update held. Behavior source: `docs/changelog.md:34`,
suppression field: `docs/lead-stage-updates-announcement.md:382`.)

### Merging duplicate Contacts (Database.merge)

`sf` has no merge command — use `apex run` with `Database.merge`. Two constraints bite:

1. **Both contacts must share an `AccountId`.** Reparent the victim to the master's account first.
2. **Reparenting fails if the victim's owner is inactive:**
   `CANNOT_REPARENT_RECORD, owner is inactive, cannot reparent record`. Reassign `OwnerId` to an
   active user *before* the reparent.

```apex
Contact m = [SELECT Id, AccountId FROM Contact WHERE Id = :masterId];
Contact v = [SELECT Id, AccountId, OwnerId FROM Contact WHERE Id = :victimId];
v.OwnerId = activeUserId;                                                 // step 2 — before reparent
update v;
if (v.AccountId != m.AccountId) { v.AccountId = m.AccountId; update v; }  // step 1
merge m v;                                                                // master first, victim second
```

**Duplicate rules interact with renames and inserts.** Giving a placeholder contact its real name
can trip `DUPLICATES_DETECTED` ("You're creating a duplicate record") because the renamed record now
matches an existing one — that failure is a *signal the two should be merged*, not something to
override with `DuplicateRuleHeader.allowSave`. Likewise, a `Lead` insert fails with
`DUPLICATES_DETECTED` while a Contact on the same email exists; delete or merge the Contact first.

(empirical (2026-08-06), <clickup-task-id>: 12 pairs — 10 merged clean, 2 failed `CANNOT_REPARENT_RECORD`
until the inactive owner was reassigned, and 12 of 47 renames were blocked by duplicate rules,
correctly identifying merge candidates.)

### `deploy report --use-most-recent` returns partial counts mid-run

The report renders whatever the job has completed so far. A still-running validation shows a
plausible-looking summary — e.g. `Passing: 27  Failing: 0  Total: 457` — that is neither the final
result nor flagged as partial. `Passing + Failing < Total` is the tell.

Never report a validation as passed from a report snapshot. Wait for the terminal line
(`Validated Source` / `FailedValidationError`) or re-run the command with `--wait` and read its exit
status.

(empirical (2026-08-06), <clickup-task-id>: a permission-set validate reported 27/0/457 mid-flight and was
relayed as "qa validate passed"; the completed run returned `FailedValidationError` on two
`QuotaRenewalReminderTest` methods failing `NO_SINGLE_MAIL_PERMISSION` — a qa deliverability
setting, unrelated to the diff, but the gate was red and had been called green.)

## Common Operations

### Via API / CLI

#### Validate in qa first

For any deploy that mutates schema, Apex, or metadata-that-activates-flows, run it against `qa` BEFORE prod validate. Before <your-name> signs off QA, deploy with `--test-level NoTestRun` (no test run; `deploy validate` runs once at the epic PR):

```bash
cd salesforce && sf project deploy start --target-org qa --source-dir <path> \
  --test-level RunSpecifiedTests --tests EmailAddressNormalizer_Test
# AE work: after the deploy succeeded, stamp the AE Console build (last line; see "qa-apex-sync.yml" below)
bash ../scripts/sf/stamp-ae-build.sh qa
```

**Required for:**

- New or modified Apex classes / triggers (deploy compile + test results may differ between orgs if dependent metadata drifted)
- Destructive deploys (`/retire-field` Phase 0 — see `docs/runbooks/salesforce-field-retirement.md` Phase 0)
- Metadata changes that activate flows (a Draft flow deploys clean against validate but only fails at activation time)

**Not required for:**

- Declarative changes (page layouts, permission set assignments, list views) — visually tested in qa already or trivially reversible in prod
- Read-only Tooling queries

**Never deploy mutated metadata to `qa` (<clickup-task-id>).** `qa` is shared: other cards deploy and migrate there while yours runs. Mutation verification (breaking the code on purpose to prove a test goes red) runs as local Jest/unit tests, or deploys the mutated copy to a scratch org only and runs `sf apex run test` there. In `qa`, `sf apex run test` runs against unchanged code only, and only the real, unmutated change is deployed or validated there. The dispatch prompts (`~/.claude/bin/exec/prompts/dev.txt`, `codex_dev.txt`) carry the same rule; `.claude/rules/test-class-matrix.md` "Mutation-verify" owns it. (empirical (2026-10-05): <clickup-task-id> deployed a deliberately broken `Lead_AE_Apply_DNC` into qa while Phase 2 was migrating there; `sf data query --use-tooling-api -o qa -q "SELECT VersionNumber, Status, LastModifiedDate FROM Flow WHERE Definition.DeveloperName='Lead_AE_Apply_DNC' ORDER BY VersionNumber DESC LIMIT 4"` returns v8 18:40:07Z, v9 18:42:39Z, v10 18:46:26Z Active.)

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

**Bulk retrieve clobbers tracked working-tree files.** A wide `sf project retrieve start -x <package.xml>` (or `--metadata Flow` / `--source-dir`) overwrites every matching file in the working tree with the org's current version — including files you committed earlier in the same session and intended to leave untouched. It can also **delete** tracked files the retrieve doesn't return. Empirical <clickup-task-id> (2026-05-25): a bulk Flow retrieve into the worktree clobbered already-committed Lead/Dispatch retrofit edits and deleted unrelated tracked flows. Two safe patterns:

- **Retrieve into a temp SFDX dir** (`sf project retrieve start -x /tmp/pkg.xml --output-dir /tmp/retrieve-scratch`), then copy only the file(s) you want into the worktree.
- **Or retrieve in place, then restore intended-untouched files** immediately after:
  ```bash
  git status                       # see what the retrieve overwrote/deleted
  git checkout -- <paths-to-keep>  # restore committed/intended files
  ```

Never run a bulk retrieve in a worktree with uncommitted or session-committed work without one of these guards.

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

#### LeadConvertSettings (lead conversion field mappings)

Native Lead→Account/Contact/Opportunity custom-field mappings, edited in Setup via Object
Manager → Lead → Fields & Relationships → "Map Lead Fields". Source-controlled under
salesforce/force-app/main/default/leadConvertSettings/ — **git is canonical**; UI edits must be retrieved + committed or the next deploy reverts them.

- **Filename casing matters:** the file must be named LeadConvertSettings.LeadConvertSetting-meta.xml.
  A lowercase *.leadConvertSetting-meta.xml suffix fails CLI deploy with `TypeInferenceError: Could not
  infer a metadata type` (empirical (2026-06-12): sf CLI 2.135.7, <clickup-task-id> probe).
- **Mappings apply via `Database.convertLead`** — all conversion paths (screen flow, quick action,
  API), not just the standard Convert UI (empirical (2026-06-12): qa probe, <clickup-task-id> spec [P5]).
- **Mappings write ONLY newly-created records** — converting into an existing account leaves the
  mapped target fields untouched (empirical (2026-06-12): qa probe, <clickup-task-id> spec [P5]/[P6]).
- **Constant-carrier pattern:** a mapping can only copy a Lead field's value (no literals). To map
  a constant, create a Lead formula field returning the constant — e.g.
  `Lead.Account_Status_On_Convert__c` (formula Text `"SQL"`) → `Account.Status__c`, which makes
  every conversion-created account land as SQL (<clickup-task-id>). Formula-Text source → restricted-picklist
  target deploys and works (empirical (2026-06-12): qa, spec [P6]).
- **Restricted-picklist coupling:** if a mapped target value (e.g. `SQL` in `Account.Status__c`) is
  deactivated, conversions creating new records fail org-wide — the <clickup-task-id> drift class. The repo's
  Status__c field metadata is aligned to prod; do not deactivate `SQL` without removing the mapping.
- Retrieve: `sf project retrieve start --metadata LeadConvertSettings -o <your-email> --target-metadata-dir /tmp/lcs`

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

- Flow tests do NOT exercise external HTTP callouts — assert on pre-callout state instead, OR pair with an Apex test that uses `HttpCalloutMock` if the callout is the behavior under test (docs-confirmed). Example: `Send_Teams_Alert` invokes an Apex action that posts a Teams webhook (`<actionType>apex</actionType>`); its happy path is un-flow-testable. Its callout Apex is covered separately by `TestSendWebhookNotification` (empirical (2026-06-07)).
- Flow tests credit flow-element coverage but do NOT credit `@InvocableMethod` Apex coverage when the flow calls one — Apex methods invoked from flows still need direct Apex test coverage (see `.claude/rules/salesforce-dev.md`).
- **Flow tests cannot drive `<scheduledPaths>`.** A flow whose only connected path is a scheduled (time-offset) entry has no test point a flow test can reach. Example: `P1_SLA_15_Minute_Alert`'s `<start>` has no immediate connector — its only path is a 15-min `<scheduledPaths>` from `CreatedDate`. Excluded as structurally un-testable (empirical (2026-06-07): baseline run returned Error). Cover the breach logic with an Apex unit test that invokes the action directly instead.

### `sf flow run test` runs the ACTIVE flow version — a flow with no active version cannot be tested

The single most load-bearing constraint, and the easiest to miss: `sf flow run test`
executes a flow's **active** version. If `FlowDefinition.ActiveVersionId IS null`, the
test run produces **blank runtime** and reports `Fail` (not Error) at every assertion —
the flow simply never executes, so the asserted `Finish` (or any element) is never reached.

Probe before authoring tests for a flow:

    sf data query --target-org qa --use-tooling-api \
      -q "SELECT DeveloperName, ActiveVersionId FROM FlowDefinition WHERE DeveloperName='<Flow>'"
    # ActiveVersionId = null  -> the flow is inactive; flow tests will Fail with blank runtime

Deploying the flow's metadata to qa does NOT make it testable if it lands as **Draft**
(qa "deploy as active" only auto-activates source flows whose `<status>` is `Active`; a
`Draft`-status source stays Draft → still no active version). You must activate the flow
for its tests to execute. **Do not activate an `EmailMessage` `RecordAfterSave` flow just
to test it** — an unhandled fault in such a flow rolls back the entire Email-to-Case
transaction (see `.claude/rules/salesforce-dev.md` "After-save flows on EmailMessage").
Activating a flow that is inactive in prod by design is a separate, human-gated decision.

**Precedent (<clickup-task-id>, 2026-06-07):** `Inbound_CC_Capture` is `ActiveVersionId = null` in
both qa AND prod. Hand-rolled `_basic/_no_cc/_multi_cc` flowtests all returned `Fail` with
blank runtime regardless of input or assertion element. Root cause was the missing active
version, not the test XML. Flow tests + the paired Apex bulk test were deferred (recorded in
the flow-test allowlist EXCLUDED block) until the flow's activation is confirmed-intended.

#### The inverse: activating a flow can break unrelated Apex tests

Activating a record-triggered flow that grants a `PermissionSetAssignment` (or writes any
row) on insert makes that side effect visible to **every** Apex test in the org that inserts
the same kind of record — including test classes the change never touched. `RunLocalTests`
then fails a PR whose diff is entirely unrelated to the flow.

The tell is an assertion scoped by *shape* rather than by *identity*:

    // fragile — counts every non-profile PSA, including ones org automation created
    System.assertEquals(0, [SELECT COUNT() FROM PermissionSetAssignment
        WHERE AssigneeId = :u.Id AND PermissionSet.IsOwnedByProfile = false]);

Scope such assertions to the specific permset the code under test is responsible for, or
exclude the known baseline explicitly. The assertion is about what the class did, not about
every row that exists on the user afterwards.

**empirical (2026-09-05): <clickup-task-id>.** Activating `User_Assign_Baseline_FLS` in qa (it grants
`Default_Field_Access` asynchronously on user insert) made
`AssignAppPermSetsActionTest.skipsUnresolvablePermSetWithoutThrowing` fail with
`Expected: 0, Actual: 1` — `Test.stopTest()` flushes the flow's async assignment before the
count runs. It surfaced as a CI failure on PR #1354, a Phase C PR touching no
`AssignAppPermSets*` file, and was misread there as a `delta_gate` crash (the gate step is
skipped when the validate step fails, so the workflow's `if: always()` comment step posts a
generic "crashed before writing a comment" fallback — see `.github/workflows/apex-test.yml`).
Diagnose that message by reading the *validate* step, not the gate.

### CLI cannot surface per-assertion detail

`sf flow run test` (and `sf flow get test -i <id>`) reports only `Pass` / `Fail` / `Error`
per test — the `MESSAGE` column and `FlowTestResult.Result` are empty even on a synchronous
run (empirical (2026-06-07): `FlowTestResult.Result` = the bare string `Fail`, no assertion
detail). For root cause, run `--synchronous`, then inspect the failing test point in the SF
UI (Flow Builder → **Tests** tab → open the run). `FlowTestResult.FlowVersionNumber` does
confirm which version executed — useful for verifying a freshly-deployed version is the one
under test.

### Advisory allowlist CI pattern

`.github/workflows/apex-test.yml` carries a non-gating `flow-tests` job
(`continue-on-error: true`, `needs: [changes, apex-test]`) driven by
`salesforce/config/flow-test-allowlist.txt` — one flow API name per uncommented line; the
EXCLUDED block at the bottom records each un-runnable flow + reason. The job:

- **deploys ONLY `force-app/main/default/flowtests` to qa, never `flows/`** — deploying a
  flow through the Metadata API can corrupt dotted relationship-field refs server-side
  (precedent <clickup-task-id> → `null__NotFound`). Tests run against the flows already active in qa.
- runs the allowlisted tests **one flow at a time, synchronously**, because
  `sf flow run test --synchronous` accepts only ONE flow per call ("Synchronous test runs can
  include tests from only one Flow") and `--wait` is valid **only** with `--synchronous`.
  Passing the whole space-joined allowlist to a single `--synchronous` call fails; the loop
  reads each flow's pass/fail immediately (empirical (2026-06-07)).
- posts the results as an advisory PR comment and never blocks the required
  `Apex tests + delta coverage gate` check.

A flow is added to a runnable allowlist line ONLY after it runs green against qa (paste the
`--synchronous` Pass output first) — never on intent alone.

## CI coverage gate (`scripts/sf_coverage/`)

The `.github/workflows/apex-test.yml` workflow spins a per-PR scratch via
`salesforce/scripts/seed/setup-scratch.sh`, runs `sf apex run test
--code-coverage --json`, and feeds the result to
`scripts/sf_coverage/delta_gate.py`.

The gate asserts >= 85% line coverage on every Apex class that this PR adds,
modifies, copies, or renames. Renamed classes follow old→new path; deleted
classes are excluded.

### Changed-class coverage: the gap is usually pre-existing branches, not your new lines

When the gate flags a *changed* class below 85%, the uncovered lines are frequently
**pre-existing** untested branches (exception `catch` blocks, callout-budget paths) — not the
code you added. Adding a test for your new lines won't move the number. Pull the *actual*
uncovered line numbers from the validate JSON and cover those:

```bash
sf project deploy validate -o qa --test-level RunSpecifiedTests --tests <Class>_Test \
  -m ApexClass:<Class> -m ApexClass:<Class>_Test --json \
  | python3 -c "import json,sys;[print(sorted(int(x['line']) for x in c.get('locationsNotCovered',[]))) for c in json.load(sys.stdin)['result']['details']['runTestResult']['codeCoverage'] if c['name']=='<Class>']"
```

Common quick win: a mock whose `respond()` does `throw new CalloutException(...)` covers the
callout-exception fault path. **Precedent (<clickup-task-id>, 2026-06-07):** `Teams_Notifier` 84.8%→88.8%
via a `ThrowingMock` — the new `subhead`/`blankAfterTitle` puts were *already* covered; only the
pre-existing exception branches were missing.

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

Default: combine same-epic PRs that touch the same files into one PR. Review and validate the combined diff under the existing required checks.

### What the validate covers (<clickup-task-id>)

- **Trigger:** the `changes` job's `sf` filter matches every `salesforce/force-app/**` path (including `*.cls-meta.xml` / `*.trigger-meta.xml`), plus `sfdx-project.json`, `scripts/sf_coverage/**`, the workflow, and the flow-test allowlist. Before <clickup-task-id> it matched only `.cls`/`.trigger` and flows, and the manifest ignored everything but Apex. A flow, permset, flexipage, layout, or LWC-only PR therefore passed the required gate without any qa validate.
- **Manifest** (`id: manifest`): every added/modified/renamed `force-app` file becomes one line in `/tmp/sf/source-dirs.txt`. `.cls`/`.trigger` and their `-meta.xml` become the source + meta pair. `objects/<Obj>/**` becomes the whole object dir, and `lwc/<b>/**` / `aura/<b>/**` become the bundle dir. Everything else is passed as the file itself. The validate step reads the file into a bash array, because 233 tracked `force-app` paths contain spaces (layouts). Deleted files follow the Deletions validation below.
- **Test level (<clickup-task-id>):** PRs use `scripts/ci/select-apex-tests.sh` with the newline-delimited changed-file list (`bash scripts/ci/select-apex-tests.sh <changed-files> [source-root]`; default root `salesforce/force-app`). It emits `test_level`, `tests` (sorted, deduplicated CSV) and `reason`. The validate step splits that CSV into separate `--tests` arguments; it does not pass a comma-delimited class name to the Salesforce parser. For each changed Apex class or trigger, selection includes `<Name>Test` / `<Name>_Test` when present, every `@isTest` class with a direct source reference to the changed name, and any changed test class itself. `RunSpecifiedTests --tests …` is used only when selection passes the fallback checks below. Full `RunLocalTests` runs against qa only on the nightly schedule (`0 7 * * *`, 07:00 UTC) and `workflow_dispatch`; their manifests contain tracked Apex classes and triggers only. Main pushes no longer validate qa; `qa-apex-sync.yml` still syncs merged metadata. Metadata-only PRs without flows or Apex retain `RunSpecifiedTests --tests EmailAddressNormalizer_Test` and skip the coverage steps and sentinel guard.
- **Full-run failure notification:** failed nightly and manual Apex jobs invoke the QA sync notification path (`scripts/ci/notify-qa-sync-failure.sh --dedup-alert`) in a separate job; PR events do not run it. It sends an A&E Teams Adaptive Card and creates an A&E ClickUp tracking card with the run URL, without PR fields. A stable node/error key shares one open incident across these events. After successful Teams delivery the incident gets an `alerted:<dedup hash>` tag; subsequent failures while that incident is open suppress channel alerts. Failed delivery can be retried; closing the incident permits a fresh alert. The notification queue serializes lookup/delivery, and the required check names and gate remain unchanged. Investigate the linked log and close the card once resolved.
- **Flow test mapping:** first select named tests (`<Name>Test` / `<Name>_Test`) and tests whose stripped source references the flow API name. If none match, read the flow XML trigger object and invoked Apex classes (`actionType=apex` / `actionName`, or `apexClass`); map matching object triggers using their own tests and tests for existing non-test classes identified in each stripped trigger body. Map those classes and invoked classes using the changed-class rules: named tests (`<Name>Test` / `<Name>_Test`) plus direct references, with at least one direct reference required for a non-test class; invoked classes that are tests select themselves. Extracted names must match `^[a-zA-Z0-9_]+$`; invalid names fall back to the full suite. If no tests map or the deduplicated union for a flow exceeds `APEX_TEST_MAX_FLOW_TESTS` (default `25`), retain `unmapped_flow:<Name>`; successful selection reports `mapped_tests`. The flow limit must be a positive integer no greater than `2147483647`; invalid values return `invalid_flow_test_limit`.
- **Targeted-test fallback:** `RunLocalTests` is selected when a changed class/trigger lacks a mapped test, a changed flow has no mapping after the flow lookup above, a changed source is missing/deleted, more than `APEX_TEST_MAX_CLASSES` classes changed (default `15`), or a changed non-test class has no selected test that directly references its identifier. Comment text and string literals are stripped before the identifier check; indirect execution alone is insufficient. This deterministic static check cannot measure or establish 75% per-class coverage: a direct reference may exercise fewer lines, and a mapped test may use indirect execution that the selector rejects. Salesforce still enforces 75% per-class coverage for `RunSpecifiedTests`; the delta coverage gate also remains active. Read `reason` in the selection step to identify a fallback. Flow-name strings do not prove Apex class coverage and are excluded from the direct identifier check.
- **All-forceignored change:** `sf project deploy validate` returns `NothingToDeploy` ("No local changes to deploy.") when every path is in `.forceignore` (empirical (2026-10-05): `--source-dir …/externalCredentials/SF_Teams_Relay_Cred.externalCredential-meta.xml` against qa). The step treats that result as a pass. The manifest step fails a PR that changes `salesforce/.forceignore` together with any `force-app` file. A `.forceignore` edit changes which files the validate covers, in both directions: it can hide the PR's own changes and turn the validate into a `NothingToDeploy` pass, or it can unignore files main still ignores. Land a `.forceignore` change in its own PR (it deploys nothing). Later PRs then validate under main's rules.
- **`.forceignore` in the change filter:** `salesforce/.forceignore` is in the `sf` filter, so the manifest's refusal runs.
- **Deletions are validated** (<clickup-task-id>). The manifest restores each deleted `force-app` file from `origin/main` into the tree and lists it in `/tmp/sf/deleted.txt`. A file removed from an `lwc`/`aura` bundle that still exists in HEAD counts as a bundle edit, so the validate covers the whole bundle instead. The validate step builds `destructiveChangesPost.xml` with `sf project generate manifest --type post`. Restored copies are removed, along with empty restored directories, before `package.xml` is built and before validate runs (<clickup-task-id>); this prevents a deleted field under a changed object from appearing in both manifests. It also builds `package.xml` from the changed sources, or writes an empty package for a deletion-only PR. It then runs `validate --manifest … --post-destructive-changes …`, because `--post-destructive-changes` requires `--manifest` (empirical (2026-10-05), sf 2.143.6: "All of the following must be provided when using --post-destructive-changes: --manifest"). Generating the manifest in-tree honors `.forceignore` (empirical (2026-10-05)): when every deleted path is ignored, the result has no `<types>` and nothing destructive is validated. A partial deletion (one half of an Apex, trigger, or email template pair; a static resource’s content or meta alone; an object file while its dir keeps files) fails with `Partial deletion:` errors naming every offending path (<clickup-task-id>). Removing a file from a folder static resource validates the remaining resource as an edit; removing its last file while its meta remains fails as a partial deletion. Whole-component deletions continue to validate destructively. A deleted `.cls`/`.trigger` runs `RunLocalTests`. The diffs use `--no-renames`, so a rename becomes a destructive delete of the old name plus a validated add of the new one.
  - **Composed live probe** (empirical (2026-10-05), qa): the real `manifest` and `apex-test` step scripts ran over a commit that deleted `objects/Account/listViews/Accounts_by_Type`. Validate failed: "This list view is referenced elsewhere … flexipage:filterListCard … Finance". Before this change, that PR would have passed the gate without any validate. Deleting `objects/Case/listViews/Accounts_Payable` passed (`0Afic0000005DELCA2`, 1 component, 16 tests).
  - Deleting a component that qa does not have fails the validate ("No <Type> named: <name> found"). That is a qa-drift failure, so it is advisory only on a provenance-checked sync PR.
- **Weekly metadata-sync PRs are advisory:** a sync PR (`weekly-metadata-sync.yml`) mirrors production, so a qa validate failure on it reflects qa drift (for example in-flight epic work deployed to qa), not a defect in the PR. A single script decides what counts as a sync PR: `scripts/ci/metadata-sync-pr.sh`. It runs in the `changes` job, and its `metadata_sync` output feeds both the coverage advisory and the gate. `fls-parity.yml` runs the same script. Every input comes from `github.event`. A PR qualifies only when all of the following hold: author exactly `<internal-name>[bot]`, head ref matching `^chore/metadata-sync-[0-9]{8}-[0-9]+$`, head repo equal to this repo, and a PR file list that is complete (its length equals `changed_files`) and contains only `salesforce/force-app/` paths, which is all the sync stages. The PR's current head SHA must also carry provenance: an unedited comment by `<internal-name>[bot]` containing `<!-- metadata-sync-provenance: <sha> -->`. `weekly-metadata-sync.yml` posts this comment right after it pushes, and only the CI App token can author as that bot. The PR checks can start before the comment exists (on #1397 `Detect SF changes` started 8 s after the PR opened), so `metadata-sync-pr.sh` waits for it, and only for a PR that already passed the author / branch / repo / complete-`force-app`-file-list checks: it re-reads the comments up to `PROVENANCE_WAIT_TRIES` times (default 12) every `PROVENANCE_WAIT_S` seconds (default 10, so at most 110 s of sleep with the defaults; no workflow sets either knob). A non-numeric value, or a `PROVENANCE_WAIT_TRIES` below 1, falls back to the default, so an override cannot disable the check or make the loop endless. An API error on the comments read still disqualifies at once, without retry. A head SHA with no matching comment returns `false` after the window (<clickup-task-id>). Any later push, by anyone, moves the head and voids the provenance. An API error disqualifies the PR. A branch name, label, title, or body never qualifies a PR on its own. Live check (2026-10-05): #1397 and #1474 both return `false`. #1397 predates provenance comments, so its validate is blocking. The next weekly sync PR carries provenance. For a PR that passes all of these checks, a validate result of `failure` passes the required `Apex tests + delta coverage gate` with a `::warning::` and a PR comment linking the run. `cancelled`/`skipped` validate results and change-detection failures still fail the gate. The `Apex validate (qa)` job itself still shows red. The advisory applies only when the validate step itself failed (`steps.apex-test.outcome == failure`, exposed as job output `validate_outcome`). It also requires that none of the steps that run after a validate failure (`soql`, `pr_comment`, `sentinel`; job output `later_failed`) failed as well. The advisory also requires that qa returned a validation result: the validate step writes `rejected=true` only when `sf` fails with `FailedValidationError` and a Salesforce `data.deployId` (`0Af…`), and `sf project deploy report --job-id <id> --target-org qa --json` returns `result.status` `Failed` with `result.checkOnly` `true` (job output `validate_rejected`). A `Canceled` or `Canceling` validate gets no advisory. A CLI, auth, connection, polling-timeout, unparseable-output or manifest error blocks the PR (<clickup-task-id>). A real validation failure has no `result.details` (empirical (2026-10-05), run 37354378806), so component/test-failure arrays cannot distinguish qa drift from command errors. A failure in CLI install, qa auth, manifest generation, or any of those later steps still blocks the PR (<clickup-task-id>). A contract test fails if a new `always()`/`failure()` step is added after the validate without being included in `later_failed`.
- **Gate inputs fail closed:** the gate treats a PR as having no Salesforce changes only when `needs.changes.outputs.sf` is exactly `false`. An empty or missing output fails the gate (<clickup-task-id>).
- **Queue:** the `sf-qa-validate` group (PR/main/manual/nightly validate jobs and `qa-apex-sync.yml`) uses `cancel-in-progress: false` and `queue: max`. The default `queue: single` cancels the older pending run every time another run joins, and that cancelled the #1397 and #1490 validates on 2026-10-05.
- **Contract:** `scripts/sf/tests/test_apex_required_check_reports.py`. It runs the real `manifest`, `apex-test`, and gate `resolve` / advisory-comment step scripts against a fixture git repo and stub `sf` / `gh`.

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

### qa drifts from main → stale classes flake the gate for EVERY PR

`apex-test.yml` validates the PR delta over qa's currently deployed metadata.
Merges to `main` touching `salesforce/**` trigger source catch-up through
`qa-apex-sync.yml` (scope and queue below). Drift can still remain while catch-up
is queued, after a failed sync or sandbox refresh, for components deleted from
main, and for intentionally excluded QA configuration. A class outside the PR
still runs at qa's deployed version. A stale class/test can fail a targeted run
that includes it or a full `RunLocalTests` run; probe the deployed source and the
catch-up run before attributing a failure to the PR.
Diagnose suspected drift by diffing the qa-deployed body against `main`:

    TOKEN=$(sf org display --target-org qa --json | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['accessToken'])")
    INST=$(sf org display --target-org qa --json | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['instanceUrl'])")
    curl -s "$INST/services/data/v66.0/tooling/query/?q=SELECT+Body,LastModifiedDate+FROM+ApexClass+WHERE+Name='<Class>'" \
      -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json;r=json.load(sys.stdin)['records'][0];print(r['LastModifiedDate']); print('HAS <marker>:', '<marker-string>' in r['Body'])"

Fix: bring qa current for the affected class — `sf project deploy start
--target-org qa --metadata ApexClass:<Class>` (run from `salesforce/`, NOT the
repo root — the SFDX project lives there; the root errors with
`InvalidProjectWorkspaceError`). A class that references a `@TestVisible`
field/method added later (e.g. `FlowFaultRecorder.testForceRetry`) will fail to
deploy against a stale impl (`Variable does not exist: <field>`) — deploy the
impl AND test together.

**Precedent (<clickup-task-id>, 2026-06-07):** the gate's two RunLocalTests failures
(`QuotaRenewalReminderTest` ×2 `NO_SINGLE_MAIL_PERMISSION`) looked like a qa
*deliverability* gap. The real cause: qa's `QuotaRenewalReminder` was from
2026-03-13 — it predated the try/catch added 2026-05-17 (PR #588) that swallows
`System.EmailException` and continues. The tests assert the dedup stamp (a
business outcome), not email-was-sent, so deploying the current class to qa made
all 6 methods pass **with deliverability untouched** (`System email only`) — no
real-email blast radius. Probing first avoided enabling `All email` on a
Partial-Copy sandbox with 32 active scheduled jobs (incl. a client-follow-up
email flow) against unmasked prod contacts.

**Orphan tests in qa+prod but not in the repo** also flake the gate and can't be
fixed via a PR. Find these via `grep -rl '<Class>' salesforce/` (empty = orphan);
resolve by retrieving+committing+fixing or deleting from both orgs.

**Resolved (<clickup-task-id>, 2026-06-07): `BusinessHoursElapsedTriggerTest`.** Deployed
2026-05-15, absent from the repo; its `BusinessHoursElapsedTrigger` (Active, on
`Case_Work_History__c`) was also orphaned. Both retrieved verbatim into
`force-app/main/default/{triggers,classes}` (first `triggers/` dir in the repo).
Root cause of the flake — the **now()-anchored BusinessHours test anti-pattern**:
the test set windows via `BusinessHours.nextStartDate(bhId, Datetime.now())`. The
`Tech Support` schedule is Mon–Fri 24h / weekends closed (ET), so on a weekend
`nextStartDate(now())` returns a *future* Monday open and the inserted record's
window mis-evaluates → `testElapsedTimeOnInsert` Actual: 0.00 (reproduced live in
qa: verbatim 5/6, deterministic 6/6). **Fix:** anchor to fixed past-weekday
datetimes via `Datetime.newInstanceGmt(...)` (GMT → no running-user-TZ dependence);
never `Datetime.now()` for a BusinessHours.diff assertion. Also fixed a side drift:
the repo's `salesforce-flows` `Elapsed_Time_Mins__c.field-meta.xml` was a
`<formula>` while prod is `Number(18,2)` (trigger-populated) — deploying that
package would have converted prod→formula, wiping data + breaking the trigger DML.

### qa-apex-sync.yml — auto-deploy merged source → qa (<clickup-task-id>)

`apex-test.yml` validates the PR delta over qa's deployed metadata. The existing
`qa-apex-sync.yml` catch-up workflow updates merged source while preserving the
AE driver's QA configuration used for cutover rehearsal.

- **Trigger:** every `push` to `main` with a `salesforce/**` change. The sandbox-refresh completion (`workflow_run` of "Sandbox Refresh") and manual (`workflow_dispatch`) triggers deploy the FULL `salesforce/force-app` tree (<clickup-task-id>): a refreshed qa is rebuilt from prod and lacks every object/flow/LWC the main-only classes reference (run 38107277470 failed with "Invalid type: AE_Build_Info__c" when only classes were deployed). They call `select-qa-source.sh . --full`, run `scripts.sf_coverage.qa_unavailable` over the checkout (same allowlist as PR validate), deploy with `NoTestRun`, then restore the stripped files before the build stamp.
- **Immutable source:** push runs check out the event's merged SHA, fetch full history and pass `github.event.before` → `github.sha` to `scripts/ci/select-qa-source.sh`. Selection rejects zero/unavailable bases, a checkout not matching the event SHA, and dirty or untracked Salesforce source before authentication. It does not edit the source being deployed.
- **Scope:** push runs: the complete tracked Apex class and trigger set on each run, plus the changed items below. Refresh and manual runs: the full `force-app` tree (see Trigger). Push runs also deploy changed flow, Visualforce page and component files; object changes deploy their complete surviving parent object directories, matching the PR validate manifest. LWC, Aura and static-resource changes deploy their complete surviving bundles/content-meta pairs. A removed object or bundle member deploys the remaining directory source. Removed components are not deleted from qa: no destructive manifest is generated.
- **AE Console build stamp (<clickup-task-id>):** the step `Stamp AE build in qa` runs right after the deploy step, only when `steps.source.outputs.available == 'true'` and the deploy step succeeded, with `bash scripts/sf/stamp-ae-build.sh "$QA_ALIAS" --expect-sha "$GITHUB_SHA"` (push events). It sets the org-default `AE_Build_Info__c` row to build + 1, the deployed HEAD sha and the UTC time; the AE Console footer reads it. Nothing in the checkout changes, and it runs inside the `sf-qa-validate` group so the counter cannot race another run. The script refuses a dirty checkout, a HEAD that is not the pushed commit, and a failed deploy. Manual deploys end with `bash ../scripts/sf/stamp-ae-build.sh qa` (after `deploy start` succeeded); prod is a production data write with per-action approval (`ae-lifecycle-cutover.md` D1). Contract: `bash scripts/sf/tests/test_stamp_ae_build.sh`; details in `ae-console.md` "Footer build stamp".
- **Configuration boundary (push runs; refresh/manual runs deploy profiles and permission sets too, after qa-unavailable stripping):** profiles, permission sets, settings, configuration and data are excluded. No QA data, org configuration or permission/configuration reset is performed. A configuration-only push still triggers catch-up of the existing Apex source set; it does not copy that configuration to qa.
- **Concurrency:** shares `sf-qa-validate` with PR, main/manual and nightly validates, with `cancel-in-progress: false` and `queue: max`. Wait for running/queued deploys and validates; do not cancel them. Killing a CLI/workflow does not remove a queued Salesforce deploy.
- **Deploy:** the selected paths become repeated `--source-dir` arguments to `sf project deploy start --target-org qa --test-level NoTestRun --wait 30 --json`, run from `salesforce/`. Deploy-only skips tests as permitted for sandbox catch-up after the PR gate. `.forceignore` remains honored. An empty source selection skips authentication and deployment.
- **Auth:** the existing prod JWT login plus `scripts/sf/qa-login.sh --prod-org sf-prod-auth` supplies QA authentication; the deploy target is qa. This workflow does not deploy to production.
- **Failure:** the existing `scripts/ci/notify-qa-sync-failure.sh` notification routes an Adaptive Card to A&E. Post-merge failure cannot block the merged PR; use the run log and existing deploy report to investigate before submitting another run.
- **Epics (the `/start-task` epic flow, `pm.md`):** an epic branch is redeployed to qa after any main sync or sandbox refresh, because the sync overwrites the epic's metadata in qa.
- **Local contracts:** `bash scripts/ci/tests/test_select_qa_source.sh` and `bash scripts/ci/tests/test_qa_sync_workflow.sh` verify source selection and workflow boundaries with fixtures, without contacting an org.
- **Staff doc:** <knowledge-base> "Automations and Engineering" — *QA Apex Sync — Auto-Deploy main → qa on Merge* (id 3841236, internal).

### qa CI auth: prod JWT → `qa-login.sh` (no qa secret)

**Current since <clickup-task-id> (2026-09-14).** Both qa-targeting workflows — `apex-test.yml` (the
required Apex gate, both jobs) and `qa-apex-sync.yml` (post-merge main→qa deploy) — authenticate
to **production** with `sf org login jwt`, then reach qa through `scripts/sf/qa-login.sh`. Nothing
stores a qa credential, so a sandbox refresh cannot break CI auth.

**How it works:**

- **GH secrets:** `SF_JWT_CONSUMER_KEY` + `SF_JWT_PRIVATE_KEY` — the **prod** connected app's
  client_id and the shared cert private key (vault `SF-JWT-PRIVATE-KEY`). Both survive a qa refresh
  because neither lives in the sandbox.
- **The workflow step is:**

      bash scripts/sf/qa-login.sh --prod-org sf-prod-auth --alias "$QA_ALIAS"

- Prod's `POST /tooling/sandboxAuth` issues a one-time auth code for `<your-email>.qa`, exchanged with
  the global `PlatformCLI` client for a qa session. Mechanism: `docs/runbooks/qa-sandbox-auth.md`.

**History — the rotation trap this replaced.** Before this, CI held qa's own consumer key in GH
secret `SF_JWT_CONSUMER_KEY_QA` (and a vault parity copy `SF-JWT-CONSUMER-KEY-QA`). A sandbox
refresh regenerates every connected-app consumer key, so the gate went red every Sunday until a
human rotated both copies by hand. **Both were deleted** (GH 2026-09-19, vault
2026-09-21) — if you find a doc or script still reading either name, it is stale.

`apex-test.yml` still files a deduped A&E card tagged `qa-jwt-auth` when a qa login step fails, so
an auth failure surfaces as an owned alert rather than only a red required check.

A token minted before a scope change lacks the new scope — re-mint after any scope edit
(see "frontdoor scope" note below / <clickup-task-id>).

**KV note:** the default `<azure-config-dir>` SP is data-plane **GET-only**; creating, rotating, or
deleting a vault secret needs a Secrets Officer identity (empirical 2026-06-14; re-confirmed
2026-09-19 when `az keyvault secret delete` returned `(Forbidden) … secrets/delete` under it). CI
does not depend on the vault — it reads the GH secrets — so a Forbidden vault write never affects
the gate. The **`<your-email>` user identity** in the default `~/.azure` config *can* write to
`<credential-vault>` (empirical 2026-06-21), but its MFA claim expires and the write then fails with
`AADSTS50078` until an interactive `az login` refreshes it (empirical 2026-09-19).

**The qa refresh is weekly + wipes deployed metadata (empirical 2026-06-21, <clickup-task-id>).** The
`.github/workflows/sandbox-refresh.yml` cron `0 2 * * 0` refreshes qa **every Sunday ~02:00 UTC**
(qa is a **Partial** sandbox, `AutoActivate=True`; confirmed `SandboxProcess` completions 06-07 /
06-14 / 06-21). A refresh does two things mid-flight work must expect: (1) it **regenerates every
connected-app consumer key** — no longer an auth problem, since `qa-login.sh` reads the key from the
live org per call (<clickup-task-id>); and (2) it **restores qa to the prod baseline**, wiping any qa deploy
not yet merged to `main` (an in-flight `convertLeadFromUi` Apex + LWC deploy vanished on the 06-21
refresh and had to be re-deployed). Re-auth a stale local qa alias with
`scripts/sf/qa-login.sh --prod-org <your-email> --jwt --key-file ~/.sf/sfjwt-prod.key --alias qa`.

**A PR that deployed to PROD but was CLOSED unmerged leaves prod AHEAD of main (<clickup-task-id> / PR #1083,
2026-06-22).** When a feature was deployed straight to prod and its PR is later closed without merging,
the new metadata lives in **prod only** — `git show origin/main:<path>` won't have it. Before
re-deploying that metadata in a later session, **`sf project retrieve` from `<your-email>` (prod) as the
baseline**, not from `main` — deploying main's older copy silently clobbers the live version with a
regression. Verify the drift with a grep before deploying: `git show origin/main:salesforce/.../<Class>.cls
| grep <newMethod>` returning empty means prod has it and main doesn't. (Precedent:
`LeadConversionService.convertLeadFromUi` / `findMatchCandidates` are live in prod, absent from main
after #1083 was closed.)

### weekly-metadata-sync.yml — production → main drift PR (<clickup-task-id>)

The only mechanism that pulls production metadata back into the repo. Every
Monday 05:00 UTC (or `workflow_dispatch`) it retrieves production into
`salesforce/force-app/main/default`, runs `scripts/sf/metadata_sync_guard.py`,
and opens a PR from `chore/metadata-sync-<date>`.

**It never auto-merges.** The PR is opened as a **draft** with the `hold`
label, both of which `auto-merge.yml`'s job condition skips. Merging it is always
a deliberate human act — and merging changes the repo only; nothing deploys.

**The guard** (`scripts/sf/metadata_sync_guard.py`, 19 tests in
`scripts/sf/tests/`) stops the sync reverting work that is merged but not
deployed. It decides per component (class + meta, whole bundles), never per file:

| Situation | Decision |
|---|---|
| prod `lastModifiedDate` newer than `main`'s newest commit | take prod |
| `main` newer (merged, not deployed) | keep `main`, list under *Kept main's version* |
| component unchanged on `main` since the flat-copy import `ef9ea8b2` | take prod, list under *import-only* (that commit's date says nothing about content) |
| GlobalValueSet | by content — `main`'s values ⊆ prod's → take prod; else keep `main` (its timestamp does not track value edits) |
| formatting-only difference (whitespace, entity spelling, CRLF) | leave as `main`, count only |
| anything unresolvable | keep `main` — never revert on missing data |

**It pushes and opens the PR as the `<internal-name>` App, not `GITHUB_TOKEN`.**
A push or PR made with `GITHUB_TOKEN` starts no workflows, so the PR never gets its
three required checks and can never merge (the first repaired run, #1387, had zero
check runs). The App also has `workflows: write`, so a sync branch cut before a
workflow change lands on `main` is no longer rejected at push.

**The FLS parity gate skips sync PRs** — only when the branch is `chore/metadata-sync-*` AND the author is `<internal-name>[bot]` (a branch name alone is spoofable). `fls-parity.yml` exists to make *authored*
fields get baseline read FLS; a sync PR copies production, so its failures describe
prod's FLS state rather than a PR defect. The first sync would have flagged 202 fields:
117 readable through profiles/permsets (just no `Default_Field_Access` entry) and 85
readable by no human access path at all — tracked as <clickup-task-id>.

**Standard objects are named explicitly.** The `CustomObject`/`CustomField` wildcards
return only custom objects and fields, so the retrieve also requests
`CustomObject:<Name>` for every standard object with a directory under `objects/`
(Account, Case, Lead, ...). Without it, standard-field drift — six Lead fields marked
history-tracked in import-era source but not in prod, pushing Lead past its 20-field
limit — was invisible. Managed-package components are excluded by `.forceignore`.

**One open sync PR at a time.** Each run pushes `chore/metadata-sync-<date>-<run id>`
and closes any earlier open sync PR as superseded (never the one it just opened).
Before this, a second run on the same day collided on the branch name and failed.

**It needs full history.** The guard dates each file by its last commit on `main`,
so the workflow checks out with `fetch-depth: 0`, and the guard exits 2 on a shallow
clone rather than run. (Precedent, 2026-09-21: the first successful run used the
default shallow checkout. Every file dated to the tip commit, all 488 modified
components were kept, and the PR carried additions only — every real prod change
suppressed, nothing reverted. Safe, but inert.)

A component that stays in *Kept main's version* week after week may have had a
non-deploy commit after prod's last change; check it by hand. *On main but not in
the org* lists source the retrieve could not find in production.

```bash
GH_APP_SHIM=0 gh workflow run weekly-metadata-sync.yml            # dispatch now
GH_APP_SHIM=0 gh run list --workflow=weekly-metadata-sync.yml     # history
```

`GH_APP_SHIM=0` bypasses the local `gh` wrapper's installation token, which gets
`Resource not accessible by integration` on Actions endpoints.

**Precedent — 26 of 26 runs failed, 2026-03-30 → 2026-09-21, and nobody
noticed.** It ran `sf` from the repo root after the SFDX project moved into
`salesforce/` (`InvalidProjectWorkspaceError`), and passed `--metadata` a
comma-joined list that `sf` rejects. The first repaired dry run produced 1,665
files (1,436 added, 229 changed) of production metadata `main` had never
carried. A scheduled job that has never succeeded is not a safety net.

**Targeted check.** `scripts/sf/assert-source-matches-org.sh -o <org>` retrieves
three named components and compares them to the working tree (exit 0 match /
1 drift / 3 retrieve failure). Use it to prove one reconciliation, not as a
substitute for the sync.

### LWC quick actions — deploy gotchas (<clickup-task-id>, 2026-06-21)

Shipping an LWC as a quick action (`lightning__RecordAction` / `ScreenAction`) has three deploy
traps, each empirically hit + resolved building the Lead `Convert_Lead_Fast` action:

- **Element name is `<lightningWebComponent>`, not `<lightningComponent>`.** `<lightningComponent>`
  resolves an **Aura** component — deploying it against an LWC fails `Unable to retrieve lightning
  component by namespace/developer name`. The QuickAction XML element for an LWC is
  `<lightningWebComponent>leadConvertAction</lightningWebComponent>`.
- **`<height>` AND `<width>` are required** for a `LightningComponent` quick action (`Required fields
  are missing: [Height]` / `[Width]`). `<optionsCreateFeedItem>` is also required. The minimal valid
  shape: `<height>`, `<label>`, `<lightningWebComponent>`, `<optionsCreateFeedItem>`, `<type>LightningComponent</type>`, `<width>` (alphabetical element order).
- **A quick action's `type` cannot be changed in place.** Editing an existing `Flow`-type action to
  `LightningComponent` fails with the opaque `unexpected metadata`; you also can't delete+recreate it
  if a **layout or Lightning record page references it** (`This action is referenced elsewhere…
  Remove the usage and try again`). The fix is a **new** quick action + repointing the Lead Layout +
  Record Page `actionName`/`actionNames` to it, leaving the old action orphaned (PR #1083).
- **Reference resolution is org-side, not payload-side.** A layout/flexipage that references a quick
  action validates the reference against what's **already deployed in the org**, not what's in the
  same deploy payload. Deploy in dependency order: Apex → LWC → quickAction → layout/flexipage.

> **⚠️ A deployed LWC `ScreenAction` quick action may never RENDER at runtime in this org (<clickup-task-id>, 2026-06-22 — prod outage).**
> All the deploy traps above were solved and `Convert_Lead_Fast` deployed clean — but clicking it
> showed only a perpetual spinner / generic Lightning **"CSS Error — Sorry to interrupt"** gack; the
> component never mounts (verified: `c-lead-convert-action` absent from the DOM, no console error, no
> module 404). It is **not** a code bug — a stripped-to-4-lines minimal component AND a brand-new clean
> quick action (`Convert_Lead_New2`) failed identically at apiVersion 61 **and** 66.
> **Diagnostic signal:** these LWC quick actions also **do not serialize through the Metadata API** —
> `sf project retrieve --metadata "QuickAction:Lead.<name>"` returns an empty zip even though
> `QuickActionDefinition` is queryable via Tooling — while Flow and Aura (`<lightningComponent>`)
> quick actions retrieve fine. Root cause not isolated (suspect a platform / org-level constraint on
> LWC `ScreenAction` quick actions). **Recommendation: prefer a Flow or Aura quick action for
> record-page UI.** If an LWC quick action is truly required, build it through the Setup UI (not
> metadata) and **live-click-test it as a non-admin before shipping** — `deploy validate` + Apex tests
> + a `.test.js` all pass while the rendered action is broken (see "LWC has no automated test gate" below).

**Repointing a quick action does not take effect until the Lightning page cache flushes — and a CLI
deploy does NOT flush it (<clickup-task-id>, 2026-06-22).** After repointing the Lead Layout + Lead Record
Page from a broken action to a working one (deploy `Succeeded`, fresh `retrieve` confirms zero stale
references), the rendered highlights-panel button kept invoking the **old, even after-deleted** action
for 25+ min — across a different user (Login-As) too, so it's **org-level page cache, not session
cache**. The cache caches the **component resolution**, not just the action API name. Levers that did
**NOT** flush it: re-deploying the flexipage/layout, deleting the old action, re-creating it as a Flow
action, waiting 25 min. **The reliable flush is a Lightning App Builder re-publish:** open the record
page in App Builder, make a real change (e.g. type one char in the page Description to enable **Save**),
click Save (revert the junk after) — that re-publishes the compiled page and the new binding takes
effect immediately. Verify with a fresh frontdoor click afterward.

### LWC has no automated test gate in this repo (<clickup-task-id>, 2026-06-22)

There is **no LWC Jest runner** here — no `@salesforce/sfdx-lwc-jest`, no jest config, no `npm test`
for LWC. CI (`apex-test.yml`) runs Apex tests (targeted PR selection or full `RunLocalTests`), so **an LWC `*.test.js` never executes**
— do not read its presence as coverage. The *only* real gate for a user-visible LWC is a **live click**
via `/sf-smoke-as` (today its `--save` path is hardcoded to Log-a-Call / a generic action needs `--doc`
or hand-written Playwright; arbitrary-quick-action drive + render-assert is tracked at **<clickup-task-id>**).
**Precedent:** `leadConvertAction.test.js` (mocked wires, asserts the panel exists) + 10/10 Apex tests
+ `deploy validate` all passed while the rendered `Convert_Lead_Fast` quick action was completely broken
→ shipped to prod, broke Sales lead-convert for ~a day.

**Obsolete after this migration:** `SFDX_AUTH_URL_QA` (GH secret) + `SFDX-AUTH-URL-QA` (vault).
Safe to delete the GH secret once the JWT gate is green on main for one PR cycle. (Prod CI auth
`SFDX_AUTH_URL` / `SFDX_AUTH_URL` is a separate OAuth-URL secret and remains in use by
`sandbox-refresh.yml`, `weekly-metadata-sync.yml`, `sf-archive-sweep.yml` — JWT migration of
prod CI is tracked separately, not in this change.)

### Concurrency + SLO

The validate jobs and QA catch-up workflow use `concurrency.group: sf-qa-validate`
with `cancel-in-progress: false` and `queue: max` (one shared QA queue). Cancelling a validate mid-test corrupts
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

2. If the queue is empty but the run is still hung, inspect the deploy job
   with `sf project deploy report --job-id <id> --target-org qa --json`
   and the workflow logs. An empty Apex job queue alone does not prove that
   the deploy has finished. Wait for the server-side result and investigate
   polling or transport failures.

3. If the queue is backed up (>5 jobs queued), there's a real qa
   contention issue (likely Playwright UI smokes or ad-hoc dev work
   running concurrently). Slack the team to pause manual qa work; the
   workflow will drain naturally within ~10 min.

4. Do not cancel an in-progress validate or catch-up deploy through `sf`
   or GitHub Actions. A queued Salesforce deploy cannot be cancelled; killing
   its CLI/workflow does not remove that server-side job. Let the queue drain
   and report/probe the existing job before submitting another run.

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

### Account PAC Member (`PAC_Member__c`, <clickup-task-id>)
- **Field:** `Account.PAC_Member__c`, Checkbox "PAC Member", default unchecked. Marks Partner Advisory Council members.
- **Rule:** `PAC_Member_Partners_Only` (active) blocks the box unless `Type` is `White Label` or `Channel Partner` (`Channel Client` is not a partner). Error shows on the field.
- **FLS:** Read + Edit on the 30 profiles that carry Account field permissions (profile XML `fieldPermissions` inserts; profiles merge on deploy). The 30-profile deploy touched no permission set.
- **Layout:** `Account-Account Layout` (after `SubType__c`) and `Account_Record_Page` flexipage (same position, same Channel Partner OR White Label visibility rule as `SubType__c`).
- **qa (2026-10-13):** deployed `NoTestRun`, verified FieldDefinition, active rule, 30 profile FieldPermissions rows; Vendor + true rejected, White Label + true accepted. 
- **prod (2026-10-13):** deploy `0AfU1000002nOT3KAM` Succeeded (35 components: field, rule, Account Layout, Account_Record_Page, 30 profile stubs carrying only the new `fieldPermissions`; no permission set). Prod rejects `--test-level NoTestRun` (`INVALID_OPERATION`), so the deploy omitted the flag; with no Apex, no tests run. Pre-deploy drift check: prod Layout and FlexiPage matched the branch parent. Verified: FieldDefinition present, rule Active, 30 profile FieldPermissions rows with Edit.
- **prod `Default_Field_Access` (2026-10-13):** deploy `0AfU1000002nOZVKA2` Succeeded (1 component). Retrieved the set from prod, inserted one `Account.PAC_Member__c` `fieldPermissions` block (read + edit, sorted after `Account.Ownership`), deployed with no `--test-level`. Prod counts by ParentId before/after: FieldPermissions 1332 -> 1333, ObjectPermissions 0 -> 0, SetupEntityAccess 0 -> 0. The `fls-parity` exclude entry was removed.
- **Rollback:** `sf project deploy start -d salesforce/destructive-deploy/<clickup-task-id>-pac-member/` (removes field and rule; profile entries go with the field).

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

## Lead-create provenance — check intermediate intake objects

When investigating "what creates Lead records of pattern X", a direct grep for Lead-create automations is necessary but not sufficient. <your-org>'s org routes several external intake streams through a **custom SObject first**, then a Flow / Trigger creates the Lead from that intermediate record. Single-hop searches miss these.

**Required two-hop search:**

```bash
# 1. Direct Lead creators (typical first instinct)
sf data query --use-tooling-api --target-org <your-email> --json \
  -q "SELECT Name FROM ApexTrigger WHERE TableEnumOrId='Lead' AND Status='Active'"
# + scan active flows for record-creates with object=Lead

# 2. Intermediate intake objects — any custom object with a Lead__c lookup or "Form_Type__c"-style provenance field
sf sobject describe --sobject Web_Form__c --target-org <your-email> --json | \
  jq '.result.fields[] | select(.name | test("Lead|Form")) | .name'

# 3. Flows triggered ON the intake object that create Lead downstream
# ⚠ sf org display REDACTS accessToken (54-char placeholder) -> Bearer curl 401s with
#   INVALID_AUTH_HEADER. --verbose and SF_DISABLE_TOKEN_REDACTION=true do not defeat it.
#   (empirical (2026-07-30), CLI 2.143.6.) Prefer `sf api request rest "<path>" --target-org <org>`,
#   which authenticates through the CLI and needs no token. See .claude/rules/salesforce-dev.md
#   "Activation pattern for prod" for the working shape.
#
#   If you genuinely need the raw Bearer token (e.g. a client library that builds its own
#   HTTP request, like Bulk API v2), the CLI's own redaction placeholder names the recovery:
#   `sf org auth show-access-token`. Without --json it prompts interactively and hangs
#   unattended — --json is load-bearing, not cosmetic:
#     sf org auth show-access-token --target-org <org> --json | jq -r '.result.accessToken'
#   Returns the real ~112-char session id (`00D...!...`), not the placeholder. (empirical
#   (2026-08-15), CLI 2.143.6.) A structural guard should still assert the returned value's
#   shape (len >= 80, starts "00D", "!" at index 15) before using it — a redacted or malformed
#   value should fail loudly on the first call, not 401 object-by-object. **Incident:** the
#   `sf-archive` nightly sweep (`sf_archive/preflight.py:fetch_org_auth`) read the token from
#   `sf org display` and 401'd on every Bulk API call for 39 consecutive nights
#   (2026-07-08 → 2026-08-15) before this recovery was wired in; card <clickup-task-id>, PR
#   `<clickup-task-id>-sf-archive-token-redaction`.
ACCESS=$(sf org display --target-org <your-email> --json | jq -r '.result.accessToken')
INSTANCE=$(sf org display --target-org <your-email> --json | jq -r '.result.instanceUrl')
for FID in $(sf data query --use-tooling-api --target-org <your-email> --json \
  -q "SELECT ActiveVersionId FROM FlowDefinition WHERE ActiveVersionId != null" \
  | jq -r '.result.records[].ActiveVersionId'); do
    body=$(curl -s "$INSTANCE/services/data/v62.0/tooling/sobjects/Flow/$FID" \
      -H "Authorization: Bearer $ACCESS")
    if echo "$body" | grep -q '"object":"Lead"' && \
       echo "$body" | grep -q '"objectType":"Web_Form__c\|<other-intake-obj>"'; then
      echo "$FID — intake → Lead flow"
    fi
done
```

**Known intermediate intake objects in <your-org> prod:**

| Intake object | Source | Flow that creates Lead |
|---|---|---|
| `Web_Form__c` | <your-org> Gravity Forms via SF Add-On | `New_Web_Form_Submitted` (see `docs/runbooks/<internal-name>.md`) |
| (add as discovered) | | |

**Precedent (<clickup-task-id>, 2026-05-28):** spent multiple turns searching for a direct webform → Lead automation, concluded "no active webform automation exists." The actual path was `Gravity Forms → Web_Form__c → New_Web_Form_Submitted flow → Lead`. The two-hop pattern was invisible to single-hop searches.

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

## Product2 catalog write-back (P3, <clickup-task-id>)

**Status:** repository implementation prepared; production deployment and <your-name>'s one-record live-click smoke remain gated. P3 plan documents the 2026-10-06 risk probes; rerun live-state checks before production approval.

An allowlisted **Propose catalog fix** click approves a single `Product2.Description` PATCH. The handler reads the persisted proposal, checks its actionable catalog-stale verdict, 15/18-character `01t` id, exact target/description binding token and nonblank description length ≤4000, and claims the proposal before reading Salesforce. It refuses other target counts, hardware families and no-op writes. Values over 4000 are refused rather than silently truncated. Thread-learning documents authorization, claim/reconcile and audit behavior.

Both SF nodes used the **admin-scoped** OAuth2 credential `Salesforce account` (`zqddB1I968wdn09b`; deleted 2026-10-10, <clickup-task-id>, after the live handler moved to `<internal-bot>: SF User Session`; the live scan of 150 workflows finds no reference), `authentication=predefinedCredentialType`, `nodeCredentialType=salesforceOAuth2Api`. Both nodes used the hardcoded org host `https://<your-org>.my.salesforce.com` and API `v66.0` because `$credentials.instanceUrl` does not resolve in HTTP Request nodes (exec 306137, 2026-10-07); see the n8n API `$credentials.instanceUrl` note (`n8n-api.md:1267`). Read `Id,Name,Family,Description,LastModifiedDate` via `/query` after id validation; PATCH `/sobjects/Product2/<id>` with only `{"Description":<stored catalog_new_description>}`. PATCH/audit/mark-fixed errors flag `catalog_fix_needs_review`, reply in-thread and stop for Error Notifier; a lost PATCH response may follow a committed write, so the proposal requires PM reconciliation.

The plan's empirical Product2 risk audit (2026-10-06):

| Surface | Finding | Severity | Mitigation |
|---|---|---|---|
| Apex triggers | 0 on Product2 | — | none found by probe |
| Validation rules | 2, both inactive | LOW | none required by probe |
| Active record-triggered flow | `Update_Price_Books_when_Product_is_Updated_or_Created`, after-save CreateAndUpdate; creates/updates PricebookEntry for four hardware families | MEDIUM | Refuse `Desk Phones`, `Cordless Phones`, `Conference Phones`, `ATA, Headsets, & Peripherals` |
| Customer-facing alerts/email | None found; the flow writes PricebookEntry | — | Recheck if automation changes |

Before the approved smoke click, capture Description and LastModifiedDate for the target and retain a `Rollback:` record in P3 smoke evidence. After the click, verify Description equals the persisted proposed value, one `catalog_writeback` audit row, hint `catalog_fixed`, thread confirmation and the expected handler execution path. A second click must not produce another SF write or audit row.

Rollback reads `cloudie_sf_audit.parameters.old_description` for the proposal; it may be null and must remain null when restoring. Compare current Description/LastModifiedDate and report later edits before proposing a restore. Capture the exact old value into a JSON payload rather than interpolating it into a shell command. Restore one Description only after a separate per-action production approval; the original card click does not authorize a rollback. `parameters.old_last_modified` records the read timestamp, and `parameters.new_description` records the applied value. If PATCH/audit failed ambiguously, use the reconcile table in the thread-learning runbook before any retry.

## Gotchas

- **FLS after deploy:** `sf project deploy` does NOT grant Field-Level Security. After deploying custom fields, grant FLS via Apex `FieldPermissions` insert or deploy a profile XML alongside.
- **SOQL safety:** Do NOT use `WITH SECURITY_ENFORCED` in Apex — caused two prod outages (2026-05-06 Email Quick Action; 2026-05-15 <internal-bot> Advisor blocked Sales/CS team for ~5h, ClickUp <clickup-task-id>). Class-level `with sharing` enforces record visibility; if you need to drop fields the user can't see, use `Security.stripInaccessible()` post-query. Detail: `.claude/rules/salesforce-dev.md` "SOQL Safety".
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

  **Assert it after every flow deploy — the deploy will not tell you.** A Draft-landed flow
  reports deploy success, passes CI, and shows nothing wrong anywhere; the previous Active
  version keeps running, so there is no user-visible symptom to notice. Run:

  ```bash
  scripts/sf/assert-flow-activated.sh --org <your-email> Flow_A Flow_B
  scripts/sf/assert-flow-activated.sh --org <your-email> Flow_A --inactive Retired_Flow
  # or, over the source directory a deploy touched:
  scripts/sf/assert-flow-activated.sh --org <your-email> \
    --source-dir salesforce/force-app/main/default/flows
  ```

  `--inactive` takes one retired flow name per occurrence. `--source-dir` routes files with
  `<status>Obsolete</status>` to the inactive check; every other file is expected Active.
  Scope the directory to the deploy's flow sources.

  Exit `0` all requested active/inactive states match · `1` an expected-active flow landed
  Draft or is absent, or a retired flow still has an active version · `3` org unreachable /
  unparseable response, or an unreadable `--source-dir` file · `64` usage, including a
  `--source-dir` that is not a directory. It fails closed: an unreadable response or source
  file is a failure, never a pass.
  For active flows the check is `FlowDefinitionView.LatestVersionId == ActiveVersionId` —
  a newer-than-active version means the deploy left a Draft behind. For retired flows,
  `ActiveVersionId` must be null, or the definition must be absent from the org.

  **Before activating an old Draft, check it did not divert the main path.** An owner-resolver
  or fault retrofit should be an *insertion* — `A -> B` becomes `A -> R -> B`, so `B` is still
  reachable. A transposed connector instead *diverts*: traffic that used to reach `B` no longer
  does, and whatever hung off `B` is stranded. No element is added or removed and no field value
  changes, so element-name and `inputAssignments` comparison are both blind to it.

  ```bash
  python3 scripts/flow-version-diff/diff.py --flow <Flow> --base <active> --head <draft>
  # verdict: PATH DIVERTED  -> do not activate
  ```

  **(empirical (2026-09-11), <clickup-task-id>: `Port_Split_Flow` v15 transposed two connectors —
  `Get_Case` was pointed at `Create_Single_Port_Split_Case` instead of `Port_Split`, and the new
  `Resolve_Port_Split_Owner` was pointed at `Port_Split` instead of the record create. Live, the
  flow skipped its input screen entirely and the screen became reachable only from a fault
  handler, with a `Port_Split -> decision -> Single_Case_Creation_Information -> Resolve -> Port_Split`
  cycle. The defect was in the repo source, so it had passed PR review; repo-vs-org parity
  reported a clean match because the wiring was equally wrong on both sides. Caught by the
  reachability check, not by review. The resolver's own `faultConnector` target was the tell —
  a fault path pointing where the success path should go.)**

  **(empirical (2026-09-11), <clickup-task-id>: six flows deployed to prod 2026-09-03 all landed
  Draft and none were activated. Five sat inert for eight days. It surfaced only when one of
  them, `Activate_New_Client`, was reached by a subflow call that expected the new version's
  `faultMessage` output and failed in front of a user (<clickup-task-id>) — the other five had no
  symptom at all. Separately, `scripts/alert-fault-audit/scan.py` reads `<status>` from the
  repo XML rather than the org, so the fault-coverage audit reported all six as live-and-
  covered for that entire window; that half is tracked in <clickup-task-id>.)**

  **Alternative — activate by deploying `FlowDefinition` metadata.** Needs no `DurableId`
  lookup and activates any number of flows in one deploy, which the per-flow Tooling PATCH
  cannot:

  ```bash
  mkdir -p /tmp/act/flowDefinitions
  cat > /tmp/act/flowDefinitions/<FlowName>.flowDefinition <<'EOF'
  <?xml version="1.0" encoding="UTF-8"?>
  <FlowDefinition xmlns="http://soap.sforce.com/2006/04/metadata">
      <activeVersionNumber>N</activeVersionNumber>
  </FlowDefinition>
  EOF
  # package.xml lists each flow as a <members> entry under <name>FlowDefinition</name>
  sf project deploy start --metadata-dir /tmp/act -o <your-email> --wait 15
  ```

  Set `<activeVersionNumber>0</activeVersionNumber>` to DEACTIVATE — required before a
  Flow can be deleted, since a destructive deploy of an Active flow fails with
  `insufficient access rights on cross-reference id`. Even once Obsolete, the destructive
  delete can keep failing with that same error; deleting the version directly works:
  `sf data delete record --use-tooling-api -s Flow -i <301...> -o <org>`.

  **Two prod-only gotchas that pair with this** (empirical (2026-09-10), <clickup-task-id>):
  - `--test-level NoTestRun` is REJECTED in production — `INVALID_OPERATION: testLevel of
    NoTestRun cannot be used in production organizations` — even for a layout-only or
    flow-only deploy with no Apex. Omit the flag and let it default.
  - The deploy reports `Succeeded` while the flow sits inert as `Draft`, so the deploy
    result is not evidence. Verify against the org:
    `sf data query --use-tooling-api -q "SELECT Definition.DeveloperName, VersionNumber,
    Status FROM Flow WHERE Definition.DeveloperName IN (...)"` and confirm the NEW version
    number is the Active one — an old version can still be Active and serving traffic.

- **Schedule-triggered flow `<startTime>` is org-local time, not UTC.** SF interprets `<startTime>HH:MM:SS.SSSZ</startTime>` as the desired hour in the org's default timezone (`America/New_York` for <your-org>) and ignores the `Z` suffix. The actual UTC fire time shows up in `CronTrigger.NextFireTime` after activation. Source XML `<startTime>14:00:00.000Z</startTime>` schedules at 2pm NY local (= `18:00:00Z` during EDT, `19:00:00Z` during EST), not 14:00 UTC. **(empirical (2026-05-09): `Lead_Manager_Parking_Lot_Daily.flow-meta.xml` with `<startTime>14:00:00.000Z</startTime>` produced `CronTrigger.NextFireTime = 2026-05-10T18:00:00Z` (= 2pm EDT); corrected to `<startTime>10:00:00.000Z</startTime>` produced `2026-05-10T14:00:00Z` (= 10am EDT).)** To target a specific NY-local hour, write that hour into `<startTime>HH:MM:SS.SSSZ</startTime>` and ignore the `Z`. Verify post-activation: `sf data query --query "SELECT NextFireTime FROM CronTrigger WHERE CronJobDetail.Name LIKE '%<flow-api-name>%'"`.

- **Validate Info warnings can harden into `WARNING_BLOCK_ACTIVATION` errors at FlowDefinition PATCH time.** The activation-time check is stricter than the validate-time check. Specifically, `$Record__Prior` references inside `<filterFormula>` may pass validate with an Info warning but reject the subsequent activation PATCH with `FORMULA_EXPRESSION_INVALID: ... isn't valid because "When to Run the Flow for Updated Records" in the Start element changed`. **(empirical (2026-05-09): `Lead_Manager_Parking_Lot_OnLogin` validated cleanly but PATCH returned `WARNING_BLOCK_ACTIVATION` for an Info-flagged `$Record__Prior.IsLoggedIn__c` reference; resolved by dropping the `$Record__Prior` clause and relying on `<doesRequireRecordChangedToMeetCriteria>true</doesRequireRecordChangedToMeetCriteria>` for edge-trigger semantics.)**
- **`FlowDefinition` SOQL is unavailable on the data API; Tooling SOQL works.** Without `--use-tooling-api`, `SELECT ... FROM FlowDefinition` returns `sObject type 'FlowDefinition' is not supported`. On the data API use `FlowDefinitionView`: `SELECT DurableId, ActiveVersionId, LatestVersionId, ApiName FROM FlowDefinitionView WHERE ApiName = '...'`. Tooling example: `sf data query --use-tooling-api -o <org> -q "SELECT Id, DeveloperName, ActiveVersionId, LatestVersionId FROM FlowDefinition WHERE DeveloperName = '<Flow>'"`. The Tooling REST PATCH endpoint (`/tooling/sobjects/FlowDefinition/{id}`) also works. **Empirical (2026-10-05, QA and prod):** Tooling queries returned definition IDs and null `ActiveVersionId` for `Lead_Temperature_Assignment`; the QA data API query returned `INVALID_TYPE` (<clickup-task-id> plan, probes P1/P8).
- **`FlowVersionView` IDs are placeholders:** `FlowVersionView` returns `000000000000000AAA` for all `Id` values. To get real Flow version IDs, use the Tooling API: `curl "$INSTANCE_URL/services/data/v66.0/tooling/query/?q=SELECT+Id,VersionNumber,Status+FROM+Flow+WHERE+Definition.DeveloperName='...'"`

### Retiring a flow — Obsolete in source does not deactivate

Setting `<status>Obsolete</status>` in source does not establish that the org has no active
version. A QA deploy created and activated `Lead_Temperature_Assignment` v7 on 2026-10-05,
after its source retirement merged. **Empirical (2026-10-05, QA):** `SetupAuditTrail` records
creation at 17:15:57Z, activation at 17:16:00Z, and explicit deactivation at 17:26:00Z. The
audit trail does not identify the deployed checkout. Evidence and Tooling probes:
`<clickup-task-id> plan`.

Retirement has four steps:

1. Merge the source change to `<status>Obsolete</status>`.
2. Deploy the scoped source to the target org, following the production deploy approval gate.
3. Deactivate the flow explicitly. Get its definition ID from `FlowDefinitionView.DurableId`,
   then update Tooling `FlowDefinition.Metadata.activeVersionNumber` to null:

   ```bash
   sf data query -o <org> \
     -q "SELECT DurableId, ApiName, ActiveVersionId FROM FlowDefinitionView WHERE ApiName = '<Flow>'"
   sf data update record --use-tooling-api -s FlowDefinition -i <300-definition-id> \
     -v "Metadata='{\"activeVersionNumber\":null}'" -o <org>
   ```

   In production, deactivation is a production write and requires <your-name>'s per-action
   confirmation (Layer 2.5). This also applies to the alternative FlowDefinition metadata
   deploy with `<activeVersionNumber>0</activeVersionNumber>` described above.
4. Verify the org state after the deploy and deactivation:

   ```bash
   scripts/sf/assert-flow-activated.sh --org <org> --inactive <Flow>
   ```

   Exit `0` confirms inactive or absent. Exit `1` identifies an active retired flow and prints
   its deactivation command; after approval where required, deactivate and rerun. Exit `3`
   means not verified, so stop.

At the AE production cutover (<clickup-task-id>), carry this procedure into the cutover plan. After
any deploy touching `Lead_Temperature_Assignment`, explicitly deactivate it and run both
read-only checks below against the target org. Require a returned Tooling `FlowDefinition`
row whose `ActiveVersionId` is null and an assertion exit of `0`:

```bash
sf data query --use-tooling-api -o <org> \
  -q "SELECT DeveloperName, ActiveVersionId FROM FlowDefinition WHERE DeveloperName = 'Lead_Temperature_Assignment'"
scripts/sf/assert-flow-activated.sh --org <org> --inactive Lead_Temperature_Assignment
```

For a repository-wide retired-only sweep, run this block with **bash**, from the repository
root. Each `--inactive` occurrence names one flow. The count guard rejects an empty sweep:

```bash
set -e
ARGS=$(grep -l '<status>Obsolete</status>' salesforce/force-app/main/default/flows/*.flow-meta.xml | xargs -n1 basename | sed 's/\.flow-meta\.xml$//; s/^/--inactive /')
test "$(printf '%s\n' $ARGS | grep -c -- '--inactive')" -ge 18
scripts/sf/assert-flow-activated.sh --org <org> $ARGS
```

The unquoted `$ARGS` expands into flags and names under bash; do not paste this block into
zsh. Alternatively, `--source-dir salesforce/force-app/main/default/flows` routes Obsolete
sources automatically, but also asserts that every other source flow's latest version is
Active. `CS_New_Client_Process` is a live producer: its source is Active, matching prod v4
(empirical (2026-10-05), Tooling `Flow` query in the linked plan), so it is excluded from the
retired-only sweep.

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

### Flow loops multiply governor consumption — bulkify into one Apex invocable (<clickup-task-id>)

A SOQL/DML/`Messaging.sendEmail` element **inside a Flow loop** (or a per-record subflow the loop calls) multiplies governor consumption against the per-transaction caps: `Messaging.sendEmail` **10**, SOQL **100**, DML **150** (synchronous). The breach throws `System.LimitException` (e.g. `Too many Email Invocations: 11`) — which, in a **record-triggered after-save flow**, surfaces as `CANNOT_EXECUTE_FLOW_TRIGGER` and **rolls back the triggering DML**. If the triggering DML was a user action (a toggle, a status flip), the user's action silently fails.

**Precedent (<clickup-task-id>):** `Lead_Manager_Parking_Lot_OnLogin` (after-save on a BDR's `Dispatch_Group_Member__c.IsLoggedIn__c`) looped Peyton's parked New leads and called a subflow **per lead**; the subflow sent 2 emails + 4 SOQL + 2 DML each. At 6 leads the 11th `Messaging.sendEmail` threw `Too many Email Invocations: 11` → `CANNOT_EXECUTE_FLOW_TRIGGER` → the login toggle rolled back → the BDR stayed LOGGED OUT (the LWC's empty catch swallowed it). All three axes scaled linearly (email at 6 leads, SOQL at 25, DML at 75).

**Fix pattern — replace the per-record loop with ONE bulk Apex `@InvocableMethod`** whose governor cost is **constant** regardless of record count:
- Query the working set once (`... LIMIT 200 FOR UPDATE` to serialize concurrent triggers); assign/transform in memory; **one** bulk DML per object; build all `Messaging.SingleEmailMessage`s and call `Messaging.sendEmail(list, false)` **once**.
- Wrap the entire body in one broad `try { ... } catch (Exception e) { System.debug(LoggingLevel.ERROR, ...); }` that **never rethrows** — so a redistribution fault can't roll back the triggering login DML. Note `System.LimitException` is **uncatchable**; the constant-cost design (+ `LIMIT`) is what keeps the transaction far from the caps so it never fires. The try/catch handles the *catchable* faults (`UNABLE_TO_LOCK_ROW` from `FOR UPDATE`, `DmlException`, `EmailException`).
- The flow collapses to **trigger → one action call**. Verify in qa by reproducing the limit fault (seed >10 qualifying records, fire the trigger, confirm rollback), then deploying the fix and confirming the trigger DML commits with 0 limit errors. See `ParkingLotRedistributeAction.cls` + `docs/superpowers/specs/evidence/<clickup-task-id>/`.

### Flow versions pin field deletions

When destructive-deploying a CustomField, Salesforce validates the field has no remaining consumers — INCLUDING Obsolete + Draft flow versions, NOT just Active versions.

**empirical (2026-05-15):** caught during <clickup-task-id> Phase 4 qa-first dry-run. The Phase 1 audit identified 4 Active-flow consumers and added them to the destructive manifest. Validation in qa still failed because 9 Obsolete + Draft versions across 6 unrelated flows ALSO held the field references. Resolution required Tooling-DELETE on each pinning version before the field destruction would validate.

**To enumerate all pinning versions of a field before a destructive deploy:**

The destructive-deploy validation error itself names the offending Flow Version IDs in the format `[3-char prefix] 301U... Flow.<DeveloperName> v<N> <Status>`. Capture them, then for each ID:

```bash
sf data delete record --use-tooling-api -s Flow -i <flow-version-id> -o <org>
```

The CLI manages auth; do not extract `accessToken` from `sf org display`, whose output is
redacted (see `.claude/rules/salesforce-dev.md`, Tooling API auth). Confirm the CLI reports
success. If the version is absent, query the org to confirm it was already deleted before
continuing.

**Note:** for Flow versions where the parent FlowDefinition has an Active version, deleting
its Obsolete predecessor is generally allowed. The Active version itself cannot be deleted
directly. Get the parent's `DurableId` and deactivate first:

```bash
sf data update record --use-tooling-api -s FlowDefinition -i <300-definition-id> \
  -v "Metadata='{\"activeVersionNumber\":null}'" -o <org>
```

Production deactivation and deletion each require <your-name>'s per-action confirmation. Verify
with the [retirement procedure](#retiring-a-flow--obsolete-in-source-does-not-deactivate)
before deleting the version.

### A destructive manifest naming a component the org does not have fails the WHOLE deploy

`destructiveChanges.xml` is all-or-nothing. If any `<members>` entry names a component with no
matching record in the target org, the entire destructive deploy fails validation — the other,
valid members are not processed. Splitting a cleanup into "delete from git only" vs "delete from
git AND the org" is therefore not cosmetic: it is what keeps the manifest deployable.

**empirical (2026-09-03):** <clickup-task-id> (Phase A of epic <clickup-task-id>) removed 14 never-deployed flows
from the repo. A `FlowDefinition` probe showed only 8 of them had a row in the org
(`ActiveVersionId = null`, `LatestVersion.Status = InvalidDraft`); the other 6 had no row at all —
they had been committed by a bulk migration and never deployed even once. Only the 8 were listed in
`salesforce/destructive-deploy/<clickup-task-id>-phase-a-flow-cleanup/destructiveChanges.xml`; the other 6
were a plain `git rm` with no org-side action. Probe before writing the manifest:

```bash
sf data query --use-tooling-api -o <org> \
  -q "SELECT DeveloperName, ActiveVersionId, LatestVersion.Status FROM FlowDefinition
      WHERE DeveloperName IN ('A','B','C')"
```

Names absent from the result set must NOT enter the manifest.

### A Flow that still has versions cannot be deleted by destructiveChanges.xml at all

Having a `FlowDefinition` row is necessary but NOT sufficient for a destructive-deploy
delete. The Metadata API refuses to delete a Flow while any version of it exists, and the
error it returns names neither versions nor flows:

```
Error in Monthly_Retention_Snapshot_Creator - insufficient access rights on cross-reference id
```

This reads like a permissions problem and is not one. Deleting such a Flow goes through the
**Tooling API**, one version at a time; removing the last version cascade-reaps the parent
`FlowDefinition` (see the section below). So the Flow name must then be absent from the
manifest too, or the deploy fails with `No Flow named: X found`. In practice, a
never-activated Flow is removed entirely outside `destructiveChanges.xml`.

**empirical (2026-09-04):** <clickup-task-id>. Eight flows, each with exactly one `v1 InvalidDraft`
version and a live `FlowDefinition` row in qa, were listed as `<name>Flow</name>` members.
`sf project deploy validate --target-org qa --pre-destructive-changes ...` failed with
`insufficient access rights on cross-reference id` for all 8 (deploy `0Afic0000000pQjCAI`).
Tooling-DELETE of `301U100000hFNmnIAG` then returned 204 and
`SELECT DeveloperName FROM FlowDefinition WHERE DeveloperName='Account_Retention_Metrics_Calculator'`
returned 0 rows. The manifest was reduced to the QuickAction alone and the flow removal moved
to `salesforce/destructive-deploy/<clickup-task-id>-phase-a-flow-cleanup/delete-flow-versions.sh`,
which is idempotent (a version already gone is simply not enumerated).

### A transaction-controlled action cannot sit on a record-triggered flow's Run Immediately path

`flowTransactionModel>NewTransaction<` on an `actionCalls` element and the flow's `<start>` topology
solve two different problems, and both are required together:

- `NewTransaction` gives the action its own transaction, which is what lets a **setup**-object DML
  (e.g. inserting `PermissionSetAssignment`) coexist with the non-setup DML of the triggering save.
  That is the MIXED_DML fix (see the "MIXED_DML gotcha" section below for the Queueable variant).
- Independently, the platform **rejects that action outright** if it sits on the Run Immediately
  path: `A record-triggered flow's Run Immediately path can't execute transaction-controlled
  actions. Remove this element from the flow, or move it to a scheduled path.` The validator checks
  the action's POSITION, not just its attribute — so keeping `NewTransaction` on Run Immediately is
  not a third option.

The fix is a `<scheduledPaths>` block, not a Queueable. Where the flow's only real work is the
transaction-controlled action, the smallest correct diff moves the **entire** flow onto an async
path: drop `<start>`'s immediate `<connector>` and add a `<scheduledPaths>` whose `<connector>`
targets the same first element, with `offsetNumber` 0:

```xml
<start>
    <filterFormula>...</filterFormula>
    <object>User</object>
    <recordTriggerType>CreateAndUpdate</recordTriggerType>
    <scheduledPaths>
        <name>Run_Async_PSA_Assignment</name>
        <connector><targetReference>Get_Profile</targetReference></connector>
        <label>Run Async PSA Assignment</label>
        <offsetNumber>0</offsetNumber>
        <offsetUnit>Minutes</offsetUnit>
        <timeSource>RecordTriggerEvent</timeSource>
    </scheduledPaths>
    <triggerType>RecordAfterSave</triggerType>
</start>
```

A `<start>` with `scheduledPaths` and NO immediate `<connector>` is valid — precedent in this repo:
`salesforce/force-app/main/default/flows/CSAT_24_Hour_Reminder.flow-meta.xml`. Splitting the flow
(lookups immediate, write async) would require proving flow-interview variables survive the async
boundary; moving the whole start avoids that unverified assumption entirely.

**empirical (2026-09-03):** <clickup-task-id> — `User_Assign_Baseline_FLS` shipped in PR #609 (2026-05-16)
already carrying `NewTransaction`, and had never deployed since because of this topology rule. The
permission set it assigns was inert for ~4 months as a result.

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
| 2026-04-30; clarified 2026-10-05 | `SELECT ... FROM FlowDefinition` → `sObject type not supported` | `FlowDefinition` is unavailable on the data API; Tooling SOQL works (<clickup-task-id> probes P1/P8) | Use `FlowDefinitionView` on the data API, or query `FlowDefinition` with `--use-tooling-api`; Tooling API REST endpoint also works for PATCH |
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
  --target-org <your-email> --no-prompt --async

# Refresh an existing sandbox (the orchestrator script picks this path automatically)
sf org refresh sandbox \
  --name qa --target-org <your-email> --no-prompt --async
# Never --wait: on completion the CLI auto-authorizes the sandbox with the prod connected
# app's client id and fails "Failure during validation of the callbackUrl" (<clickup-task-id>).
# Poll SandboxProcess instead (create-sandbox.sh does), then log in with scripts/sf/qa-login.sh.
sf data query --use-tooling-api --target-org <your-email> \
  -q "SELECT Status, CopyProgress, ActivatedDate FROM SandboxProcess WHERE SandboxName='qa' ORDER BY CreatedDate DESC LIMIT 1"

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

### Manager impersonation workflow + dedicated cadence-QA user

RevOps managers (e.g. Brittany Barnes) sometimes need to validate cadence/Sales-Engagement behavior **from the rep's perspective** rather than from an admin profile (which bypasses permission sets and sees a different UI). Two pieces support this:

**1. Login-As is already enabled org-wide.** `enableAdminLoginAsAnyUser=true` (empirical 2026-06-07, `Settings:Security` retrieve), so **any** System Administrator can Login-As any active user with no org-metadata change. Brittany is already a System Administrator (`<sf-record-id>`), so she can impersonate via **Setup → Users → (user) → Login** or the `servlet.su` frontdoor chain above — no `Modify All Data` grant or per-user "Login Access" button needed. The original ask ("grant Brittany the profile combo for loginas URLs") was already satisfied by the existing org policy + her admin profile.

**2. A dedicated combined SDR/BDR cadence-QA user** (rather than borrowing a real rep's record like Stephanie's). Identity:

| Field | Value |
|---|---|
| Username | `<service-email>` |
| User Id (prod) | `<sf-record-id>` (empirical 2026-06-07) |
| Email | `<service-email>` (activation/reset mail routes to the manager) |
| Name / Alias | `Cadence QA (SDR/BDR Test)` / `cadqa` |
| Profile | <your-org> Standard (`<sf-record-id>`) — same as real SDR/BDR reps |
| Role | Sales Development Representative (`00EU1000002bLE1MAM`) |
| Permsets | 14-permset **Sales_SDR ∪ Sales_BDR superset** (Sales, Sales_SDR, Sales_BDR, Lead_Sales_Tabs_Base, Lead_Stage_Update_Fields, Source_Detail_Field_Access, Performance_User, Calendly, Mailchimp_Standard, Cloudie_Advisor_User, Blocked_Sender_Management, TeamsIntegration, Th_Badge_User, Multi_Factor_Authentication) |

**Why one combined user, not two:** real SDR (Jam Calapre) and BDR (Cyndi Amerman) reps share the same <your-org> Standard profile and differ only by the `Sales_BDR` permset + role. A single user holding the union of both permsets exercises both cadence surfaces. **Caveat:** the user carries a *single* UserRole (SDR), so BDR-owned-record visibility rides the role hierarchy rather than a second role — validate BDR cadence surfaces explicitly during the Login-As smoke. If a cadence entry rule ever hard-gates on single-role exclusivity, split into two faithful users (tracked deferral).

**Provisioning helper:** `salesforce/scripts/provision-cadence-qa-user.sh` (idempotent, dry-run by default; `--apply` writes). A rerun reconciles any missing permsets (self-healing). The prod User insert is a Layer 2.5 production write — gated for explicit human approval before `--apply`. Consumes one Salesforce seat.

**Audit trail:** a successful Login-As writes a `SetupAuditTrail` row `Logged in using Login-As access for Cadence QA (SDR/BDR Test)` under both the source admin and the target user. Query: `sf data query -o <your-email> -q "SELECT Action, CreatedDate, CreatedBy.Name FROM SetupAuditTrail WHERE Action LIKE '%loginAs%' ORDER BY CreatedDate DESC LIMIT 3" --use-tooling-api`.

> **Frontdoor token-scope caveat — RESOLVED 2026-06-14 (<clickup-task-id>).** Historically (empirical 2026-06-07), some non-interactive/dispatched CLI sessions saw `sf org open --url-only` return `ERROR_HTTP_403: Invalid_Scope` from `Org.getFrontDoorUrl` because the JWT-bearer token carried only `Api` + `RefreshToken` scopes — not the `Web` scope `frontdoor.jsp` requires — so the `servlet.su` + Playwright smoke (`/sf-smoke-as`) exited 3. **Durable fix shipped:** the JWT connected app **`OCC_Orchestrator_Agent`** (whose consumer key is the vaulted `SF-JWT-CONSUMER-KEY`, and which `<your-email>` JWT-authenticates against) now carries `<scopes>Web</scopes>` alongside `Api`/`RefreshToken`. A freshly-minted JWT token therefore passes frontdoor — one token serves both `sf project deploy` AND `/sf-smoke-as`, with no interactive `sf org login web` workaround. Verified 2026-06-14: after the deploy, re-minting the JWT and running `sf org open --url-only -o <your-email>` returned a frontdoor URL (was `Invalid_Scope`). If `Invalid_Scope` recurs, re-mint the JWT token (`sf org login jwt …`) so the new scope is reflected — a token minted *before* the scope deploy still lacks `web`.

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

### `<faultConnector>` is not accepted on every flow element — FlowSubflow has none

Only a subset of flow element types accept a `<faultConnector>` child. **Verified empirically 2026-05-25 (<clickup-task-id>)** — adding `<faultConnector>` to a `<subflows>` element is rejected at every XSD position with:

```
Element faultConnector invalid at this location in type FlowSubflow
```

Element types that **do** accept `<faultConnector>` (the elements that can throw a recoverable runtime fault):

- `FlowActionCall` (`<actionCalls>`)
- `FlowRecordCreate` / `FlowRecordUpdate` / `FlowRecordLookup` / `FlowRecordDelete` (`<recordCreates>` / `<recordUpdates>` / `<recordLookups>` / `<recordDeletes>`)
- `FlowWait` (`<waits>`)
- `FlowApexPluginCall` (`<apexPluginCalls>`)

Element types that do **not** accept `<faultConnector>` — notably `FlowSubflow` (`<subflows>`), plus `FlowAssignment`, `FlowDecision`, `FlowScreen`, `FlowLoop`. A subflow propagates its child flow's faults to the parent; you cannot intercept them at the `<subflows>` element itself.

**Retrofit decision for a subflow-only flow** (a flow whose only fault-capable work happens inside a called subflow):

1. **Subflow is <your-org>-owned and non-nesting** (it doesn't itself call further subflows) → retrofit the **target subflow's** own fault-capable elements with `<faultConnector>` + `FlowFaultRecorder` (this is what Wave 1 did for `Triage_Gate`).
2. **Subflow is managed/standard, or nests further subflows** → use the **Phase-1 interceptor** instead: the record-triggered `Intercept_System_Created_CSE_Error_Cases` flow routes platform-generated error Cases to `SalesforceFaultLogger`, capturing the fault without modifying the uninstrumentable subflow.

Full 20-flow classification (which flows are subflow-only and which retrofit path each takes) lives in `docs/superpowers/specs/2026-05-25-cse-wave1-noisiest-flow-retrofit-design.md` "FlowSubflow" section.

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

---

## qa-impersonation session-scope gotchas

**Empirical 2026-05-18, <clickup-task-id> Phase 0.**

Login-As via `servlet.su` in qa sandboxes can produce gacks that do NOT occur for the same user's real session in prod. This is a **platform-level scope restriction on Lightning Flow screen rendering under servlet.su impersonation** — not a flow bug, not an FLS gap, not a cache issue.

### Observed gack family

| Trailer | Flow | Action | Users observed |
|---|---|---|---|
| `(1787458317)` | `Lead_Log_a_Call` | `FlowRuntimeConnectController/ACTION$startFlow` | <service-email>.qa, <service-email>.qa |

**Gack IDs vary per request** (e.g. `2024165084-30690`, `630209098-73369`, `246401657-1405`, `607269782-524635`) — only the trailer `(1787458317)` is stable across occurrences. The `/sf-smoke-as` regression guard matches on trailer, not on the full ID.

### Root cause

The `FlowRuntimeConnect.startFlow` aura action returns `state: "SUCCESS"` with `returnValue.error` containing the gack when the Lightning runtime renders a flow **screen element** for an impersonated non-admin session. The flow EXECUTES correctly (FlowInterviewLog shows `FlowStart` + `ScreenNext`); the failure is in the Lightning UI render layer, not in the flow's SOQL or DML.

**Confirmed NOT caused by:**
- FLS gaps on Lead fields — <your-org> Standard profile has correct FLS for all fields used by `Log_a_Call` screen
- Sharing rules — gack occurs on leads owned by the impersonated user
- Cache drift — `?cache=false` URL param does not change the outcome
- cloudieAdvisor LWC — the failing component is `c:leadLogACallFlow`, not cloudieAdvisor
- Metadata drift — qa Lead flexipages match prod

### Detection

The `/sf-smoke-as` script now exits **8** (not 1) when a FlowRuntimeConnect response matches a known-gack trailer:

```bash
# In qa — exits 8 (known gack, qa-impersonation-specific)
node tests/playwright/sf-smoke-as.mjs <lead-id> <service-email>.qa --org qa

# In qa — exits 0 (admin session, no gack)
node tests/playwright/sf-smoke-as.mjs <lead-id> <your-email>.qa --org qa
```

Known trailers are stored in `tests/playwright/sf-smoke-as/known-gacks.json`. Regression test: `tests/playwright/sf-smoke-as/test-known-gacks.mjs`.

### Workaround for smoke testing

- **Admin smoke**: Run `/sf-smoke-as --org qa <your-email>.qa` — exits 0, confirms no regressions for the admin path.
- **Non-admin behavior validation**: Since the gack is impersonation-specific, the real Jam/Chris flow experience cannot be validated via `servlet.su` Login-As. Use FlowInterviewLog to verify the flow execution path is correct (FlowStart → ScreenNext → expected elements), then rely on prod deployment for real-user smoke.
- **Known-gack exit 8**: Treat exit 8 as "known platform limitation — flow execution is correct, screen rendering under impersonation is impacted". This is expected for all `<your-org> Standard` profile users on `Lead_Log_a_Call` via Login-As in qa.

### Capture quirk — SUCCESS-state responses

The v1 aura capture only checked for `state: "ERROR"` responses. The FlowRuntimeConnect gack is returned in a `state: "SUCCESS"` response with the error nested at `returnValue.error`. The updated `sf-smoke-as.mjs` (Phase 0, <clickup-task-id>) explicitly checks for this pattern.

**Pattern (for custom aura listeners):**
```js
// Check for SUCCESS-state responses with returnValue.error containing a gack
const parsed = JSON.parse(body);
const rv = parsed?.actions?.[0]?.returnValue;
if (rv && typeof rv.error === 'string' && /\d+-\d+\s*\(\d+\)/.test(rv.error)) {
  // This is a FlowRuntimeConnect gack in a SUCCESS-state response
}
```

---

## Login-As smoke testing — v2 contract

**Phase 2 deliverable — <clickup-task-id>.** Extends the v1 read-only smoke with `--save` click-through, assertion DSL, persona-template leads, and journaled 5-surface cleanup.

**Record selector.** A bare Id resolves its object through the prefix map in `tests/playwright/sf-smoke-as.mjs` (`ID_PREFIX_MAP`: Lead, Case, Account, Contact, Opportunity, `SFDC_Employee__c`). For any other object, pass the Lightning URL `https://<instance>/lightning/r/<ObjectApiName>/<Id>/view`; the object name is taken from the URL. Custom-object key prefixes differ between orgs (`Employee_Compensation__c` is `a1S` in qa), so do not extend the map for custom objects. (empirical (2026-10-08, <clickup-task-id>): a bare `a1S…` Id and, before this fix, its Lightning URL both exited 64 with `Unknown Id prefix 'a1S'`.)

### --save click-through

`--save` drives the Log a Call quick action end-to-end:
1. Clicks the "Log a Call" button on the Lead Record page
2. Fills the Comments field with a smoke marker string
3. Clicks "Save and Move to Next Lead" (the user-visible contract per <knowledge-base> article 3727088)
4. Waits for URL transition to confirm next-lead navigation
5. Captures a post-save screenshot (`/tmp/sf-smoke-as-<runid>-save.png`)

If the Email_Only_Lead_Screen appears instead of the standard modal, the "Next" button is clicked as fallback.

**Safety for email-only flow branches:** `smoke-recipients.json` lists allowed email addresses/domains. If the lead's email is not in the allowlist AND the smoke could trigger an email branch, the smoke refuses before Save. Synthetic persona-template leads use `*@<your-org>.qa` addresses which are in the allowlist.

**Prod guard:** `--save` against prod (`<your-email>` or `prod`) requires `SF_SMOKE_SAVE_PROD_CONFIRMED=1` env var. QA is the default and safe for automated runs.

### Assertion DSL

Post-save assertions evaluate SOQL-fetched field values:

```bash
--assert Lead.Lead_Cadence_Day__c==2      # numeric equality
--assert "Lead.Lead_Notes__c~made call"   # regex match (case-insensitive)
--assert Lead.Status!=Closed Lost         # inequality
```

Exit code 9 if any assertion fails. Assertions run after the save click-through.

### Journaled 5-surface cleanup

Every `--save` run takes a pre-smoke snapshot and reverses all mutations in a `finally` block. Reversal order (reverse of creation order):

| Surface | Snapshot | Reversal |
|---|---|---|
| servlet.su session | n/a | `page.goto('about:blank')` |
| Tasks | `SELECT Id FROM Task WHERE WhoId = '<leadId>'` | DELETE Task Ids NOT in snapshot |
| EmailMessages | `SELECT Id FROM EmailMessage WHERE RelatedToId = '<leadId>'` | DELETE EmailMessage Ids NOT in snapshot |
| ContentDocumentLinks | `SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = '<leadId>'` | DELETE ContentDocument Ids NOT in snapshot |
| Lead fields | `SELECT Lead_Notes__c, Lead_Cadence_Day__c, Next_Scheduled_Date__c, OwnerId FROM Lead WHERE Id = '<leadId>'` | UPDATE back to snapshot |

Journal write-ahead: every intent row is written BEFORE the mutation. Cleanup result (`ok: true/false`) written AFTER each step.

**Mid-flight recovery:** if cleanup fails (exit 7):

```bash
node tests/playwright/sf-smoke-as/resume-cleanup.mjs --lead <leadId> --runid <runId> --org qa
```

The resume script reads the journal, skips already-completed steps (idempotent), and re-runs any incomplete cleanup steps.

### Persona templates

`--persona-template` synthesizes a known-shape lead via Apex anonymous and tags it with `sf-smoke-persona:<template>:<runId>` in `Description`. The lead is deleted at end-of-run unless `--keep`.

Available templates:

| Template | Lead_Cadence_Day__c | Status |
|---|---|---|
| `day-1-cold` | 1 | New |
| `day-5-cold` | 5 | New |
| `day-20-terminal` | 20 | Attempting Contact |

### New exit codes (v2)

| Code | Meaning |
|---|---|
| 7 | Cleanup failed — journal path + resume command in stderr |
| 9 | `--assert` assertion(s) failed — post-save SOQL values did not match |

Exit 6 (v1 `--save` reservation) is removed in v2. `--save` now runs the full click-through.

### Render-assert verdict (v2.1 — <clickup-task-id>)

The v1/v2 capture only flagged an aura `state:ERROR`. A component that silently
never mounts (e.g. the `Convert_Lead_Fast` LWC, <clickup-task-id>) emits no such error, so
the smoke false-passed. v2.1 adds a **render verdict**: a clicked action with no
*visible* expected content is a failure (exit `10`).

- **Auto-require rule:** any action click MUST be paired with a render expectation —
  an `expect-visible:<text>` step, the top-level `--expect-render "<text>"` flag, or
  (for `--save`) the built-in Log-a-Call form expectation. A click with no expectation
  exits `64` before the browser launches.
- **Inert-boundary filter:** the Aura "Sorry to interrupt" / CSS-Error boundary exists
  in every Lightning DOM; it is ignored unless it is itself `isVisible()` (a visible
  boundary is a render failure).

### Inline step driver (`--steps`)

```bash
--steps "click:Convert_Lead_Fast; expect-visible:Converting:; screenshot:flow-screen"
```

`;`-separated `verb:arg` tokens: `click:<label>`, `expect-visible:<text>`,
`fill:<label>=<value>`, `screenshot:<label>`, `wait:<ms>`. Distinct from the
natural-language `--doc` grammar; shares Playwright primitives via `actions.mjs`.
Named screenshots land in `/tmp/sf-smoke-as-<runId>/screenshots/<label>.png` with a
`manifest.json`.

### Prod-safe `--no-commit` (default in prod)

In prod (`--org <your-email>`/`prod`), `--save`/`--steps` default to `--no-commit`:
open → screenshot → assert render → STOP before the irreversible commit. The real
write path requires explicit `--commit` AND `SF_SMOKE_SAVE_PROD_CONFIRMED=1`. qa keeps
the full commit path by default.

### `--via-cowork` delegation

`--via-cowork` writes a session-stamped task into `~/Projects/Cowork/tasks/inbox/`
(per `docs/runbooks/cowork-queue.md`) for the human-grade authed/visible pass, then
bounded-polls `done/`/`blocked/`/`needs-input/` (`--cowork-timeout <seconds>`, default
600) and reads back the verified result + named screenshots. Exit `12` on
blocked/timeout.

### New exit codes (v2.1)

| Code | Meaning |
|---|---|
| 10 | Render-assert failed — action clicked but expected content never visible |
| 12 | Cowork delegation blocked or timed out |
| 64 | Misconfiguration — click without a render expectation, or malformed `--steps` |

---

## App→profile permset provisioning (config-driven)

Ships with <clickup-task-id> (the PandaDoc-widget FLS fix). A reusable engine that assigns a managed
permission set to every user of a given profile — current users (one-time backfill) and future
users (a User after-save flow) — driven entirely by Custom Metadata config.

**To wire a new app to a profile: add ONE `App_PermSet_Provisioning__mdt` record.** No code or
flow change. Example — give the `Sales` profile DocuSign access:

```xml
<!-- salesforce/force-app/main/default/customMetadata/App_PermSet_Provisioning.Sales_DocuSign.md-meta.xml -->
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <label>Sales - DocuSign</label>
    <protected>false</protected>
    <values><field>Profile_Name__c</field><value xsi:type="xsd:string">Sales</value></values>
    <values><field>Permission_Set_API_Name__c</field><value xsi:type="xsd:string">DocuSignUser</value></values>
    <values><field>Active__c</field><value xsi:type="xsd:boolean">true</value></values>
</CustomMetadata>
```

Deploy the record, then run the backfill (below) for existing users of that profile. New users
get it automatically via the flow.

### Components

| Component | Role |
|---|---|
| `App_PermSet_Provisioning__mdt` | Config: `Profile_Name__c`, `Permission_Set_API_Name__c`, `Active__c` (one row per grant) |
| `AssignAppPermSetsAction.cls` | Invocable `assign(List<Request>)` (flow entry) enqueues a `Provisioner` Queueable; `run(List<Request>)` is the synchronous worker (CMT lookup → resolve permset → skip already-assigned → insert PSAs). `Active__c=false` and unresolvable permset names are skipped, never thrown. |
| `User_Provision_App_PermSets.flow-meta.xml` | User RecordAfterSave (create+update), immediate path → Get Profile → calls the invocable. Generic; no-ops for profiles with no active mapping. |
| `backfill-app-permsets.apex` | One-time anon Apex; calls `run()` synchronously across active users of mapped profiles. |

### MIXED_DML gotcha (why the engine uses a Queueable, not flow NewTransaction)

`PermissionSetAssignment` is a **Setup object**. Inserting it in the same transaction as the
User DML that triggered the flow throws `MIXED_DML_OPERATION`. Two platform constraints (verified
empirically 2026-06-13 at qa-validate) rule out the flow-side fixes:

- A record-triggered flow's **immediate** path cannot run a transaction-controlled action
  (`flowTransactionModel=NewTransaction`) — deploy fails with a field-integrity exception.
- An **AsyncAfterCommit** scheduled path requires change-detection entry criteria, so it would
  not fire on user **create**.

So the async boundary lives in Apex: `assign()` calls `System.enqueueJob(new Provisioner(...))`,
and the Queueable inserts the PSAs in its own transaction. (The older `User_Assign_Baseline_FLS`
flow uses immediate-path `NewTransaction` and still runs only because it is **grandfathered** — do
not copy that shape into a new flow.)

### Backfill (production data write — gate per Layer 2.5)

```bash
# DRY-RUN first: comment out the `AssignAppPermSetsAction.run(reqs);` line, then:
sf apex run -o <your-email> -f salesforce/scripts/backfill-app-permsets.apex   # logs "Candidate users: N"
# Live run (after explicit go-ahead): un-comment the run() line, re-run the same command.
```

voipdoc (Automations and Engineering): <internal-url>

Idempotent — re-running never creates duplicate assignments (the engine skips already-assigned
users). Verify: `sf data query -o <your-email> -q "SELECT COUNT(Id) c FROM PermissionSetAssignment WHERE Assignee.Profile.Name='<Profile>' AND Assignee.IsActive=true AND PermissionSet.Name='<Permset>'"`.
