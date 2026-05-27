# GATE-2B5-PHASE2-Q-REVIEW-v3

**Date:** 2026-05-27
**Reviewer:** Q (Code Implementation)
**Spec:** GATE-2B5-PHASE2-SPEC-v3.md
**Scope:** iPhone-only (no Mac changes)
**Files Reviewed:**
- `BeeChatMobileViewModel.swift` (iPhone)
- `MessageMapper.swift` (iPhone)
- `SyncBridge.swift` (shared — BeeChat-v5)
- `Topic.swift` (shared — BeeChat-v5)
- `TopicRepository.swift` (shared — BeeChat-v5)
- `MessageRepository.swift` (shared — BeeChat-v5)
- `BeeChatPersistenceStore.swift` (shared — BeeChat-v5)
- `GatewayClient.swift` (shared — BeeChat-v5)
- `RPCClient.swift` (shared — BeeChat-v5)

---

## B — BLOCKERS (must fix before build)

### B1. No `TopicSyncPayload` type exists yet; spec invents a new model the build will fail on

**Location:** Spec §2A, §4

The spec introduces a new `TopicSyncPayload.swift` file with a `Codable` struct, `extract(from:)` method, and nested `TopicPayloadItem`. This file does not exist in the codebase. The iPhone project is missing it from the build sources.

**Impact:** Build will fail — the `readSyncSession()` and `reconcileFromPayload()` methods will reference an undefined type.

**Fix:** Create `BeeChatMobile/Sources/BeeChatMobileKit/TopicSyncPayload.swift` with the Codable struct. Add it to the Xcode project build sources. The payload must handle both pure JSON and gateway-message-wrapped content (since `chat.history` returns `[ChatMessagePayload]`, not raw JSON).

**Priority:** Must be in the same PR as the spec implementation.

---

### B2. `reconcileFromPayload()` references `topicRepo.saveBridge` for topics that already exist, but `saveBridge` INSERT has no ON CONFLICT UPDATE

**Location:** `TopicRepository.swift`, `saveBridge()`

```swift
// Current saveBridge():
INSERT INTO topic_session_bridge (topicId, spaceId, openclawSessionKey, ...)
VALUES (?, 'default', ?, 1, 'active', datetime('now'), datetime('now'))
ON CONFLICT(topicId) DO UPDATE SET openclawSessionKey = excluded.openclawSessionKey, updatedAt = excluded.updatedAt
```

The unique constraint is on `(topicId)`. If a Mac-published topic has the same `openclawSessionKey` as an existing iPhone topic but a *different* `topicId` (e.g., the Mac generated a new topic ID), the bridge table gets a duplicate `openclawSessionKey` entry because the PK is `topicId`, not the session key.

**Impact:** Two topics can point to the same `openclawSessionKey`, breaking `resolveTopicId(for:)` which returns the first match arbitrarily.

**Fix:** Either:
- (a) Add a UNIQUE constraint on `openclawSessionKey` in the bridge table and change `ON CONFLICT(topicId)` to `ON CONFLICT(openclawSessionKey)` in `saveBridge()`, or
- (b) In `reconcileFromPayload()`, check if the session key already has a bridge entry before creating a new one.

Option (a) is cleaner but needs a schema migration. Option (b) is a surgical runtime guard.

---

### B3. `processChatFinal` calls `dedupLocalMessages` after `fetchHistory`, but `fetchHistory` upserts messages — the dedup may run against stale IDs

**Location:** `SyncBridge.swift`, `processChatFinal()`

```swift
_ = try await fetchHistory(sessionKey: sessionKey)
try? config.persistenceStore.dedupLocalMessages(sessionKey: sessionKey)
```

`fetchHistory()` calls `upsertMessages()` which does `INSERT OR REPLACE`. If the gateway message has a *different* ID than the local message, the upsert creates a new row. Then `dedupLocalMessages` runs and tries to match `id != gateway.id` — but the local message still exists with its original local UUID, and the gateway message has its own ID. The SQL JOIN matches on content+timestamp and deletes the local one. This works.

**BUT** — if the gateway message has the *same* content but the local message's `role` is `"user"` and the gateway message's `role` is also `"user"`, the dedup works. However, the `dedupLocalMessages` SQL only checks `local.id != gateway.id` and `local.role = 'user'`. If the gateway message arrives with `role = "assistant"` (the reply), it won't match because the gateway `role` filter is `gateway.role = 'user'`.

