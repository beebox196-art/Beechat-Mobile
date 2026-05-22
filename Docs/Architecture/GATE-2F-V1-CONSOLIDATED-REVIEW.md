# Gate 2F Spec v1 — Consolidated Review

**Date:** 2026-05-22
**Consolidator:** Bee (Coordinator)
**Reviewers:** Q (Builder), Kieran (Adversarial), Mel (Designer)
**Spec:** GATE-2F-CROSS-DEVICE-TOPIC-SYNC.md (v1)
**Result:** 7 blockers, 13 warnings, 3 questions → all resolved in v2

---

## Reviewer Reports

| Reviewer | Report | Blockers | Warnings | Highlights |
|---|---|---|---|---|
| Q (Builder) | [GATE-2F-V1-Q-REVIEW.md](GATE-2F-V1-Q-REVIEW.md) | 3 | 5 | 2 |
| Kieran (Adversarial) | [GATE-2F-V1-KIERAN-REVIEW.md](GATE-2F-V1-KIERAN-REVIEW.md) | 5 | 3 | 2 |
| Mel (Designer) | [GATE-2F-V1-MEL-REVIEW.md](GATE-2F-V1-MEL-REVIEW.md) | 2 | 5 | 2 |

---

## Blockers (deduplicated, merged)

| # | Sources | Issue | v2 Resolution |
|---|---|---|---|
| 1 | Q-B1, K-B1 | `operator.admin` scope dependency undocumented | ✅ Scope table added, exit criteria added, risk added |
| 2 | K-B2 | `rejectWebchatSessionMutation` client identity contract undocumented | ✅ Client identity contract table added |
| 3 | Q-B2, K-B3 | `SessionInfo.pluginExtensions` shared-package prerequisite | ✅ Extracted to Phase 0 with explicit exit criteria |
| 4 | Q-W2, K-B4 | Topic deletion leaves ghost on gateway | ✅ `clearTopicState` with `pluginPatch(unset:true)` on delete |
| 5 | K-B5 | iPhone creates topics with random UUIDs on connect | ✅ Explicit removal + exit criterion |
| 6 | Mel-B1 | No loading state for first launch | ✅ Skeleton/shimmer + pull-to-refresh in Phase 2 |
| 7 | Mel-B2 | Archived topics vanish silently on iPhone | ✅ Toast "Topic archived from Mac" + allow-while-typing |

---

## Warnings (deduplicated, merged)

| # | Sources | Issue | v2 Resolution |
|---|---|---|---|
| 1 | Q-W1, K-W3 | Non-atomic RPC calls, no error handling | ✅ `pluginPatch` first, then `patch`. Log errors. Reconcile on reconnect. |
| 2 | Q-W3 | No retry/queue for offline publish | ✅ `reconcileAllTopicState()` on reconnect |
| 3 | Q-W4 | `topicId` redundant with session key | ✅ Keep for explicitness, add debug assert |
| 4 | Q-W5 | `AnyCodable` untyped — fragile | ✅ `BeeChatTopicMetadata: Codable` struct + convenience method |
| 5 | K-W1 | Risk table wrong: `sessions.changed` DOES include `pluginExtensions` | ✅ Risk table corrected |
| 6 | K-W2 | `updatedAt` for last-write-wins is wrong model | ✅ Changed to "gateway wins, iPhone overwrites" |
| 7 | Mel-W1 | Import flow removal needs replacement | ✅ First-run onboarding screen |
| 8 | Mel-W2 | Empty state not defined | ✅ Bee/hive motif + guidance text |
| 9 | Mel-W3 | No sync status indicator | ✅ Subtle "Synced"/"Last synced X ago" |
| 10 | Mel-W4 | Archive-while-typing edge case | ✅ Allow send + toast |
| 11 | Mel-W5 | iPhone topic creation removed too early | ✅ Gate behind config, not delete. Logged as future "Quick Chat" |

---

## Questions (resolved)

| # | Source | Question | Resolution |
|---|---|---|---|
| 1 | Mel-Q1 | Expected latency for `sessions.changed`? | Sub-second on same gateway. Documented. |
| 2 | Mel-Q2 | Show `projectPath` on iPhone? | Store but don't render. |
| 3 | Mel-Q3 | What happens with two Macs? | Future concern. Added to future development table. |

---

## Key Architectural Decisions from Review

1. **Gateway is truth, iPhone is cache.** No last-write-wins, no timestamp comparison. iPhone always overwrites with gateway data. (Kieran W2 → fundamental model change from v1)

2. **`pluginPatch` first, `patch` second.** If metadata fails, don't set label. Consistent partial failure is better than inconsistent partial success. (Q-W1, K-W3)

3. **Full re-list on `sessions.changed`, not incremental.** For 20-50 sessions, this is fine. Incremental event handling is a future optimization. (Q-B3)

4. **`SessionInfo.pluginExtensions` is Phase 0, not a Phase 1 checkbox.** Shared-package work that both apps depend on. (Q-B2, K-B3)

5. **Topic deletion clears gateway metadata.** `sessions.pluginPatch(unset:true)` prevents ghost topics. (K-B4)

6. **UX: toast on archive, allow-while-typing.** Silent disappearance is a trust-breaker. (Mel-B2, W4)

---

## Verdict

**v1: REVISED.** All 7 blockers resolved in v2 spec. Team consensus on architecture. Ready for Adam approval then Phase 0 implementation.

**v2 spec:** [GATE-2F-CROSS-DEVICE-TOPIC-SYNC-v2.md](GATE-2F-CROSS-DEVICE-TOPIC-SYNC-v2.md)