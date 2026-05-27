# Build Verification Review: Gate 2F Persistent Topic Linking Spec v2

**Reviewer:** Q (subagent)  
**Date:** 2026-05-26  
**Spec:** `GATE-2F-PERSISTENT-TOPIC-LINKING.md` (v2)  
**Status:** DRAFT v2 — Review Complete  

---

## 1. Blocker Fix Verification

### Blocker 1: RPCClient Signatures — **FIXED**

v1 had three mismatches. v2 corrects them in the "API Reference (Actual Signatures)" section:

| Method | v1 Wrong | v2 Correct | Code Evidence |
|--------|----------|-----------|---------------|
| `sessionsPatch` | `sessionsPatch(sessionKey:title:)` | `sessionsPatch(key:label:)` | `RPCClient.swift:159` — `public func sessionsPatch(key: String, label: String)` |
| `sessionsPluginPatch` | `sessionsPluginPatch(sessionKey:metadata:)` | `sessionsPluginPatch(key:pluginId:namespace:value:unset:)` | `RPCClient.swift:173` — actual 5-param signature |
| `chatInject` | `chatInject(sessionKey:text:)` | `chatInject(sessionKey:message:label:)` | `RPCClient.swift:193` — `public func chatInject(sessionKey: String, message: String, label: String? = nil)` |

The spec also uses the correct names inline (e.g., `sessionsPatch(key:label:)` in the Phase 2 table). This is clean and unambiguous.

### Blocker 2: `sessions.changed` Delegate Method — **FIXED**

v1: No delegate method existed; `EventRouter` received `sessions.changed` but only called `fetchSessions()` internally, with no callback to `SyncBridgeDelegate`.

v2 spec (Change 1):
- Proposes `func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String])` added to `SyncBridgeDelegate` protocol
- States: "The `EventRouter` already receives `sessions.changed` events from the gateway. Wire it to call this delegate method."
- Shows the ViewModel implementation in Change 4

This is a reasonable design. The existing `EventRouter.handleSessionsChanged()` at `EventRouter.swift:121` currently just calls `syncBridge.fetchSessions()`. Adding a delegate callback here is a small surgical change.

### Blocker 3: `fetchSessionInfos()` vs `fetchSessions()` — **FIXED**

v1: The spec conflated the two methods. `fetchSessions()` returns `[Session]` (persistence type, strips `pluginExtensions`). `fetchSessionInfos()` returns `[SessionInfo]` (gateway type, has `pluginExtensions`).

v2 spec (Change 2):
- Explicitly states: "Currently the ViewModel calls `bridge.fetchSessions()` which returns `[Session]` — the **persistence layer** type that strips `pluginExtensions`. We need `bridge.fetchSessionInfos()` which returns `[SessionInfo]` — the **gateway type** that includes `pluginExtensions`."
- Shows the correct call: `let sessionInfos = try await bridge.fetchSessionInfos()`

This is correct. The `fetchSessionInfos()` method exists at `SyncBridge.swift:897` and calls `rpcClient.sessionsList()` directly, returning raw `SessionInfo` with `pluginExtensions` intact.

### Blocker 4: Archive State Reconciliation — **FIXED**

v1: No code path read `beechatMetadata.isArchived` and updated local `Topic.isArchived`.

v2 spec (Change 3, reconciliation table):
- Row 1: "Gateway has metadata, local topic exists" → "Update name, archive state, project path"
- Shows: `if existingTopic.isArchived != metadata.isArchived { existingTopic.isArchived = metadata.isArchived; changed = true }`
- Exit criteria includes: "Archive a topic on Mac → iPhone archives it locally"

The `Topic` struct has `isArchived: Bool = false` as a mutable property. The `save()` method upserts via GRDB. This is technically feasible.

### Blocker 5: Orphan Cleanup — **FIXED**

v1: No orphan detection. Deleted Mac sessions became immortal zombie topics on iPhone.

v2 spec (Change 3):
- Adds explicit orphan detection: "after reconciliation, compare local topic session keys against the fetched session list"
- Shows code that iterates local topics and archives any whose `sessionKey` isn't in the gateway list
- Decision table row: "Local topic exists, no matching gateway session → Archive locally, don't delete"

This is a safe, non-destructive approach. Archive instead of delete preserves message history.

### Blocker 6: 500ms Polling — **FIXED**

v1: The spec said "remove 500ms polling" but Kieran identified this would break local UI refresh (message counts, preview text).

v2 spec (Change 5):
- Explicit heading: "Keep 500ms Polling (Don't Remove)"
- States: "The existing 500ms polling serves a different purpose than event-driven metadata sync. It refreshes local SQLite data — message counts, preview text, unread indicators. This is cheap and keeps the UI responsive."
- "Keep it. Remove it later only if GRDB ValueObservation replaces it."