Wait — let me re-read the SQL:

```sql
INNER JOIN messages gateway ON local.sessionId = gateway.sessionId
  AND gateway.role = 'user'
  AND TRIM(COALESCE(local.content, '')) = TRIM(COALESCE(gateway.content, ''))
```

Yes — the gateway side also requires `role = 'user'`. This is correct: it only dedups a *local user message* against a *gateway user message* with the same content. The assistant reply is not involved. So B3 is **not a blocker** — it's actually correct.

**However** — the `dedupLocalMessages` SQL uses `LIMIT 1` inside the subquery. If two local user messages match the same gateway message (e.g., rapid re-send), only one is deleted. This is the documented safety net. Acceptable.

**Revised B3:** The dedup runs in a fire-and-forget `Task { }` inside `processChatFinal`. If `fetchHistory` succeeds but `dedupLocalMessages` throws (rare but possible), the error is silently swallowed. That's fine for a dedup. But the `fetchHistory` result is also discarded (`_ = try await`). If `fetchHistory` throws, the whole `Task` fails and `dedup` never runs. The streaming indicator still stops (delegate notified first). Messages may not refresh. **This is a blocker.**

**Fix:** Wrap `fetchHistory` + `dedupLocalMessages` in a `do/catch` so that a failure in either is logged but doesn't prevent the streaming UI from resetting.

Wait — it *is* in a `do/catch` inside the `Task`:
```swift
do {
    _ = try await fetchHistory(sessionKey: sessionKey)
    try? config.persistenceStore.dedupLocalMessages(sessionKey: sessionKey)
} catch { ... }
```

Actually, looking at the code again: `processChatFinal` has `do { _ = try await fetchHistory } catch { print }`. And `dedupLocalMessages` is called with `try?` (silently ignored). So B3 is handled. **B3 is NOT a blocker.** Striking it.

---

### B3 (replaced). `MessageMapper` dedup uses a 10-second window but the spec says 10s, the current code uses 2s — the spec change is correct but must be verified against edge cases

Wait — the current code in `MessageMapper.swift` uses `< 2.0`. The spec says change to `< 10.0`. This is a spec-driven change. The concern is: a user sends a message, 5 seconds later sends the exact same message intentionally (e.g., "yes"). The second message would be deduped away.

**Location:** `MessageMapper.swift`, `exyteMessages()`

```swift
if message.role == "user", let content = message.content, let existingTime = lastUserContent[content] {
    if abs(message.timestamp.timeIntervalSince(existingTime)) < 10.0 {
        continue  // Skip duplicate
    }
}
```

With a 10-second window, any two identical user messages within 10 seconds are collapsed into one. The user would lose the second message entirely from the UI. The mapper is the *last* line before Exyte Chat renders. The deduped message is gone from the UI even though it exists in the database.

**Impact:** Legitimate repeated messages disappear. This is worse than showing a duplicate.

**Fix:** The 10-second window is too wide for UI-level dedup. The spec says minimum 20 characters, user-role only. A 10s window is acceptable for long messages (≥20 chars) because people rarely re-send the exact same 20+ char message within 10s. But for short messages (which are excluded by the ≥20 guard), it's fine. **The ≥20 guard mitigates the risk.**

However, the current `MessageMapper` code does NOT have the ≥20 guard:

```swift
if message.role == "user", let content = message.content, let existingTime = lastUserContent[content] {
    if abs(message.timestamp.timeIntervalSince(existingTime)) < 2.0 {  // No length guard!
        continue
    }
}
```

The spec says: "New: dedup by role+content within 10-second window, minimum 20 characters, user-role only." The implementation must add the ≥20 guard.

**This is a blocker if the ≥20 guard is missing in the implementation.** The spec requires it.

---

### B4. `reconcileFromPayload()` spec says "if a topic from the payload has no local match → create it with `origin: "mac"`" but `TopicRepository.create()` always sets `origin = "local"`

**Location:** `TopicRepository.swift`, `create(name:)`

```swift
let topic = Topic(
    id: topicId,
    name: name,
    sessionKey: gatewayKey,
    pendingGatewaySync: pendingGatewaySync,
    origin: "local"
)
```

The spec requires `origin: "mac"` for topics created from the sync payload. `create()` is hardcoded to `"local"`. If the implementation uses `topicRepo.create()` for payload-derived topics, they'll be marked `"local"` and will never be auto-archived when the payload drops them (because the rule is: only archive `origin == "mac"` topics).

