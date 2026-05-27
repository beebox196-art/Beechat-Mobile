# Kieran — Gate 2F Persistent Topic Linking Spec Review

**Reviewed:** 2026-05-26 12:00 GMT+1
**Reviewer:** Kieran (adversarial reviewer role)
**Spec:** `/Users/openclaw/Projects/BeeChat-Mobile/Docs/Architecture/GATE-2F-PERSISTENT-TOPIC-LINKING.md`
**Source files reviewed:** All shared packages (Steps 1-3), Gateway server implementation, mobile ViewModel

---

## 1. Data Loss Scenarios

### 1.1 iPhone creates topic offline, then connects
**BLOCKER**

`BeeChatMobileViewModel.createTopic()` creates a local topic with `pendingGatewaySync: true` when offline. On reconnect, `connect()` iterates pending topics and calls `bridge.sendMessage(sessionKey:text:topic:)` as a "bootstrap." But **Phase 1 of the spec explicitly says no iPhone→Mac publishing yet**. So the ViewModel code as-is will send a "Start" message but will NOT call `publishTopicState()`, meaning the gateway never gets `pluginExtensions` for this topic. The Mac won't see it.

Additionally, after the bootstrap send succeeds, `markSynced()` clears `pendingGatewaySync` — but the metadata was never published. The topic is now marked as synced when it isn't.

**Fix:** Phase 1 should either skip the bootstrap path entirely, or the bootstrap must include `publishTopicState()` as part of the reconcile flow. And `markSynced()` should only fire after BOTH the bootstrap AND the metadata publish succeed.

### 1.2 iPhone deletes a topic Mac is still using
**WARNING**

`deleteTopic()` in the ViewModel calls `deleteCascading()` which wipes messages, bridge entries, and the topic from local SQLite. It does NOT call `clearTopicState()` on the gateway. So the gateway retains the `pluginExtensions` metadata, and the Mac will still see the topic. On the next `sessions.changed` cycle, the Mac's `reconcileAllTopicState()` will republish it, and the iPhone... has no topic record to reconcile into. The current `connect()` logic would recreate it as a new local topic (no bridge exists).

This isn't strictly data loss, but it's a zombie topic resurrection that the user didn't ask for.

**Fix:** Phase 2 must call `bridge.clearTopicState(sessionKey:)` before `deleteCascading()`, and handle the case where the gateway still lists the session after deletion.

### 1.3 Mac archives a topic while iPhone has it active
**BLOCKER**

The spec says "Archive a topic on Mac → iPhone archives it locally" as an exit criterion, but **this is not implemented**. Looking at the actual reconciliation code:

```swift
// TopicRepository.syncMetadataFromSessions — only updates these fields:
// lastMessagePreview, lastActivityAt, unreadCount
```

There is no code path that reads `beechatMetadata.isArchived` from the gateway and sets `topic.isArchived` locally. The `beechatMetadata` accessor exists on `SessionInfo`, but nothing uses `isArchived` during reconciliation.

Furthermore, if a topic is actively streaming on the iPhone when the Mac archives it, the UI will keep showing the topic as active until the next reconciliation — no conflict, but a confusing UX gap.

**Fix:** The reconciliation loop must read `session.beechatMetadata?.isArchived` and update the local topic's `isArchived` field accordingly. Add a delegate callback when a topic transitions to archived while streaming.

### 1.4 Both devices rename a topic simultaneously
**WARNING**

`publishTopicState()` uses `TopicPublishQueue` (actor, serialised per topic) to prevent stale overwrites within a single device. That's fine for intra-device ordering. But there's **no cross-device ordering**. If Mac fires `sessionsPluginPatch` at the same instant iPhone does, both write to `pluginExtensions.beechat.metadata` on the gateway. The gateway's `patchPluginSessionExtension` is a simple write — last HTTP request wins. No versioning, no timestamps for conflict resolution.

The `BeeChatTopicMetadata.updatedAt` field exists but is **never used for conflict resolution** — it's metadata-only, purely informational.

In practice this is low-frequency (who renames on both devices at once?), but the spec claims "no merge conflicts" and "deterministic" resolution. It's deterministic only by accident.

**Fix:** Either document this as "last write wins, no conflict strategy needed" (honest), or add a `version` field to `BeeChatTopicMetadata` and have the gateway reject stale versions.

---

## 2. Race Conditions

### 2.1 `sessions.changed` arrives during reconciliation
**WARNING**

`connect()` does a full session fetch + reconciliation loop that takes multiple sequential steps (fetch, filter, create topics, sync metadata, refresh list). If a `sessions.changed` event fires mid-reconcile, the event handler would trigger a second re-fetch while the first is still running. The ViewModel doesn't have a debounce or in-progress guard on the event handler.

