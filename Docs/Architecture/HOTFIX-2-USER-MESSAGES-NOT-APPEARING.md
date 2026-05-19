# Hotfix #2: User Messages Not Appearing in Chat View

**Date:** 2026-05-19  
**Status:** Implementation  
**Severity:** P1 — core functionality broken  
**Reviewer assignments:** Q (build), Kieran (adversarial), Mel (UX)

## Symptom

User messages typed and sent in the chat view do not appear in the message list. Only assistant (Bee) responses are visible.

## Root Cause

The iOS `BeeChatMobileViewModel.send()` method has two paths:

1. **Offline path** (syncBridge == nil): Correctly persists the user message locally before returning.
2. **Online path** (syncBridge connected): Does **NOT** persist the user message locally. It relies on the gateway echoing back the user message via `session.message` WebSocket events, which arrive asynchronously.

The macOS `MessageViewModel.sendMessage()` correctly persists the user message before sending to the gateway. The iOS version omits this step.

### Timing issue

Even after Hotfix #1 added `messageVersion += 1` to trigger `loadMessages()`, the user message may not yet be in the DB when `loadMessages()` fires, because:

1. `bridge.sendMessage()` returns after the RPC completes
2. `onMessageSent()` fires → `messageVersion += 1` → `loadMessages()` runs
3. But the gateway echo (`session.message` with `role: "user"`) arrives asynchronously on the WebSocket
4. EventRouter saves it → but `loadMessages()` already ran without it

### Dedup safety

The EventRouter has an idempotency guard (`messageExists(id:)`) that prevents duplicate persistence if the user message is already in the DB when the gateway echo arrives. So it's safe to persist locally before the echo.

## Fix

Add local persistence of the user message in the online path of `BeeChatMobileViewModel.send()`, matching the macOS pattern.

### File: `BeeChatMobileKit/BeeChatMobileViewModel.swift`

In the `send(text:to:)` method, **before** calling `bridge.sendMessage()`:

```swift
// Persist user message locally for immediate display.
// The EventRouter's dedup guard will skip the gateway echo.
let userMessage = BeeChatPersistence.Message(
    id: UUID().uuidString,           // local ID — gateway echo gets its own ID
    sessionId: sessionKey,
    role: "user",
    content: text,
    senderName: "Adam",
    senderId: "adam",
    timestamp: Date()
)
try persistenceStore.saveMessage(userMessage)
```

### Why this works

- User message appears immediately in chat (persisted before send)
- `onMessageSent()` triggers `loadMessages()` → message visible
- Gateway echo arrives later with a different `id` → EventRouter saves it too (different ID, no dedup needed)
- Both messages have `role: "user"` → both render as user bubbles
- **Wait** — this means the user would see **two** messages for every one they send

### Refined fix

To avoid duplicates, we need the local message ID to match the gateway echo ID. But we don't know the gateway's message ID until the echo arrives.

**Better approach:** Use the idempotency key from `sendMessage()` as the local message ID, OR accept that both messages will exist and merge them in the mapper.

Actually, let me re-examine. The gateway sends a `session.message` event for the user message with its own `id`. If we persist locally with a random UUID, we'll have two user messages in the DB with different IDs.

**Simplest correct fix:** Persist locally, then when the gateway echo arrives, the EventRouter will save a second message with a different ID. We need to dedup at display time.

**Even simpler:** Use the same approach as macOS — persist locally. When the gateway echo arrives, the `messageExists` check won't find it (different ID), so it'll be saved too. But both have `role: "user"` and similar timestamps, so the user sees a duplicate.

**Cleanest fix:** Persist locally with a **temporary** marker, then when the gateway echo arrives, replace it. OR: accept the brief duplicate and let `loadMessages()` merge messages with the same `(sessionId, role, content, timestamp within 1s)`.

**Recommended fix (simplest, matching macOS behavior):**

1. Persist user message locally before `bridge.sendMessage()` 
2. In `loadMessages()`, add dedup logic: if two messages have the same `(sessionId, role, content)` and timestamps within 2 seconds, merge them (keep the one with the gateway-provided ID)

Actually, the **simplest** fix that avoids duplicates entirely:

1. Persist user message locally before `bridge.sendMessage()` 
2. In `EventRouter.handleSessionMessage()`, when `role == "user"`, check for a local message with matching `(sessionId, content)` within a 5-second window. If found, UPDATE its ID to the gateway's ID (or just skip saving the echo).

This is getting complex. Let me propose the **pragmatic** fix:

### Pragmatic Fix

1. Persist user message locally before `bridge.sendMessage()` (immediate display)
2. Add `content-based dedup` in `MessageMapper.exyteMessages()` — skip messages where `(role, content, timestamp within 2s)` would create a visible duplicate
3. This handles the race condition AND the duplicate echo

### Alternative (simpler but less precise)

1. Persist user message locally with a temporary ID
2. When `session.message` arrives for `role: "user"`, the EventRouter checks `messageExists(id:)` — won't find it (different ID)
3. Accept that two user messages exist briefly
4. When `loadMessages()` runs after the echo, the mapper skips messages with `content` that matches an existing message within a 2-second window

## Implementation Spec

### Changes Required

1. **`BeeChatMobileViewModel.send()`** — Add local persistence before `bridge.sendMessage()` in the online path
2. **`MessageMapper.exyteMessages()`** — Add content-based dedup: skip consecutive messages with same `(role, content)` and timestamps within 2 seconds
3. **`MessageMapper.exyteMessage()`** — No changes needed

### Testing

- User sends message → message appears immediately in chat
- Bee responds → response appears after stream
- No duplicate user messages visible
- Offline path still works (already saves locally)