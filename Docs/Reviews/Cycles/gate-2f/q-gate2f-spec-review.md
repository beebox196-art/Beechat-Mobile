# Build Verification Review: Gate 2F Persistent Topic Linking Spec

**Reviewer:** Q  
**Date:** 2026-05-26  
**Spec:** `GATE-2F-PERSISTENT-TOPIC-LINKING.md`  
**Status:** DRAFT — Pending team review  

---

## 1. Shared Package API Accuracy

### ✅ VERIFIED

| Spec Claim | Code Evidence | Status |
|---|---|---|
| `SyncBridge.publishTopicState(topic:sessionKey:)` | `SyncBridge.swift:1054` — `public func publishTopicState(topic: Topic, sessionKey: String)` | **VERIFIED** |
| `SyncBridge.clearTopicState(sessionKey:)` | `SyncBridge.swift:1104` — `public func clearTopicState(sessionKey: String) async` | **VERIFIED** |
| `SyncBridge.clearTopicStateWithResult(sessionKey:)` | `SyncBridge.swift:1110` — `public func clearTopicStateWithResult(sessionKey: String) async -> Bool` | **VERIFIED** |
| `SyncBridge.reconcileAllTopicState()` | `SyncBridge.swift:1129` — `public func reconcileAllTopicState()` | **VERIFIED** |
| `SyncBridge.requeueContextInjection(sessionKey:)` | `SyncBridge.swift:635` — `public func requeueContextInjection(sessionKey: String)` | **VERIFIED** |
| `SyncBridge.formatSessionSummary(_:projectPath:)` | `SyncBridge.swift:657` — `func formatSessionSummary(_ recentMessages: [Message], projectPath: String? = nil) -> String` | **VERIFIED** |
| `SyncBridge.fetchSessions()` | `SyncBridge.swift:184` — `public func fetchSessions() async throws -> [Session]` (returns `[Session]` from persistence layer, not raw `SessionInfo`) | **VERIFIED** |
| `SyncBridge.sendMessage(sessionKey:text:topic:)` | `SyncBridge.swift:209` — `public func sendMessage(sessionKey: String, text: String, thinking: String? = nil, attachments: [ChatAttachment]? = nil, topic: Topic? = nil)` — `topic` param exists and is optional | **VERIFIED** |
| `RPCClient.sessionsPatch(sessionKey:title:)` | `RPCClient.swift:159` — `public func sessionsPatch(key: String, label: String) async throws -> Bool` | **MISMATCH** |
| `RPCClient.sessionsPluginPatch(sessionKey:metadata:)` | `RPCClient.swift:173` — `public func sessionsPluginPatch(key: String, pluginId: String, namespace: String, value: Encodable?, unset: Bool) async throws -> Bool` | **MISMATCH** |
| `RPCClient.chatInject(sessionKey:text:)` | `RPCClient.swift:193` — `public func chatInject(sessionKey: String, message: String, label: String? = nil) async throws -> String` | **MISMATCH** |
| `SessionInfo.pluginExtensions` | `SessionInfo.swift:18` — `public let pluginExtensions: [String: [String: AnyCodable]]?` | **VERIFIED** |
| `SessionInfo.beechatMetadata` | `SessionInfo.swift:55` — computed property, extracts `pluginExtensions["beechat"]["metadata"]` into `BeeChatTopicMetadata` | **VERIFIED** |
| `Topic.projectPath` | `Topic.swift:84` — computed property reading from `metadataJSON` | **VERIFIED** |
| `TopicRepository.updateProjectPath(topicId:path:)` | `TopicRepository.swift:226` — `public func updateProjectPath(topicId: String, path: String?) throws` | **VERIFIED** |
| `TopicPublishQueue` | `TopicPublishQueue.swift:9` — `actor TopicPublishQueue` | **VERIFIED** |
| `BeeChatTopicMetadata` | `BeeChatTopicMetadata.swift` — struct with `topicId`, `isArchived`, `projectPath`, `updatedAt` | **VERIFIED** |
| `GatewaySessionInfo` | `GatewaySessionInfo.swift` — struct with `key`, `label`, `channel`, `model`, `totalTokens`, `lastMessageAt`, `agentId`, `spawnedBy` | **VERIFIED** |
| `GatewayClient.grantedScopes()` | `GatewayClient.swift:88` — `public func grantedScopes() async -> [String]` | **VERIFIED** |

### ⚠️ RPCClient Signature Mismatches

The spec describes simplified method signatures that **do not match the actual RPCClient API**:

1. **`sessionsPatch`** — Spec says `sessionsPatch(sessionKey:title:)` but actual signature is `sessionsPatch(key:label:)`. The spec's parameter names are wrong.
2. **`sessionsPluginPatch`** — Spec says `sessionsPluginPatch(sessionKey:metadata:)` but actual signature is `sessionsPluginPatch(key:pluginId:namespace:value:unset:)`. The spec hides 4 required parameters. Callers must pass `pluginId: "beechat"`, `namespace: "metadata"`, `value: metadata`, `unset: false`.
3. **`chatInject`** — Spec says `chatInject(sessionKey:text:)` but actual signature is `chatInject(sessionKey:message:label:)`. Parameter name is `message`, not `text`.