Two concurrent reconciliations writing to the same SQLite tables could produce inconsistent state (e.g., topic created by reconcile A, then overwritten by reconcile B with stale data).

**Fix:** Add an `isReconciling: Bool` guard or use `Task { @MainActor in ... }` with a cancellation check. The simplest fix: debounce `sessions.changed` events by 500ms and cancel any in-flight reconciliation before starting a new one.

### 2.2 Multiple `sessions.changed` in quick succession
**WARNING**

The gateway emits `sessions.changed` for every `sessions.patch`, `sessions.pluginPatch`, session create, and session reset. A batch operation (e.g., Mac importing 5 topics at once) could fire 5+ events in rapid succession. Without debouncing, the iPhone would re-fetch the full session list 5 times.

**Fix:** Same debounce as 2.1. The `reconnectDebounceSeconds` config exists but applies to reconnection, not event handling.

### 2.3 iPhone creates topic at exact moment Mac publishes same session
**PASS (with caveat)**

The `topic_session_bridge` table has a UNIQUE constraint on `topicId`, and `sessions.list` is idempotent. The worst case is a duplicate local topic that gets cleaned up on next reconciliation. Low risk, self-healing.

---

## 3. Scope and Auth

### 3.1 iPhone without `operator.admin` scope
**PASS**

The gateway server enforces `operator.admin` at the RPC level — `sessions.pluginPatch` will reject the call with a clear error. The Swift code also has `verifyAdminScope()` and `hasAdminScope()` that warn on connect. The spec correctly identifies this as Low likelihood / High impact with auto-pairing mitigation.

### 3.2 Scope lost mid-session
**WARNING**

`grantedScopes()` returns the scopes from the initial `hello` handshake. If the gateway config changes after connect (e.g., someone edits `openclaw.json` and restarts the gateway, or revokes scopes), the cached scope list becomes stale. The iPhone would continue believing it has `operator.admin` and attempt publishes that fail.

`verifyAdminScope()` is only called at startup. There's no periodic re-verification.

**Fix:** Call `verifyAdminScope()` before each `publishTopicState()` attempt, or at minimum before the first publish after reconnect. The error from `sessionsPluginPatch` will surface anyway, but proactive checking is cleaner.

### 3.3 Can any client publish topic metadata on any session?
**WARNING**

The gateway's `sessions.pluginPatch` checks:
1. `operator.admin` scope — yes, enforced
2. `rejectWebchatSessionMutation` — blocks webchat clients, but gateway-connected clients (Mac, iPhone) are NOT webchat
3. **No ownership check** — any client with `operator.admin` can patch plugin metadata on ANY session

This means if a third OpenClaw client (or a malicious actor with the gateway token) connects with `operator.admin` scope, they can overwrite topic metadata on any session. This is by design for the trusted-device model, but the spec should explicitly document the trust boundary: "any authenticated client with admin scope can modify any session's plugin metadata."

**Fix:** Document the trust model explicitly. If this is acceptable (trusted LAN, single user), state it. If not, the gateway would need session ownership enforcement.

---

## 4. Gateway API Safety

### 4.1 `sessionsPluginPatch` payload format
**PASS**

The RPC client round-trips via `JSONEncoder` → `JSONDecoder(AnyCodable.self)`. The gateway validates with `isPluginJsonValue()` (JSON-compatible only — no cycles, no custom types). If the metadata is malformed, the gateway rejects with `"sessions.pluginPatch value must be JSON-compatible"`. Safe.

### 4.2 `sessionsPatch` — can you rename any session?
**WARNING**

`sessions.patch` on the gateway takes a `key` and `label`. There's no ownership check beyond the session key existing. Any authenticated client can rename any session's label. This is consistent with the `sessions.pluginPatch` trust model but worth noting — if someone accidentally calls `sessionsPatch` with the wrong session key, they rename someone else's session.

**Fix:** `publishTopicState` already validates that `topicId` matches the session key suffix. This is a good guard. Ensure `sessionsPatch` in Phase 2 is always called with the correct session key.

### 4.3 `chatInject` with no active session
**PASS**

