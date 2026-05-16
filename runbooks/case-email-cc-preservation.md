# Case Email CC Preservation — Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-05

## Architecture — parallel-field design

The original plan was to widen a single Text(255) seed field to LongTextArea(32000) in-place. The Setup UI blocked the type change while five active producer flows referenced the field, and stripping those references still left dozens of obsolete (non-deletable) flow versions blocking programmatic deploy.

The parallel-field design (Text(255) -> LongTextArea(32000) is the shape change, but two fields ship side by side) avoided a destructive operation on those flow versions:

- The original Text(255) field remains in use by the producer flows for seed addresses at case-create.
- A new LongTextArea(32000) field is written by the inbound thread-accumulator flow.
- The outbound `QuickActionDefaultsHandler` reads both fields and unions the addresses (deduped via `Set<String>`) at outbound time.

Follow-up work consolidates the producer flows onto the new field and eventually retires the original.
