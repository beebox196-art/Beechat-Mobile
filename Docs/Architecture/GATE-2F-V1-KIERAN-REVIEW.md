# Gate 2F Spec v1 — Kieran (Adversarial) Review

**Date:** 2026-05-22
**Reviewer:** Kieran (Adversarial Reviewer)
**Spec:** GATE-2F-CROSS-DEVICE-TOPIC-SYNC.md (v1)

---

## Blockers (must fix before implementation)

### B1: `sessions.pluginPatch` requires `operator.admin` scope — spec assumes it "just works"

The spec says Mac calls `sessions.pluginPatch` to store topic metadata. The gateway source confirms:

```js
if (!(...).includes("operator.admin")) {
  respond(false, ..., "sessions.pluginPatch requires gateway scope: operator.admin");
  return;
}
```

BeeChat's `GatewayClient` **does** request `operator.admin` in its scopes array (line in `performHandshake`), and it connects as `clientMode: "ui"` with `client.id: "openclaw-control-ui"` / `"openclaw-ios"`. So it *will* get `operator.admin` on successful pairing. But the spec never documents this dependency or what happens if pairing fails and the client gets reduced scopes. The risk table mentions "rate-limited" but not "scope denied."

**Fix:** Add explicit exit criterion: "Verify `sessions.pluginPatch` succeeds with the actual BeeChat client identity and scopes." Add risk: "Client pairing fails → no `operator.admin` → `pluginPatch` returns error → topic metadata never reaches gateway."

### B2: `sessions.patch` is gated by `rejectWebchatSessionMutation` — not all BeeChat clients may pass

The `rejectWebchatSessionMutation` function blocks session mutations from "webchat" clients. It exempts `CONTROL_UI` (`openclaw-control-ui`). But it **also** blocks `openclaw-ios` if the gateway classifies it as a webchat client. Currently, `isWebchatClient` checks `mode === "webchat"` OR `id === "webchat-ui"`. BeeChat iOS uses `mode: "ui"` and `id: "openclaw-ios"`, so it should pass. But the spec never verifies this, and if anyone changes the iOS client mode to `"webchat"` (e.g., for the web client variant), it silently breaks.

**Fix:** Document the client identity contract explicitly. Add an exit criterion: "Verify `sessions.patch` succeeds from both Mac (`openclaw-control-ui`) and iOS (`openclaw-ios`) clients with `mode: "ui"`."

### B3: `SessionInfo` currently has NO `pluginExtensions` field — Phase 1 exit criterion is unimplementable

The current `SessionInfo` struct in BeeChat-v5 (`Sources/BeeChatSyncBridge/Models/SessionInfo.swift`) has these fields:

```swift
key, label, channel, model, totalTokens, lastMessageAt, agentId, spawnedBy
```

No `pluginExtensions` field exists. The spec's Phase 1 exit criterion says: "`SessionInfo` decodes `pluginExtensions` from sessions.list response" — but that's listed as Phase 1 work, and it says to extend `SessionInfo` to decode it. However, `SessionInfo` is in `BeeChatSyncBridge`, which is a **shared package** used by both Mac and iOS. Adding `pluginExtensions` there affects both apps simultaneously.

The spec doesn't address: what type should `pluginExtensions` be decoded as? The gateway returns `Record<string, Record<string, SessionPluginJsonValue>>` where `SessionPluginJsonValue` is arbitrary JSON. This needs `AnyCodable` handling or a custom decoder. The spec says `optional field: pluginExtensions: [String: [String: AnyCodable]]?` which is reasonable but needs explicit implementation detail.

**Fix:** The extension to `SessionInfo` should be listed as Phase 1 prerequisite work, not a check-box at the end. Specify the exact Swift type. Acknowledge this is shared-package work that must be released to both apps simultaneously.

### B4: Topic deletion on Mac has no gateway cleanup path

The spec says for `TopicRepository.deleteCascading()`:

> "clear plugin metadata or let session deletion handle it"

This is dangerously vague. Looking at the actual code, `deleteCascading` deletes local messages, bridge entries, and the topic — but makes **zero** gateway calls. The session on the gateway persists with `pluginExtensions.beechat.metadata` still set. When iPhone next calls `sessions.list`, it sees that session as a topic that should exist locally — and may recreate it.

The spec also mentions `sessions.delete` as a possibility, but `sessions.delete` requires `operator.admin` scope AND is blocked by `rejectWebchatSessionMutation`. The gateway also prevents deleting the main session. The "or let session deletion handle it" path is a punt — sessions are not automatically deleted when topics are deleted locally.