This is correct. The polling is in `startMessageObservation()` at `BeeChatMobileViewModel.swift:363`, doing `fetchAllActiveWithCounts()` (local SQLite read, no network).

### Blocker 7: `Topic.setProjectPath` for iOS — **FIXED**

v1: `Topic.setProjectPath` hardcoded `/Users/openclaw/Projects/` prefix validation. iOS sandbox has no such path.

v2 spec (Change 6):
- Shows platform-conditional fix:
```swift
#if os(macOS)
guard path.hasPrefix("/Users/") else { throw TopicError.invalidProjectPath }
#else
// iOS: accept any non-empty path (it comes from Mac via gateway)
guard !path.isEmpty else { throw TopicError.invalidProjectPath }
#endif
```

This is correct. The current `setProjectPath` at `Topic.swift:115` does:
```swift
guard resolved.hasPrefix("/Users/openclaw/Projects/") else { throw ... }
```
The `#if os(macOS)` guard is the minimal fix. However, note the spec's suggested `#if os(macOS)` block uses `"/Users/"` as prefix while the actual code checks `"/Users/openclaw/Projects/"`. The spec should be precise here, but the approach is correct.

---

## 2. Simplicity Assessment

### Change 1: Add `sessions.changed` Delegate Method — **Minimal**
- One new protocol method, one new `EventRouter` case → delegate call
- The `EventRouter` already handles `sessions.changed`; just needs to add the delegate callback alongside the existing `fetchSessions()` call
- **Verdict:** Simplest possible approach. Could we skip it? No — without it, the iPhone never learns about Mac-side changes.

### Change 2: `fetchSessionInfos()` Call — **Minimal**
- Replace one method call with another in `connect()`
- `fetchSessionInfos()` already exists in `SyncBridge.swift`
- **Verdict:** Simplest possible. This is a one-line change.

### Change 3: Topic Reconciliation — **Most Complex Change, but Necessary**
- New method `reconcileTopics(from:)` in ViewModel — ~30 lines
- Needs to handle: create, update, orphan detection
- **Could it be simpler?** The spec shows a lot of branching. Could we simplify by making `TopicRepository` do the heavy lifting? Maybe, but that would require adding a new repository method that understands `SessionInfo`, which would couple the persistence layer to gateway types. Keeping it in the ViewModel is the right separation.
- **One concern:** The spec shows `try topicRepo.update(existingTopic)` but `TopicRepository` has no `update(_:)` method — it only has `save(_:)` (which upserts via GRDB). The spec should use `save()` not `update()`. This is a minor wording issue, not a blocker.
- **Another concern:** The orphan detection iterates all topics. With a large topic list this is O(n) where n is topics. But topics are bounded by active sessions (no user will have 1000 topics), so this is fine.
- **Verdict:** About right. Not over-engineered, but the most involved change in Phase 1.

### Change 4: Wire `sessions.changed` + Debounce — **Minimal**
- One delegate method implementation in ViewModel (~6 lines)
- Simple debounce with `lastReconciliation: Date?` property
- **Verdict:** Simplest possible. Could we skip debounce? No — rapid `sessions.changed` events from batch operations would cause redundant fetches.

### Change 5: Keep Polling — **Minimal**
- No change needed. Just don't delete existing code.
- **Verdict:** Zero cost.

### Change 6: Platform-Conditional Path Validation — **Minimal**
- One `#if os(macOS)`/`#else` block around existing validation
- **Verdict:** Simplest possible.

### Change 7: Scope Verification — **Minimal**
- Call `grantedScopes()` + `contains("operator.admin")` in `connect()`
- Just log warning, don't block
- **Verdict:** Simplest possible. Could skip it (auto-pairing should always grant admin), but a warning is cheap insurance.

---

## 3. Reconciliation Method Realism

### Does `TopicRepository` have `findBySessionKey()`?

**No.** The spec shows:
```swift
if let existingTopic = topicRepo.findBySessionKey(info.key) { ... }
```

But `TopicRepository` has no such method. What it **does** have:
- `resolveTopicId(for: String) -> String?` — returns topic ID for a session key
- `fetchById(_:) -> Topic?` — returns topic by ID

**The realistic implementation would be:**
```swift
if let topicId = try topicRepo.resolveTopicId(for: info.key),
   let existingTopic = try topicRepo.fetchById(topicId) {
    // update...
}
```

Or more simply, query by session key directly. But `TopicRepository` doesn't expose a `fetchBySessionKey` method. This is a **gap in the spec** — the pseudocode won't compile as written.

