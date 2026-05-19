# GATE-2B5 Phase 2 — Hotfix #1: Kieran Adversarial Code Review Brief

**For:** Kieran (Adversarial Code Reviewer)  
**Date:** 2026-05-19  
**Scope:** Two targeted bug fixes  

---

## Review Checklist

### Bug 1: Messages Not Appearing After Send

**Files to review:**
- `/Users/openclaw/Projects/BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/BeeChatView.swift`
- `/Users/openclaw/Projects/BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/OnlineChatView.swift`
- `/Users/openclaw/Projects/BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/OfflineChatView.swift`

**Review points:**

1. **Reload trigger correctness:** Does `onChange(of: messageVersion)` fire reliably after `send()` completes? Is there a race condition where the DB write hasn't completed before `loadMessages()` reads?
2. **Callback propagation:** Is the `onMessageSent` callback (or equivalent) properly wired through both Online and Offline views? No dangling closures?
3. **Offline send path:** Does the offline `viewModel.send()` in OfflineChatView also trigger a reload? The offline path writes directly to the DB, so `loadMessages()` should pick it up immediately.
4. **Stale state check:** In `loadMessages()`, the guard `if viewModel.selectedTopicId == topicId` — does this still work correctly after async send?
5. **Thread safety:** `messageVersion` is `@State` (MainActor). Is the increment always on the main thread after `await viewModel.send()`?

### Bug 2: Message Sort Order

**File to review:**
- `/Users/openclaw/Projects/BeeChat-v5/Sources/BeeChatPersistence/Repositories/MessageRepository.swift`

**Review points:**

1. **Correctness:** Is `.asc` the right order for Exyte ChatView? (Yes — Exyte renders oldest at top, newest at bottom, auto-scrolls to bottom.)
2. **Pagination:** The `before` cursor uses `Column("timestamp") < before`. With `.asc` order, this still correctly fetches messages older than the cursor. Does the limit still make sense? (Yes — limit applies after ordering.)
3. **Other callers:** Does any other code path call `fetchBySession` and expect `.desc` order? Check all usages.
4. **Test impact:** Do any existing tests depend on `.desc` order? If so, they need updating.

### General

5. **No scope creep:** Are there any other changes beyond the two specified fixes?
6. **Build verification:** Both iOS and macOS targets should build clean.