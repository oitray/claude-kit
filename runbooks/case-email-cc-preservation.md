# Case Email CC Preservation — Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-27

## Architecture — parallel-field design

The original plan was to widen a single Text(255) seed field to LongTextArea(32000) in-place. The Setup UI blocked the type change while five active producer flows referenced the field, and stripping those references still left dozens of obsolete (non-deletable) flow versions blocking programmatic deploy.

The parallel-field design (Text(255) -> LongTextArea(32000) is the shape change, but two fields ship side by side) avoided a destructive operation on those flow versions:

- The original Text(255) field remains in use by the producer flows for seed addresses at case-create.
- A new LongTextArea(32000) field is written by the inbound thread-accumulator flow.
- The outbound `QuickActionDefaultsHandler` reads both fields and unions the addresses (deduped via `Set<String>`) at outbound time.

Follow-up work consolidates the producer flows onto the new field and eventually retires the original.

## Enabling / disabling the outbound handler

`CaseSettings.enableEmailActionDefaultsHandler` has an **asymmetric deploy contract** (empirical, prod, 2026-05-27):

| Transition | Mechanism | Why |
|---|---|---|
| **Enable (→ true)** | **Setup UI only** | Setting the flag `true` via Metadata API fails `Missing newEmailDefaultTemplateClass`; adding that companion element then fails `Property 'newEmailDefaultTemplateClass' not valid in version 66.0`. The required handler-class field is not exposed in the v66 metadata schema (tested at api-version 58/59/60/64 — same rejection; a retrieve of an enabled org omits the field entirely). |
| **Disable (→ false)** | Metadata API **or** UI | `false` carries no companion-field requirement, so the stripped-CaseSettings deploy validates clean. This is the kill switch. |

**Enable via Setup UI (the only path):**

1. Setup → **Support Settings** → **Edit** (or navigate directly to `/_ui/support/organization/SupportOrganizationSetupUi/e` via an `sf org open --url-only` frontdoor).
2. Check **"Enable Default Email Templates or the Default Handler for Email Action"** (form field id `caseEmailCustomizerClassEnabled`).
3. Set **Apex Class Name** (form field id `caseEmailCustomizerClassId`) to `SendEmailQuickActionDefaultsHandler`.
4. Save. Confirm via a `Settings:Case` retrieve — `enableEmailActionDefaultsHandler` reads `true` (note: the handler-class element is NOT round-tripped by the retrieve).

This UI toggle can be driven headless via Playwright + a frontdoor URL (see `.claude/rules/browser-automation.md`); the Login-As + composer smoke (T7 below) confirms the end-to-end pre-fill.

**Kill-switch (disable via Metadata API), the safe revert:** deploy a `Case.settings-meta.xml` with `<enableEmailActionDefaultsHandler>false</enableEmailActionDefaultsHandler>` and the `<emailToCase>` block stripped (a full retrieve includes read-only `<emailServicesAddress>` routing entries that fail on deploy). Reverts in <1 min.

## Outage history — `WITH USER_MODE` / `WITH SECURITY_ENFORCED` FLS-throw

Two prod outages were caused by FLS-enforcing SOQL clauses in `SendEmailQuickActionDefaultsHandler`. Both surfaced in Lightning as **"Unable to complete action"** on the Email quick action for non-`System Administrator` profiles:

- **2026-05-06** — `WITH SECURITY_ENFORCED` on the Case/Contact queries blocked every non-`<your-org> Standard` profile.
- **<clickup-task-id> (2026-05-26, PR #798)** — `WITH USER_MODE` on the `Email_CC_Skip_Rule__mdt` query threw `System.QueryException: sObject type 'Email_CC_Skip_Rule__mdt' is not supported` for the **<your-org> Standard** profile (the affected audience: ~1,412 CC-populated cases). CMTs have no row-level FLS concept; under USER_MODE a non-admin profile lacks object access and the query throws. Null-CC cases worked because they early-return before that query. **Fix:** drop the FLS-enforcing clauses, add `with sharing` at the class level (record visibility stays enforced). Per `.claude/rules/salesforce-dev.md` SOQL Safety — never grant CMT access profile-by-profile.

### Scheduled prod re-enable — <clickup-task-id> (2026-05-27)

After PR #798 shipped the FLS-fixed class, the handler was re-enabled in prod (it had been `false` since the 2026-05-06 disable). Run results:

| Step | Result |
|---|---|
| Pre1 baseline | handler `false`, old `WITH USER_MODE` class present — confirmed |
| Pre2 inert deploy | fixed class deployed, `RunSpecifiedTests` 22/22 green in prod |
| Flip | `enableEmailActionDefaultsHandler=true` via Setup UI (metadata path is a v66 gap); retrieve confirms `true`, all 15 E2C routing addresses intact |
| T3 (primary) | `SendEmailQuickActionDefaultsHandler_Test` 22/22, `runAs(<your-org> Standard)` regression green |
| T4 (E2C guard) | post-flip inbound E2C Case `00284938` created at 02:30:41Z — E2C unaffected |
| T5/T6 | all 3 paths + leading-comma parse + excluded + vendor early-return + profile matrix green in prod suite |
| T7 (live UI) | Login-As **Dana Curtis (<your-org> Standard)**, opened Email composer on CC Case 00284835 → Cc pre-filled `brice.sampson@basiccarbide.com` (leading comma stripped), no error |