**Impact:** Mac topics created via sync payload are marked as local, so they won't auto-archive when the Mac removes them. Stale topics persist forever.

**Fix:** Either:
- (a) Add an `origin: String?` parameter to `TopicRepository.create()` (default `"local"`), or
- (b) Use `Topic.init(...)` directly in `reconcileFromPayload()` and call `topicRepo.save()` instead of `topicRepo.create()`.

Option (b) is cleaner for this flow.

---

## W — WARNINGS (should fix, but not blocking)

### W1. `BeeChatMobileViewModel.connect()` still calls `reconcileFromGateway()` and `fetchSessionInfos()` even though the spec replaces them with `reconcileFromPayload()`

**Location:** `BeeChatMobileViewModel.swift`, `connect()`

The spec says replace `reconcileFromGateway()` with `reconcileFromPayload()`. But `connect()` currently has:

```swift
let sessionInfos = try await bridge.fetchSessionInfos()
try await reconcileFromGateway(sessionInfos)
```

And later:

```swift
let beeChatSessions = sessions.filter { ... BeeChatSessionFilter.isBeeChatSession ... }
try persistenceStore.topicRepo.syncMetadataFromSessions(beeChatSessions)
```

If `reconcileFromPayload()` is the new source of truth, the old `reconcileFromGateway()` call should be removed or gated behind "no sync payload available". Otherwise, the iPhone will still do the old circular filtering + create 80+ topics.

**Impact:** If the old code isn't removed, the fix for topic discovery is not actually deployed.

**Fix:** In `connect()`, after `bridge.start()`:
1. Try `readSyncSession()` first.
2. If sync payload exists → call `reconcileFromPayload()` and skip the old `fetchSessionInfos` + `reconcileFromGateway` + `syncMetadataFromSessions` path.
3. If no sync payload → fall back to the old path (standalone mode).

This needs a clear conditional in `connect()`.

---

### W2. `BeeChatSessionFilter.isBeeChatSession` is used in `connect()` but the spec says it's the root cause of the circular problem

**Location:** `BeeChatMobileViewModel.swift`, `connect()`

```swift
let beeChatSessions = sessions.filter { session in
    (try? BeeChatSessionFilter.isBeeChatSession(session.id, topicRepo: persistenceStore.topicRepo)) == true
}
```

The spec explicitly says this is circular: "only returns true if the session key already has a local topic bridge entry. New sessions can never be discovered."

If the sync payload approach replaces this, the old `BeeChatSessionFilter` usage should be removed entirely from `connect()`. Keeping it is dead code at best, a footgun at worst.

**Fix:** Remove the `BeeChatSessionFilter` block from `connect()` once `reconcileFromPayload()` is the primary path. Keep the filter class for backward compatibility if needed, but don't call it in the new flow.

---

### W3. The `chat.history` call on `agent:main:beechat-sync` returns `[ChatMessagePayload]`, but the spec assumes a single JSON payload message

**Location:** Spec §2A

The spec says: "On connect, call `chat.history(sessionKey: "agent:main:beechat-sync", limit: 1)` to get the latest topic list payload."

