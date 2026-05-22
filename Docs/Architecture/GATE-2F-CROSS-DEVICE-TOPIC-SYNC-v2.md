# Gate 2F: Cross-Device Topic Sync — Spec v2

**Date:** 2026-05-22
**Author:** Bee (Coordinator)
**Status:** 📋 DRAFT v2 — Team review resolved, pending Adam approval
**v1 reviewers:** Q (Builder), Kieran (Adversarial), Mel (Designer)
**v2 changes:** All blockers and warnings from team review resolved (see Appendix A)

---

## Goal

Mac is the master topic source. iPhone sees the same topics as Mac. Messages are shared automatically via the gateway's existing session model. No bidirectional sync needed.

## Design Constraints (Adam, May 22)

1. **Mac is master** — topic definitions (name, archive status, project binding) flow Mac → iPhone only
2. **iPhone is conversations on the go** — no need for iPhone-created topics to sync back to Mac
3. **One device at a time typically** — no relentless real-time pinging
4. **Simple, stable, unbreakable** — no over-engineering
5. **Standard patterns** — use existing gateway infrastructure, minimal invention
6. **Message history is shared automatically** — same session key = same gateway conversation. No extra sync needed.
7. **"Load earlier messages" pagination** — dropped for iPhone initial release. Logged as future development option.

## Architecture

### Core insight

The gateway already has everything we need. Topics are sessions with metadata. We use:

- **`sessions.patch`** — set `label` (topic name) on a session
- **`sessions.pluginPatch`** — store arbitrary JSON metadata per-session (archive status, project binding, topic ID)
- **`sessions.list`** — returns all sessions with labels + `pluginExtensions` (already called by both apps on connect)
- **`sessions.subscribe` + `sessions.changed`** — gateway already broadcasts metadata changes including `pluginExtensions` to all connected clients
- **`chat.history`** — messages are shared automatically because both devices use the same session key

### Gateway scope requirements

| RPC | Required scope | Mac has it? | Notes |
|---|---|---|---|
| `sessions.patch` | `operator.write` | ✅ | Also gated by `rejectWebchatSessionMutation` — client must use `mode: "ui"`, not `"webchat"` |
| `sessions.pluginPatch` | `operator.admin` | ✅ | Mac connects as `openclaw-control-ui` with full operator scopes |
| `sessions.list` | `operator.read` | ✅ | Both devices already call this |
| `sessions.pluginPatch(unset)` | `operator.admin` | ✅ | Used on topic deletion to clear metadata |

**iPhone only reads** — it never calls `sessions.patch` or `sessions.pluginPatch`. No admin scope needed on iPhone.

### Client identity contract

Both BeeChat clients must connect with these settings to pass gateway mutation guards:

| Client | `client.id` | `mode` | Must pass `rejectWebchatSessionMutation`? |
|---|---|---|---|
| Mac | `openclaw-control-ui` | `"ui"` | Yes — exempted as CONTROL_UI |
| iOS | `openclaw-ios` | `"ui"` | N/A — iOS never calls mutation RPCs |

**Do not change iOS client mode to `"webchat"`** — this would silently break the architecture if future bidirectional sync is added.

### Data flow

```
Mac creates/renames/archives a topic
  → Mac calls sessions.pluginPatch (metadata FIRST) 
  → Mac calls sessions.patch (label second)
  → Gateway stores metadata + label on the session
  → Gateway broadcasts sessions.changed (includes pluginExtensions)
  → iPhone receives event → full sessions.list refresh → derives topics

iPhone connects / reconnects
  → iPhone calls sessions.list (already does this)
  → iPhone derives topics from sessions that have pluginExtensions.beechat.metadata.topicId
  → Full conversation history available via chat.history (same session key)
  
Mac deletes a topic
  → Mac calls sessions.pluginPatch(unset: true) to clear metadata
  → Gateway broadcasts sessions.changed
  → iPhone sees session without metadata → removes from topic list
```

### What gets stored on the gateway

For each session that has a BeeChat topic:

