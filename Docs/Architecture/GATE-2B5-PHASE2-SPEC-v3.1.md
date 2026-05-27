# Gate 2B5 Phase 2 — Topic Sync & Message Ordering Fix (v3.1)

**Date:** 2026-05-27
**Status:** DRAFT — Awaiting reviewer confirmation on blockers
**Scope:** iPhone app only (no Mac app changes)
**Pre-requisite:** Gate 2B5 Phase 1 (merged)
**Reviewers:** Q (4 blockers, 7 warnings, 10 concerns), Kieran (3 blockers, 5 conditions), Mel (0 blockers, 5 concerns)

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

#### Call flow:

```
connect()
  ├─ bridge.start()
  ├─ readSyncSession()        // NEW: try sync payload first
  │   ├─ payload found → reconcileFromPayload(payload)
  │   └─ no payload → skip (standalone mode, local topics only)
  └─ [REMOVED: fetchSessionInfos + reconcileFromGateway — old path deleted entirely]

didReceiveSessionChange(sessionKeys)
  ├─ guard isReconciling (prevent re-entry)
  ├─ if sessionKeys contains "agent:main:beechat-sync"
  │   ├─ readSyncSession()
  │   └─ reconcileFromPayload(payload) if found
  └─ [REMOVED: fetchSessionInfos + reconcileFromGateway — old path deleted entirely]
```

**Key change from v3:** The old `reconcileFromGateway()` path is **removed entirely**, not coexisted with. In standalone mode (no sync payload), no gateway-based topic reconciliation happens at all — only local topics are shown. This prevents the circular filter from ever running.

#### Payload format:

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

- All timestamps are **ISO 8601 with Z suffix** (UTC). No local times.
- Maximum payload size: **50KB** (sanity guard — 50 topics × ~200 bytes ≈ 10KB, so 50KB is generous)
- `v` field is required; payloads with missing or unsupported `v` are rejected
- `topics` must be an array; payloads where `topics` is missing, null, or not an array are rejected
- Individual topic items missing `id` or `name` are skipped (not rejected entirely)

#### How `readSyncSession()` works:

```swift
func readSyncSession() async throws -> TopicSyncPayload? {
    // 1. Call chat.history on the sync session
    let messages = try await bridge.chatHistory(sessionKey: "agent:main:beechat-sync", limit: 1)
    
    // 2. No messages → no sync data (standalone mode)
    guard let latestMessage = messages.last else { return nil }
    
    // 3. Extract content and parse JSON
    return TopicSyncPayload.extract(from: latestMessage.content)
}
```