**Impact:** These are naming mismatches in the spec, not API gaps. The methods exist and work correctly. The spec should be corrected to use actual parameter names, or explicitly note that it uses shorthand.

---

## 2. Mobile ViewModel Compatibility

### Current State of `BeeChatMobileViewModel.swift`

**File:** `BeeChatMobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

| Question | Answer | Status |
|---|---|---|
| Does it use `SyncBridge`? | Yes. `syncBridge: SyncBridge?` property. Created in `connect()`, used for `fetchSessions()`, `sendMessage()`, `streamingContent()`, `connectionStateStream()`. | **VERIFIED** |
| Does it call `fetchSessions()`? | Yes. `connect()` line ~117: `let sessions = try await bridge.fetchSessions()`. | **VERIFIED** |
| Does it have `SyncBridgeDelegate` conformance? | Yes. `extension BeeChatMobileViewModel: SyncBridgeDelegate` implements 8 methods. | **VERIFIED** |
| Does it handle `sessions.changed` events? | **No.** The delegate conformance exists but `didReceiveSessionChange` is **not** in the protocol. Mobile uses 500ms polling (`startMessageObservation()`) instead. | **GAP** |
| Does `sendMessage` accept `topic` parameter? | Yes. Called in `send(text:to:)` and `createTopic()` with `topic: topic`. | **VERIFIED** |
| Current topic creation flow? | `createTopic(name:)` → creates local topic + bridge → if online, sends "Start" bootstrap via `sendMessage(sessionKey:text:topic:)`. Does **not** call `publishTopicState()`. | **GAP** |

### 🔴 Key Gaps

1. **`sessions.changed` event handler missing** — The spec says "New: When `SyncBridge` receives a `sessions.changed` event, the ViewModel should re-fetch sessions and reconcile local topics." But the actual `SyncBridgeDelegate` protocol does **not** have a `didReceiveSessionChange` method. The spec proposes adding one, but this needs to be implemented in `BeeChatSyncBridge` first, then wired in the ViewModel.

2. **Topic creation does not publish to gateway** — The spec's Phase 2 says "publish its metadata to the gateway" on topic create. Currently, mobile creates a local topic and sends "Start" but never calls `publishTopicState()`. The spec needs to clarify whether Phase 1 (read-only) requires this, or if it's strictly a Phase 2 concern.

3. **No `fetchSessionInfos()` usage** — The spec shows extracting `beechatMetadata` from `SessionInfo`, but `fetchSessions()` returns `[Session]` (persistence layer type), not `[SessionInfo]` (gateway type). The ViewModel would need to call `bridge.fetchSessionInfos()` (exists in `SyncBridge.swift:1186`) to get raw gateway metadata. Currently it only calls `fetchSessions()` which loses `pluginExtensions`.

4. **No metadata reconciliation in connect()** — The `connect()` method fetches sessions and creates topics for raw sessions, but does **not** extract `beechatMetadata` from `SessionInfo` to create/update topics from gateway metadata. It uses `syncMetadataFromSessions(_:)` which only updates `lastMessagePreview`, `lastActivityAt`, `unreadCount` — not topic names, archive state, or project paths from metadata.

---

## 3. Spec Completeness

### Phase 1: Read-Only Sync (Mac → iPhone)

| Concern | Assessment | Status |
|---|---|---|
| Missing steps in Phase 1? | **GAP:** Phase 1 does not specify how the ViewModel gets from `SessionInfo` (with `pluginExtensions`) to local `Topic` creation. The spec shows pseudocode but doesn't describe the actual repository calls needed. | **GAP** |
| `beechatMetadata` is nil (raw session)? | Spec mentions: "No metadata yet — this is a raw session, create local topic as before." But this is pseudocode, not a concrete step. The ViewModel currently does this for raw sessions, but the spec doesn't explicitly map this to the existing `BeeChatSessionFilter.isBeeChatSession` logic. | **GAP** |
| Local topic exists but no gateway session? | **Not addressed.** If a topic was created offline and later a gateway session appears with different metadata, the spec doesn't describe conflict resolution. The current `createTopic()` generates its own session key, so this could happen. | **GAP** |
| Gateway session exists with metadata but local topic deleted? | **Not addressed.** If a topic is deleted on iPhone but the Mac session still has metadata, the spec doesn't say whether the iPhone should recreate it or ignore it. The current `resolveTopicId(for:)` would return nil, so the topic would be recreated as a new local topic (with new UUID) on next connect. | **GAP** |
| `SessionInfo.asGatewaySessionInfo` usage? | The `SessionInfo` type has an `asGatewaySessionInfo` computed property, but the spec never mentions it. The `GatewaySessionInfo` type exists but is unused in the spec. | **GAP** |

### Phase 2: Write-Through Sync

| Concern | Assessment | Status |
|---|---|---|
| Topic rename on iPhone? | Spec says "When renaming a topic (future UI)" — this is not implemented yet in mobile. Acceptable as future work. | **VERIFIED** (future) |
| Archive/delete clearing metadata? | Spec describes the desired behavior but no mobile UI for archive/delete exists yet. `archiveTopic()` and `deleteTopic()` in ViewModel do not call `clearTopicState()` or `publishTopicState()`. | **GAP** |

### Phase 3: Context Injection

| Concern | Assessment | Status |
|---|---|---|
| `sendMessage` with `topic` parameter? | Already works. Mobile already passes `topic: topic` in `send()` and `createTopic()`. | **VERIFIED** |
| `contextInjectedKeys` cleanup on reset? | `resetSession()` in `SyncBridge` does `contextInjectedKeys.remove(sessionKey)`. The spec mentions this as a requirement. | **VERIFIED** |
| `requeueContextInjection` usage? | Exists but never called from mobile. Only used internally in `SyncBridge`. Spec doesn't describe when mobile would call it. | **GAP** |

---

## 4. Exit Criteria Assessment

### Phase 1 Exit Criteria

| Criterion | Testable? | Assessment |
|---|---|---|
| "Create a topic on Mac → it appears on iPhone within seconds" | Yes | Requires `sessions.changed` event handler + `fetchSessionInfos()` + metadata extraction. Currently not implemented. |
| "Rename a topic on Mac → iPhone updates the name" | Yes | Same as above. The `sessions.changed` handler would need to update `Topic.name` from `beechatMetadata` or `SessionInfo.label`. |
| "Archive a topic on Mac → iPhone archives it locally" | Yes | Requires `Topic.isArchived` update from metadata. Currently `syncMetadataFromSessions` does not update `isArchived`. |
| "No data loss on reconnect" | Ambiguous | What does "data loss" mean here? Messages are persisted locally. Topics? If a topic is deleted on iPhone but Mac still has metadata, the spec doesn't define the expected behavior. |

### Edge Cases the Spec Misses

1. **Offline topic creation race** — iPhone creates topic offline (pendingGatewaySync=true). Later, Mac creates a topic with the same conceptual name. Both get different session keys. On reconnect, iPhone sees Mac's session as a new topic. Now there are two topics for the same conversation. The spec doesn't address deduplication.

2. **Topic deletion on one device** — iPhone deletes a topic (cascading delete). Mac still has metadata. On next Mac refresh, nothing changes (Mac is master). But on iPhone reconnect, the deleted topic would be recreated from gateway metadata. The spec doesn't define deletion propagation.

3. **`operator.admin` scope verification** — Spec says "warn if missing" but the ViewModel doesn't call `verifyAdminScope()` or `hasAdminScope()`. The `connect()` method does not check scopes.

4. **`fetchSessions()` vs `fetchSessionInfos()` confusion** — The spec conflates these. `fetchSessions()` returns `[Session]` (persistence type, no metadata). `fetchSessionInfos()` returns `[SessionInfo]` (gateway type, has `pluginExtensions`). The ViewModel needs both, or `fetchSessionInfos()` specifically for metadata extraction.

5. **Polling removal** — Spec mentions "Remove 500ms polling once events are confirmed working" as a risk mitigation, but doesn't include it as a concrete step in any phase.

6. **`TopicRepository.syncMetadataFromSessions` is insufficient** — This existing method only updates `lastMessagePreview`, `lastActivityAt`, `unreadCount`. It does NOT update `name`, `isArchived`, or `metadataJSON` from gateway metadata. The spec needs a new repository method or an update to this one.

---

## Summary

| Category | Count |
|---|---|
| **VERIFIED** | 15 |
| **MISMATCH** | 3 (RPCClient parameter names) |
| **GAP** | 11 |

### Critical Gaps Requiring Spec Updates

1. **RPCClient signatures** — Correct parameter names in spec (`key`, `label`, `message`, `pluginId`, `namespace`, `unset`).
2. **`SyncBridgeDelegate` extension** — Add `didReceiveSessionChange` to the protocol (requires shared package change).
3. **`fetchSessionInfos()` usage** — Clarify that mobile needs raw `SessionInfo` array to extract `beechatMetadata`, not `fetchSessions()`.
4. **Metadata reconciliation method** — `TopicRepository` needs a new method to reconcile topics from `SessionInfo` array (name, archive state, project path from metadata).
5. **Edge case definitions** — Define behavior for: deleted topics reappearing, offline topic creation races, scope verification failure.
6. **Polling removal** — Make removing 500ms polling a concrete Phase 1 step.

### Confidence

**Moderate.** The shared package infrastructure is solid and matches the spec's "What Already Exists" table. The mobile ViewModel has the right hooks (`SyncBridge`, `SyncBridgeDelegate`, `topic` parameter in `sendMessage`). But the spec is incomplete on the actual wiring steps needed in the ViewModel, and conflates some method signatures. Phase 1 is achievable but needs 1-2 new shared package APIs (delegate method, metadata reconciliation) and clearer instructions on which `SyncBridge` methods to call.