The RPC client returns `{ ok: true }` without a `runId` in this case, and the code falls through to return `"injected"` — a sentinel value. It doesn't crash, doesn't throw. Not ideal (caller can't distinguish success from "nothing happened"), but safe.

---

## 5. Offline/Reconnection

### 5.1 iPhone offline 1 hour, reconnects — reconcile ALL or just changed?
**PASS (spec is correct)**

The spec says "full re-list (incremental is future optimisation)" and the code confirms: `fetchSessions()` calls `sessions.list` which returns all sessions. The reconciliation iterates all of them. This is correct but expensive for large session counts. Not a blocker — just note that with 50+ sessions, this will be a noticeable pause.

### 5.2 iPhone has a topic deleted on Mac — persist or delete?
**BLOCKER**

There is **no orphan cleanup**. If the Mac deletes a session (or the gateway drops it), the iPhone's local topic persists forever. The reconciliation loop only creates/updates topics for sessions it finds — it never deletes topics for sessions that no longer exist.

This means deleted sessions on Mac become immortal zombie topics on iPhone.

**Fix:** Add an orphan detection pass: after reconciliation, compare local topic session keys against the fetched session list. Any local topic whose session key is absent from the gateway list should be flagged (at minimum) or archived (at maximum). Don't auto-delete — archive with a note.

### 5.3 Mac publishes topic state while iPhone is offline
**PASS**

The gateway persists `pluginExtensions` on the session object. When the iPhone reconnects and calls `fetchSessions()`, the full session list includes `pluginExtensions`. The iPhone extracts `beechatMetadata` and reconciles. This works correctly.

---

## 6. Spec Gaps

### 6.1 "Mac is master" — what specific operation?
**BLOCKER**

The spec says "Mac is master. Gateway is truth. iPhone is cache" but doesn't define what "master" means operationally. There is no code that gives Mac priority over iPhone. Both devices call the same `sessionsPluginPatch` with the same auth. The only asymmetry is that the Mac app has been publishing topic state (Steps 1-3) while the iPhone hasn't (Phase 1 is read-only).

"Mac is master" is an aspirational statement, not an enforced constraint.

**Fix:** Either (a) implement actual master/slave by having the gateway reject iPhone publishes when a Mac client is connected, or (b) drop "Mac is master" from the spec and honestly state "both devices are peers, last write wins."

### 6.2 Messages synced with topics, or metadata only?
**PASS (clarified)**

The spec only syncs topic metadata. Messages are delivered via the existing streaming/event system — they're not part of topic sync. This is correct and documented in "What Does NOT Change" → "Message send/receive — works as-is."

### 6.3 Is `sessions.changed` wired up in mobile SyncBridge?
**BLOCKER**

The spec says to add a delegate method `syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String])`, but:

1. **`SyncBridge` doesn't route `sessions.changed` events to a delegate method.** The `EventRouter` handles gateway events, but looking at the SyncBridge code, there's no handler for `sessions.changed` — only `chat.*` events are routed.
2. **`BeeChatMobileViewModel` doesn't implement the delegate method.** The `SyncBridgeDelegate` extension on the ViewModel has methods for connection state, errors, streaming, and resets — but no `didReceiveSessionChange`.
3. The 500ms polling in `startMessageObservation()` currently drives topic refresh. Removing it without wiring the event handler means **topic updates stop entirely**.

**Fix:** Before Phase 1 exits, the `EventRouter` must route `sessions.changed` to a new delegate callback, and the ViewModel must implement it. Phase 1 exit criteria should include "event handler confirmed working" before polling is removed.

### 6.4 Remove 500ms polling — what does it currently do?
**BLOCKER**

The 500ms polling in `startMessageObservation()` calls `refreshTopics()` which does `fetchAllActiveWithCounts()` — a local SQLite read. It refreshes the **local** topic list (message counts, preview text). It does NOT poll the gateway.

The spec says "remove 500ms polling" but the polling and the event handler serve different purposes:
- Polling: refreshes local SQLite view (message counts, last activity)
- Events: triggers gateway re-fetch for topic metadata changes

If polling is removed, message count updates on the topic list will lag until the next streaming event or manual refresh.

**Fix:** Don't remove the 500ms polling yet. It's cheap (local SQLite read) and keeps the UI responsive. Remove it only after GRDB ValueObservation is implemented (mentioned as a future improvement in the ViewModel comments). Or increase to 2-3 seconds to reduce churn.

---

## 7. Shared Package Concerns

### 7.1 `Topic.projectPath` hardcodes `/Users/openclaw/Projects/`
**BLOCKER**

```swift
// Topic.setProjectPath:
guard resolved.hasPrefix("/Users/openclaw/Projects/") else {
    throw TopicError.invalidProjectPath("Path must be within /Users/openclaw/Projects/")
}
```

iOS apps run in a sandbox. `/Users/openclaw/Projects/` doesn't exist on iOS. If the iPhone receives topic metadata with a `projectPath` from the Mac and tries to call `setProjectPath()` on the local Topic model, it will throw.

Even if the iPhone never calls `setProjectPath()` directly (it reads from `metadataJSON`), the computed `projectPath` property is fine (it just decodes JSON). But **any code that calls `setProjectPath()` on iOS will crash**.

**Fix:** Either (a) make the prefix validation platform-conditional (`#if os(macOS)`), (b) move validation to the Mac side only (iPhone reads metadata but never validates paths), or (c) make the prefix configurable and set it to nil on iOS.

### 7.2 `TopicPublishQueue` actor safety from iOS main thread
**PASS (with note)**

`TopicPublishQueue` is an actor with `enqueue()` and `drain()`. The `SyncBridge.publishTopicState()` method is `public func` (non-async, not `@MainActor`) and spawns `Task { await publishQueue.enqueue(...) }`. This crosses isolation boundaries correctly — the Task bridges from the SyncBridge actor to the main thread context, then to the TopicPublishQueue actor.

However, if the mobile app calls `publishTopicState` from `@MainActor` (which the ViewModel is), the `Task {}` inherits `@MainActor` and the `await publishQueue.enqueue()` hops to the actor's executor. This is fine but adds a hop. Not a correctness issue, just a minor performance note.

### 7.3 `BeeChatTopicMetadata` encodes/decodes via AnyCodable — iOS issues?
**PASS**

`BeeChatTopicMetadata` uses standard `Codable` with primitive types (String, Bool, optional String). The RPC client round-trips via `JSONEncoder` → `JSONDecoder(AnyCodable.self)` → gateway. On decode, `SessionInfo.beechatMetadata` extracts from `[String: Any]` with `as?` casts. No platform-specific issues.

**One minor concern:** `SessionInfo.beechatMetadata` uses force-unwrap-style guards:
```swift
guard let ext = pluginExtensions?["beechat"]?["metadata"]?.value as? [String: Any],
      let topicId = ext["topicId"] as? String,
      let isArchived = ext["isArchived"] as? Bool,
      let updatedAt = ext["updatedAt"] as? String
else { return nil }
```
If the gateway ever changes the metadata format (e.g., `isArchived` becomes an Int `0/1`), this silently returns `nil` instead of failing visibly. Consider logging when metadata parse fails.

### 7.4 `reconcileAllTopicState` uses `fetchAllActive()` — excludes archived topics
**WARNING**

```swift
let topics = try topicRepo.fetchAllActive()  // WHERE isArchived = 0
```

This means archived topics are NOT republished on reconnect. If a topic was archived on Mac, the iPhone reconciles, sees no `beechatMetadata` for it (because it wasn't republished), and... the iPhone topic remains with whatever state it had before. The archive state is lost on reconnect for archived topics.

**Fix:** Use `fetchAll()` instead of `fetchAllActive()` in `reconcileAllTopicState()`, or explicitly republish archived topics with `isArchived: true`.

---

## Summary

| Area | Rating | Count |
|------|--------|-------|
| Data Loss | BLOCKER | 2 (1.1, 1.3) |
| Data Loss | WARNING | 2 (1.2, 1.4) |
| Race Conditions | WARNING | 2 (2.1, 2.2) |
| Race Conditions | PASS | 1 (2.3) |
| Scope/Auth | WARNING | 2 (3.2, 3.3) |
| Scope/Auth | PASS | 1 (3.1) |
| Gateway API | WARNING | 1 (4.2) |
| Gateway API | PASS | 2 (4.1, 4.3) |
| Offline/Reconnect | BLOCKER | 1 (5.2) |
| Offline/Reconnect | PASS | 2 (5.1, 5.3) |
| Spec Gaps | BLOCKER | 3 (6.1, 6.3, 6.4) |
| Spec Gaps | PASS | 1 (6.2) |
| Shared Packages | BLOCKER | 1 (7.1) |
| Shared Packages | WARNING | 2 (7.3 nil-silent-fail, 7.4) |
| Shared Packages | PASS | 1 (7.2) |

**Totals: 7 BLOCKERs, 9 WARNINGs, 9 PASSes**

### Must-fix before Phase 1 starts:

1. **BLOCKER 1.3** — Archive state not reconciled. Add `isArchived` propagation from `beechatMetadata` to local topics.
2. **BLOCKER 5.2** — No orphan cleanup. Deleted Mac sessions become immortal zombie topics on iPhone.
3. **BLOCKER 6.3** — `sessions.changed` event handler not wired up. Cannot remove polling until this works.
4. **BLOCKER 6.4** — Don't remove 500ms polling yet. It serves a different purpose than event-driven metadata sync.
5. **BLOCKER 7.1** — `Topic.setProjectPath` hardcoded macOS path will fail on iOS.
6. **BLOCKER 6.1** — "Mac is master" is not enforced. Clarify or implement.
7. **BLOCKER 1.1** — Phase 1 bootstrap path marks topics as synced without publishing metadata.

### Recommended before Phase 2:

- Orphan detection pass (5.2)
- Debounce `sessions.changed` events (2.1, 2.2)
- Cross-device rename conflict strategy (1.4)
- Scope re-verification on reconnect (3.2)
- Include archived topics in reconciliation (7.4)
