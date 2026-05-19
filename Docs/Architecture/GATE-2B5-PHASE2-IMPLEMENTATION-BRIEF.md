# Gate 2B.5 — Phase 2: Implementation Brief for Q

**Date:** 2026-05-19
**Status:** APPROVED by all three reviewers (Mel, Kieran, Q)
**Base spec:** GATE-2B5-PHASE2-UI-LAYER-v2.md + v3-DELTA.md (read both)
**Previous work:** Phase 1 committed at `31f6848` in BeeChat-v5

---

## What to Build

Phase 2 adds the UI layer on top of the Phase 1 data layer. 9 files to create/modify.

### Files to CREATE (new)

| File | Package | What |
|------|---------|------|
| `NewTopicSheet.swift` | BeeChatUI | Adaptive popover for creating topics |
| `EmptyTopicsView.swift` | BeeChatUI | Empty state (2 variants: fresh install vs import available) |
| `OnlineChatView.swift` | BeeChatUI | Online chat sub-view (default Exyte input) |
| `OfflineChatView.swift` | BeeChatUI | Offline chat sub-view (disabled input + reconnect) |
| `ImportSessionsSheet.swift` | BeeChatUI | Multi-select import sheet |

### Files to MODIFY (existing)

| File | Package | What to Add |
|------|---------|-------------|
| `BeeChatMobileViewModel.swift` | BeeChatMobileKit | `createTopic`, `archiveTopic`, `unarchiveTopic`, `deleteTopic`, `importCandidates`, `importSelected`, `TopicError` enum |
| `TopicRepository.swift` | BeeChat-v5/BeeChatPersistence | `fetchById()`, `fetchAllActiveSessionKeys()`, `saveAndBridgeInTransaction()` |
| `TopicListView.swift` | BeeChatUI | `+` button, popover, empty state, swipe actions, archive undo (Task-based), import flow |
| `BeeChatView.swift` | BeeChatUI | Refactor to coordinator + delegate to OnlineChatView/OfflineChatView |

---

## Critical Implementation Notes (from reviews)

These are the things the reviewers caught that aren't obvious from the spec text:

### 1. saveAndBridgeInTransaction SQL — include all columns

The spec's raw SQL INSERT omits `spaceId` and `bridgeVersion`. Q verified this works (defaults apply), but the existing `saveBridge()` method includes them explicitly. **Match the existing `saveBridge()` pattern** — include `spaceId` ('default') and `bridgeVersion` (1) in the INSERT for consistency:

```sql
INSERT INTO topic_session_bridge (topicId, spaceId, openclawSessionKey, bridgeVersion, status, createdAt, updatedAt)
VALUES (?, 'default', ?, 1, 'active', datetime('now'), datetime('now'))
```

### 2. Extract mergedMessages — don't duplicate

Both `OnlineChatView` and `OfflineChatView` have identical `mergedMessages` computed properties. **Extract this to a shared helper** — either a method on `BeeChatMobileViewModel` or a small struct. Don't copy-paste 15 lines twice.

### 3. preservedDraft asymmetry — add a comment

`OnlineChatView` gets `@Binding var preservedDraft: String` (can clear on send). `OfflineChatView` gets `let preservedDraft: String` (read-only display). Add a brief comment on each explaining why.

### 4. @Environment values — use SwiftUI-native, not UIKit

- `@Environment(\.dynamicTypeSize)` instead of hardcoded computed property
- `@Environment(\.accessibilityVoiceOverEnabled)` instead of `UIAccessibility.isVoiceOverRunning`
- Both available iOS 15+, project targets iOS 16+

### 5. Toast timeout — 7s normal, 30s VoiceOver

```swift
let timeout: TimeInterval = isVoiceOverEnabled ? 30 : 7
```

### 6. Delete confirmation wording

"This deletes this conversation and all its messages from BeeChat. This cannot be undone."

### 7. Archive tint — .secondary (neutral), not .orange

### 8. Import button — only visible when importCandidateCount > 0

### 9. BeeChatView sessionKey(for:) must be public

Phase 1 made it `public` for BeeChatView access. OnlineChatView/OfflineChatView are in the same package, so `internal` would work, but keep `public` for consistency with Phase 1.

### 10. Edit mode for import sheet multi-select

```swift
.environment(\.editMode, .constant(.active))
```

---

## Build Verification

After implementing, verify:

1. `cd /Users/openclaw/Projects/BeeChat-v5 && swift build` — macOS target
2. `cd /Users/openclaw/Projects/BeeChat-Mobile && xcodebuild -scheme BeeChat-Mobile -destination 'platform=iOS Simulator,name=iPhone 17' build` — iOS target
3. Both must compile clean with zero errors

---

## Commit Message Format

```
Gate 2B.5 Phase 2: UI Layer (v3)

- NewTopicSheet: adaptive popover with keyboard focus + validation
- EmptyTopicsView: fresh install + import available states
- OnlineChatView + OfflineChatView: split from BeeChatView for generic type compatibility
- TopicListView: + button, swipe actions, archive undo (Task-based), import flow
- ViewModel: createTopic, archiveTopic, unarchiveTopic, deleteTopic, importCandidates, importSelected
- TopicRepository: fetchById, fetchAllActiveSessionKeys, saveAndBridgeInTransaction
- ImportSessionsSheet: multi-select with edit mode
- Accessibility: VoiceOver labels, Dynamic Type, Reduce Motion
```