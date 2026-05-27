# Gate 2B.5 — Phase 1: Data Layer (v4)

**Status:** APPROVED — team review complete (Kieran ✅ Mel ✅ Q partial)  
**Parent:** GATE-2B5-TOPIC-ARCHITECTURE-v2.md  
**Date:** 2026-05-27  
**Replaces:** GATE-2B5-PHASE1-DATA-LAYER-v3.2.md  
**Author:** Bee (coordinator)

---

## Why v4?

v3.2 was approved and partially implemented. Then we discovered that `sessions.pluginPatch` with namespace `beechat/metadata` fails because the gateway rejects unknown plugin namespaces on sessions. The Mac-side publishing (Gate 2F wiring) is disabled (commit `c5f5280`, version `0.6.3-gate2f-disabled`).

This means the `reconcileTopics(from:)` method in the mobile ViewModel — which reads `beechatMetadata` from `pluginExtensions` — will never find any metadata. It's dead code that should be removed.

v4 strips the dead path, keeps everything that works, and defines the clean baseline for the mobile app.

---

## 0. What Changed from v3.2

| Item | v3.2 | v4 | Why |
|------|------|----|-----|
| `reconcileTopics(from:)` using `beechatMetadata` | Present | **Removed** | `pluginPatch` dead — Mac can't publish metadata |
| `didReceiveSessionChange` delegate | Calls `reconcileTopics(from:)` with metadata | Calls `refreshFromGateway()` without metadata | No metadata available |
| `fetchSessionInfos()` call in `connect()` | Present | **Kept** (routed to new method) | `fetchSessionInfos()` returns complete list (including 0-token sessions) — metadata is dead, session list is not (Kieran B1) |
| Session-based topic creation | Present | **Unchanged** | Still works — this is the active path |
| `BeeChatSessionFilter` filtering | Present | **Unchanged** | Still works |
| `pendingGatewaySync` field + reconcile | Present | **Unchanged** | Still needed for offline topic creation |
| All shared package changes (3.1–3.6) | Present | **Unchanged** | Already implemented |
| Seed data rewrite | Present | **Unchanged** | Already implemented |
| `sessionKey(for:)` helper | Present | **Unchanged** | Already implemented |
| Topic CRUD (create, archive, delete) | Present | **Unchanged** | Already implemented |
| Import sessions flow | Present | **Unchanged** | Already implemented |

**Net change:** Remove 3 things (dead metadata path), keep everything else. This is a cleanup, not a rewrite.

---

## 1. Current State of the Codebase

### 1.1 What's Already Built (BeeChat-Mobile ViewModel)

The mobile ViewModel (`BeeChatMobileViewModel.swift`) already has:

- ✅ `topics: [Topic]` (not `[Session]`)
- ✅ `start()` loads topics from `topicRepo.fetchAllActiveWithCounts()`
- ✅ `connect()` filters sessions through `BeeChatSessionFilter`
- ✅ `connect()` creates topics for new BeeChat sessions
- ✅ `connect()` syncs metadata via `syncMetadataFromSessions()`
- ✅ `connect()` reconciles pending offline topics
- ✅ `send(text:to:)` resolves topic ID → session key
- ✅ `createTopic(name:)` with offline `pendingGatewaySync` support
- ✅ `archiveTopic(id:)`, `unarchiveTopic(id:)`, `deleteTopic(id:)`
- ✅ `importCandidates()`, `importSelected(_:)`
- ✅ `sessionKey(for:)` helper
- ✅ Seed data creates Topics, not Sessions

### 1.2 What's Dead (Must Remove)

The `reconcileTopics(from:)` method is dead code — it reads `beechatMetadata` from `pluginExtensions` which Mac never publishes:

```swift
// DEAD — this reads beechatMetadata which Mac never publishes
private func reconcileTopics(from sessionInfos: [SessionInfo]) {
    // ... iterates sessionInfos, extracts beechatMetadata, creates/updates topics ...
}
```

The calls to `fetchSessionInfos()` that feed into `reconcileTopics(from:)` are also dead-end calls — but `fetchSessionInfos()` itself is NOT dead. It returns the complete session list (including 0-token sessions), which `fetchSessions()` does not. Kieran B1: we keep `fetchSessionInfos()` for the complete list, just route it through a different method.

