# Gate 2F: Cross-Device Topic Sync — Spec v1

**Date:** 2026-05-22
**Author:** Bee (Coordinator)
**Status:** 📋 DRAFT — Pending team review (Q, Kieran, Mel)

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
7. **"Load earlier messages" pagination** — dropped for iPhone initial release. Log as future development option.

## Architecture

### Core insight

The gateway already has everything we need. Topics are just sessions with metadata. We use:

- **`sessions.patch`** — set `label` (topic name) on a session
- **`sessions.pluginPatch`** — store arbitrary JSON metadata per-session (`isArchived`, `projectPath`, `topicId`)
- **`sessions.list`** — returns all sessions with labels (already called by both apps on connect)
- **`sessions.subscribe` + `sessions.changed`** — gateway already broadcasts metadata changes to all connected clients
- **`chat.history`** — messages are shared automatically because both devices use the same session key

### Data flow

```
Mac creates/renames/archives a topic
  → Mac calls sessions.patch (label) + sessions.pluginPatch (metadata)
  → Gateway stores metadata on the session
  → Gateway broadcasts sessions.changed event
  → iPhone receives event → updates local topic state

iPhone connects / reconnects
  → iPhone calls sessions.list (already does this)
  → iPhone derives topics from sessions that have topic metadata
  → Full conversation history available via chat.history
```

### What gets stored on the gateway

For each session that has a BeeChat topic, we store:

| Field | Source | Via |
|---|---|---|
| `label` | Topic name | `sessions.patch` |
| `pluginExtensions.beechat.metadata.isArchived` | Bool | `sessions.pluginPatch` |
| `pluginExtensions.beechat.metadata.projectPath` | String? | `sessions.pluginPatch` |
| `pluginExtensions.beechat.metadata.topicId` | String | `sessions.pluginPatch` |
| `pluginExtensions.beechat.metadata.updatedAt` | ISO 8601 | `sessions.pluginPatch` |

**Namespace:** `pluginId: "beechat"`, `namespace: "metadata"`

### What the iPhone derives from sessions.list

When iPhone receives sessions from `sessions.list`, it filters for sessions that have `pluginExtensions.beechat.metadata.topicId`. These are the topics. For each:

- `label` → Topic name
- `metadata.topicId` → Topic ID (local DB primary key)
- `metadata.isArchived` → Archive status
- `metadata.projectPath` → Project binding (for display, not functional on iOS yet)
- Session key → maps to gateway conversation (messages shared with Mac)

### Message sharing

Messages need **no sync mechanism** beyond what already exists:

1. Both devices use the same `sessionKey` for the same topic
2. Gateway stores all messages for that session
3. `chat.history` returns messages regardless of which device sent them
4. Real-time `chat` events stream to whichever device is connected

**This means:** If you chat on Mac, then pick up iPhone and open the same topic, you see the full conversation. No extra work.

---

## Phased Build Plan

### Phase 1: Gateway RPC Wrappers (Mac-side publishing)

**Goal:** Mac publishes topic state to gateway on every CRUD operation.

**Changes in BeeChat-v5 (macOS):**

1. Add `sessionsPatch(key:label:)` to `RPCClientProtocol` + `RPCClient`
2. Add `sessionsPluginPatch(key:pluginId:namespace:value:)` to `RPCClientProtocol` + `RPCClient`
3. Add `publishTopicState(topic:sessionKey:)` convenience method on SyncBridge
   - Calls `sessions.patch` with `label`
   - Calls `sessions.pluginPatch` with metadata JSON
4. Hook into existing topic CRUD operations:
   - `TopicRepository.create()` → `publishTopicState` (after local save)
   - `TopicRepository.archive()` → `publishTopicState`
   - `TopicRepository.save()` → `publishTopicState` (on rename/edit)
   - `TopicRepository.deleteCascading()` → clear plugin metadata or let session deletion handle it

**Changes in BeeChatPersistence (shared):**

5. Extend `SessionInfo` to decode `pluginExtensions` from `sessions.list` response
   - New optional field: `pluginExtensions: [String: [String: AnyCodable]]?`
   - Backwards compatible — nil if not present

**Exit criteria:**
- [ ] `sessionsPatch` RPC wrapper works (can set label on a session)
- [ ] `sessionsPluginPatch` RPC wrapper works (can store JSON metadata on a session)
- [ ] Creating a topic on Mac publishes label + metadata to gateway
- [ ] Archiving a topic on Mac publishes updated metadata to gateway
- [ ] `SessionInfo` decodes `pluginExtensions` from sessions.list response
- [ ] No regression on Mac — existing topic CRUD still works when gateway is offline (publish is fire-and-forget, not blocking)

### Phase 2: iPhone Topic Derivation

**Goal:** iPhone derives its topic list from gateway session metadata instead of local-only state.

**Changes in BeeChatMobile (iOS):**

1. On `sessions.list` response, filter sessions with `pluginExtensions.beechat.metadata.topicId`
2. For each matching session, create/update local Topic:
   - `id` = `metadata.topicId`
   - `name` = `session.label`
   - `sessionKey` = `session.key`
   - `isArchived` = `metadata.isArchived ?? false`
   - `metadataJSON` = encode `{projectPath: metadata.projectPath}`
   - `pendingGatewaySync` = false (gateway is source)
