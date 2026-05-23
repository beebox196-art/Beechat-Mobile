# Gate 2F Phase 1: Mac-Side Topic Publishing — Build Spec v3

**Date:** 2026-05-22
**Author:** Bee (Coordinator)
**Repo:** BeeChat-v5 (macOS) — `/Users/openclaw/Projects/BeeChat-v5`
**Branch:** `feature/gate-2f-phase1`
**Reviewers:** Q (Builder ✅), Kieran (Adversarial ✅), Mel (Designer ✅)
**Status:** 📋 v3 — All blockers resolved, awaiting Adam approval

---

## v3 Changelog

| ID | Source | Issue | v3 Resolution |
|---|---|---|---|
| Q-B1 | Q | `mode: "webchat"` in AppRootView blocks sessions.patch | ✅ Section 0 added: fix client identity before Phase 1 |
| Q-B2 | Q | No `rpc`/`encodeCodable` helper — pseudocode won't compile | ✅ All code uses actual `gateway.call` + `AnyCodable` pattern |
| Q-B3 | Q | BeeChatTopicMetadata encoding unclear | ✅ Explicit JSON round-trip via `JSONEncoder` → `JSONDecoder(AnyCodable.self)` |
| K-B1 | Kieran | Half-published ghost (pluginPatch succeeds, patch fails) | ✅ `publishTopicState` now uses ordered serial queue per topic |
| K-B2 | Kieran | operator.admin scope asserted, not verified | ✅ Scope check in `SyncBridge.start()`, fail-fast log if missing |
| K-B3 | Kieran | `assert` compiled out in Release | ✅ Replaced with runtime `log.warning()` guard |
| K-W1 | Kieran | Race condition on rapid CRUD | ✅ Serial `publishQueue` actor ensures ordering per topic |
| K-W2 | Kieran | Reconnect flood (50 topics × 2 RPCs) | ✅ `TaskGroup` with concurrency limit of 5 |
| K-W3 | Kieran | clearTopicState one-shot, no retry | ✅ Single retry with 1s delay |
| Mel-W1 | Mel | Risk table mentions UI warning but scope is no UI | ✅ Risk table corrected: log-only, no UI |
| Mel-W2 | Mel | reconcileAllTopicState blocks main thread | ✅ Wrapped in detached Task |
| Mel-W3 | Mel | assert() compiled out | ✅ Merged with K-B3 |

---

## Goal

Mac publishes topic state (name, archive status, metadata) to the gateway on every CRUD operation. After Phase 1, the gateway is the authoritative source of topic definitions. iPhone (Phase 2) will derive its topic list from gateway data.

---

## Scope

**What's in:**
- Client identity fix: `mode: "webchat"` → `"ui"` in AppRootView
- `sessionsPatch` and `sessionsPluginPatch` RPC wrappers
- `publishTopicState`, `clearTopicState`, `reconcileAllTopicState` on SyncBridge
- Serial publish queue (ordering guarantee per topic)
- Hook into existing topic CRUD: create, archive, save, delete
- Reconnect reconciliation with concurrency limiter
- Scope verification on startup

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
| `sessions.pluginPatch` | `operator.admin` | ✅ (verified at startup) |

### Client identity (MUST FIX — Q-B1)
**Current (broken):** `AppRootView.swift` sets `clientMode: "webchat"` and `clientInfo.mode: "webchat"`
**Required:** Both must be `"ui"` to pass `rejectWebchatSessionMutation` guard

**Pre-Phase 1 task:**
```swift
// AppRootView.swift — change:
clientMode: "ui",  // was "webchat"
clientInfo: .init(id: "openclaw-control-ui", version: "1.0", platform: "macos", mode: "ui")  // was "webchat"
```
**Risk:** This changes the identity of the Mac client. Verify existing functionality is unaffected. The `openclaw-control-ui` client ID already matches the CONTROL_UI exemption — only the mode changes. The mode affects `rejectWebchatSessionMutation` which guards `sessions.patch`/`sessions.pluginPatch` — existing `chat.send` and `sessions.list` calls are unaffected by mode.