Error handling:
- `chat.history` throws "session not found" → return `nil` (standalone mode)
- `chat.history` throws network error → log warning, return `nil` (will retry on next connect)
- `chat.history` returns empty array → return `nil` (standalone mode)
- Payload JSON is malformed → log warning, return `nil`
- Payload is valid but empty topics array → return `nil` (don't archive everything)

#### Staleness guard:

Store `lastSyncTimestamp` in **UserDefaults** (key: `"beechat_lastSyncTimestamp"`). This is transient state that shouldn't survive app reinstall.

- Before reconciling, compare `payload.timestamp` against stored `lastSyncTimestamp`
- If `payload.timestamp <= lastSyncTimestamp` → skip (stale payload)
- If `payload.timestamp > lastSyncTimestamp` → reconcile and update `lastSyncTimestamp`
- On first run (no stored timestamp) → always accept

This prevents re-processing the same payload on every `sessions.changed` event.

#### Reconciliation rules:

1. **Match by `sessionKey` first** — check `resolveTopicId(for: sessionKey)` to find existing local topics that already bridge to the same session
2. **Then match by `id`** — if no sessionKey match, check if a topic with the same `id` exists locally
3. **If matched by sessionKey or id** → update its `name`, `isArchived`, `lastActivityAt`, `lastMessagePreview`, set `origin = "mac"`
4. **If no match** → create new topic with `origin: "mac"` using `Topic.init(...)` + `topicRepo.save()` (NOT `topicRepo.create()` which hardcodes `origin: "local"`)
5. **If local topic has `origin: "mac"` but isn't in payload** → archive it (Mac removed it)
6. **If local topic has `origin: nil` or `origin: "local"`** → never archive it (user created it on iPhone)
7. **If payload has 0 topics** → do nothing (safety: don't archive all topics)
8. **If payload is malformed** → do nothing

**Known limitation (documented):** iPhone-side topic renames are overwritten by Mac sync. This is intentional — one-way sync (Mac → iPhone).

**Migration note:** Existing iPhone installations may have topics with `origin: nil` from the old `reconcileFromGateway()` path. These will NOT match Mac topics by id (different UUIDs) but MAY match by `sessionKey`. The reconciliation rule #1 handles this: if the sessionKey matches, the existing topic is updated rather than duplicated.

#### Duplicate name handling:

If a Mac topic and an iPhone local topic have the same display name, both remain visible. The topic list shows `lastMessagePreview` as secondary text to help disambiguate. No dedup by name — two different topics can have the same name.

### 2B. Message Ordering Fix

**Approach:** Strengthen the existing content-based dedup in `MessageMapper` and add a SQL-level dedup that runs after `fetchHistory()` completes.

**MessageMapper dedup (existing, strengthen):**
- Current: dedup by role+content within 2-second window
- New: dedup by role+content within 10-second window, minimum 20 characters, user-role only
- The ≥20 character guard ensures short messages like "yes", "ok", "thanks" are never accidentally deduped

**SyncBridge dedup (new):**
- After `fetchHistory()` completes for a session, run a SQL query that:
  1. Finds local user-role messages with content ≥20 chars that don't have a matching gateway message
  2. Matches by: same session key, user role, content prefix (first 20 chars), timestamp within 10 seconds
  3. Deletes the local duplicate, keeping the gateway version (which has the correct ID)
- Runs only once per `fetchHistory()` call, not on every streaming event

**Where the dedup runs (corrected from v3):**

The SQL dedup runs in `SyncBridge.processChatFinal()` and `SyncBridge.processChatError()`, **after** `fetchHistory()` upserts the gateway messages. It does NOT run in `loadMessages()` (which only reads from DB and never calls fetchHistory).

```swift
// In SyncBridge.processChatFinal():
delegate?.syncBridge(self, didStopStreaming: sessionKey)
Task {
    do {
        _ = try await fetchHistory(sessionKey: sessionKey)
        try? config.persistenceStore.dedupLocalMessages(sessionKey: sessionKey)
    } catch {
        print("[SyncBridge] fetchHistory/dedup failed: \(error)")
    }
}
```

**Error handling:** Both `fetchHistory` and `dedupLocalMessages` failures are logged. If `fetchHistory` fails, dedup is skipped (will retry on next message exchange). If dedup fails, the worst case is a temporary duplicate in the UI — the `MessageMapper` dedup is the fallback.

---

## 3. Success Criteria

1. **Topic discovery:** When a sync payload exists, the iPhone shows the Mac's topics (not all 80+ gateway sessions, just the Mac's actual topics)
2. **Topic creation:** New Mac topics appear on iPhone within 60 seconds of the payload updating
3. **Topic archival:** When Mac archives a topic, it archives on iPhone (but iPhone-created topics are never archived by sync)
4. **Standalone:** If no sync payload exists, iPhone works fine with local topics only — no gateway-based topic reconciliation runs
5. **Message ordering:** Replies always appear below the user's message, never above
6. **No regressions:** Mac app still compiles and runs unchanged
7. **No duplicate topics:** Existing iPhone topics from the old path are updated, not duplicated, when matched by sessionKey
8. **Empty payload safety:** An empty-but-valid payload (`topics: []`) does not archive all Mac-origin topics

---

## 4. Implementation Scope

### iPhone changes only (BeeChat-Mobile):

1. **`BeeChatMobileViewModel.swift`** — Add `readSyncSession()` method; remove `reconcileFromGateway()` entirely; add `reconcileFromPayload()`; update `connect()` and `didReceiveSessionChange` to use new path only
2. **`TopicSyncPayload.swift`** — New file: `Codable` struct for the JSON payload, with `extract(from:)` method that parses `ChatMessagePayload.content` as JSON
3. **`MessageMapper.swift`** — Strengthen content-based dedup (10s window, ≥20 chars, user-role only)
4. **`SyncBridge.swift`** — Add `dedupLocalMessages(sessionKey:)` call after `fetchHistory()` in `processChatFinal()` and `processChatError()` (shared package, Mac app doesn't call it)
5. **`MessageRepository.swift`** — Add `dedupLocalMessages(sessionKey:)` SQL method (shared package)
6. **`TopicRepository.swift`** — No changes needed; use `Topic.init(...)` + `save()` instead of `create()` for payload-derived topics
7. **Xcode project** — Add `TopicSyncPayload.swift` to build sources
8. **UserDefaults** — Store `beechat_lastSyncTimestamp` for staleness guard

### No Mac app changes (deferred to separate spec)

### Removed from iPhone:

- `reconcileFromGateway()` method — deleted entirely
- `BeeChatSessionFilter.isBeeChatSession()` usage in `connect()` and `didReceiveSessionChange` — removed
- `fetchSessionInfos()` call in `connect()` — removed (only used by old reconciliation path)
- `syncMetadataFromSessions()` call in `connect()` — removed

---

## 5. Out of Scope

- Mac-side topic publishing (future spec)
- Deleting topics on iPhone that Mac deleted (archive only)
- Topic renames from iPhone (one-way sync: Mac → iPhone)
- Unread count sync
- Push notifications for new topics
- Sync state UI feedback (defer to next gate)
- Topic ordering rules (defer — use `lastActivityAt` descending as default)

---

## 6. Risks

| Risk | Mitigation |
|------|-------------|
| Empty payload archives all topics | Guard: if payload has 0 topics, return nil (do nothing) |
| Stale payload overwrites fresh data | `lastSyncTimestamp` in UserDefaults; reject payloads with timestamp ≤ stored value |
| `chat.history` fails on non-existent session | Distinguish: "not found" → nil (standalone); "network error" → log + retry on next connect |
| Mac publishes while iPhone offline | Next connect reads latest payload — no race |
| Dedup removes wrong message | 1:1 matching (user-role, ≥20 chars, 10s window, session-key match) |
| `lastSyncTimestamp` clock skew | Use ISO 8601 UTC timestamps; tolerance is inherent in "accept if newer" logic |
| Short messages (<20 chars) not deduped | Acceptable — MessageMapper dedup catches some; SQL dedup is belt-and-suspenders |
| Duplicate topic names | Both topics shown; `lastMessagePreview` disambiguates |
| Existing nil-origin topics | Matched by sessionKey in reconciliation; updated rather than duplicated |
| `TopicRepository.create()` hardcodes `origin: "local"` | Use `Topic.init(...)` + `save()` for payload-derived topics |