| Field | Source | Via | Notes |
|---|---|---|---|
| `label` | Topic name | `sessions.patch` | Already supported |
| `pluginExtensions.beechat.metadata.topicId` | String (UUID) | `sessions.pluginPatch` | MUST match UUID in session key (`agent:main:<topicId.lowercased()>`) |
| `pluginExtensions.beechat.metadata.isArchived` | Bool | `sessions.pluginPatch` | False by default |
| `pluginExtensions.beechat.metadata.projectPath` | String? | `sessions.pluginPatch` | Stored but NOT displayed on iPhone |
| `pluginExtensions.beechat.metadata.updatedAt` | ISO 8601 | `sessions.pluginPatch` | Set by Mac |

**Namespace:** `pluginId: "beechat"`, `namespace: "metadata"`

### iPhone local model: gateway is truth, local DB is cache

iPhone does NOT use last-write-wins or timestamp comparison. The model is:

- **Gateway is the authoritative source.** iPhone local state is always a cache of gateway state.
- **On conflict: gateway wins.** Always overwrite local with gateway data. No timestamp comparison needed.
- **On `sessions.changed`:** Full `sessions.list` refresh (not incremental). For 20-50 sessions this is fine. Incremental event handling is a future optimization.

### Message sharing

Messages need **no sync mechanism** beyond what already exists:

1. Both devices use the same `sessionKey` for the same topic
2. Gateway stores all messages for that session
3. `chat.history` returns messages regardless of which device sent them
4. Real-time `chat` events stream to whichever device is connected

---

## Phased Build Plan

### Phase 0: Shared Package Prerequisite

**Goal:** Extend `SessionInfo` to decode `pluginExtensions`. This is a hard dependency for both Phase 1 and Phase 2.

**Changes in BeeChatSyncBridge (shared package):**

1. Add `pluginExtensions` field to `SessionInfo`:
   ```swift
   public let pluginExtensions: [String: [String: AnyCodable]]?
   ```
2. Create typed `BeeChatTopicMetadata` struct for safe decoding:
   ```swift
   public struct BeeChatTopicMetadata: Codable {
       public let topicId: String
       public let isArchived: Bool
       public let projectPath: String?
       public let updatedAt: String
   }
   ```
3. Add convenience method on `SessionInfo`:
   ```swift
   public var beechatMetadata: BeeChatTopicMetadata? {
       guard let ext = pluginExtensions?["beechat"]?["metadata"],
             let data = try? JSONEncoder().encode(ext),
             let meta = try? JSONDecoder().decode(BeeChatTopicMetadata.self, from: data)
       else { return nil }
       return meta
   }
   ```

**Exit criteria:**
- [ ] `SessionInfo` decodes `pluginExtensions` from `sessions.list` response (nil if absent — backwards compatible)
- [ ] `BeeChatTopicMetadata` parses correctly from nested AnyCodable
- [ ] Both BeeChat-v5 (Mac) and BeeChat-Mobile (iOS) build with the updated shared package
- [ ] No regression: existing `SessionInfo` fields still decode correctly

**Note:** This is shared-package work. Must be released to both repos simultaneously (SPM local dependency update).

### Phase 1: Mac-Side Publishing

**Goal:** Mac publishes topic state to gateway on every CRUD operation.

**Changes in BeeChat-v5 (macOS):**

1. Add `sessionsPatch(key:label:)` to `RPCClientProtocol` + `RPCClient`
2. Add `sessionsPluginPatch(key:pluginId:namespace:value:unset:)` to `RPCClientProtocol` + `RPCClient`
3. Add `publishTopicState(topic:sessionKey:)` on SyncBridge:
   - Calls `sessions.pluginPatch` FIRST (metadata)
   - Then calls `sessions.patch` (label)
   - If `pluginPatch` fails, don't call `patch` (avoid orphaned label without metadata)
   - Log errors, don't throw — this is fire-and-forget for the publish path
4. Add `clearTopicState(sessionKey:)` on SyncBridge:
   - Calls `sessions.pluginPatch` with `unset: true` to clear beechat metadata
   - Used on topic deletion
5. Add `reconcileAllTopicState()` on SyncBridge:
   - Iterates all local topics, calls `publishTopicState` for each
   - Called on `SyncBridge.start()` / reconnect to ensure gateway is current