---

## Detailed Changes

### 0. Pre-step: Fix Client Identity

**File:** `Sources/App/AppRootView.swift`

Change `mode: "webchat"` to `mode: "ui"` in both `clientMode` and `clientInfo.mode`. This is a one-line change in two places. Test that the Mac app still connects and works after this change **before** proceeding with Phase 1.

### 1. Add `sessionsPatch` to `RPCClientProtocol` + `RPCClient`

**File:** `Sources/BeeChatSyncBridge/Protocols/SyncBridgeConfiguration.swift` (protocol)
**File:** `Sources/BeeChatSyncBridge/RPCClient.swift` (implementation)

```swift
// In RPCClientProtocol:
func sessionsPatch(key: String, label: String) async throws -> Bool

// In RPCClient:
public func sessionsPatch(key: String, label: String) async throws -> Bool {
    let params: [String: AnyCodable] = [
        "key": AnyCodable(key),
        "label": AnyCodable(label)
    ]
    let result = try await gateway.call(method: "sessions.patch", params: params)
    return (result["result"] as? AnyCodable)?.value as? Bool ?? false
}
```

**Notes:**
- Uses existing `gateway.call(method:params:)` API with `AnyCodable` wrapping
- `sessions.patch` sets the `label` field on a gateway session
- Returns Bool (success/failure)
- Will fail if client lacks `operator.write` scope

### 2. Add `sessionsPluginPatch` to `RPCClientProtocol` + `RPCClient`

```swift
// In RPCClientProtocol:
func sessionsPluginPatch(key: String, pluginId: String, namespace: String, value: Encodable?, unset: Bool) async throws -> Bool

// In RPCClient:
public func sessionsPluginPatch(key: String, pluginId: String, namespace: String, value: Encodable?, unset: Bool) async throws -> Bool {
    var params: [String: AnyCodable] = [
        "key": AnyCodable(key),
        "pluginId": AnyCodable(pluginId),
        "namespace": AnyCodable(namespace),
        "unset": AnyCodable(unset)
    ]
    if let value = value, !unset {
        // Round-trip: Codable → JSON → AnyCodable
        let data = try JSONEncoder().encode(value)
        params["value"] = try JSONDecoder().decode(AnyCodable.self, from: data)
    }
    let result = try await gateway.call(method: "sessions.pluginPatch", params: params)
    return (result["result"] as? AnyCodable)?.value as? Bool ?? false
}
```

**Notes:**
- `pluginId: "beechat"`, `namespace: "metadata"` for all topic publishing
- `value` is the `BeeChatTopicMetadata` JSON (from Phase 0 struct)
- `unset: true` clears the metadata (used on topic deletion)
- Encoding: `JSONEncoder` → `JSONDecoder(AnyCodable.self)` is the standard round-trip for fitting `Codable` structs into `AnyCodable` params
- Requires `operator.admin` scope

### 3. Serial Publish Queue (K-W1 resolution)

**New file:** `Sources/BeeChatSyncBridge/TopicPublishQueue.swift`

```swift
/// Ensures topic publishing is serialised per topic to prevent stale overwrites.
/// e.g., create then rapid rename → rename wins, not vice versa.
actor TopicPublishQueue {
    private var queues: [String: [() async -> Void]] = [:]
    private var running: [String: Bool] = [:]
    
    func enqueue(sessionKey: String, operation: @escaping () async -> Void) {
        if queues[sessionKey] == nil { queues[sessionKey] = [] }
        queues[sessionKey]!.append(operation)
        if running[sessionKey] != true {
            running[sessionKey] = true
            Task { await drain(sessionKey: sessionKey) }
        }
    }
    
    private func drain(sessionKey: String) async {
        while let op = queues[sessionKey]?.first {
            queues[sessionKey]?.removeFirst()
            await op()
        }
        running[sessionKey] = false
    }
}
```

