# Gate 2F: Persistent Topic Linking — Implementation Brief

**Spec ID:** GATE-2F-PERSISTENT-TOPIC-LINKING
**Date:** 2026-05-26 (v3 — revised after v2 review)
**Author:** Bee (coordinator)
**Reviewers:** Q (implementation), Kieran (safety)
**Status:** APPROVED — Ready for build
**Priority:** High — next active feature for mobile

---

## Problem

Topics created on the Mac don't appear on the iPhone, and vice versa. Each device only sees its own locally-created topics. This makes BeeChat feel like two separate apps rather than one conversation across devices.

## Goal

Same topics on both Mac and iPhone — like Telegram. Phase 1: Mac is sole publisher, iPhone is read-only. Phase 2: both are peers with last-write-wins, self-healing on reconcile.

---

## Architecture Principle: Simple, Using What Exists

The iPhone connects to the Mac's gateway via **Tailscale Serve** — a persistent, encrypted tunnel. This means:

- **The Mac is always reachable** when the iPhone is online
- **File paths are Mac-specific** — they come FROM Mac via gateway metadata, iPhone doesn't generate them
- **No need for complex conflict resolution** — Mac is the only device publishing project paths
- **Last-write-wins on metadata** is fine because only one device publishes at a time for most operations

The shared packages already have everything we need. The work is **wiring existing APIs into the mobile ViewModel**, not building new infrastructure.

---

## How It Works

### Read Path (Mac → iPhone)

1. Mac publishes topic metadata to gateway via `sessionsPluginPatch`
2. Gateway stores this as `pluginExtensions` on the session
3. iPhone receives `sessions.changed` event → calls `fetchSessionInfos()` → extracts `beechatMetadata` → creates/updates local Topics

### Write Path (iPhone → Mac, Phase 2 only)

1. iPhone creates a topic locally → sends bootstrap message → publishes metadata to gateway
2. Mac picks it up on next `sessions.changed` refresh (same mechanism, reverse direction)

### Reconnect

On reconnect, iPhone calls `fetchSessionInfos()` and reconciles all topics from gateway state. Full list, no incremental — simple and correct.

---

## What Already Exists (BeeChat-v5 `develop` branch)

All shared package infrastructure was added in Steps 1-3 (commits `d0c6cec`, `3ff639d`, `5b6a5f7`):

| Component | File | What It Does |
|-----------|------|--------------|
| `BeeChatTopicMetadata` | `BeeChatSyncBridge/Models/BeeChatTopicMetadata.swift` | Codable struct: `topicId`, `isArchived`, `projectPath`, `updatedAt` |
| `GatewaySessionInfo` | `BeeChatSyncBridge/Models/GatewaySessionInfo.swift` | Struct: `key`, `label`, `channel`, `model`, `totalTokens`, `lastMessageAt`, `agentId`, `spawnedBy` |
| `TopicPublishQueue` | `BeeChatSyncBridge/TopicPublishQueue.swift` | Actor-serialised queue for metadata publishes |
| `RPCClient` methods | `BeeChatSyncBridge/RPCClient.swift` | `sessionsPatch(key:label:)`, `sessionsPluginPatch(key:pluginId:namespace:value:unset:)`, `chatInject(sessionKey:message:label:)` |
| `SessionInfo.pluginExtensions` | `BeeChatSyncBridge/Models/SessionInfo.swift` | `[String: [String: AnyCodable]]?` — gateway metadata |
| `SessionInfo.beechatMetadata` | `BeeChatSyncBridge/Models/SessionInfo.swift` | Computed property extracting `pluginExtensions["beechat"]["metadata"]` → `BeeChatTopicMetadata?` |
| `publishTopicState` / `clearTopicState` | `BeeChatSyncBridge/SyncBridge.swift` | Publish/clear topic metadata on gateway |
| `reconcileAllTopicState` | `BeeChatSyncBridge/SyncBridge.swift` | Re-publish all Mac topics (Mac-side only) |
| `GatewayClient.grantedScopes()` | `BeeChatGateway/GatewayClient.swift` | Returns scopes from hello handshake |
| `Topic.projectPath` | `BeeChatPersistence/Models/Topic.swift` | Computed property from `metadataJSON` |
| `TopicRepository.updateProjectPath()` | `BeeChatPersistence/Repositories/TopicRepository.swift` | Update project path on a topic |