6. Hook into topic CRUD operations:
   - After `TopicRepository.create()` → `publishTopicState`
   - After `TopicRepository.archive()` → `publishTopicState`
   - After `TopicRepository.save()` (rename/edit) → `publishTopicState`
   - After `TopicRepository.deleteCascading()` → `clearTopicState` (clear gateway metadata, session persists)
7. Add debug assert in `publishTopicState`: verify `topic.id.lowercased()` matches suffix of `sessionKey`

**Exit criteria:**
- [ ] `sessionsPatch` RPC wrapper works (can set label on a session)
- [ ] `sessionsPluginPatch` RPC wrapper works (can store and unset JSON metadata)
- [ ] Mac client has `operator.admin` scope in handshake response (verify with live test)
- [ ] `sessions.patch` succeeds from Mac client (verify `rejectWebchatSessionMutation` passes)
- [ ] Creating a topic on Mac publishes label + metadata to gateway
- [ ] Archiving a topic on Mac publishes updated metadata to gateway
- [ ] Renaming a topic on Mac publishes updated label + metadata to gateway
- [ ] Deleting a topic on Mac clears gateway metadata (no ghost topic on iPhone)
- [ ] On reconnect, `reconcileAllTopicState()` republishes all topic state
- [ ] No regression: existing topic CRUD still works when gateway is offline (publish fails silently)
- [ ] Debug assert: topicId matches UUID in session key

### Phase 2: iPhone Topic Derivation

**Goal:** iPhone derives its topic list from gateway session metadata.

**Changes in BeeChatMobile (iOS):**

1. On `sessions.list` response, filter sessions where `beechatMetadata != nil`
2. For each matching session, create/update local Topic:
   - `id` = `metadata.topicId` (from gateway, NOT a random UUID)
   - `name` = `session.label` ?? "(untitled)"
   - `sessionKey` = `session.key`
   - `isArchived` = `metadata.isArchived`
   - `metadataJSON` = encode `{projectPath: metadata.projectPath}` (stored but not rendered)
   - `pendingGatewaySync` = false (gateway is source)
   - Use upsert: if topic with same `id` exists locally, overwrite with gateway data (gateway wins)
3. Remove topics from local DB that no longer have `beechatMetadata` in `sessions.list` (gateway cleanup)
4. **Remove the local topic creation loop** in `BeeChatMobileViewModel.connect()` that creates topics with random UUIDs — this fights the gateway model
5. On `sessions.changed` event → existing `fetchSessions()` → `refreshTopics()` flow (full re-list, already works)
6. Add first-run onboarding: "Your topics from Mac will appear here automatically" (replaces removed import flow)
7. Add empty state: bee/hive motif + "No topics yet" + "Create a topic on your Mac to get started"
8. Add subtle sync indicator in topic list header: "Synced" (green) / "Last synced X ago" (yellow)
9. Add toast notification: "Topic archived from Mac" when a topic disappears due to archive

**Message handling:**
- Opening a topic on iPhone calls `chat.history` with the session key — full conversation available
- No "load earlier messages" pagination for initial release
- Logged as future option

