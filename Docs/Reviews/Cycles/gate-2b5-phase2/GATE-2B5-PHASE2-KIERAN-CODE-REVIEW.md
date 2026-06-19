# Gate 2B.5 — Phase 2: UI Layer — Kieran Code Review

**Reviewer:** Kieran (Adversarial Reviewer)
**Date:** 2026-05-19
**Scope:** Phase 2 implementation (UI Layer) — BeeChat-v5 + BeeChat-Mobile
**Verdict:** ⚠️ **NEEDS CHANGES** (1 Blocker, 2 Warnings, 5 Notes)

---

## BLOCKER

### B1: EmptyTopicsView missing `showArchiveToast` parameter — toast overlaps CTA buttons

**Severity:** Blocker
**Spec:** v3 Delta W7 / §3.2
**File:** `EmptyTopicsView.swift`, `TopicListView.swift`

The v3 spec (W7) requires `EmptyTopicsView` to accept `showArchiveToast: Bool` and add `60pt` bottom padding when the archive undo toast is visible, preventing overlap with the CTA buttons.

**Implementation gap:**

```swift
// EmptyTopicsView.swift — missing parameter
struct EmptyTopicsView: View {
    let hasImportableSessions: Bool
    let isLoading: Bool
    // showArchiveToast: Bool — MISSING
```

```swift
// TopicListView.swift — not passing it
EmptyTopicsView(
    hasImportableSessions: importCandidateCount > 0,
    isLoading: isLoadingCandidateCount,
    onStartConversation: { ... },
    onImportSessions: ...
)
// showArchiveToast: showArchiveUndo — NOT PASSED
```

When a user archives a topic and sees the empty state, the undo toast renders at `.bottom` overlay while the empty state buttons sit at the bottom with no offset. They overlap.

**Fix:** Add `let showArchiveToast: Bool` to `EmptyTopicsView` init, add `.padding(.bottom, showArchiveToast ? 60 : 0)` to the outer `VStack`, and pass `showArchiveToast: showArchiveUndo` from `TopicListView`.

---

## WARNINGS

### W1: Import sheet shows empty state before candidates load (UX flash)

**Severity:** Warning
**File:** `TopicListView.swift`, `ImportSessionsSheet.swift`

```swift
onImportSessions: importCandidateCount > 0 ? {
    Task { await loadImportCandidates() }
    isShowingImportSheet = true  // sheet opens BEFORE load completes
} : nil
```

The sheet is presented immediately (`isShowingImportSheet = true`) while `loadImportCandidates()` runs asynchronously. `ImportSessionsSheet` has no loading state parameter — it shows `candidates.isEmpty` empty text while loading, then populates. User sees "No sessions available to import" for ~500ms before candidates appear.

**Fix:** Either (a) add `isLoading` parameter to `ImportSessionsSheet` with a `ProgressView`, or (b) `await loadImportCandidates()` before setting `isShowingImportSheet = true`. Option (b) is simpler and avoids the flash entirely.

### W2: Redundant `@State private var streamingMessageId` in OnlineChatView + OfflineChatView

**Severity:** Warning
**File:** `OnlineChatView.swift`, `OfflineChatView.swift`

Both views declare:
```swift
@State private var streamingMessageId: String = "streaming-msg"
```

This value is passed to `MergedMessagesHelper.merge()` which has a hardcoded default of `"streaming-msg"`. The `@State` wrapper is unnecessary — it's a compile-time constant that never changes. `@State` on an immutable constant is wasted overhead and implies mutability that doesn't exist.

**Fix:** Remove `@State` and use a static constant, or rely on the default parameter:
```swift
// In both views:
private static let streamingMessageId = "streaming-msg"
// Or just omit the parameter and use the default
```

---

## NOTES

### N1: Import errors silently fail — no user feedback

**File:** `BeeChatMobileViewModel.swift` — `importSelected(_:)`

```swift
do {
    try persistenceStore.topicRepo.saveAndBridgeInTransaction(topic, sessionKey: session.id)
    count += 1
} catch {
    print("[ViewModel] Import failed for session \(session.id): \(error)")
}
```

If individual imports fail (TOCTOU race, constraint violation), they're logged to stderr and silently skipped. The user sees "Imported 3" out of 5 selected — no indication which failed or why. For a batch of 2-3 this is tolerable, but the UX is unclear.