**Why:** Without this, rapid CRUD (create → rename) fires two concurrent Tasks. The slower one (create) might finish after the faster one (rename), overwriting with stale data. Serialising per topic prevents this with minimal overhead.

### 4. `publishTopicState` on SyncBridge

```swift
func publishTopicState(topic: Topic, sessionKey: String) {
    // Runtime guard: verify topicId matches session key suffix (K-B3)
    let keySuffix = sessionKey.split(separator: ":").last.map(String.init)?.lowercased()
    if topic.id.lowercased() != keySuffix {
        log.warning("topicId \(topic.id) does not match session key suffix \(keySuffix ?? "nil") — skipping publish")
        return
    }
    
    // Build metadata
    let metadata = BeeChatTopicMetadata(
        topicId: topic.id,
        isArchived: topic.isArchived,
        projectPath: topic.metadataJSON.flatMap { try? extractProjectPath(from: $0) },
        updatedAt: ISO8601DateFormatter().string(from: Date())
    )
    
    // Enqueue for serial execution per topic
    publishQueue.enqueue(sessionKey: sessionKey) { [weak self] in
        guard let self = self else { return }
        do {
            // Metadata FIRST — if this fails, don't publish label
            let metaOk = try await self.rpcClient.sessionsPluginPatch(
                key: sessionKey,
                pluginId: "beechat",
                namespace: "metadata",
                value: metadata,
                unset: false
            )
            guard metaOk else {
                self.log.error("pluginPatch failed for topic \(topic.id)")
                return  // Skip label — no ghost topic
            }
            
            // Label SECOND
            let labelOk = try await self.rpcClient.sessionsPatch(
                key: sessionKey,
                label: topic.name
            )
            if !labelOk {
                self.log.error("sessionsPatch failed for topic \(topic.id) — metadata published but label not set")
            }
        } catch {
            self.log.error("publishTopicState failed for \(topic.id): \(error)")
            // Don't throw — fire-and-forget. reconcileAllTopicState handles retry on reconnect.
        }
    }
}
```

**Order: metadata FIRST, label SECOND.** Rationale: a session with metadata but no label is usable (shows session key as name). A session with a label but no metadata is a ghost topic that iPhone can't identify.

### 5. `clearTopicState` on SyncBridge (with retry — K-W3 resolution)

```swift
func clearTopicState(sessionKey: String) async {
    for attempt in 1...2 {
        do {
            let ok = try await rpcClient.sessionsPluginPatch(
                key: sessionKey,
                pluginId: "beechat",
                namespace: "metadata",
                value: nil,
                unset: true
            )
            if ok { return }  // Success
            log.warning("clearTopicState attempt \(attempt): pluginPatch(unset) returned false for \(sessionKey)")
        } catch {
            log.error("clearTopicState attempt \(attempt) failed: \(error)")
        }
        if attempt < 2 {
            try? await Task.sleep(for: .seconds(1))
        }
    }
    log.error("clearTopicState: all retries exhausted for \(sessionKey) — ghost metadata may persist")
}
```

### 6. `reconcileAllTopicState` on SyncBridge (with concurrency limit — K-W2, Mel-W2 resolution)

```swift
func reconcileAllTopicState() {
    Task.detached { [weak self] in
        guard let self = self, let delegate = self.delegate else { return }
        let topics = delegate.allTopics().filter { !$0.isArchived && !$0.isDeleted }
        
        // Concurrency limit: max 5 concurrent publishes (K-W2)
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for topic in topics {
                guard let sessionKey = topic.sessionKey else { continue }
                group.addTask {
                    await self.publishTopicState(topic: topic, sessionKey: sessionKey)
                }
                active += 1
                if active >= 5 {
                    await group.next()  // Wait for one to finish before adding more
                    active -= 1
                }
            }
        }
    }
}
```

**When called:**
- On `SyncBridge.start()` after `fetchSessions()` completes — ensures all existing topics are published
- After gateway reconnection (detect via `GatewayClient.connected` event)

### 7. Scope Verification on Startup (K-B2 resolution)