The `didReceiveSessionChange` delegate calls into the dead path:

```swift
nonisolated public func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    Task { @MainActor in
        guard !self.isReconciling else { return }
        self.isReconciling = true
        defer { self.isReconciling = false }
        do {
            let sessionInfos = try await bridge.fetchSessionInfos()
            self.reconcileTopics(from: sessionInfos)  // ← dead path
        } catch {
            print("[ViewModel] Failed to reconcile topics: \(error)")
        }
    }
}
```

### 1.3 What's Missing

The `didReceiveSessionChange` delegate is wired but calls dead code. It should use `fetchSessionInfos()` (complete list) + a new shared `reconcileFromGateway()` method that creates topics from sessions without relying on `beechatMetadata`. The `connect()` method has similar logic duplicated inline — both should call the shared method.

---

## 2. Changes Required

### 2.1 Remove `reconcileTopics(from:)` Method

**File:** `BeeChatMobileViewModel.swift`

Remove the entire `// MARK: - Topic Reconciliation` extension containing `reconcileTopics(from:)`.

This method was designed for the `pluginExtensions`/`beechatMetadata` path which is dead. It will be replaced with a simpler method when the sync channel approach is implemented (future spec).

### 2.2 Keep `fetchSessionInfos()` Call in `connect()` — But Change Its Purpose

**File:** `BeeChatMobileViewModel.swift`

The existing block in `connect()` that calls `fetchSessionInfos()` stays, but the `reconcileTopics(from:)` call is replaced with the shared `reconcileFromGateway()` method (§2.5).

**Why keep `fetchSessionInfos()`?** Kieran B1: `fetchSessions()` applies `sessionShouldAppearByDefault()`, which filters out sessions with `totalTokens == 0`. Brand-new sessions that haven't exchanged a message yet would be invisible. `fetchSessionInfos()` returns ALL sessions from the same `rpcClient.sessionsList()` RPC — no filter applied. The metadata is dead, but the **complete session list** is not.

**Change:** Replace the dead `reconcileTopics(from:)` call with the shared method:

```swift
// BEFORE (dead path):
do {
    let sessionInfos = try await bridge.fetchSessionInfos()
    reconcileTopics(from: sessionInfos)
} catch {
    print("[ViewModel] fetchSessionInfos() failed: \(error). Continuing without metadata sync.")
}

// AFTER:
do {
    let sessionInfos = try await bridge.fetchSessionInfos()
    try await reconcileFromGateway(sessionInfos)
} catch {
    print("[ViewModel] fetchSessionInfos() failed: \(error). Continuing without metadata sync.")
}
```

### 2.3 Rewrite `didReceiveSessionChange` Delegate

**File:** `BeeChatMobileViewModel.swift`

Replace the dead metadata path with a call to the shared `reconcileFromGateway()` method:

```swift
nonisolated public func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    Task { @MainActor in
        guard !self.isReconciling else { return }
        self.isReconciling = true
        defer { self.isReconciling = false }
        do {
            // Use fetchSessionInfos() — returns ALL sessions (fetchSessions() filters out 0-token ones)
            let sessionInfos = try await bridge.fetchSessionInfos()
            try await self.reconcileFromGateway(sessionInfos)
        } catch {
            print("[ViewModel] Failed to reconcile sessions: \(error)")
        }
    }
}
```

**Why `fetchSessionInfos()` not `fetchSessions()`?** Kieran B1: `fetchSessions()` applies `sessionShouldAppearByDefault()` which excludes sessions with `totalTokens == 0`. Brand-new sessions would be invisible. `fetchSessionInfos()` returns the complete list from the same `sessionsList()` RPC. The metadata (`pluginExtensions`) is dead, but the **complete session list** is not.

**Note on `sessionKeys` parameter:** The delegate receives changed session keys but we fetch ALL sessions. This is O(N) when O(K) would suffice. Acceptable for Phase 1 — tracked as future optimisation (Kieran W5).

### 2.4 Extract Shared `reconcileFromGateway()` Method

**File:** `BeeChatMobileViewModel.swift`

