# Gate 2B.5 — Phase 2 UI Layer: Consolidated Review (v2)

**Date:** 2026-05-19
**Status:** Compiled — awaiting v3 spec revision
**Reviewers:** Q (Builder) ✅, Kieran (Adversarial) ✅, Mel (Designer) ✅

---

## Reviewer Verdicts

| Reviewer | Verdict | Blockers | Warnings |
|----------|---------|---------|----------|
| **Q** | 🟡 NEEDS CHANGES | 1 | 10 |
| **Kieran** | 🟡 NEEDS CHANGES | 2 | 5 |
| **Mel** | 🟡 NEEDS CHANGES | 2 | 7 |

**Total unique blockers: 4** (after deduplication)

---

## Blockers (Consolidated & Deduplicated)

| # | Issue | Sources | Impact | Fix |
|---|-------|---------|--------|-----|
| **B1** | `BeeChatView` `if/else` on `connectionState` produces two different `ChatView` generic types — won't compile | Q NB1, Mel B1 | 🔴 Compile failure | Extract into separate `OnlineChatView` and `OfflineChatView` sub-views (Q Option B). Each has its own concrete ChatView generic type. |
| **B2** | `importSelected()` rollback uses `deleteCascading()` which deletes gateway messages that already existed before the import attempt | Kieran B1 | 🔴 Data loss | Replace `deleteCascading()` with targeted delete: delete only the topic row + the new bridge entry, NOT messages. Or: attempt `saveBridge()` first (catch UNIQUE), only `save(topic)` if bridge succeeds. |
| **B3** | Draft text lost on online↔offline ChatView switch | Mel B2 | 🔴 User-facing data loss (M10 requirement) | Preserve draft in a `@State` that survives the view switch. On reconnection, feed the preserved draft back into the new ChatView's input. Use `@State private var preservedDraft: String = ""` and `.onChange(of: connectionState)` to capture/restore. |
| **B4** | `importSelected()` TOCTOU race — `fetchAllActiveSessionKeys()` pre-check doesn't protect against concurrent macOS writes to the same bridge table | Kieran B2 | 🟡 Constraint error → B2 data loss | Wrap each `save()` + `saveBridge()` in a GRDB `write` transaction. On UNIQUE constraint error specifically, delete only the topic row (not cascading). Clarify that the pre-check reduces but doesn't prevent violations. |

---

## Warnings (High Severity — Should Fix)

| # | Issue | Sources | Fix |
|---|-------|---------|-----|
| **W1** | `.presentationDetents` silently ignored on iPad popover (works on iPhone adapted sheet) | Q NB2, Mel W1 | Document explicitly. `.frame` on `NewTopicSheet` controls iPad popover size. |
| **W2** | Toast timeout 5s too short for non-VoiceOver users | Mel W2 | Change to 7s for non-VoiceOver. 30s for VoiceOver stays. |
| **W3** | No loading state for import candidate count — shows wrong empty state briefly | Mel W3 | Add `isLoadingCandidateCount` state + subtle loading indicator. |
| **W4** | "No conversations yet" vs "No topics yet" — confusing terminology for new users | Mel W4 | Use "topics" consistently. Fresh install → "No topics yet. Start a topic when you're ready to chat with Bee." |
| **W5** | `dynamicTypeSize` hardcoded `.large` instead of `@Environment(\.dynamicTypeSize)` | Q W5/W9 | Use `@Environment(\.dynamicTypeSize) private var dynamicTypeSize` directly. |
| **W6** | `UIAccessibility.isVoiceOverRunning` is UIKit; should use `@Environment(\.accessibilityVoiceOverEnabled)` | Q W10 | Use SwiftUI-native environment value. |
| **W7** | Toast + empty state overlap when archiving last topic | Mel W5, Kieran W4 | Add bottom padding to `EmptyTopicsView` when toast visible. |
| **W8** | Double-archive shows undo toast for already-archived topic | Kieran W1 | Add `guard !topic.isArchived else { return nil }` in `archiveTopic()`. |
| **W9** | `inputViewBuilder` closure parameter naming misleading (5th is `inputViewActionClosure`, not `dismissKeyboard`) | Q W3, Mel B1 | Correct the parameter labels in the spec code. |
| **W10** | `TopicError` not `Sendable` — Swift 6 strict concurrency will flag | Q W7 | Add `: Sendable` conformance (trivial for enums). |