**None of this is wired up in the mobile app yet.** The mobile `BeeChatMobileViewModel` doesn't call any of these methods.

---

## What Needs to Change

### Change 1: Add `sessions.changed` Delegate Method (Shared Package)

**File:** `BeeChatSyncBridge/SyncBridgeDelegate.swift` + `EventRouter.swift`

The `SyncBridgeDelegate` protocol currently has no method for session list changes. We need one:

```swift
// Add to SyncBridgeDelegate protocol:
func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String])
```

**Implementation:** The `EventRouter` already receives `sessions.changed` events from the gateway. Wire it to call this delegate method. This is a single shared package change.

**Why this matters:** Without this, the iPhone can't know when the Mac creates/renames/archives a topic. It's the event-driven replacement for polling.

### Change 2: Add `fetchSessionInfos()` Call (Mobile ViewModel)

**File:** `BeeChatMobileViewModel.swift`

Currently the ViewModel calls `bridge.fetchSessions()` which returns `[Session]` — the **persistence layer** type that strips `pluginExtensions`. We need `bridge.fetchSessionInfos()` (already exists at `SyncBridge.swift:1186`) which returns `[SessionInfo]` — the **gateway type** that includes `pluginExtensions`.

```swift
// In connect(), after existing fetchSessions():
let sessionInfos = try await bridge.fetchSessionInfos()
reconcileTopics(from: sessionInfos)
```

**Why this matters:** `fetchSessions()` loses the metadata we need. `fetchSessionInfos()` preserves it.

### Change 3: Add Topic Reconciliation (Mobile ViewModel)

**File:** `BeeChatMobileViewModel.swift` + `TopicRepository.swift`

New method that creates/updates local topics from gateway metadata:

```swift
func reconcileTopics(from sessionInfos: [SessionInfo]) {
    for info in sessionInfos {
        guard let metadata = info.beechatMetadata else {
            // No metadata — this is a raw session (no topic published yet)
            // Create local topic from session label as before
            continue
        }

        // Gateway has topic metadata — use it as truth
        if let topicId = try? topicRepo.resolveTopicId(for: info.key),
           let existingTopic = try? topicRepo.fetchById(topicId) {
            // Update existing topic with gateway data
            var changed = false
            if existingTopic.name != info.label { existingTopic.name = info.label; changed = true }
            if existingTopic.isArchived != metadata.isArchived { existingTopic.isArchived = metadata.isArchived; changed = true }
            if existingTopic.projectPath != metadata.projectPath { try existingTopic.setProjectPath(metadata.projectPath); changed = true }
            if changed { try topicRepo.save(existingTopic) }
        } else {
            // New topic from gateway — create locally
            var topic = Topic(id: metadata.topicId, name: info.label ?? "Conversation", sessionKey: info.key, isArchived: metadata.isArchived)
            try topic.setProjectPath(metadata.projectPath)
            try topicRepo.save(topic)
        }
    }

    // Orphan detection: local topics whose session key isn't in gateway list
    let gatewayKeys = Set(sessionInfos.map(\.key))
    for topic in topics where !gatewayKeys.contains(topic.sessionKey) {
        // Gateway session gone — archive locally (don't delete, user might want history)
        if !topic.isArchived {
            topic.isArchived = true
            try topicRepo.save(topic)
        }
    }
}
```

**Key decisions in this method:**

| Scenario | Behaviour | Why |
|----------|-----------|-----|
| Gateway has metadata, local topic exists | Update name, archive state, project path | Gateway is truth |
| Gateway has metadata, no local topic | Create local topic from metadata | New topic from Mac |
| Gateway has no metadata, raw session | Create local topic as before (existing flow) | Backwards compatible |
| Local topic exists, no matching gateway session | Archive locally, don't delete | User might want history |
| `beechatMetadata` parse fails | Treat as raw session, log warning | Graceful degradation |

### Change 4: Wire `sessions.changed` Event (Mobile ViewModel)