Kieran B2: The reconciliation logic is duplicated between `connect()` and `didReceiveSessionChange`. Extract a shared method to prevent divergence:

```swift
/// Reconcile local topics from a complete gateway session list.
/// Creates topics for new BeeChat sessions, syncs metadata, and refreshes the list.
/// Called from both connect() and didReceiveSessionChange.
private func reconcileFromGateway(_ sessionInfos: [SessionInfo]) async throws {
    let topicRepo = persistenceStore.topicRepo
    
    // 1. Filter to BeeChat sessions using injected repo
    let beeChatSessionKeys = sessionInfos.filter { info in
        (try? BeeChatSessionFilter.isBeeChatSession(info.key, topicRepo: topicRepo)) == true
    }.map(\.key)
    
    let beeChatInfos = sessionInfos.filter { beeChatSessionKeys.contains($0.key) }
    
    // 2. Create topics for any new BeeChat sessions
    for info in beeChatInfos {
        if try topicRepo.resolveTopicId(for: info.key) == nil {
            let topic = Topic(
                id: UUID().uuidString,
                name: info.label ?? "Conversation",
                lastMessagePreview: nil,  // SessionInfo doesn't have preview
                lastActivityAt: info.lastMessageAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                sessionKey: info.key
            )
            try topicRepo.save(topic)
            do {
                try topicRepo.saveBridge(topicId: topic.id, sessionKey: info.key)
            } catch {
                print("[ViewModel] Bridge already exists for session \(info.key): \(error)")
            }
        }
    }
    
    // 3. Sync metadata from sessions to local topics
    // Note: syncMetadataFromSessions takes [Session], not [SessionInfo].
    // For didReceiveSessionChange, we skip this step (SessionInfo doesn't have preview/unread).
    // connect() still calls syncMetadataFromSessions separately with [Session] data.
    
    // 4. Refresh topic list
    self.topics = try topicRepo.fetchAllActiveWithCounts()
}
```

**Important: `SessionInfo` vs `Session` types.** `syncMetadataFromSessions()` takes `[Session]` (persistence type with `lastMessagePreview`, `unreadCount`). `SessionInfo` (gateway type) has `label`, `lastMessageAt`, `totalTokens` but not `lastMessagePreview` or `unreadCount`. The shared method creates topics from `SessionInfo` (name, session key, activity date). Metadata sync (preview, unread) still happens in `connect()` via the existing `syncMetadataFromSessions(beeChatSessions)` call with `[Session]` data.

**Usage in `connect()`:**
```swift
// After existing steps 1-2 (pending topics, fetchSessions):
let sessionInfos = try await bridge.fetchSessionInfos()
try await reconcileFromGateway(sessionInfos)
// Then: syncMetadataFromSessions(beeChatSessions) — only in connect() where [Session] is available
try persistenceStore.topicRepo.syncMetadataFromSessions(beeChatSessions)
self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
```

**Usage in `didReceiveSessionChange`:** See §2.3.

**Note on `isReconciling` guard:** This flag prevents rapid `sessions.changed` events from queuing redundant work. It does NOT guard against concurrent execution with `connect()` (Kieran W1 — benign, no data corruption, bridge UNIQUE constraint catches duplicates). This is a known limitation, not a bug.

---

## 3. What Does NOT Change

1. **Shared packages** — no changes. All v3.2 shared package work (3.1–3.6) stays.
2. **Topic model** — `pendingGatewaySync` field stays.
3. **TopicRepository** — all 5 new methods stay.
4. **Migration012** — stays.
5. **BeeChatSessionFilter overloads** — stay.
6. **TopicListView** — stays (already changed to `Topic`).
7. **Seed data** — stays.
8. **Topic CRUD methods** — stay.
9. **Import sessions flow** — stays.
10. **Mac app** — untouched (`0.6.3-gate2f-disabled`).

---

## 4. Success Criteria

### 4.1 Build

- [ ] BeeChat-Mobile compiles (iOS simulator)
- [ ] BeeChat-v5 compiles (macOS — regression check)

### 4.2 Dead Code Removed