### Can `Topic` be initialised with the parameters the spec suggests?

The spec shows:
```swift
let topic = Topic(id: metadata.topicId, name: info.label, sessionKey: info.key, isArchived: metadata.isArchived, projectPath: metadata.projectPath)
```

**No.** The `Topic` init has these parameters:
```swift
public init(
    id: String = UUID().uuidString,
    name: String,
    lastMessagePreview: String? = nil,
    lastActivityAt: Date? = nil,
    unreadCount: Int = 0,
    sessionKey: String? = nil,
    isArchived: Bool = false,
    pendingGatewaySync: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    metadataJSON: String? = nil,
    messageCount: Int = 0
)
```

There's no `projectPath` parameter. `projectPath` is a computed property from `metadataJSON`. The spec's init call is wrong — it would need to construct `metadataJSON` from `metadata.projectPath` first, or call `setProjectPath` after creation (but `setProjectPath` validates `/Users/openclaw/Projects/` on macOS, and this code runs on iOS where the `#if os(macOS)` fix would allow it).

**Correct init would be:**
```swift
var topic = Topic(
    id: metadata.topicId,
    name: info.label ?? "Conversation",
    sessionKey: info.key,
    isArchived: metadata.isArchived
)
try topic.setProjectPath(metadata.projectPath) // after iOS fix
```

### Does existing `createTopic()` flow conflict with reconciliation?

**Yes, subtly.** The current `createTopic()` generates its own session key:
```swift
let gatewayKey = "agent:main:\(topicId.lowercased())"
```

If the Mac creates a topic and publishes metadata, the iPhone sees a gateway session with a key. If the iPhone user later creates a topic with the same name (but different ID), it gets a different session key. The reconciliation treats them as separate topics. This is correct behavior — different session keys = different topics.

However, there's a potential race: if iPhone creates a topic offline (pending sync), then Mac creates a topic with the same conceptual name, both get different keys. On reconnect, iPhone sees the Mac's topic as a new topic (good). But the iPhone's offline topic is still pending. The bootstrap send will create a new session on the gateway. Now there are two sessions for similar topics. This is handled by the spec's "orphan detection" eventually archiving one, but it's not an ideal UX. **Not a blocker**, but worth noting.

---

## 4. Debounce Approach

The spec suggests:
```swift
var lastReconciliation: Date?
// In didReceiveSessionChange:
guard Date().timeIntervalSince(lastReconciliation ?? .distantPast) > 0.5 else { return }
lastReconciliation = Date()
```

**Is this the simplest approach?**

Yes. Alternatives considered:
- **Combine/throttle:** Would require importing Combine and adding cancellables. Overkill for a single debounce.
- **Task cancellation:** Would need `reconcileTask: Task?` and `task.cancel()` before each new one. Slightly more complex but same effect.
- **GRDB ValueObservation:** Would eliminate both polling and debounce, but is a larger refactor (post-Gate-2 per spec notes).

**Are there existing patterns?**
The codebase uses `reconnectDebounceSeconds` in `SyncBridgeConfiguration`, but that's for reconnection, not event handling. There's no existing debounce pattern in the ViewModel.

**Verdict:** Simple and sufficient. A `Date` property is the lightest-weight debounce possible. One minor improvement: use `Date().timeIntervalSince(lastReconciliation ?? .distantPast) >= 0.5` (≥ instead of >) to avoid edge cases.

---

## 5. New Issues Introduced by v2 Changes

### Issue A: Spec's `reconcileTopics` pseudocode won't compile as-is

The spec shows pseudocode, but several details don't match actual APIs:

1. `topicRepo.findBySessionKey(info.key)` → does not exist. Use `resolveTopicId(for:)` + `fetchById(_:)`.
2. `Topic(id: ..., name: ..., sessionKey: ..., isArchived: ..., projectPath: ...)` → `projectPath` is not an init parameter. Use `setProjectPath()` after init.
3. `try topicRepo.update(existingTopic)` → method doesn't exist. Use `save(_:)`.

**Severity:** Medium. These are pseudocode inaccuracies, not design flaws. An implementer would hit them quickly.

### Issue B: `sessions.changed` event doesn't carry `sessionKeys` payload

The spec's delegate signature is `didReceiveSessionChange sessionKeys: [String]`, but looking at `EventRouter.handleSessionsChanged()`:
```swift
case "sessions.changed":
    try await handleSessionsChanged()
```

There's no payload parsing. The `sessions.changed` event from the gateway is a signal that the session list changed, not a list of which keys changed. The delegate method should probably take no parameters (or the payload needs to be parsed). If the spec expects `sessionKeys: [String]` from the event, it needs to verify the gateway actually sends that in the payload.