3. On `sessions.changed` event, if the changed session has topic metadata → upsert local topic
4. Remove or deprecate: `importCandidates` / `importSelected` flow (no longer needed — topics come from gateway automatically)
5. Remove or deprecate: local-only topic creation on iPhone (topics come from Mac via gateway)

**Message handling:**
- Opening a topic on iPhone calls `chat.history` with the session key — full conversation available
- No "load earlier messages" pagination for initial release
- Log as future option: pagination for long conversations

**Exit criteria:**
- [ ] iPhone topic list matches Mac topic list after connecting
- [ ] Archiving a topic on Mac removes it from iPhone topic list
- [ ] Renaming a topic on Mac updates the name on iPhone
- [ ] Opening a topic on iPhone shows the full conversation history
- [ ] Messages sent on Mac are visible on iPhone and vice versa
- [ ] iPhone works when gateway is offline (shows last-known topic state)
- [ ] `sessions.changed` events update individual topics without full refresh

### Phase 3: Cleanup & Validation

**Goal:** Remove dead code, validate end-to-end, confirm the architecture is clean.

1. Remove `importCandidates` / `ImportSessionsSheet` from iPhone (no longer needed)
2. Remove `pendingGatewaySync` flag handling from iPhone (gateway is source, not local)
3. Remove local-only topic creation from iPhone ViewModel (or gate it behind a config flag for future)
4. End-to-end test: full topic lifecycle across both devices
5. Verify offline resilience: iPhone works with stale data when gateway is unreachable

**Exit criteria:**
- [ ] No dead import/local-creation code on iPhone
- [ ] Full lifecycle test: create on Mac → see on iPhone → archive on Mac → gone on iPhone → chat on iPhone → messages visible on Mac
- [ ] iPhone handles gateway offline gracefully (cached topics + offline banner)
- [ ] No regression on Mac (existing behaviour unchanged)
- [ ] Kieran sign-off on architecture

---

## Future Development (logged, not implemented)

| Item | Notes |
|---|---|
| "Load earlier messages" pagination on iPhone | Mac has this via `chat.history(limit:)` with scroll. iPhone can add later. |
| Bidirectional topic sync | Currently Mac-only master. If BeeChat becomes a saleable app, iPhone-created topics could sync back. |
| Topic creation on iPhone | Currently deferred. Could add "create on iPhone → sync to gateway → Mac sees it" later. |
| Project binding on iPhone | `projectPath` stored but not functional on iOS. Could add file browsing later. |
| Unread count sync | Could add `unreadCount` to plugin metadata for badge sync across devices. |

---

## Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `sessions.pluginPatch` unavailable or rate-limited | Low — confirmed in gateway source | Fall back to `sessions.patch` label-only (names sync, archive status doesn't) |
| Mac offline when iPhone connects | Expected — normal usage | iPhone shows last-known topic state, updates on reconnect |
| `sessions.changed` event doesn't include pluginExtensions | Medium — need to verify | If not, iPhone does periodic `sessions.list` refresh (every 60s) as fallback |
| `pluginExtensions` not returned by `sessions.list` | Low — field exists on SessionEntry | Verify with live gateway test before Phase 2 |
| Race condition: Mac publishes while iPhone is reading | Low — one-device-at-a-time usage | Last-write-wins by `updatedAt` timestamp in metadata |
| Large number of sessions makes `sessions.list` expensive | Low — personal use, ~20-50 sessions | Filter on `label` or `pluginExtensions` if needed later |

---

## Verification Plan

After each phase, before merging:

1. **Build:** Both BeeChat-v5 (Mac) and BeeChat-Mobile (iPhone) compile clean
2. **Unit:** New RPC wrappers tested with mock gateway responses
3. **Integration:** 
   - Mac creates topic → verify gateway session has label + plugin metadata
   - iPhone connects → verify topic appears in list
   - iPhone opens topic → verify messages load from gateway
4. **Kieran review:** Architecture review + code review of all changes
5. **Adam validation:** Real-device test — create on Mac, see on iPhone, chat on both

---

## Dependencies

- **BeeChat-v5 (macOS)** — Phase 1 changes are in the Mac app and shared Core packages
- **BeeChat-Mobile (iOS)** — Phase 2 changes are in the iPhone app
- **Shared packages** — `SessionInfo` extension in BeeChatPersistence affects both apps
- **Gateway** — No changes needed. Uses existing `sessions.patch`, `sessions.pluginPatch`, `sessions.list`, `sessions.subscribe`

## Git Strategy

- Phase 1: Branch `feature/gate-2f-phase1` off `main` in BeeChat-v5
- Phase 2: Branch `feature/gate-2f-phase2` off `main` in BeeChat-Mobile  
- Phase 3: Cleanup branches in both repos
- Merge to `main` only after Kieran sign-off + Adam validation
- Tag: `gate-2f` after all phases complete

---

*This spec is a draft. All blockers and concerns from team review will be tracked and resolved before implementation begins.*