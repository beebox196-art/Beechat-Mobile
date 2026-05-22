# Gate 2F Spec v1 — Q (Builder) Review

**Date:** 2026-05-22
**Reviewer:** Q (Builder)
**Spec:** GATE-2F-CROSS-DEVICE-TOPIC-SYNC.md (v1)

---

## Blockers (must fix before implementation)

### B1: `sessions.pluginPatch` requires `operator.admin` scope — BeeChat iOS may not have it

The gateway source confirms: `sessions.pluginPatch` requires `operator.admin` scope. If the iOS client connects without `admin` scope, it can't call `pluginPatch`. The spec says *Mac* does the publishing (Phase 1), and iPhone only reads via `sessions.list`, so this is fine for the read path. But if you ever want iPhone to publish (future development mentions "iPhone-created topics could sync back"), this scope requirement blocks it.

More critically: **verify the Mac client connects with `operator.admin` scope.** Looking at `SyncBridge.init`, the scope is set in `GatewayClient.Configuration` — the Mac app currently connects as `openclaw-control-ui` with scopes negotiated via the handshake. The Mac client sets `role: "operator"` with `scopes: ["operator.read", "operator.write", "operator.admin", "operator.approvals", "operator.pairing"]`. **This is confirmed.** But the spec should explicitly note this dependency so it's not accidentally broken by a future scope reduction.

**Action:** Add a note to Phase 1 exit criteria: "Verify Mac client has `operator.admin` scope in handshake response. If scope is missing, `sessions.pluginPatch` calls will fail silently."

### B2: `SessionInfo` currently has no `pluginExtensions` field — the decode will silently return nil for ALL sessions, making Phase 2 impossible until this is added

`SessionInfo.swift` decodes: `key`, `label`, `channel`, `model`, `totalTokens`, `lastMessageAt`, `agentId`, `spawnedBy`. No `pluginExtensions` field exists. The spec says "New optional field: `pluginExtensions: [String: [String: AnyCodable]]?`" which is correct and backwards-compatible. But **this must be done first in Phase 1** before any iPhone code can filter on `pluginExtensions.beechat.metadata.topicId`. The spec puts this in Phase 1 step 5, but the Phase 2 exit criteria depend on it. This is correctly sequenced, but the dependency is fragile — if step 5 is deprioritized or split to a separate PR, Phase 2 breaks.

**Action:** Make `SessionInfo.pluginExtensions` a **hard dependency** for Phase 2, not just a step within Phase 1. Consider making it the very first PR/commit since both phases need it.

### B3: `handleSessionsChanged()` in EventRouter discards the event payload entirely — no `pluginExtensions` reaches the client on `sessions.changed`

The current `EventRouter.handleSessionsChanged()` calls `syncBridge.fetchSessions()` which does a full `sessions.list` round-trip. This works but is wasteful — every `sessions.changed` event triggers a full re-list. The spec says iPhone should react to `sessions.changed` events, but the current code doesn't pass the event payload through at all. The gateway DOES include `pluginExtensions` in the `sessions.changed` broadcast (confirmed in gateway source), but the client throws it away and re-lists.

This isn't a blocker for correctness (full re-list works), but it **is** a performance concern for Phase 2: every metadata change on Mac → full sessions.list from iPhone. For 20-50 sessions, this is acceptable. But the spec's Phase 2 step 3 ("On `sessions.changed` event, if the changed session has topic metadata → upsert local topic") implies incremental updates, which requires plumbing the event payload through.

**Action:** Two options:
1. **Simple (recommended):** Keep the full re-list approach for Phase 2. The iPhone ViewModel already refreshes topics on every `sessions.changed` (via `fetchSessions()` → `refreshTopics()`). Just add the `pluginExtensions`-based filtering to the existing `fetchSessions()` flow. Document that incremental `sessions.changed` handling is a future optimization.
2. **Complex:** Route `sessions.changed` payload through to the ViewModel with incremental upsert. More code and more edge cases for Phase 2.

I recommend option 1. Update the spec to reflect this.

---

## Warnings (should fix)

### W1: Two sequential RPC calls per topic CRUD — `sessions.patch` + `sessions.pluginPatch` are not atomic

