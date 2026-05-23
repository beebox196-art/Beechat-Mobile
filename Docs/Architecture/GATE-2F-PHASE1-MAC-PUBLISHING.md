# Gate 2F Phase 1: Mac-Side Topic Publishing — Build Spec

**Date:** 2026-05-22
**Author:** Bee (Coordinator)
**Repo:** BeeChat-v5 (macOS) — `/Users/openclaw/Projects/BeeChat-v5`
**Branch:** `feature/gate-2f-phase1`
**Reviewer:** Q (Builder), Kieran (Adversarial), Mel (Designer)
**Status:** 📋 DRAFT — Team review

---

## Goal

Mac publishes topic state (name, archive status, metadata) to the gateway on every CRUD operation. After Phase 1, the gateway is the authoritative source of topic definitions. iPhone (Phase 2) will derive its topic list from gateway data.

---

## Scope

**What's in:**
- `sessionsPatch` and `sessionsPluginPatch` RPC wrappers
- `publishTopicState`, `clearTopicState`, `reconcileAllTopicState` on SyncBridge
- Hook into existing topic CRUD: create, archive, save, delete
- Reconnect reconciliation (republish all topics)
- Verify `operator.admin` scope availability

**What's out:**
- iPhone changes (Phase 2)
- UI changes on Mac (no visible UI changes expected)
- Topic creation/deletion logic changes (existing behaviour preserved)
- Message sync (already works via shared session key)

---

## Dependencies

### Phase 0 (✅ Complete)
- `SessionInfo.pluginExtensions` decodes from `sessions.list` response
- `BeeChatTopicMetadata` struct with safe decoding
- Tagged `gate-2f-phase0`, both repos build with updated shared package

### Gateway (no changes needed)
| RPC | Required scope | Mac has it? |
|---|---|---|
| `sessions.patch` | `operator.write` | ✅ |
| `sessions.pluginPatch` | `operator.admin` | ✅ |

### Client identity
| Field | Value | Reason |
|---|---|---|
| `client.id` | `openclaw-control-ui` | Matches CONTROL_UI exemption |
| `mode` | `"ui"` | Passes `rejectWebchatSessionMutation` guard |

---

## Detailed Changes

### 1. Add `sessionsPatch` to `RPCClientProtocol` + `RPCClient`

**File:** `Sources/BeeChatSyncBridge/Protocols/SyncBridgeConfiguration.swift` (protocol)
**File:** `Sources/BeeChatSyncBridge/RPCClient.swift` (implementation)

```swift
// In RPCClientProtocol:
func sessionsPatch(key: String, label: String) async throws -> Bool

// In RPCClient:
public func sessionsPatch(key: String, label: String) async throws -> Bool {
    let result = try await rpc("sessions.patch", ["key": key, "label": label])
    return (result as? Bool) ?? false
}
```

**Notes:**
- `sessions.patch` sets the `label` field on a gateway session
- Returns Bool (success/failure)
- Will fail if client lacks `operator.write` scope

### 2. Add `sessionsPluginPatch` to `RPCClientProtocol` + `RPCClient`

```swift
// In RPCClientProtocol:
func sessionsPluginPatch(key: String, pluginId: String, namespace: String, value: Codable?, unset: Bool) async throws -> Bool

// In RPCClient:
public func sessionsPluginPatch(key: String, pluginId: String, namespace: String, value: Codable?, unset: Bool) async throws -> Bool {
    var params: [String: Any] = [
        "key": key,
        "pluginId": pluginId,
        "namespace": namespace,
        "unset": unset
    ]
    if let value = value, !unset {
        params["value"] = try encodeCodable(value)
    }
    let result = try await rpc("sessions.pluginPatch", params)
    return (result as? Bool) ?? false
}
```

**Notes:**
- `pluginId: "beechat"`, `namespace: "metadata"` for all topic publishing
- `value` is the `BeeChatTopicMetadata` JSON (from Phase 0 struct)
- `unset: true` clears the metadata (used on topic deletion)
- If `unset: true`, `value` is omitted from params
- Requires `operator.admin` scope

### 3. `publishTopicState` on SyncBridge