```swift
// In SyncBridge.start(), after successful handshake and before sessionsSubscribe:
func verifyAdminScope() async {
    guard let scopes = config.gatewayClient.helloResponse?.auth?.scopes else {
        log.error("Cannot verify operator.admin scope — handshake auth.scopes unavailable")
        return
    }
    if !scopes.contains("operator.admin") {
        log.error("operator.admin scope MISSING — topic publishing will fail. Scopes granted: \(scopes)")
        // Don't throw — allow app to function without topic sync.
        // Log is visible in console. Future: show banner in settings.
    }
}
```

**Note:** This is log-only, no UI changes (Mel-W1). The scope check is visible in the Mac's debug console. If `operator.admin` is missing, topic publishing silently fails but the app continues to work. Future: add a settings banner.

### 8. Hook into Topic CRUD

**File:** Topic creation / archive / save / delete handlers in the Mac app

| Operation | Existing call | Add |
|---|---|---|
| Create topic | `TopicRepository.create(topic)` | `syncBridge.publishTopicState(topic, sessionKey:)` |
| Archive topic | `TopicRepository.archive(topicId:)` | `syncBridge.publishTopicState(updatedTopic, sessionKey:)` |
| Rename / edit topic | `TopicRepository.save(topic)` | `syncBridge.publishTopicState(topic, sessionKey:)` |
| Delete topic | `TopicRepository.deleteCascading(topicId:)` | `await syncBridge.clearTopicState(sessionKey:)` |

**Important:** These calls fire AFTER the local DB operation succeeds. If the local DB fails, no gateway call is made. If the gateway call fails, local state is still correct (gateway is eventually consistent via `reconcileAllTopicState`).

### 9. `deriveSessionKey` clarification (Q1, K-Q4, K-W7)