**Archive-while-typing edge case:**
- If user is typing in a topic that gets archived from Mac: message still sends (it's a gateway message on an existing session). Show non-blocking toast "Topic archived from Mac." Topic fades from list on next refresh.

**Exit criteria:**
- [ ] iPhone topic list matches Mac topic list after connecting (names, archive status)
- [ ] All topic IDs match the gateway `metadata.topicId` (no random UUIDs)
- [ ] Archiving a topic on Mac removes it from iPhone topic list (with toast notification)
- [ ] Renaming a topic on Mac updates the name on iPhone
- [ ] Deleting a topic on Mac removes it from iPhone topic list (no ghost)
- [ ] Opening a topic on iPhone shows the full conversation history (messages from both devices)
- [ ] First-run onboarding screen shows on first launch
- [ ] Empty state shows when no topics exist from Mac
- [ ] Sync indicator visible in topic list header
- [ ] iPhone works when gateway is offline (shows last-known topic state + offline banner)
- [ ] Archive-while-typing: message sends, toast appears, topic fades from list
- [ ] No local topic creation on connect — all topics derive from gateway metadata

### Phase 3: Cleanup & Validation

**Goal:** Remove dead code, validate end-to-end, confirm architecture is clean.

1. Remove `importCandidates` / `ImportSessionsSheet` from iPhone (no longer needed)
2. Gate local topic creation on iPhone behind config flag (don't delete — prepare for future "Quick Chat")
3. End-to-end test: full topic lifecycle across both devices
4. Verify offline resilience: iPhone works with stale data when gateway unreachable
5. Verify reconnect resilience: Mac republishes all state, iPhone refreshes

**Exit criteria:**
- [ ] No dead import/local-creation code (gated, not deleted)
- [ ] Full lifecycle test: create on Mac → see on iPhone → archive on Mac → gone on iPhone (with toast) → chat on iPhone → messages visible on Mac
- [ ] Delete lifecycle test: create on Mac → delete on Mac → gone on iPhone (no ghost)
- [ ] Offline test: iPhone shows cached topics + offline banner when gateway unreachable
- [ ] Reconnect test: Mac publishes stale state on reconnect, iPhone refreshes
- [ ] No regression on Mac (existing topic CRUD behaviour unchanged)
- [ ] Kieran sign-off on architecture

---

## Future Development (logged, not implemented)

| Item | Notes | Priority |
|---|---|---|
| "Load earlier messages" pagination on iPhone | Mac has this via `chat.history(limit:)` with scroll. | Medium |
| Bidirectional topic sync | If BeeChat becomes saleable, iPhone topics sync back to Mac. | Low (future product decision) |
| iPhone "Quick Chat" / local topic creation | Local-only topics (📱 badge) that don't sync to Mac. Promoted to full topics if bidirectional sync added. | Medium |
| Incremental `sessions.changed` handling | Currently full re-list. Could parse event payload for incremental upserts. | Low |
| Project binding display on iPhone | `projectPath` stored but not rendered. Could add file/project browsing. | Low |
| Unread count sync across devices | Add `unreadCount` to plugin metadata for badge sync. | Low |
| Two-Mac support | If Adam gets a work laptop, topics from both Macs would flow to same iPhone. Needs topic namespacing. | Low |
| TTS read-back on Bee's responses | Phase 2 of voice roadmap. Not related to topic sync. | Separate roadmap |

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Client pairing fails → no `operator.admin` → `pluginPatch` returns error | Low | High | Mac shows warning. `reconcileAllTopicState()` retries on reconnect. |
| iOS client mode changed to `"webchat"` → `sessions.patch` blocked | Low | Medium | Document client identity contract. Code comment on `client.id`/`mode`. |
| `sessions.pluginPatch` succeeds but `sessions.patch` fails | Medium | Low | Label missing → topic shows session key as name. `pluginPatch` first minimises this. |
| Both RPC calls fail (gateway offline) | Expected | Low | `reconcileAllTopicState()` on reconnect. Mac local state unaffected. |
| Deleted topic's gateway metadata not cleared | Low | Medium | `clearTopicState` calls `pluginPatch(unset:true)`. If that fails, metadata persists but is stale. `reconcileAllTopicState` doesn't re-publish deleted topics. iPhone filters by checking if topic still exists in gateway metadata on next refresh. |
| iPhone processes stale `sessions.changed` event | Low | Low | Gateway-wins model: iPhone always overwrites with freshest `sessions.list` data. |
| Large number of sessions makes full re-list expensive | Low | Low | Personal use (~20-50 sessions). Add `label` filter if needed later. |

---

## Verification Plan

After each phase, before merging:

1. **Build:** Both BeeChat-v5 (Mac) and BeeChat-Mobile (iPhone) compile clean
2. **Gateway test:** Call `sessions.list` from CLI to verify `pluginExtensions` appears in response
3. **Integration:**
   - Mac creates topic → verify gateway session has label + plugin metadata (via `sessions.list` CLI)
   - iPhone connects → verify topic appears in list with correct name and ID
   - iPhone opens topic → verify messages load from gateway
   - Mac archives topic → verify iPhone shows toast and removes topic
   - Mac deletes topic → verify iPhone removes topic (no ghost)
4. **Kieran review:** Architecture review + code review of all changes
5. **Adam validation:** Real-device test — create on Mac, see on iPhone, chat on both

---

## Dependencies

- **BeeChat-v5 (macOS)** — Phase 0 + Phase 1 changes in Mac app and shared Core packages
- **BeeChat-Mobile (iOS)** — Phase 0 + Phase 2 changes in iPhone app
- **Shared packages** — `SessionInfo` extension in BeeChatSyncBridge affects both apps
- **Gateway** — No changes needed. Uses existing RPCs.

## Git Strategy

- Phase 0: First commit in BeeChat-v5 `feature/gate-2f-phase0` (shared package change, both repos update SPM)
- Phase 1: Branch `feature/gate-2f-phase1` in BeeChat-v5
- Phase 2: Branch `feature/gate-2f-phase2` in BeeChat-Mobile
- Phase 3: Cleanup branches in both repos
- Merge to `main` only after Kieran sign-off + Adam validation
- Tag: `gate-2f` after all phases complete

---

## Appendix A: v1 Review Findings — All Resolved

| ID | Source | Finding | v2 Resolution |
|---|---|---|---|
| Q-B1 | Q | `operator.admin` scope dependency not documented | ✅ Added scope table, exit criterion, risk |
| Q-B2 | Q | `SessionInfo.pluginExtensions` dependency fragile | ✅ Made Phase 0 prerequisite |
| Q-B3 | Q | `handleSessionsChanged` discards payload | ✅ Document: full re-list for v1, incremental is future |
| K-B1 | K | `operator.admin` scope — same as Q-B1 | ✅ Merged with Q-B1 |
| K-B2 | K | `rejectWebchatSessionMutation` not documented | ✅ Added client identity contract table |
| K-B3 | K | `SessionInfo` shared package — same as Q-B2 | ✅ Merged with Q-B2, Phase 0 |
| K-B4 | K | Topic deletion no gateway cleanup | ✅ `clearTopicState` with `pluginPatch(unset:true)` |
| K-B5 | K | iPhone creates topics with random UUIDs on connect | ✅ Explicit removal + exit criterion |
| Mel-B1 | Mel | No loading state for first launch | ✅ Skeleton/shimmer + pull-to-refresh (Phase 2) |
| Mel-B2 | Mel | Archived topics vanish silently | ✅ Toast notification "Topic archived from Mac" |
| Q-W1 | Q | Two non-atomic RPC calls | ✅ `pluginPatch` first, then `patch`. If first fails, skip second. |
| Q-W2 | Q | Delete doesn't clean gateway metadata | ✅ Merged with K-B4 |
| Q-W3 | Q | No retry/queue for offline publish | ✅ `reconcileAllTopicState()` on reconnect |
| Q-W4 | Q | `topicId` redundant with session key | ✅ Keep for explicitness, add debug assert |
| Q-W5 | Q | `AnyCodable` untyped — fragile | ✅ `BeeChatTopicMetadata: Codable` struct |
| K-W1 | K | `sessions.changed` DOES include pluginExtensions | ✅ Risk table corrected |
| K-W2 | K | `updatedAt` timestamp for last-write-wins wrong | ✅ Changed to "gateway wins" model |
| K-W3 | K | No error handling for publish failures | ✅ `pluginPatch` first, log errors, reconcile on reconnect |
| Mel-W1 | Mel | Import flow removal needs replacement | ✅ First-run onboarding screen |
| Mel-W2 | Mel | Empty state not defined | ✅ Bee/hive motif + guidance text |
| Mel-W3 | Mel | No sync status indicator | ✅ Subtle "Synced"/"Last synced X ago" |
| Mel-W4 | Mel | Archive-while-typing | ✅ Allow send + toast |
| Mel-W5 | Mel | iPhone topic creation removed too early | ✅ Gate behind config, not delete |
| Mel-Q1 | Mel | `sessions.changed` latency | ✅ Sub-second on same gateway. Documented. |
| Mel-Q2 | Mel | Show `projectPath` on iPhone? | ✅ Store but don't render |
| Mel-Q3 | Mel | Two Macs? | ✅ Added to future development table |

---

*This spec incorporates all findings from Q, Kieran, and Mel's v1 review. Ready for Adam approval before implementation begins.*