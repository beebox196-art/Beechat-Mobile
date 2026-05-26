# Gate 2F: Persistent Topic Linking — Implementation Brief

**Spec ID:** GATE-2F-PERSISTENT-TOPIC-LINKING
**Date:** 2026-05-26
**Author:** Bee (coordinator)
**Status:** DRAFT — Pending team review
**Priority:** High — next active feature for mobile

---

## Problem

Topics created on the Mac don't appear on the iPhone, and vice versa. Each device only sees its own locally-created topics. This makes BeeChat feel like two separate apps rather than one conversation across devices.

## Goal

Same topics on both Mac and iPhone — like Telegram. Mac is master. Gateway is truth. iPhone is cache.

---

## Architecture

**Gateway is truth, iPhone is cache.**
- No last-write-wins, no timestamp comparison
- iPhone always overwrites local with gateway data
- On `sessions.changed`: full re-list (incremental is future optimisation)
- On reconnect: Mac republishes all topic state, iPhone refreshes

**How it works:**
1. Mac publishes topic metadata to gateway via `sessionsPluginPatch` (topic name, project path, etc.)
2. Gateway stores this as `pluginExtensions` on the session
3. iPhone receives `sessions.changed` event → re-lists sessions → extracts `pluginExtensions` → creates/updates local Topics to match
4. When iPhone creates a topic → publishes to gateway → Mac picks it up on next refresh

---

## What Already Exists (BeeChat-v5 `develop` branch)

All shared package infrastructure was added in Steps 1-3 (commits `d0c6cec`, `3ff639d`, `5b6a5f7`):

| Component | File | Status |
|-----------|------|--------|
| `BeeChatTopicMetadata` | `BeeChatSyncBridge/Models/BeeChatTopicMetadata.swift` | ✅ Merged |
| `GatewaySessionInfo` | `BeeChatSyncBridge/Models/GatewaySessionInfo.swift` | ✅ Merged |
| `TopicPublishQueue` | `BeeChatSyncBridge/TopicPublishQueue.swift` | ✅ Merged |
| `sessionsPatch` / `sessionsPluginPatch` / `chatInject` | `BeeChatSyncBridge/RPCClient.swift` | ✅ Merged |
| `SessionInfo.pluginExtensions` + `beechatMetadata` | `BeeChatSyncBridge/Models/SessionInfo.swift` | ✅ Merged |
| `publishTopicState` / `clearTopicState` / `reconcileAllTopicState` | `BeeChatSyncBridge/SyncBridge.swift` | ✅ Merged |
| `GatewayClient.grantedScopes()` + `helloResponse` | `BeeChatGateway/GatewayClient.swift` | ✅ Merged |
| `TopicMetadata` + `Topic.projectPath` | `BeeChatPersistence/Models/Topic.swift` | ✅ Merged |
| `TopicRepository.updateProjectPath()` | `BeeChatPersistence/Repositories/TopicRepository.swift` | ✅ Merged |
| `requeueContextInjection` / `formatSessionSummary` / `buildContextHeader` (enhanced) | `BeeChatSyncBridge/SyncBridge.swift` | ✅ Merged |

**None of this is wired up in the mobile app yet.** The mobile `BeeChatMobileViewModel` doesn't call any of these methods.

---

## What Needs to Change in Mobile

### 1. On Connect: Fetch + Reconcile Gateway Topics

**Current:** Mobile fetches raw sessions and creates local topics for ones without bridges.

**New:** After fetching sessions, extract `pluginExtensions.beechatMetadata` from each session. If metadata exists, use it to create/update local topics with the correct name, project path, and archived state from the gateway.

```swift
// In BeeChatMobileViewModel.connect(), after fetching sessions:
let sessions = try await bridge.fetchSessions()
for session in sessions {
    if let metadata = session.beechatMetadata {
        // Gateway has topic metadata — use it as truth
        // Create or update local topic to match
    } else if BeeChatSessionFilter.isBeeChatSession(session.id, ...) {
        // No metadata yet — this is a raw session, create local topic as before
    }
}
```

### 2. On `sessions.changed` Event: Refresh Topics from Gateway

**Current:** No event handler for `sessions.changed`. The mobile app polls topic list every 500ms.

**New:** When `SyncBridge` receives a `sessions.changed` event, the ViewModel should re-fetch sessions and reconcile local topics. This replaces polling with event-driven updates.

The `SyncBridgeDelegate` needs a new delegate method:
```swift
func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String])
```

### 3. On Topic Create: Publish to Gateway

**Current:** Mobile creates a local topic and sends a "Start" bootstrap message.

**New:** After creating the local topic, publish its metadata to the gateway:
```swift
try await bridge.publishTopicState(topic: topic, sessionKey: sessionKey)
```