```swift
func publishTopicState(topic: Topic, sessionKey: String) {
    // Build metadata
    let metadata = BeeChatTopicMetadata(
        topicId: topic.id,
        isArchived: topic.isArchived,
        projectPath: topic.metadataJSON != nil ? extractProjectPath(from: topic.metadataJSON!) : nil,
        updatedAt: ISO8601DateFormatter().string(from: Date())
    )
    
    // Metadata FIRST — if this fails, don't publish label
    Task { [weak self] in
        guard let self = self else { return }
        do {
            let metaOk = try await self.rpcClient.sessionsPluginPatch(
                key: sessionKey,
                pluginId: "beechat",
                namespace: "metadata",
                value: metadata,
                unset: false
            )
            guard metaOk else {
                log.error("pluginPatch failed for topic \(topic.id)")
                return
            }
            
            // Label SECOND
            let labelOk = try await self.rpcClient.sessionsPatch(
                key: sessionKey,
                label: topic.name
            )
            if !labelOk {
                log.error("sessionsPatch failed for topic \(topic.id) — label not set, metadata published")
            }
        } catch {
            log.error("publishTopicState failed for \(topic.id): \(error)")
            // Don't throw — fire-and-forget. reconcileAllTopicState handles retry on reconnect.
        }
    }
}
```

**Order: metadata FIRST, label SECOND.** Rationale: a session with metadata but no label is usable (shows session key as name). A session with a label but no metadata is a ghost topic that iPhone can't identify.

### 4. `clearTopicState` on SyncBridge

```swift
func clearTopicState(sessionKey: String) {
    Task { [weak self] in
        guard let self = self else { return }
        do {
            let ok = try await self.rpcClient.sessionsPluginPatch(
                key: sessionKey,
                pluginId: "beechat",
                namespace: "metadata",
                value: nil,
                unset: true
            )
            if !ok {
                log.warning("clearTopicState: pluginPatch(unset) failed for \(sessionKey)")
            }
        } catch {
            log.error("clearTopicState failed: \(error)")
        }
    }
}
```

### 5. `reconcileAllTopicState` on SyncBridge

```swift
func reconcileAllTopicState() {
    guard let delegate = self.delegate else { return }
    let topics = delegate.allTopics() // or TopicRepository.fetchAll()
    for topic in topics where !topic.isArchived && !topic.isDeleted {
        let sessionKey = deriveSessionKey(from: topic)
        publishTopicState(topic: topic, sessionKey: sessionKey)
    }
}
```

**When called:**
- On `SyncBridge.start()` — ensures all existing topics are published after reconnect
- After gateway reconnection (detect via `GatewayClient.connected` event)

### 6. Hook into Topic CRUD

**File:** Topic creation / archive / save / delete handlers in the Mac app

| Operation | Existing call | Add |
|---|---|---|
| Create topic | `TopicRepository.create(topic)` | `syncBridge.publishTopicState(topic, sessionKey:)` |
| Archive topic | `TopicRepository.archive(topicId:)` | `syncBridge.publishTopicState(updatedTopic, sessionKey:)` |
| Rename / edit topic | `TopicRepository.save(topic)` | `syncBridge.publishTopicState(topic, sessionKey:)` |
| Delete topic | `TopicRepository.deleteCascading(topicId:)` | `syncBridge.clearTopicState(sessionKey:)` |

**Important:** These calls fire AFTER the local DB operation succeeds. If the local DB fails, no gateway call is made. If the gateway call fails, local state is still correct (gateway is eventually consistent via `reconcileAllTopicState`).

### 7. Reconnect Hook

**File:** `GatewayClient` or `SyncBridge` connection state handler

```swift
// On gateway reconnect (after successful handshake + sessions.subscribe):
syncBridge.reconcileAllTopicState()
```

This ensures that if the Mac made topic changes while the gateway was unreachable, they get published on reconnection.

### 8. Debug Assert

```swift
// In publishTopicState:
assert(
    topic.id.lowercased() == sessionKey.split(separator: ":").last.map(String.init),
    "topicId \(topic.id) does not match session key suffix"
)
```

This catches the case where a topic's UUID doesn't match the session key's embedded topic ID — a consistency check that prevents mismatched metadata.

---

## Exit Criteria

### Build
- [ ] BeeChat-v5 compiles clean (`swift build` in project root)
- [ ] No new warnings in BeeChatSyncBridge module