The spec says `publishTopicState` calls `sessions.patch` (label) then `sessions.pluginPatch` (metadata). If the first succeeds and the second fails, you have a session with a label but no metadata. The iPhone would see a labeled session without `topicId` in `pluginExtensions`, so it wouldn't appear as a topic — but the label is set on the gateway.

**Mitigation:** Reverse the order — call `sessions.pluginPatch` first, then `sessions.patch`. If `pluginPatch` fails, don't call `patch`. If `pluginPatch` succeeds but `patch` fails, the metadata exists (iPhone can find it) but the label is missing (topic name shows as session key). This is less confusing than having a named session that doesn't show up as a topic. Or better: make both calls concurrent with `async let` and check both results before considering the publish successful.

### W2: `deleteCascading` doesn't clean up gateway session metadata

The spec says "clear plugin metadata or let session deletion handle it" for `deleteCascading`. But `deleteCascading` deletes the local topic + bridge + messages. It does NOT delete the gateway session. The gateway session persists with stale `pluginExtensions.beechat` metadata and a label. iPhone would see a "ghost topic" from the deleted Mac topic.

**Action:** Add a `sessions.pluginPatch(key:, pluginId: "beechat", namespace: "metadata", unset: true)` call when deleting a topic. Or accept that deleted topics persist on the gateway as ghost sessions and filter them out on iPhone by checking if the local DB still has the topic.

### W3: The spec says "fire-and-forget" for publish on CRUD, but has no retry or queue mechanism

If Mac publishes topic state and the gateway is offline, the publish is lost. When the gateway comes back online, the topic state on the gateway is stale. The spec mentions "no regression on Mac — existing topic CRUD still works when gateway is offline" but doesn't address what happens when Mac reconnects. The iPhone would get stale topic state from the gateway until Mac does another CRUD operation.

**Mitigation:** On `SyncBridge.start()` / reconnect, iterate all local topics and call `publishTopicState` for each. This is a one-time reconciliation on connect, similar to the existing `fetchPendingSyncTopics` reconciliation for offline messages. Add this to Phase 1 exit criteria.

### W4: `topicId` in `pluginExtensions` uses the local UUID, not the gateway session key

The spec stores `metadata.topicId` as the local topic UUID. But the gateway session key is already `agent:main:<topicId.lowercased()>` (from `TopicRepository.create()`). The iPhone could derive the topic ID from the session key itself by stripping the `agent:main:` prefix and uppercasing. Storing `topicId` in metadata is redundant and creates a consistency risk if the local topic ID ever diverges from the one in the session key.

**Consideration:** Keep `topicId` for explicitness, but document that it MUST match the UUID embedded in the session key. Add a debug assert in `publishTopicState`.

### W5: The `AnyCodable` type for `pluginExtensions` is untyped on the Swift side

The spec proposes `pluginExtensions: [String: [String: AnyCodable]]?` on `SessionInfo`. This means the iPhone needs to manually extract `beechat.metadata.topicId`, `beechat.metadata.isArchived`, etc. from nested `AnyCodable` dictionaries. This is fragile — typos in key names, type mismatches (Bool vs Int), etc. will silently fail.

**Mitigation:** Create a typed `BeeChatTopicMetadata: Codable` struct and add a convenience method on `SessionInfo` to decode it:

```swift
struct BeeChatTopicMetadata: Codable {
    let topicId: String
    let isArchived: Bool
    let projectPath: String?
    let updatedAt: String
}

extension SessionInfo {
    var beechatMetadata: BeeChatTopicMetadata? {
        guard let ext = pluginExtensions?["beechat"]?["metadata"],
              let data = try? JSONEncoder().encode(ext),
              let meta = try? JSONDecoder().decode(BeeChatTopicMetadata.self, from: data)
        else { return nil }
        return meta
    }
}
```

---

## Highlights

### H1: Using existing gateway infrastructure is the right call

No new endpoints, no custom sync protocol. `sessions.patch` + `sessions.pluginPatch` + `sessions.list` + `sessions.changed` cover the entire use case. This is minimal invention.

### H2: `pluginExtensions` is the perfect extensibility slot

The gateway's plugin extension system was designed for exactly this kind of per-session metadata. Using `pluginId: "beechat"` and `namespace: "metadata"` is clean and doesn't collide with anything else.

---

*v2 resolution: All blockers and warnings addressed in v2 spec.*