`Topic` already has a `sessionKey: String?` property. **Use it directly.** No `deriveSessionKey` function needed. If `topic.sessionKey` is nil, skip publishing for that topic (it means the topic hasn't been linked to a gateway session yet — a bug in topic creation, not a Phase 1 concern).

### 10. `extractProjectPath` helper

Simple JSON extraction from `topic.metadataJSON` (optional String containing JSON):

```swift
func extractProjectPath(from metadataJSON: String) throws -> String? {
    guard let data = metadataJSON.data(using: .utf8) else { return nil }
    let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return dict["projectPath"] as? String
}
```

---

## Exit Criteria

### Pre-Phase 1
- [ ] `mode: "ui"` change verified — Mac app connects and works (existing features unaffected)

### Build
- [ ] BeeChat-v5 compiles clean (`swift build` in project root)
- [ ] No new warnings in BeeChatSyncBridge module

### RPC Wrappers
- [ ] `sessionsPatch` sets label on a gateway session (test via CLI or integration test)
- [ ] `sessionsPluginPatch` stores and retrieves JSON metadata (AnyCodable round-trip verified)
- [ ] `sessionsPluginPatch(unset: true)` clears metadata
- [ ] Both wrappers fail gracefully when scope is missing (not crash)

### Scope Verification
- [ ] `verifyAdminScope()` logs scope status on startup
- [ ] Console shows warning if `operator.admin` is missing

### Topic CRUD Hooks
- [ ] Creating a topic publishes label + `beechat` metadata to gateway
- [ ] Archiving a topic publishes `isArchived: true` to gateway
- [ ] Renaming a topic publishes new label + metadata to gateway (no stale overwrite)
- [ ] Deleting a topic clears gateway metadata (no ghost)

### Ordering
- [ ] Rapid CRUD (create → rename) results in correct final state (rename wins)

### Reconnect
- [ ] `reconcileAllTopicState()` republishes all non-archived, non-deleted topics
- [ ] Concurrency limited to max 5 simultaneous publishes
- [ ] Called on initial start (after fetchSessions) and after reconnection

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
| `Sources/App/AppRootView.swift` | `mode: "webchat"` → `"ui"` (2 places) | 2 |
| `Sources/BeeChatSyncBridge/Protocols/SyncBridgeConfiguration.swift` | Add 2 protocol methods | ~10 |
| `Sources/BeeChatSyncBridge/RPCClient.swift` | Implement 2 RPC wrappers with AnyCodable | ~30 |
| `Sources/BeeChatSyncBridge/TopicPublishQueue.swift` | New file: serial publish queue | ~25 |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Add publishing methods + scope check + reconcile | ~80 |
| Mac app topic CRUD handlers | Add publish hooks | ~20 |
| **Total** | | **~167 lines** |

---

## Test Plan

### Unit Tests (BeeChatSyncBridgeTests)
1. `testSessionsPatchBuildsCorrectRequest` — verify RPC params via `gateway.call`
2. `testSessionsPluginPatchWithValues` — verify AnyCodable encoding round-trip
3. `testSessionsPluginPatchUnset` — verify unset omits value
4. `testPublishTopicStateMetadataFirst` — verify pluginPatch called before patch
5. `testPublishTopicStateMetadataFailureSkipsPatch` — verify short-circuit
6. `testPublishTopicStateMismatchedTopicId` — verify runtime guard skips publish
7. `testClearTopicStateCallsUnset` — verify unset is called
8. `testClearTopicStateRetry` — verify retry on first failure
9. `testReconcileAllTopicStatePublishesNonArchived` — verify filtering
10. `testPublishQueueSerialisesPerTopic` — verify rapid CRUD ordering

### Integration Test
1. Fix `mode: "ui"`, start gateway, pair Mac client — verify connection works
2. Create topic via Mac UI → run `openclaw sessions list` → verify label + `pluginExtensions.beechat.metadata` present
3. Archive topic → verify `isArchived: true` in gateway metadata
4. Rename topic → verify new label in gateway
5. Delete topic → verify metadata cleared (topic session still exists, but no beechat metadata)
6. Rapid create → rename → verify final state is correct (rename wins)
7. Disconnect gateway, create topic → no crash, no error in UI
8. Reconnect gateway → verify topic published (reconcileAllTopicState)

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `mode: "ui"` change breaks existing Mac functionality | Low | High | Test existing features after mode change before proceeding |
| `operator.admin` missing after re-pairing | Low | Medium | `verifyAdminScope()` logs on startup. App still works without topic sync. |
| Both RPC calls fail (gateway offline) | Expected | Low | `reconcileAllTopicState()` on reconnect. |
| App shutdown during publish → lost update | Low | Low | Next reconnect or CRUD operation catches up. |
| `sessions.patch` blocked by `rejectWebchatSessionMutation` | Low | Medium | Fixed by `mode: "ui"` change. Verify client ID matches CONTROL_UI exemption. |
| Topic created locally but publish never succeeds | Low | Medium | Reconcile on reconnect catches this. |

---

## Git

- Branch: `feature/gate-2f-phase1` in BeeChat-v5 repo
- First commit: `mode: "webchat"` → `"ui"` fix (test independently)
- Subsequent commits: Phase 1 implementation
- Squash merge to `main` after Kieran sign-off + Adam validation
- Tag: `gate-2f-phase1` after merge

---

## Notes for Reviewers

**Q (Builder):** All code now uses the real `gateway.call(method:params:)` API with `AnyCodable`. `encodeCodable` pseudocode replaced with explicit JSON round-trip. `TopicPublishQueue` actor handles serialisation. `deriveSessionKey` replaced with direct `topic.sessionKey` usage.

**Kieran (Adversarial):** Scope verification added (K-B2). Assert replaced with runtime guard + log (K-B3). Serial queue per topic prevents race (K-W1). Concurrency limit on reconcile (K-W2). clearTopicState has retry (K-W3). Half-publish ghost handled by serial queue + metadata-first ordering (K-B1).

**Mel (Designer):** Zero visual impact maintained. Risk table corrected — no UI warnings, log-only. Reconcile wrapped in `Task.detached` to avoid main thread blocking (Mel-W2). No UI changes in Phase 1.
