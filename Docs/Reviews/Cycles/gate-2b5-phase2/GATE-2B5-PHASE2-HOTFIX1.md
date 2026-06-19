# GATE-2B5 Phase 2 — Hotfix #1: Message Display Bugs

**Date:** 2026-05-19  
**Status:** DRAFT — Pending team review  
**Author:** Bee (Coordinator)  
**Scope:** Two bugs found during simulator testing  

---

## Bug 1: Messages Not Appearing After Send

### Problem
When the user types a message and sends it (via the send button or Return key), the message does not appear in the chat view. The message is sent to the gateway (or saved locally if offline), but the UI never refreshes to show it.

### Root Cause
`BeeChatView.loadMessages()` is only called on:
- `onAppear`
- `onChange(of: viewModel.selectedTopicId)`
- `onChange(of: viewModel.isStreaming)` (only when streaming stops)

There is **no reload trigger after a successful send**. The `OnlineChatView`'s `didSendMessage` callback fires `viewModel.send()`, but never calls `loadMessages()` afterward.

### Fix
Add a `.task` modifier or `onChange` that reloads messages after the ViewModel's topic list changes. Since `viewModel.send()` refreshes topics via `refreshTopics()`, we can observe changes to the `topics` array or add an explicit message-count change trigger.

**Preferred approach:** Add a `@State private var messageVersion: Int = 0` counter that increments after each successful send, with `onChange(of: messageVersion)` triggering `loadMessages()`. This avoids polling and is deterministic.

**Implementation:**

In `BeeChatView.swift`:
```swift
@State private var messageVersion: Int = 0

// In OnlineChatView's didSendMessage callback:
Task {
    do {
        try await viewModel.send(text: draft.text, to: topicId)
        messageVersion += 1  // Trigger reload
        preservedDraft = ""
    } catch {
        viewModel.connectionError = error.localizedDescription
    }
}

// Add onChange:
.onChange(of: messageVersion) { _, _ in loadMessages() }
```

Same pattern in `OfflineChatView`'s send callback.

**Alternative approach:** Use GRDB `ValueObservation` to watch for message changes in the database and auto-reload. This is the proper long-term solution (noted in the ViewModel's `startMessageObservation` comment as "Post-Gate-2: use GRDB ValueObservation"), but the counter approach is simpler and sufficient for this hotfix.

---

## Bug 2: Message Sort Order — Oldest First Instead of Newest First

### Problem
Messages appear in reverse order in the chat. The oldest message is at the top, and the newest is at the bottom requiring the user to scroll down. The expected behavior (iMessage/WhatsApp style) is that the chat auto-scrolls to the newest message at the bottom, with older messages above.

### Root Cause
`MessageRepository.fetchBySession()` orders by `Column("timestamp").desc` — newest first. Exyte's `ChatView` expects messages in **ascending** order (oldest first, newest last) and renders them top-to-bottom with auto-scroll to bottom.

```swift
// Current (WRONG):
return try query.order(Column("timestamp").desc)
                 .limit(limit)
                 .fetchAll(db)

// Should be:
return try query.order(Column("timestamp").asc)
                 .limit(limit)
                 .fetchAll(db)
```

### Fix
Change `.desc` to `.asc` in `MessageRepository.fetchBySession()`.

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Repositories/MessageRepository.swift`  
**Line:** The `order` call in `fetchBySession(sessionId:limit:before:)`

```swift
// Before:
return try query.order(Column("timestamp").desc)
                 .limit(limit)
                 .fetchAll(db)

// After:
return try query.order(Column("timestamp").asc)
                 .limit(limit)
                 .fetchAll(db)
```

**Note:** The `before` cursor pagination uses `Column("timestamp") < before`, which works correctly with ascending order — it fetches messages older than the cursor, which is the correct "load more" behavior.

### Impact
This is a one-line change in a single file. The `fetchBySession` method is only used by `BeeChatPersistenceStore.fetchMessages()`, which is only called by `BeeChatMobileViewModel.messages()`. No other code path is affected.

---

## Testing Checklist

After the fix:

1. **Send a message** — it should appear immediately in the chat view
2. **Receive a response** (if gateway connected) — Bee's response should appear below your message
3. **Message order** — Oldest messages at top, newest at bottom (like iMessage)
4. **Auto-scroll** — Chat should auto-scroll to the newest message on load and after send
5. **Offline send** — Messages should appear locally when gateway is disconnected
6. **Seed data** — The 3 seed messages in "Welcome to BeeChat" should appear in chronological order

---

## Review Notes

- Bug 1 is in BeeChatView.swift (BeeChat-Mobile project)
- Bug 2 is in MessageRepository.swift (BeeChat-v5 project — shared SPM package)
- Both fixes are minimal and targeted
- No spec changes needed — these are implementation bugs, not design issues