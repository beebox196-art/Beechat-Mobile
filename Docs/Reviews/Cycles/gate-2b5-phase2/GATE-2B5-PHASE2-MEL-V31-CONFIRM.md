# Gate 2B5 Phase 2 - Mel UX Confirmation Review (v3.1)

**Date:** 2026-05-27  
**Reviewer:** Mel  
**Scope:** Quick confirmation review of v3.1 updates against Mel v3 concerns/suggestions  
**Spec reviewed:** `GATE-2B5-PHASE2-SPEC-v3.1.md`  
**Verdict:** APPROVED - previous UX concerns are addressed or explicitly deferred

## Summary

v3.1 adequately resolves the specific UX clarity gaps raised in Mel's v3 review for this gate. The spec now documents the main user-facing limitations instead of leaving them implicit.

No new blocker from Mel.

## Concern Confirmation

| Prior item | v3.1 status | Confirmation |
|---|---|---|
| C1 - Sync can happen invisibly | Deferred | Adequately documented. `Sync state UI feedback` is now explicitly out of scope and deferred to the next gate. This is acceptable for this spec as long as the next gate carries it forward. |
| C2 - Topic origin and naming need a display rule | Addressed | Duplicate names are explicitly allowed, and `lastMessagePreview` is defined as secondary row text to disambiguate same-name local/Mac topics. |
| C3 - Topic ordering is underspecified | Addressed/deferred | v3.1 specifies `lastActivityAt` descending as the default, with further UX refinement deferred. This is enough for implementation. |
| C4 - Archived Mac topics may feel like silent deletion | Documented limitation | The one-way Mac-to-iPhone authority model is clearer now. iPhone renames are overwritten by Mac sync, and Mac archives remain authoritative for Mac-origin topics. Still a UX concern, but not a blocker for this gate. |
| C5 - Message dedup may create a visible correction | Still acceptable | No additional UX validation text was added, but the core success criterion remains: replies appear below the user's message. This was a concern, not a blocker, and does not need to hold v3.1. |

## Suggestion Confirmation

| Prior item | v3.1 status | Confirmation |
|---|---|---|
| S1 - Add sync state copy to empty/local-only states | Deferred | Covered by explicit `Sync state UI feedback` deferral. |
| S2 - Treat malformed and empty payloads differently in UI/logging | Partially addressed | Data behavior remains safe. UI/diagnostic distinction can ride with the next sync-state gate. |
| S3 - Use `lastMessagePreview` carefully | Addressed enough | `lastMessagePreview` is now part of the duplicate-name disambiguation rule. Future truncation/fallback polish can remain implementation detail. |
| S4 - Add duplicate-name test case | Addressed by spec behavior | The spec states both duplicate-name topics remain visible and are disambiguated with secondary text. A test is still useful, but the behavioral requirement is now present. |
| S5 - Validate message ordering with short-message edge cases | Still suggested | The >=20 character dedup guard remains a deliberate data-safety choice. Short-message manual validation is still recommended, but not blocking. |

## Final Assessment

Approved from UX/design review.

The important v3 gaps are now either directly specified or clearly deferred:
- iPhone-side topic renames are overwritten by Mac sync as a known one-way limitation.
- Duplicate topic names remain side by side with `lastMessagePreview` as secondary disambiguating text.
- Topic ordering uses `lastActivityAt` descending for now.
- Sync state UI feedback is deferred to the next gate.

Remaining UX follow-up for the next gate: define visible sync status/local-only states and confirm message-list stability during dedup with short and long user messages.