- [ ] `reconcileTopics(from:)` method does not exist in ViewModel
- [ ] No reference to `beechatMetadata` or `pluginExtensions` in ViewModel
- [ ] `fetchSessionInfos()` call remains in `connect()` (for complete session list), but calls `reconcileFromGateway()` instead of dead `reconcileTopics(from:)`

### 4.3 Session-Based Reconciliation Works

- [ ] `reconcileFromGateway()` method exists and is called from both `connect()` and `didReceiveSessionChange`
- [ ] `didReceiveSessionChange` uses `fetchSessionInfos()` (complete list, including 0-token sessions)
- [ ] `didReceiveSessionChange` creates topics for new BeeChat sessions
- [ ] `didReceiveSessionChange` refreshes the topic list
- [ ] `isReconciling` guard prevents concurrent reconciliation (self-guard only)
- [ ] If `fetchSessionInfos()` fails, error is logged and app continues
- [ ] `connect()` still calls `syncMetadataFromSessions()` for preview/unread data (Session type)

### 4.4 Existing Functionality Preserved

- [ ] `start()` loads topics from local DB
- [ ] `connect()` filters + creates topics for new sessions (existing path works)
- [ ] `connect()` reconciles pending offline topics
- [ ] `send(text:to:)` resolves topic → session key
- [ ] `createTopic(name:)` works (online + offline)
- [ ] `archiveTopic(id:)`, `deleteTopic(id:)` work
- [ ] Import sessions flow works

### 4.5 macOS Regression

- [ ] BeeChat macOS still builds and runs
- [ ] No change to macOS code (all changes are in BeeChat-Mobile)

### 4.6 Design Assumptions

**Topic ID Independence:** iPhone and Mac generate **different topic IDs** (UUIDs) for the same gateway session. The **session key** (gateway key) is the canonical cross-device link. The bridge table (`topic_session_bridge`) maps session key → topic ID per device. This is acceptable because messages route via session key, not topic ID. Future sync-channel spec will need to handle ID reconciliation if cross-device topic matching becomes necessary.

**Session key is the source of truth.** Topic IDs are device-local convenience identifiers. When the iPhone creates a topic for a gateway session `agent:main:abc123`, it generates its own UUID as `topicId` and stores the mapping in the bridge table. The Mac did the same thing independently with a different UUID. Both devices find the same messages because they query by session key, not topic ID.

---

## 5. Scope Boundary

### In Scope (Phase 1 v4.1)

- Remove dead `reconcileTopics(from:)` method
- Replace `reconcileTopics(from:)` call in `connect()` with `reconcileFromGateway()`
- Extract shared `reconcileFromGateway()` method (called from both `connect()` and `didReceiveSessionChange`)
- Rewrite `didReceiveSessionChange` to use `fetchSessionInfos()` + `reconcileFromGateway()`
- Verify build + existing functionality

### Out of Scope

- **BeeChat sync channel** — future spec (gateway as transport, not data store)
- **Mac app publishing** — blocked on gateway plugin namespace resolution
- **Orphan detection** (archive topics whose gateway session disappeared) — **acknowledged as removed capability** (Kieran W4). Was part of old `reconcileTopics`. Will be re-added in future sync-channel spec when we have a reliable way to detect disappearance.
- **ValueObservation replacing 500ms polling** — future
- **UI changes** — none (TopicListView already uses `Topic`)
- **Incremental session fetching** — currently fetches ALL sessions on `sessions.changed` (Kieran W5) — future optimisation

---

## 6. Risk Table

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | `didReceiveSessionChange` fires before `connect()` completes | Low | Low | `isReconciling` self-guard + bridge UNIQUE catches duplicates (Kieran W1) |
| 2 | Duplicate topic creation (connect + session change both fire) | Low | Low | Bridge UNIQUE constraint catches it; `do/catch` handles gracefully |
| 3 | Removing `reconcileTopics` breaks something unexpected | Low | Low | Method was never called with real data (Mac never published metadata) |
| 4 | `SessionInfo` lacks `lastMessagePreview` / `unreadCount` | Expected | Low | `syncMetadataFromSessions()` in `connect()` handles these from `[Session]` type |
| 5 | Orphan detection lost — stale local topics persist | Medium | Low | Acknowledged as removed capability (Kieran W4). Re-add in sync-channel spec |

---

## 7. Implementation Steps (Q)