This makes the topic visible to Mac immediately.

### 4. On Topic Rename: Update Gateway

**Current:** Mobile doesn't support renaming topics.

**New:** When renaming a topic (future UI), call:
```swift
try await bridge.sessionsPatch(sessionKey: sessionKey, title: newName)
try await bridge.publishTopicState(topic: topic, sessionKey: sessionKey)
```

### 5. On Topic Archive/Delete: Clear Gateway Metadata

**Current:** Local-only archive/delete.

**New:** 
- **Archive:** Publish updated metadata with `isArchived: true`
- **Delete:** Clear gateway metadata with `sessionsPluginPatch(unset: true)`, then delete locally

### 6. On Reconnect: Mac Republishes, iPhone Refreshes

**Current:** Mobile reconnects but doesn't re-sync topic state.

**New:** On reconnect, call `reconcileAllTopicState()` which re-publishes Mac's topics, then mobile re-fetches and reconciles.

---

## Implementation Phases

### Phase 1: Read-Only Sync (Mac → iPhone)
**Goal:** iPhone sees topics created on Mac. No iPhone→Mac publishing yet.

Changes needed:
1. **SessionInfo parsing** — extract `beechatMetadata` from `pluginExtensions` in fetched sessions
2. **Topic reconciliation** — create/update local topics from gateway metadata on connect
3. **`sessions.changed` event handler** — re-fetch and reconcile on gateway push
4. **Scope verification** — check `operator.admin` on connect, warn if missing

**Exit criteria:**
- Create a topic on Mac → it appears on iPhone within seconds
- Rename a topic on Mac → iPhone updates the name
- Archive a topic on Mac → iPhone archives it locally
- No data loss on reconnect

### Phase 2: Write-Through Sync (iPhone → Mac)
**Goal:** Topics created on iPhone appear on Mac.

Changes needed:
1. **`publishTopicState`** on topic create — publish metadata to gateway after bootstrap
2. **Topic rename** — update gateway when user renames on iPhone
3. **Topic archive/delete** — clear gateway metadata

**Exit criteria:**
- Create a topic on iPhone → Mac picks it up
- Mac and iPhone show the same topic list

### Phase 3: Context Injection (iPhone)
**Goal:** First message in a topic includes `[TOPIC-CONTEXT]` header (same as Mac).

Changes needed:
1. **`sendMessage` with topic** — pass `topic: Topic` to `sendMessage`
2. **Context injection** — `contextInjectedKeys` set in SyncBridge, inject `[TOPIC-CONTEXT]` header on first message
3. **Session reset cleanup** — remove key from `contextInjectedKeys` on reset

**Exit criteria:**
- First message in a topic includes context header
- Second message does not
- After session reset, context is re-injected

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Sync direction | Bidirectional (Mac ↔ iPhone) | Telegram-like UX requires both |
| Authority | Gateway is truth | Single source of truth, no merge conflicts |
| Conflict resolution | iPhone overwrites local | Simple, deterministic |
| Persistence | `metadataJSON` column on Topic | Already exists, no migration needed |
| RPC method | `sessionsPluginPatch` | Already exists in shared packages |
| Event driver | `sessions.changed` | Already emits from gateway |
| Scope required | `operator.admin` | Already granted on auto-pairing |

---

## What Does NOT Change

1. **Topic model** — no new columns (uses existing `metadataJSON`)
2. **Database** — no migrations
3. **Topic sidebar UI** — no changes in Phase 1
4. **Message send/receive** — works as-is
5. **Gateway** — no new endpoints needed
6. **Mac app** — already publishing topic state (Steps 1-3)

---

## Risk Table

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | `pluginExtensions` not in `sessions.changed` payload | Low | High | Kieran verified gateway source — it IS included |
| 2 | `operator.admin` scope missing on iPhone | Low | High | Auto-pairing grants full scopes; verify on connect |
| 3 | Race condition: local topic + gateway topic for same session | Medium | Medium | Bridge UNIQUE constraint prevents duplicates |
| 4 | `metadataJSON` malformed from gateway | Low | Medium | Graceful fallback: if metadata parse fails, use raw session data |
| 5 | Polling still active alongside events | Low | Low | Remove 500ms polling once events are confirmed working |

---

## Build Estimate

| Phase | Estimated Time | Dependencies |
|-------|---------------|--------------|
| Phase 1: Read-only sync | 1-2 days | Shared packages already merged |
| Phase 2: Write-through sync | 0.5-1 day | Phase 1 complete |
| Phase 3: Context injection | 0.5 day | Phase 1 complete |

**Total: 2-3.5 days** (Q building, Kieran reviewing, per team protocol)