### RPC Wrappers
- [ ] `sessionsPatch` sets label on a gateway session (test via CLI or integration test)
- [ ] `sessionsPluginPatch` stores and retrieves JSON metadata
- [ ] `sessionsPluginPatch(unset: true)` clears metadata
- [ ] Both wrappers fail gracefully when scope is missing (not crash)

### Scope Verification
- [ ] Mac client confirms `operator.admin` in handshake response
- [ ] `sessions.patch` succeeds (passes `rejectWebchatSessionMutation` guard)

### Topic CRUD Hooks
- [ ] Creating a topic publishes label + `beechat` metadata to gateway
- [ ] Archiving a topic publishes `isArchived: true` to gateway
- [ ] Renaming a topic publishes new label + metadata to gateway
- [ ] Deleting a topic clears gateway metadata (no ghost)

### Reconnect
- [ ] `reconcileAllTopicState()` republishes all non-archived, non-deleted topics
- [ ] Called on initial connect and after reconnection

### Offline Resilience
- [ ] Gateway offline: publish calls fail silently, no crash, no UI disruption
- [ ] Gateway comes back: `reconcileAllTopicState()` catches up

### Existing Behaviour
- [ ] No regression: topic CRUD works identically when gateway is unreachable
- [ ] No regression: existing SyncBridge features (message send/receive, streaming) unaffected

### Review
- [ ] Kieran adversarial review: PASS
- [ ] Mel UI review: confirms no visual regression on Mac

---

## Files Changed (estimated)

| File | Change | Lines |
|---|---|---|
| `Sources/BeeChatSyncBridge/Protocols/SyncBridgeConfiguration.swift` | Add 2 protocol methods | ~10 |
| `Sources/BeeChatSyncBridge/RPCClient.swift` | Implement 2 RPC wrappers | ~30 |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Add 3 publishing methods | ~60 |
| Mac app topic CRUD handlers | Add publish hooks | ~20 |
| GatewayClient/SyncBridge reconnect | Add reconcile hook | ~10 |
| **Total** | | **~130 lines** |

---

## Test Plan

### Unit Tests (BeeChatSyncBridgeTests)
1. `testSessionsPatchBuildsCorrectRequest` — verify RPC params
2. `testSessionsPluginPatchWithValues` — verify metadata encoding
3. `testSessionsPluginPatchUnset` — verify unset omits value
4. `testPublishTopicStateOrder` — verify pluginPatch called before patch
5. `testPublishTopicStateMetadataFailureSkipsPatch` — verify short-circuit
6. `testClearTopicStateCallsUnset` — verify unset is called
7. `testReconcileAllTopicStatePublishesNonArchived` — verify filtering

### Integration Test
1. Start gateway, pair Mac client
2. Create topic via Mac UI → run `openclaw sessions list` → verify label + `pluginExtensions.beechat.metadata` present
3. Archive topic → verify `isArchived: true` in gateway metadata
4. Rename topic → verify new label in gateway
5. Delete topic → verify metadata cleared (topic session still exists, but no beechat metadata)
6. Disconnect gateway, create topic → no crash, no error in UI
7. Reconnect gateway → verify topic published (reconcileAllTopicState)

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Mac client lacks `operator.admin` after re-pairing | Low | High | Check scope on start. Show warning in UI if missing. |
| `sessions.patch` blocked by `rejectWebchatSessionMutation` | Low | Medium | Verify `client.id` = `openclaw-control-ui` and `mode` = `"ui"`. |
| Both RPC calls fail (gateway offline) | Expected | Low | `reconcileAllTopicState()` on reconnect. |
| Topic created locally but publish never succeeds | Low | Medium | Reconcile on reconnect catches this. Manual "republish all" button as future option. |

---

## Git

- Branch: `feature/gate-2f-phase1` in BeeChat-v5 repo
- Squash merge to `main` after Kieran sign-off + Adam validation
- Tag: `gate-2f-phase1` after merge

---

## Notes for Reviewers

**Q (Builder):** Focus on RPC wrapper correctness, error handling, and the publish order (metadata first). Does `sessionsPluginPatch` correctly encode `Codable` values for the gateway RPC?

**Kieran (Adversarial):** Look for failure modes. What happens if pluginPatch succeeds but patch fails? What if the topic UUID doesn't match the session key? What if reconnect fires before subscribe completes?

**Mel (Designer):** Phase 1 should have zero visual impact on Mac. Confirm there's nothing that could cause UI flicker, spinner states, or error dialogs for the user.