`chat.history` returns an array of `ChatMessagePayload` objects (gateway messages). The sync payload is presumably stored as the *content* of the latest message in that session. The spec's `TopicSyncPayload.extract(from:)` must handle:
1. A `ChatMessagePayload` array (take the last message's `content`)
2. The `content` being a JSON string (parse it)
3. The content being wrapped in markdown code blocks (`` ```json ... ``` ``)

The spec says "handles both pure JSON and wrapped content" but doesn't show the implementation. This is feasible but error-prone.

**Fix:** Document the expected message format in the sync session. The Mac will publish the payload as a single message. The iPhone must extract `messages.last?.content` and then JSON-decode it. Edge cases: empty array, malformed JSON, content is not JSON (e.g., plain text).

---

### W4. `reconcileFromPayload()` must guard against empty or malformed payload, but the spec's "do nothing" rule is too vague

**Location:** Spec §2A

> If payload is empty or malformed → do nothing (safety: don't archive all topics)

This is correct but needs to be precise in code. "Malformed" includes:
- Missing `topics` key
- `topics` is not an array
- Individual topic items missing `id` or `name`
- `timestamp` is unparseable
- `v` is missing or unsupported

The implementation should log each case and return early.

Also: "If payload has 0 topics, do nothing" — but what if the Mac *intentionally* wants to clear all topics? The spec says "archive only, not delete", but 0 topics could mean "Mac has no topics". The iPhone should probably archive all `origin == "mac"` topics if the payload is valid but empty. The spec says "do nothing", which means Mac topics persist even when the Mac says "I have no topics". This might be intentional (don't nuke topics on a transient empty state).

**Suggestion:** Clarify whether an empty-but-valid payload (correct JSON schema, `v: 1`, `topics: []`) should archive all Mac topics or do nothing. If "do nothing", document that a Mac with zero topics will not clear iPhone topics.

---

### W5. `SyncBridge` shared-package changes must not break Mac app compilation

**Location:** Spec §4 item 5

The spec says: "`SyncBridge.swift` — Add `dedupAfterFetchHistory(sessionKey:)` method (shared package, but Mac app doesn't call it)"

This is safe in principle, but the Mac app still compiles against `SyncBridge`. Adding a new public method is fine. However, if the new method references iPhone-only types or imports, it could break Mac compilation.

**Fix:** Ensure the new `dedupAfterFetchHistory` method uses only shared-package types (`BeeChatPersistence`, `GRDB`). It should not import `BeeChatMobileKit` or any iOS-specific framework. The method should be in an extension or conditional block if needed.

Actually, looking at the current `SyncBridge.swift`, it's in the shared package and has no iOS-specific imports. The `dedupAfterFetchHistory` method should be a thin wrapper around `config.persistenceStore.dedupLocalMessages(sessionKey:)`, which already exists and is shared. **This is safe as long as the implementation stays in the shared package.**

---

### W6. `MessageMapper.exyteMessages()` dedup is case-sensitive and whitespace-sensitive

**Location:** `MessageMapper.swift`

```swift
if message.role == "user", let content = message.content, let existingTime = lastUserContent[content] {
```

The key is `content` exactly as stored. If the user sends "Hello" and then "hello" (different case), or "Hello " with a trailing space, it's not deduped. The spec's 20-char guard reduces the risk, but case-insensitive dedup might be desirable.

Also: `lastUserContent` is a `[String: Date]` dictionary. If the user sends two different 20+ char messages, both are stored. This is fine. But if they send 100 different 20+ char messages in one session, the dictionary grows unbounded within the single `exyteMessages()` call. This is harmless (it's a local var scoped to the call).

**Fix:** Consider normalizing the dedup key (trim + lowercase) for better matching. Not blocking.

---

### W7. `sessions.changed` event handling in `SyncBridgeDelegate` doesn't distinguish between sync-session changes and regular session changes

**Location:** `SyncBridgeDelegate.swift`

```swift
func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String])
```

The spec says: "Listen for `sessions.changed` events on the sync session, re-read the payload when it changes."

But `didReceiveSessionChange` gives an array of *all* changed session keys, not just `agent:main:beechat-sync`. The delegate implementation in `BeeChatMobileViewModel` currently does:

```swift
let sessionInfos = try await bridge.fetchSessionInfos()
try await self.reconcileFromGateway(sessionInfos)
```

If the sync session changes, the delegate should call `readSyncSession()` (the new method), not `reconcileFromGateway()`. If a regular session changes, it should still call `syncMetadataFromSessions` or similar.

**Fix:** In the delegate's `didReceiveSessionChange`, check if `sessionKeys` contains `"agent:main:beechat-sync"`. If yes, call `readSyncSession()` + `reconcileFromPayload()`. Otherwise, handle as before (or skip if the sync payload is the source of truth).

---

## C — CONCERNS (worth noting, ok to defer)

### C1. Timestamp drift between Mac and iPhone could cause `lastSyncTimestamp` comparisons to misbehave

**Location:** Spec §2A (staleness guard)

The spec says: "Store `lastSyncTimestamp`, reject payloads older than last sync."

But `Date()` on the Mac and `Date()` on the iPhone are from different system clocks. If the Mac clock is 5 minutes ahead, the iPhone might reject a fresh payload as "older than last sync". Conversely, if the Mac clock is behind, the iPhone might accept stale payloads.

**Mitigation:** The spec uses ISO8601 strings, which are absolute. But the comparison is `payload.timestamp > lastSyncTimestamp`. If clocks drift, this breaks.

**Fix:** Use the gateway's server time for `lastSyncTimestamp` if available, or accept a tolerance window (e.g., reject only if payload is >30s older). Defer unless sync issues are observed.

---

### C2. `Topic.origin` is a free-form `String?` with no validation; typos in Mac publisher could break archival logic

**Location:** `Topic.swift`

```swift
public var origin: String?
```

The spec uses `"mac"`, `"local"`, and `nil` as sentinel values. But `origin` is just a String. If the Mac publisher sends `"Mac"` (capitalized) or `"macos"`, the archival rule `"origin == \"mac\""` won't match.

**Fix:** Consider making `origin` an enum or at least documenting the canonical values. For now, just be careful in the Mac-side spec (future work).

---

### C3. The `chat.history` call for sync payload uses `limit: 1`, but if the sync session has multiple messages (e.g., test injections), only the latest is used

**Location:** Spec §2A

This is intentional — the spec wants the latest payload. But it means if the Mac publishes a new payload and the iPhone's `limit: 1` happens to catch a message in the middle of a multi-message update, the iPhone gets an intermediate state.

**Mitigation:** The Mac should publish the complete payload as a single message. Don't append incremental updates. The iPhone always reads the latest message. Document this contract.

---

### C4. `BeeChatMobileViewModel` is `@MainActor` but `SyncBridge` is an `actor`; cross-actor calls may introduce latency

**Location:** `BeeChatMobileViewModel.swift`

The `ViewModel` is `@MainActor`. `SyncBridge` is an `actor`. All calls like `bridge.sendMessage()`, `bridge.fetchHistory()` are cross-actor hops. For a 10s dedup window and 50ms streaming poll, this is fine. But for high-frequency operations (e.g., rapid message sending), the actor isolation could create backpressure.

**Note:** This is existing architecture, not new to this spec. Defer.

---

### C5. `MessageRepository.dedupLocalMessages` SQL uses `TRIM(COALESCE(content, ''))` on both sides of the equality, but the local message may have been saved before trimming

**Location:** `MessageRepository.swift`

When the user sends a message, the local copy is saved with the raw text (including leading/trailing whitespace). The gateway message has the same raw text. The `TRIM()` in the SQL normalizes both sides, so they match. This is actually a feature, not a bug. But it means that if the user intentionally sends a message that is *only* whitespace (or <20 chars after trim), it won't match the ≥20 guard.

**This is correct behavior.** Just noting that `TRIM` in SQL is a normalization that the Swift-level `MessageMapper` dedup doesn't do (the mapper uses raw content).

---

### C6. `SyncBridge.processChatFinal` and `processChatError` both call `fetchHistory` in a `Task { }`, but `processAgentEvent` (legacy) calls it directly (synchronously)

**Location:** `SyncBridge.swift`

```swift
// processChatFinal (v4 format):
delegate?.syncBridge(self, didStopStreaming: sessionKey)
Task {
    do { _ = try await fetchHistory(...) } catch { ... }
}

// processAgentEvent (legacy format):
try await fetchHistory(sessionKey: sessionKey)
```

The legacy path blocks the actor until `fetchHistory` completes. The v4 path is fire-and-forget. This inconsistency could cause the legacy path to stall streaming state updates if `fetchHistory` is slow.

**Note:** This is existing code, not changed by this spec. Defer. But if the iPhone app still receives legacy-format events, this could be a real UX issue.

---

### C7. `GatewayClient.debugLogURL` is hardcoded to `/Users/openclaw/Desktop/BeeChat-debug.log`

**Location:** `GatewayClient.swift`

```swift
private let debugLogURL = URL(fileURLWithPath: "/Users/openclaw/Desktop/BeeChat-debug.log")
```

On iOS, this path doesn't exist (no `/Users/openclaw/Desktop`). The `FileManager` write will fail silently. The `debugLog` method catches errors with `try?`, so it doesn't crash. But no logs are written on iOS.

**Impact:** Debugging iOS gateway issues is harder. But this is not a functional bug.

**Fix:** Use a platform-appropriate path (e.g., iOS documents directory). Defer to a logging pass.

---

### C8. `TopicRepository.resolveTopicId(for:)` has multiple fallback queries — potential performance issue at scale

**Location:** `TopicRepository.swift`

```swift
public func resolveTopicId(for sessionKey: String) throws -> String? {
    // Try topics table first
    if let topicId = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [sessionKey]) { return topicId }
    // Fall back to bridge table
    return try String.fetchOne(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [sessionKey])
}
```

At small scale (hundreds of topics), this is fine. At large scale (thousands), the repeated `fetchOne` calls per message event could add up.

**Fix:** Add a compound index on `topics(sessionKey)` and `topic_session_bridge(openclawSessionKey)`. Defer.

---

### C9. `BeeChatMobileViewModel.send()` saves the local message with `Date()` before calling `bridge.sendMessage()`, but the gateway message timestamp is server-time

**Location:** `BeeChatMobileViewModel.swift`, `send()`

```swift
let userMessage = BeeChatPersistence.Message(
    id: UUID().uuidString,
    sessionId: sessionKey,
    role: "user",
    content: text,
    senderName: "Adam",
    senderId: "adam",
    timestamp: Date()  // Local clock
)
try persistenceStore.saveMessage(userMessage)
```

The gateway's message timestamp comes from the server (or from when the gateway processed it). If the iPhone clock is off by even 1 second, the local message and gateway message may have different timestamps. The `MessageMapper` dedup uses `abs(timestamp difference) < 10.0`, which absorbs this. The SQL dedup also uses `ABS(local.timestamp - gateway.timestamp) < 10.0`.

**This is handled by the 10-second window.** But if the user sends a message, goes offline for 30 seconds, comes back online, and the gateway delivers the message, the timestamps could be 30s apart. The dedup would miss it.

**Mitigation:** This is the fundamental problem the spec is solving. The SQL dedup (content match + session match + role match) should still catch it even if the time window misses. But the SQL uses the 10s window. If the time gap is >10s, the duplicate persists.

**This is a known limitation.** The spec's approach is: "Strengthen the existing content-based dedup" and add SQL-level dedup. If both miss (large time gap, different content due to gateway processing), the duplicate shows. Acceptable for now.

---

### C10. No migration path for existing users who already have topics from the old `reconcileFromGateway()` approach

**Location:** General

Users who already have topics created by the old circular logic will have those topics in their local DB with `origin: nil` (since `origin` was added later and defaults to nil). The new sync payload may create *duplicate* topics for the same Mac sessions because `resolveTopicId(for:)` falls back to bridge table matching.

If a user has an old topic with `sessionKey = "agent:main:abc"` and the sync payload also has a topic with `id = "abc"` and `sessionKey = "agent:main:abc"`, the `reconcileFromPayload()` should find the existing topic (via `resolveTopicIdBySuffix` or `resolveTopicId`) and update it rather than creating a new one.

The spec says: "If a topic from the payload has a matching `id` locally → update its name, isArchived, ..." This is correct if matching by `id`. But what if the old topic has a different `id` but the same `sessionKey`?

**Fix:** In `reconcileFromPayload()`, match by `sessionKey` first (via `resolveTopicId(for: sessionKey)`), then by `id`. If matched by `sessionKey`, update the topic (including its `id` if the payload's `id` is the canonical one? Or keep the local `id`?). This needs to be specified.

---

## Summary

| Severity | Count | Items |
|----------|-------|-------|
| Blocker | 4 | B1 (missing TopicSyncPayload), B2 (bridge table duplicate keys), B3 (MessageMapper ≥20 guard missing), B4 (origin hardcoded to "local") |
| Warning | 7 | W1 (old reconcile not removed), W2 (BeeChatSessionFilter still used), W3 (chat.history format), W4 (malformed payload handling), W5 (Mac compilation safety), W6 (case-sensitive dedup), W7 (sessions.changed filtering) |
| Concern | 10 | C1–C10 (timing, schema, migration, logging, performance) |

---

## Recommendations

1. **Before build:** Create `TopicSyncPayload.swift`, add it to Xcode build sources, and implement `extract(from:)` with robust JSON parsing.
2. **Before build:** Fix `TopicRepository.create()` to accept an `origin` parameter, or use direct `Topic.init` + `save()` in `reconcileFromPayload()`.
3. **Before build:** Add `UNIQUE(openclawSessionKey)` to bridge table or add a pre-insert check in `reconcileFromPayload()`.
4. **Before build:** Add the ≥20 character guard to `MessageMapper.exyteMessages()` dedup logic.
5. **Before merge:** In `BeeChatMobileViewModel.connect()`, gate the old `reconcileFromGateway` path behind "no sync payload".
6. **Before merge:** Filter `didReceiveSessionChange` to only re-read sync payload when `agent:main:beechat-sync` changes.
7. **Defer:** Clock drift tolerance, `origin` enum, iOS debug log path, bridge table index.
