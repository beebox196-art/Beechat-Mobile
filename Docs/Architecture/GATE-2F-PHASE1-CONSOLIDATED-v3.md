# Gate 2F Phase 1: Mac-Side Topic Publishing — Consolidated Review

**Date:** 2026-05-22
**Consolidator:** Bee (Coordinator)
**Spec:** `GATE-2F-PHASE1-MAC-PUBLISHING-v3.md`
**Reviewers:** Q (Builder ✅), Kieran (Adversarial ✅), Mel (Designer ✅)

---

## Reviewer Reports

| Reviewer | Report | Blockers | Warnings | Verdict |
|---|---|---|---|---|
| Q (Builder) | [GATE-2F-PHASE1-Q-REVIEW.md](GATE-2F-PHASE1-Q-REVIEW.md) | 3 | 4 | REVISED — all resolved in v3 |
| Kieran (Adversarial) | [GATE-2F-PHASE1-KIERAN-REVIEW.md](GATE-2F-PHASE1-KIERAN-REVIEW.md) | 3 | 7 | NOT READY — all resolved in v3 |
| Mel (Designer) | [GATE-2F-PHASE1-MEL-REVIEW.md](GATE-2F-PHASE1-MEL-REVIEW.md) | 0 | 3 | PASS — all resolved in v3 |

---

## Blockers Resolved (v1 → v3)

| ID | Source | Issue | v3 Resolution |
|---|---|---|---|
| 1 | Q-B1 | `mode: "webchat"` blocks sessions.patch | ✅ Pre-step: change to `"ui"` in AppRootView (2 places) |
| 2 | Q-B2 | No `rpc`/`encodeCodable` helper exists | ✅ All code uses `gateway.call` + `AnyCodable` with explicit JSON round-trip |
| 3 | Q-B3 | BeeChatTopicMetadata encoding unclear | ✅ `JSONEncoder` → `JSONDecoder(AnyCodable.self)` pattern specified |
| 4 | K-B1 | Half-published ghost topic (pluginPatch succeeds, patch fails) | ✅ Serial `TopicPublishQueue` actor prevents race + metadata-first ordering |
| 5 | K-B2 | operator.admin scope asserted, not verified | ✅ `verifyAdminScope()` in `SyncBridge.start()` — log on mismatch |
| 6 | K-B3 | `assert` compiled out in Release | ✅ Runtime guard with `log.warning()` + skip publish on mismatch |

---

## Warnings Resolved

| ID | Source | Issue | v3 Resolution |
|---|---|---|---|
| 1 | K-W1 | Race condition on rapid CRUD | ✅ `TopicPublishQueue` actor serialises per topic |
| 2 | K-W2 | Reconnect flood (100 simultaneous RPCs) | ✅ `TaskGroup` with concurrency limit of 5 |
| 3 | K-W3 | clearTopicState one-shot, no retry | ✅ 2 attempts with 1s delay between |
| 4 | K-W4 | Value encoding fragile | ✅ Explicit JSON round-trip pattern, consistent with existing codebase |
| 5 | K-W6 | Hardcoded protocol strings | ✅ Acknowledged — consistent with existing patterns. Future improvement. |
| 6 | K-W7 | `deriveSessionKey` undefined | ✅ Use `topic.sessionKey` directly (already exists on Topic model) |
| 7 | Mel-W1 | Risk table mentions UI warning | ✅ Corrected to log-only, no UI changes |
| 8 | Mel-W2 | Reconcile blocks main thread | ✅ Wrapped in `Task.detached` |
| 9 | Q-W1 | Double RPC traffic on reconnect | ✅ Concurrency limit (5) + serial queue |
| 10 | Q-W2 | Offline burst on reconnect | ✅ Same as above |

---

## Key Architectural Decisions Confirmed

1. **`mode: "ui"` fix is pre-Phase 1.** Must be tested independently before any publishing code ships.
2. **Metadata first, label second.** The safer partial failure state.
3. **Serial queue per topic.** Prevents stale overwrites from rapid CRUD.
4. **Concurrency limit on reconcile.** Max 5 simultaneous publishes on reconnect.
5. **Gateway wins, fire-and-forget locally.** Simple, correct, appropriate for personal use.
6. **Log-only on scope mismatch.** No UI changes in Phase 1. Future: settings banner.
7. **Runtime guard on topicId/sessionKey match.** Not just a debug assert.
8. **`topic.sessionKey` used directly.** No derive function needed.

---

## Verdict

**v3: READY FOR APPROVAL.** All blockers resolved. All warnings addressed. Architecture unchanged (still solid). Implementation details corrected to match actual codebase API surface.

**Spec:** [GATE-2F-PHASE1-MAC-PUBLISHING-v3.md](GATE-2F-PHASE1-MAC-PUBLISHING-v3.md)

**Next step:** Adam approval → Q implements → Kieran reviews → Bee validates → Adam validates on real devices.