**Recommendation:** Track failed IDs and show a post-import toast/alert: "3 of 5 imported — 2 already exist."

### N2: Offline draft persists across topic switches

**File:** `BeeChatView.swift`

`preservedDraft` is a `@State` on `BeeChatView`. When the user switches topics while offline, the draft from the previous topic persists and appears as placeholder text in the new topic's `OfflineChatView`. This could confuse the user about which topic their draft belongs to.

**Acceptable for Phase 2** but worth noting. Full fix would key draft by `topicId`.

### N3: TopicRow accessibility label incomplete vs spec

**Spec:** §4.1 — "Topic: {name}, {preview}, {time}, {unread}"

**Implementation:**
```swift
.accessibilityLabel("Topic: \(topic.name)")
.accessibilityHint("Tap to open conversation")
```

Preview, time, and unread count are omitted from the VoiceOver label. The unread badge has its own `.accessibilityLabel`, but the row label should include the full context per spec.

**Minor** — the unread badge is a separate element so VoiceOver will announce it separately, but the spec says the row should be self-contained.

### N4: `.onChange(of: viewModel.streamingContent)` removed — correct

The v2 spec had:
```swift
.onChange(of: viewModel.streamingContent) { _, _ in
    updateStreamingMessage()
}
```

This is absent in the v3 implementation. This is **correct** — the `mergedMessages` computed property reads `viewModel.streamingContent` reactively, so SwiftUI's dependency tracking handles updates without an explicit observer. Good cleanup.

### N5: `ConnectionStatusView` + reconnect button in offline input — dual retry paths

Both `BeeChatView`'s `ConnectionStatusView` and `OfflineChatView`'s input bar have reconnect buttons. This is intentional redundancy (visibility in both views) but rapid-tap on either could queue multiple `reconnect()` Tasks. `reconnect()` calls `disconnect()` then `connect()`, and `connect()` has a `guard syncBridge == nil` — so concurrent reconnects serialize via the guard. Not a bug, but worth knowing.

---

## Spec Compliance Summary

| Spec Section | Status | Notes |
|---|---|---|
| §2.1 createTopic() | ✅ | Matches spec exactly |
| §2.2 archiveTopic() + double-archive guard | ✅ | `guard !topic.isArchived` present |
| §2.3 unarchiveTopic() + re-select | ✅ | Sets `selectedTopicId` |
| §2.4 deleteTopic() | ✅ | Uses `deleteCascading()` |
| §2.5 fetchById() | ✅ | Returns regardless of archived status |
| §2.5 fetchAllActiveSessionKeys() | ✅ | No status filter — returns ALL bridges |
| §2.5 saveAndBridgeInTransaction() | ✅ | Atomic GRDB write, rolls back on failure |
| §2.6 importCandidates() | ✅ | System prefix filter present |
| §2.7 importSelected() | ✅ | Pre-check + atomic transaction |
| §2.8 TopicError (Sendable) | ✅ | Conforms to `LocalizedError, Sendable` |
| §3.1 NewTopicSheet | ✅ | Popover + compact adaptation |
| §3.2 EmptyTopicsView | ⚠️ | Missing `showArchiveToast` (B1) |
| §3.3 TopicListView | ✅ | Swipe actions, undo toast, import flow |
| §3.4 BeeChatView coordinator | ✅ | Sub-view split correct |
| §3.4.1 OnlineChatView | ✅ | Generic type matches spec |
| §3.4.2 OfflineChatView | ✅ | Generic type + inputViewBuilder correct |
| §3.5 ImportSessionsSheet | ✅ | Edit mode + empty state |
| §4 Accessibility labels | ⚠️ | Row label incomplete (N3) |
| §4.3 Reduce Motion | ✅ | `reduceMotion` checked throughout |
| §6.8 macOS regression | ✅ | New methods in BeeChat-v5, no macOS path affected |

---

## Verdict: NEEDS CHANGES

**Must fix before merge:**
- B1: Add `showArchiveToast` to `EmptyTopicsView` and pass it from `TopicListView`

**Should fix (low effort, high value):**
- W1: Load import candidates before presenting sheet, or add loading state
- W2: Remove redundant `@State` for `streamingMessageId`

**Overall assessment:** Clean implementation. The Exyte generic type split is correctly handled, atomic transaction rollback is sound, double-archive guard works, and accessibility is mostly complete. The single blocker is a straightforward parameter addition.
