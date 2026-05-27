# Gate 2B5 Phase 2 — Topic Sync & Message Ordering Fix (v3)

**Date:** 2026-05-27
**Status:** DRAFT — Awaiting review
**Scope:** iPhone app only (no Mac app changes)
**Pre-requisite:** Gate 2B5 Phase 1 (merged)

---

## 1. Problem Statement

### 1A. Topics: iPhone can't discover Mac's topics

The iPhone only shows the two seed topics ("Welcome to BeeChat", "Leeds United"). It cannot discover the Mac's actual topic list.

**Root cause:** `reconcileFromGateway()` uses `BeeChatSessionFilter.isBeeChatSession()`, which only returns `true` if the session key **already has a local topic bridge entry**. New sessions can never be discovered — it's circular.

**Previous approach (v1/v2):** Filter gateway sessions with `sessionShouldAppearByDefault()`. This was wrong because it would create 80+ topics from cron, subagent, and agent boot sessions.

**Correct approach (per Adam):** The Mac already knows its topics — they're in its local GRDB database. The iPhone just needs a list of topic names + IDs. The gateway is the transport, not the data store.

### 1B. Messages: Reply appears above user message

When the user sends a message and gets a reply, the reply sometimes appears above the user's message instead of below it.

**Root cause:** The user message is saved locally with a random UUID and `Date()` timestamp. When `fetchHistory()` replaces it with the gateway version, the gateway message has a different ID. If the dedup in `MessageMapper` misses it (different content length, or >2s gap), the user sees two copies — one local, one from gateway — and ordering can break.

---

## 2. Solution

### 2A. Topic Sync Channel

The Mac publishes its topic list as a JSON payload through a well-known gateway session (`agent:main:beechat-sync`). The iPhone reads this payload on connect and when it changes.

**Mac side (deferred):** A future spec will add Mac-side code that:
1. Writes the current topic list (from its GRDB database) to `agent:main:beechat-sync`
2. Updates the payload when topics change

**iPhone side (this spec):**

1. On connect, call `chat.history(sessionKey: "agent:main:beechat-sync", limit: 1)` to get the latest topic list payload
2. Parse the JSON payload into a `TopicSyncPayload`
3. Reconcile: create/update local topics from the payload, archive local topics that the Mac has archived
4. Listen for `sessions.changed` events on the sync session, re-read the payload when it changes
5. If no sync payload exists, show local topics only (standalone mode)

**Payload format:**
```json
{
  "v": 1,
  "timestamp": "2026-05-27T20:00:00Z",
  "topics": [
    {
      "id": "abc123",
      "name": "Project Status",
      "sessionKey": "agent:main:main",
      "isArchived": false,
      "lastActivityAt": "2026-05-27T19:30:00Z",
      "lastMessagePreview": "Build succeeded"
    }
  ]
}
```

**Reconciliation rules:**
- If a topic from the payload has a matching `id` locally → update its name, isArchived, lastActivityAt, lastMessagePreview
- If a topic from the payload has no local match → create it with `origin: "mac"`
- If a local topic has `origin: "mac"` but isn't in the payload → archive it (Mac deleted it)
- If a local topic has `origin: nil` or `origin: "local"` → never archive it (user created it on iPhone)
- If payload is empty or malformed → do nothing (safety: don't archive all topics)

**Testing approach (until Mac publishing is ready):**
- Use `chat.inject` or the OpenClaw gateway CLI to inject a test payload into `agent:main:beechat-sync`
- Verify iPhone reads and reconciles the payload correctly

### 2B. Message Ordering Fix

**Approach:** Strengthen the existing content-based dedup in `MessageMapper` and add a SQL-level dedup inside `SyncBridge` that runs after `fetchHistory()` completes.

**MessageMapper dedup (existing, strengthen):**
- Current: dedup by role+content within 2-second window
- New: dedup by role+content within 10-second window, minimum 20 characters, user-role only

**SyncBridge dedup (new):**
- After `fetchHistory()` completes for a session, run a SQL query that:
  1. Finds local user-role messages with content ≥20 chars that don't have a matching gateway message
  2. Matches by: same session key, user role, content prefix (first 20 chars), timestamp within 10 seconds
  3. Deletes the local duplicate, keeping the gateway version (which has the correct ID)
- Runs only once per `fetchHistory` call, not on every streaming event

**Timing:** The dedup runs inside `loadMessages()` after `fetchHistory()` returns. This is guaranteed to happen after the gateway messages are in the database.

---

## 3. Success Criteria

1. **Topic discovery:** When a sync payload exists, the iPhone shows the Mac's topics (not all 80+ gateway sessions, just the Mac's actual topics)
2. **Topic creation:** New Mac topics appear on iPhone within 60 seconds of the payload updating
3. **Topic archival:** When Mac archives a topic, it archives on iPhone (but iPhone-created topics are never archived by sync)
4. **Standalone:** If no sync payload exists, iPhone works fine with local topics only
5. **Message ordering:** Replies always appear below the user's message, never above
6. **No regressions:** Mac app still compiles and runs unchanged

---

## 4. Implementation Scope

### iPhone changes only (BeeChat-Mobile):

1. **`BeeChatMobileViewModel.swift`** — Add `readSyncSession()` method, call it on connect and on `sessions.changed` events for `beechat-sync`
2. **`BeeChatMobileViewModel.swift`** — Replace `reconcileFromGateway()` with `reconcileFromPayload()` that uses the sync payload instead of session filtering
3. **`TopicSyncPayload.swift`** — New file: `Codable` struct for the JSON payload, with `extract(from:)` method that handles both pure JSON and wrapped content
4. **`MessageMapper.swift`** — Strengthen content-based dedup (10s window, ≥20 chars, user-role only)
5. **`SyncBridge.swift`** — Add `dedupAfterFetchHistory(sessionKey:)` method (shared package, but Mac app doesn't call it)
6. **Xcode project** — Add `TopicSyncPayload.swift` to build sources

### No Mac app changes (deferred to separate spec)

---

## 5. Out of Scope

- Mac-side topic publishing (future spec)
- Deleting topics on iPhone that Mac deleted (archive only)
- Topic renames from iPhone (one-way sync: Mac → iPhone)
- Unread count sync
- Push notifications for new topics

---

## 6. Risks

| Risk | Mitigation |
|------|-------------|
| Empty payload archives all topics | Guard: if payload has 0 topics, do nothing |
| Stale payload overwrites fresh data | Store `lastSyncTimestamp`, reject payloads older than last sync |
| `chat.history` fails on non-existent session | Wrap in `try?`, treat as "no sync data available" |
| Mac publishes while iPhone offline | Next connect reads latest payload — no race condition |
| Dedup removes wrong message | 1:1 matching (user-role, ≥20 chars, 10s window, session-key match) |