---

## Warnings (Lower Severity — Defer or Accept)

| # | Issue | Source |
|---|-------|--------|
| VoiceOver announcement reliability — use `UIAccessibility.post()` | Kieran W2 |
| Import sheet empty state needs retry button | Mel W6 |
| Reduce Motion table missing 3+ animations | Mel W7 |
| Import completion has no feedback | Mel observation |
| Delete confirmation double "this" in copy | Mel observation |
| `unarchiveTopic` uses `save()` not dedicated repo method (acceptable but inconsistent) | Q W8 |
| Offline ChatView `didSendMessage` callback should be empty/guarded | Q W1 |
| `existingKeys` stale within `importSelected()` loop (structurally impossible to trigger) | Kieran W5 |
| iPad popover auto-focus timing issue (`.onAppear` before animation completes) | Mel observation |
| `.xxLarge`/`.xxxL` may need `.large` detent | Mel observation |

---

## v1 Blocker Resolution Status

| # | v1 Blocker | v2 Fix | v2 Review Status |
|---|-----------|--------|-----------------|
| B1 | `.sheet` + `.popover` dual modifier | Single `.popover` with compact adaptation | ✅ Resolved (all 3 reviewers confirm) |
| B2 | `archiveTopic()` ignores existing repo method | Uses `topicRepo.archive(topicId:)` | ✅ Resolved (all 3 reviewers confirm) |
| B3 | Toast uses `DispatchQueue.asyncAfter` | `Task` + `Task.sleep`, VoiceOver-safe | ✅ Resolved (all 3 reviewers confirm) |
| B4 | Import button shown on connection state, not count | Conditional on `importCandidateCount > 0` | ✅ Resolved (Mel confirms) |
| B5 | `saveBridge()` UNIQUE conflict in import | Pre-check + rollback | ⚠️ Partially resolved — see B2/B4 above |
| B6 | `.disabled()` on ChatView disables message list | `inputViewBuilder` with offline bar | ⚠️ Resolved for offline case, but see B1 (generic type mismatch) |
| B7 | `unarchiveTopic()` doesn't re-select | Sets `selectedTopicId = topic.id` | ✅ Resolved (Mel confirms) |

---

## v3 Spec Changes Required

### Must Fix (Blockers)

1. **B1:** Extract `OnlineChatView` and `OfflineChatView` as separate View structs
2. **B2:** Replace `deleteCascading()` in import rollback with targeted delete (topic + bridge only)
3. **B3:** Add draft preservation across online/offline transitions (`preservedDraft` state + capture/restore on connection change)
4. **B4:** Wrap import `save()` + `saveBridge()` in GRDB write transaction; handle UNIQUE constraint specifically

### Should Fix (High Warnings)

5. **W1:** Document `.presentationDetents` behavior with popover
6. **W2:** Change toast timeout to 7s (non-VoiceOver) / 30s (VoiceOver)
7. **W3:** Add loading state for import candidate count
8. **W4:** Consistent "topics" terminology in empty states
9. **W5:** Use `@Environment(\.dynamicTypeSize)` instead of hardcoded value
10. **W6:** Use `@Environment(\.accessibilityVoiceOverEnabled)` instead of UIKit
11. **W7:** Add bottom padding to empty state when toast visible
12. **W8:** Guard against double-archive in `archiveTopic()`
13. **W9:** Correct `inputViewBuilder` closure parameter labels
14. **W10:** Add `Sendable` to `TopicError`