**File:** `BeeChatMobileViewModel.swift`

Add the delegate method from Change 1:

```swift
func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    guard !isReconciling else { return }  // skip if already in-flight
    isReconciling = true
    Task { @MainActor in
        defer { isReconciling = false }
        do {
            let sessionInfos = try await bridge.fetchSessionInfos()
            reconcileTopics(from: sessionInfos)
        } catch {
            logger.warning("Failed to reconcile topics: \(error)")
        }
    }
}
```

**Guard, not debounce:** Use an `isReconciling: Bool` flag instead of date-based debounce. If a reconciliation is already in-flight, skip the event — the next one will pick up any changes. Simpler and avoids the race where a debounce timer fires after data has already been reconciled.

**Error handling:** If `fetchSessionInfos()` fails, log the warning and continue. The `sessions.changed` event will trigger another reconciliation when the connection stabilises.

### Change 5: Keep 500ms Polling (Don't Remove)

The existing 500ms polling (`startMessageObservation()`) serves a different purpose than event-driven metadata sync. It refreshes local SQLite data — message counts, preview text, unread indicators. This is cheap and keeps the UI responsive.

**Keep it.** Remove it later only if GRDB ValueObservation replaces it.

### Change 6: Fix `Topic.setProjectPath` for iOS (Shared Package)

**File:** `BeeChatPersistence/Models/Topic.swift`

Current validation rejects paths not starting with `/Users/`. iOS will never have that path.