1. Remove `reconcileTopics(from:)` extension from ViewModel
2. Add `reconcileFromGateway(_ sessionInfos:)` private method
3. Update `connect()`: replace `reconcileTopics(from:)` call with `reconcileFromGateway()`
4. Rewrite `didReceiveSessionChange` delegate to use `fetchSessionInfos()` + `reconcileFromGateway()`
5. Build and test on iOS simulator
6. Verify macOS BeeChat still works

**Estimated time:** < 2 hours

---

## 8. Rollback

All changes are in `BeeChatMobileViewModel.swift`. Rollback is a single file revert:

```bash
cd /Users/openclaw/Projects/BeeChat-Mobile
git log --oneline -5   # find pre-v4 commit
git checkout <commit> -- BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift
```

---

## 9. Future: Sync Channel Approach

When the Mac app's metadata publishing is re-enabled (via the "gateway as transport" approach — a dedicated BeeChat session or shared state channel, not `pluginPatch`), a new spec will define:

1. How the Mac publishes its topic list (payload format, channel)
2. How the iPhone subscribes and reconciles
3. What replaces `reconcileTopics(from:)` in the ViewModel

That spec will build on this clean baseline — no dead code, no `pluginExtensions` assumptions.

---

## 10. Review History

| Version | Date | Change |
|---------|------|--------|
| v3.2 | 2026-05-18 | All blockers resolved, team-approved (Q ✅ Kieran ✅ Mel ✅) |
| v4 | 2026-05-27 | Strip dead `beechatMetadata`/`pluginPatch` path; session-based reconciliation only |
| v4.1 | 2026-05-27 | Address team review: Kieran B1 (use `fetchSessionInfos()` for complete list), B2 (extract shared reconcile method), W4 (acknowledge orphan detection dropped), W6 (document topic ID assumption) |

---

## 11. Team Review Findings & Resolution (v4)

### Kieran (adversarial)

| Finding | Verdict | v4.1 Resolution |
|---------|---------|----------------|
| **B1:** `fetchSessions()` filters out 0-token sessions via `sessionShouldAppearByDefault()` — brand-new sessions invisible | Fix required | Use `fetchSessionInfos()` for the session LIST (metadata is dead, but complete list is not). See §2.3. |
| **B2:** Duplication between `connect()` and `didReceiveSessionChange` — divergence risk | Fix recommended | Extract shared `reconcileFromGateway()`. See §2.5. |
| W1: `isReconciling` doesn't guard against concurrent `connect()` | Acceptable (benign) | Document as known limitation |
| W2: All errors in `didReceiveSessionChange` are silently printed | Acceptable for Phase 1 | No change — future UX indicator in Phase 2/3 |
| W3: O(N) DB lookups in session filter | Negligible for MVP | No change |
| **W4:** Orphan detection silently dropped | Acknowledge | Explicitly documented in §5 as removed capability |
| W5: `sessionKeys` parameter unused (fetches ALL sessions) | Performance, not correctness | Tracked for future |
| **W6:** Fresh UUIDs mean Mac/iPhone topic IDs won't match | Document assumption | Documented in §4.6 |

6 passes confirmed: dead code audit, `syncMetadataFromSessions`, bridge UNIQUE, rollback, `connect()` unchanged, `isReconciling` self-guard.

### Mel (designer)

| Finding | Verdict | v4.1 Resolution |
|---------|---------|----------------|
| 0 blockers | — | — |
| W1: Mac/mobile topic parity remains approximate | Acceptable | Known limitation of session-based approach |
| W2: Remote disappearance not specified | Acceptable for Phase 1 | Same as Kieran W4 — acknowledged |
| W3: Refresh failure is silent | Acceptable for Phase 1 | Future UX indicator |
| W4: Rapid session changes dropped while reconciling | Acceptable | `isReconciling` guard is correct for MVP |

5 passes confirmed: no empty-state regression, topic creation still works, offline-topic UX preserved, filtering intact, future sync-channel easier.

### Q (builder)

Q's subagent ran but did not produce a review file. The core finding (same as Kieran B1) was identified during the analysis — `fetchSessions()` vs `fetchSessionInfos()` filtering difference is the critical issue.