**Severity:** Medium. The `EventRouter` currently ignores payload for `sessions.changed`. The spec should clarify whether `sessionKeys` comes from the event payload or is derived from the subsequent `fetchSessionInfos()` call.

### Issue C: `reconcileTopics` is O(n×m) for topics × sessions

The reconciliation iterates all sessions, and for each session potentially does a DB lookup. Then it iterates all local topics for orphan detection. For small numbers this is fine, but if a user has 50+ sessions, this could be a noticeable pause on the main thread.

**Mitigation:** The spec wraps it in `Task { @MainActor in ... }`, but heavy DB work on MainActor is still heavy. Consider doing the DB reads on a background queue and only updating `@Published` properties on MainActor.

**Severity:** Low for now. 50 sessions × 2 DB calls = trivial on modern hardware.

### Issue D: `projectPath` computed property vs `metadataJSON` mutation

The spec's reconciliation sets `existingTopic.projectPath = metadata.projectPath`, but `projectPath` is a computed property (read-only). You can't assign to it. The correct way is `setProjectPath()` or direct `metadataJSON` mutation.

**Severity:** Medium. The spec treats `projectPath` as a stored property in several places.

### Issue E: Missing `hasAdminScope` property on ViewModel

The spec (Change 7) shows `let scopes = await bridge.grantedScopes()` but the ViewModel doesn't declare `hasAdminScope` as a property. It should be added.

**Severity:** Low. Easy fix during implementation.

### Issue F: `topicRepo.update()` doesn't exist, `topicRepo.save()` is upsert

The spec mentions both `save()` and `update()` but `TopicRepository` only has `save(_:)` (which does GRDB `upsertPreservingCreatedAt`). The reconciliation pseudocode uses `update()` which doesn't exist.

**Severity:** Low. Use `save()` instead.

---

## 6. Overall Simplicity Rating

### **ABOUT RIGHT**

The spec is **not over-engineered**. Each change serves a clear purpose, and the overall approach is "wire existing APIs into the ViewModel." Phase 1 is 6 steps; Phase 2 is 4 steps; Phase 3 is 3 steps. That's minimal for bidirectional topic sync.

**What could be simpler:**
1. **Drop Phase 2 entirely for now** — Phase 1 (Mac→iPhone read-only) delivers the core value. Phase 2 (iPhone→Mac) could wait until Phase 1 is validated in production.
2. **Use `save()` consistently** instead of inventing `update()` methods
3. **Simplify `reconcileTopics` pseudocode** to use actual API names (`resolveTopicId`, `save`, `setProjectPath`)
4. **Remove Change 7 (scope verification)** from Phase 1 — it's defensive but adds noise to the critical path. Can be a log-only check.

**What should NOT be simpler:**
- The delegate method (Change 1) — event-driven is simpler than polling
- The debounce (Change 4) — necessary for batch operations
- Orphan cleanup (Change 3) — without it, zombie topics accumulate forever
- Platform-conditional path (Change 6) — required for iOS correctness

---

## Summary Table

| # | Blocker | v2 Status | Notes |
|---|---------|-----------|-------|
| 1 | RPCClient signatures | **FIXED** | Correct in API Reference section |
| 2 | `sessions.changed` delegate | **FIXED** | Design is sound, `EventRouter` needs wiring |
| 3 | `fetchSessionInfos()` usage | **FIXED** | Explicitly correct in Change 2 |
| 4 | Archive state reconciliation | **FIXED** | Included in reconciliation table and exit criteria |
| 5 | Orphan cleanup | **FIXED** | Safe archive approach, not delete |
| 6 | 500ms polling | **FIXED** | Explicitly kept, not removed |
| 7 | `Topic.setProjectPath` iOS | **FIXED** | Platform-conditional approach correct |

**Overall Simplicity:** **ABOUT RIGHT**

**New Issues Found:**
- Pseudocode uses `findBySessionKey()` which doesn't exist → use `resolveTopicId(for:)` + `fetchById(_:)`
- Pseudocode initializes `Topic` with `projectPath:` parameter which doesn't exist → use `setProjectPath()`
- Pseudocode calls `topicRepo.update()` which doesn't exist → use `save()`
- `sessions.changed` delegate signature takes `[String]` but event payload may not include session keys
- `projectPath` is computed property, not assignable
- Consider background queue for DB work in reconciliation

**Recommended before build:**
1. Fix pseudocode to use actual API names
2. Verify `sessions.changed` payload includes session keys, or adjust delegate signature
3. Consider dropping Phase 2 from initial build (read-only first, validate, then add write-through)
4. Move scope verification to log-only (don't add `hasAdminScope` to ViewModel state unless UI needs it)