**Fix:** Make the **entire validation block** platform-conditional. The current code has three checks: prefix guard, `fileExists`, and `isDirectory`. On iOS, the prefix will never match (it's a Mac path) and `fileExists`/`isDirectory` will always fail for Mac paths. Gate ALL of it:

```swift
func setProjectPath(_ path: String?) throws {
    guard let path else { self.metadataJSON = nil; return }
    #if os(macOS)
    let resolved = path.hasPrefix("/") ? path : ("/Users/openclaw/Projects/" + path)
    guard resolved.hasPrefix("/Users/openclaw/Projects/") else { throw TopicError.invalidProjectPath }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else { throw TopicError.invalidProjectPath }
    self.metadataJSON = TopicMetadata(projectPath: resolved).encode()
    #else
    // iOS: path comes from Mac via gateway metadata — skip filesystem validation
    guard !path.isEmpty else { throw TopicError.invalidProjectPath }
    self.metadataJSON = TopicMetadata(projectPath: path).encode()
    #endif
}
```

On iOS, we only check the path is non-empty since it's a Mac path we'll never validate against a local filesystem.

### Change 7: Scope Verification (Deferred to Phase 2)

Phase 1 is read-only — the iPhone only calls `fetchSessionInfos()` which doesn't require `operator.admin` scope. Scope verification only matters when the iPhone starts publishing metadata (Phase 2). Defer this check.

In Phase 2, add after `connect()`:
```swift
let scopes = await bridge.grantedScopes()
hasAdminScope = scopes.contains("operator.admin")
if !hasAdminScope {
    // Log warning — topic metadata publishing will fail
}
```

---

## Implementation Phases

### Phase 1: Read-Only Sync (Mac → iPhone)

**Goal:** iPhone sees topics created on Mac. No iPhone→Mac publishing yet.

| Step | What | File | Shared Package? |
|------|------|------|-----------------|
| 1A | Add `didReceiveSessionChange` to `SyncBridgeDelegate` + route in `EventRouter` | `SyncBridgeDelegate.swift`, `EventRouter.swift` | Yes |
| 1B | Add `fetchSessionInfos()` call in `connect()` | `BeeChatMobileViewModel.swift` | No |
| 1C | Add `reconcileTopics(from:)` method | `BeeChatMobileViewModel.swift` | No |
| 1D | Wire `didReceiveSessionChange` delegate + guard | `BeeChatMobileViewModel.swift` | No |
| 1E | Fix `Topic.setProjectPath` for iOS (full validation block) | `Topic.swift` | Yes |

**Build order:** 1A and 1E first (shared package changes, can compile and unit-test independently). Then 1B+1C together (fetch + reconcile). Then 1D (wires the delegate, requires 1A merged).

**Error handling:** If `fetchSessionInfos()` fails on connect, log the error and continue. The `sessions.changed` event will trigger reconciliation when the connection stabilises. Don't block the UI for metadata sync.

**Exit criteria:**
- Create a topic on Mac → it appears on iPhone within seconds
- Rename a topic on Mac → iPhone updates the name
- Archive a topic on Mac → iPhone archives it locally
- Delete a topic on Mac (gateway session gone) → iPhone archives it locally (not deleted)
- No data loss on reconnect
- 500ms polling still active (not removed)

### Phase 2: Write-Through Sync (iPhone → Mac)

**Goal:** Topics created on iPhone appear on Mac.

| Step | What | File | Shared Package? |
|------|------|------|-----------------|
| 2A | Call `publishTopicState()` after topic create + bootstrap | `BeeChatMobileViewModel.swift` | No |
| 2B | Call `sessionsPatch(key:label:)` on topic rename (future UI) | `BeeChatMobileViewModel.swift` | No |
| 2C | Call `publishTopicState()` with `isArchived: true` on archive | `BeeChatMobileViewModel.swift` | No |
| 2D | Call `clearTopicStateWithResult()` before local delete | `BeeChatMobileViewModel.swift` | No |

**Exit criteria:**
- Create a topic on iPhone → Mac sees it on next refresh
- Archive a topic on iPhone → Mac archives it
- Delete a topic on iPhone → Mac clears metadata
- Mac and iPhone show the same topic list

### Phase 3: Context Injection (iPhone)

**Goal:** First message in a topic includes `[TOPIC-CONTEXT]` header (same as Mac).

| Step | What | File | Shared Package? |
|------|------|------|-----------------|
| 3A | Pass `topic: Topic` to `sendMessage` (already works) | Already done | — |
| 3B | Verify `contextInjectedKeys` flow works on mobile | `SyncBridge.swift` | No |
| 3C | Verify session reset clears `contextInjectedKeys` | `SyncBridge.swift` | No |

**Exit criteria:**
- First message in a topic includes context header
- Second message does not
- After session reset, context is re-injected

---

## API Reference (Actual Signatures)

These are the real method signatures from the shared packages. Use these exactly:

```swift
// RPCClient — actual parameter names
try await rpcClient.sessionsPatch(key: sessionKey, label: newName)
try await rpcClient.sessionsPluginPatch(key: sessionKey, pluginId: "beechat", namespace: "metadata", value: metadata, unset: false)
try await rpcClient.chatInject(sessionKey: sessionKey, message: text, label: nil)

// SyncBridge — publish/clear topic state
try await bridge.publishTopicState(topic: topic, sessionKey: sessionKey)
try await bridge.clearTopicState(sessionKey: sessionKey)
try await bridge.clearTopicStateWithResult(sessionKey: sessionKey) -> Bool

// SyncBridge — session fetch
let sessions: [Session] = try await bridge.fetchSessions()           // persistence type, no pluginExtensions
let infos: [SessionInfo] = try await bridge.fetchSessionInfos()     // gateway type, HAS pluginExtensions

// SyncBridge — metadata extraction
let metadata: BeeChatTopicMetadata? = sessionInfo.beechatMetadata    // computed property on SessionInfo

// SyncBridge — events
func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String])  // NEW — add to delegate
```

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Sync direction | Phase 1: Mac → iPhone (read-only). Phase 2: bidirectional | Get read-only working first, then add write-through |
| Authority | Phase 1: Mac is sole publisher. Phase 2: peers, last-write-wins, self-healing | Honest about the asymmetry. No enforcement needed for single-user two-device setup. |
| Conflict resolution | Gateway state wins on reconcile | Simple, deterministic. Last-write-wins for metadata. |
| Orphan handling | Archive locally, don't delete | User might want message history. Safe default. |
| Persistence | `metadataJSON` column on Topic | Already exists, no migration needed |
| RPC method | `sessionsPluginPatch(key:pluginId:namespace:value:unset:)` | Already exists in shared packages |
| Event driver | `sessions.changed` via `SyncBridgeDelegate` | Need to add delegate method — single shared package change |
| Scope required | `operator.admin` | Only needed in Phase 2 (iPhone publishing). Defer scope check to Phase 2. |
| Polling | Keep 500ms polling | It's for local UI, not gateway sync. Different purpose. |
| `fetchSessions` vs `fetchSessionInfos` | Use `fetchSessionInfos()` for metadata | `fetchSessions()` strips `pluginExtensions` |

---

## What Does NOT Change

1. **Topic model** — no new columns (uses existing `metadataJSON`)
2. **Database** — no migrations
3. **Topic sidebar UI** — no changes in Phase 1
4. **Message send/receive** — works as-is
5. **Gateway** — no new endpoints needed
6. **Mac app** — already publishing topic state (Steps 1-3)
7. **500ms polling** — stays (local UI refresh, not gateway sync)

---

## Edge Cases

| Scenario | Behaviour | Why |
|----------|-----------|-----|
| iPhone creates topic offline | Topic created locally, marked `pendingGatewaySync`. On connect, bootstrap message sent + metadata published. | Existing flow + `publishTopicState()` in Phase 2 |
| iPhone deletes topic Mac still uses | iPhone archives locally (Phase 1) or clears gateway metadata (Phase 2). Mac is unaffected. | Mac is master by convention |
| Mac archives topic while iPhone has it active | iPhone archives it on next `sessions.changed` reconciliation | Gateway state wins |
| Both devices rename simultaneously | Last `sessionsPluginPatch` wins. Both get the same state on next reconcile. | Low frequency, self-healing |
| `beechatMetadata` parse fails | Treat as raw session, log warning | Graceful degradation |
| `operator.admin` scope missing | Warn in UI, topic metadata won't sync | Auto-pairing should prevent this |
| Gateway session gone but local topic exists | Archive locally (don't delete) | Preserve message history |

---

## Risk Table

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | `sessions.changed` event doesn't include `pluginExtensions` | Low | High | Kieran verified gateway source — it IS included in the event payload |
| 2 | `operator.admin` scope missing on iPhone | Low | High | Auto-pairing grants full scopes; warn on connect if missing |
| 3 | Race: local topic + gateway topic for same session | Low | Medium | Bridge UNIQUE constraint prevents duplicates |
| 4 | `beechatMetadata` parse fails on nil/empty | Low | Medium | Graceful fallback to raw session data |
| 5 | Rapid `sessions.changed` events | Medium | Low | `isReconciling` guard — skip if already in-flight |

---

## Build Estimate

| Phase | Estimated Time | Dependencies |
|-------|---------------|--------------|
| Phase 1: Read-only sync | 1-2 days | Shared package delegate method (1A) + iOS path fix (1E) |
| Phase 2: Write-through sync | 0.5-1 day | Phase 1 complete |
| Phase 3: Context injection | 0.5 day | Phase 1 complete |

**Total: 2-3.5 days** (Q building, Kieran reviewing, per team protocol)

---

## Review History

| Version | Date | Reviewer | Outcome |
|---------|------|----------|---------|
| v1 | 2026-05-26 | Q | 15 verified, 3 mismatches, 11 gaps — RPCClient signatures wrong, no delegate method, wrong fetch method |
| v1 | 2026-05-26 | Kieran | 7 blockers, 9 warnings, 9 passes — no orphan cleanup, archive state not reconciled, polling shouldn't be removed, iOS path validation broken |
| v2 | 2026-05-26 | Bee (coordinator) | Revised spec addressing all 7 blockers + 9 warnings |
| v2 | 2026-05-26 | Q | All 7 blockers FIXED. Simplicity: ABOUT RIGHT. Pseudocode uses non-existent methods (`findBySessionKey`, `update`, `projectPath` init param) — fix at build time |
| v2 | 2026-05-26 | Kieran | 6 FIXED, 1 PARTIALLY FIXED (setProjectPath needs full block gated, not just prefix). Simplicity: ABOUT RIGHT. Deferred scope check to Phase 2. Guard > debounce. |
| v3 | 2026-05-26 | Bee (coordinator) | Fixed setProjectPath to gate full validation block. Guard instead of debounce. Deferred scope check. Honest Phase 1/2 asymmetry. Build order added. |