**Fix:** Decide explicitly: on Mac topic delete, do we (a) call `sessions.pluginPatch` with `unset: true` to clear the metadata, (b) call `sessions.delete` to remove the session entirely, or (c) set `isArchived: true` on the gateway and let iPhone filter? Document the choice and add it to Phase 1.

### B5: iPhone creates topics locally on connect — this will fight the gateway-as-source model

The current `BeeChatMobileViewModel.connect()` does this (step 4):

```swift
for gatewaySession in beeChatSessions {
    if try persistenceStore.topicRepo.resolveTopicId(for: gatewaySession.id) == nil {
        let topic = Topic(id: UUID().uuidString, ...)
        try persistenceStore.topicRepo.save(topic)
        try persistenceStore.topicRepo.saveBridge(topicId: topic.id, sessionKey: gatewaySession.id)
    }
}
```

This creates local topics with **random UUIDs** as topic IDs, **not** the `metadata.topicId` from the gateway. Under the new model, the iPhone should derive the topic ID from the gateway's `pluginExtensions.beechat.metadata.topicId`. If this code runs before the new derivation logic, it will create duplicate topics with different IDs.

**Fix:** Phase 2 must explicitly remove or gate this loop. It cannot coexist with the gateway-derived topic model. Add explicit exit criterion: "No local topic creation on connect — all topics derive from `pluginExtensions`."

---

## Warnings (should fix)

### W1: `sessions.changed` events DO include `pluginExtensions` — the risk table is wrong

The spec's risk table says:

> `sessions.changed` event doesn't include pluginExtensions — Medium likelihood — need to verify

This is incorrect. I verified in the gateway source (`server-methods-BAy3NbTS.js`):

```js
pluginExtensions: sessionRow.pluginExtensions
```

The `emitSessionsChanged$1` function includes `pluginExtensions` in the broadcast payload. The "fallback: periodic `sessions.list` refresh every 60s" is unnecessary complexity.

**Fix:** Remove this from the risk table or downgrade it. Update the architecture to rely on `sessions.changed` including `pluginExtensions` as the primary sync mechanism, with `sessions.list` on reconnect as the catch-all (already in the design).

### W2: The `updatedAt` timestamp in metadata doesn't guarantee last-write-wins across devices

The spec says:

> Race condition: Mac publishes while iPhone is reading — Last-write-wins by `updatedAt` timestamp in metadata

But `updatedAt` is set by the Mac client, not by the gateway. If Mac and iPhone both update the same topic (even in the "Mac-only master" model, iPhone could process stale event data and upsert old state), the comparison is between Mac's clock and iPhone's local clock. No clock sync exists.

More importantly: if the iPhone receives a `sessions.changed` event and upserts local state, but the event is delayed/stale compared to a newer `sessions.list` it already processed, the iPhone could regress its local state.

**Fix:** iPhone should always prefer gateway data over local data (it's not writing to the gateway, so "last-write-wins" is the wrong mental model). The correct model is: iPhone local state is always a cache of the gateway's state. On conflict, gateway wins. No timestamp comparison needed — just overwrite.

### W3: No error handling for `sessions.patch` / `sessions.pluginPatch` RPC failures on Mac

The spec says publishing is "fire-and-forget" but doesn't specify what "forget" means:

- If `sessions.patch` succeeds but `sessions.pluginPatch` fails, the label is updated on the gateway but metadata isn't. iPhone sees a topic with the right name but wrong archive status.
- If both fail, iPhone never sees the topic until Mac does another CRUD or reconnects.

**Fix:** Define explicit failure handling:
1. Call `pluginPatch` first (metadata). If it fails, don't call `patch` — better to have no data than inconsistent data.
2. If `pluginPatch` succeeds but `patch` fails, the topic appears on iPhone with session key as name (acceptable — metadata is correct).
3. Log all failures. On reconnect, `reconcileAllTopicState()` catches up.

---

## Highlights

### H1: Using the gateway as the sync transport is architecturally correct

No separate sync server, no CloudKit, no CRDTs. The gateway is already the session authority. Making it the topic authority too is consistent and minimal.

### H2: The "gateway wins" model eliminates an entire class of bugs

By making iPhone state a pure cache of gateway state (not a peer that can diverge), we avoid sync conflicts entirely. This is the right model for a single-master architecture.

---

*v2 resolution: All blockers and warnings addressed in v2 spec.*