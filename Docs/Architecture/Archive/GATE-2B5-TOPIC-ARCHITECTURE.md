# Gate 2B.5: Topic Architecture Specification

**Date:** 2026-05-18
**Status:** REVISED — Team review complete, incorporating Kieran (adversarial) and Mel (UX) feedback
**Author:** Bee (Coordinator)
**Reviewers:** Kieran (Adversarial) ✅, Mel (UX) ✅, Gav (Research) — pending, Q (Builder) — pending
**Blocks:** Gate 2C (send/receive) cannot proceed without this

### Review Log

#### Kieran (Adversarial) — ✅ Complete
- **B1:** `BeeChatSessionFilter.isBeeChatSession()` creates new `TopicRepository()` per call — will deadlock on iOS @MainActor. **Fix:** Inject ViewModel's existing repo instance.
- **B2:** `sessionKey: nil` pattern is fragile — macOS generates gateway-format key upfront. **Fix:** Create topics with `sessionKey = "agent:main:\(topicId.lowercased())"` immediately.
- **B3:** Bare UUID fallback in send flow has no `agent:main:` prefix. **Fix:** Eliminated by B2 fix — no nil session keys.
- **B4:** First launch after 2B→2B.5 upgrade loses all existing seed data from UI. **Fix:** Migration step to convert Session entries to Topic entries.
- **W1:** 500ms polling loop is wasteful — replace with GRDB `ValueObservation`.
- **W2:** Topic ordering should be explicit decision: last-activity descending for mobile.
- **W3:** Bridge table cleanup strategy needed for stale entries.
- **W5:** `MessageMapper` needs updating for Topic model.
- **W8:** Seed data should be in one transaction.

#### Mel (UX) — ✅ Complete
- **Must-have:** Compact sheet for iPhone new topic creation, popover on iPad.
- **Must-have:** No fake "Start" bootstrap message — generate key upfront (Kieran B2).
- **Must-have:** Distinguish fresh install from "existing sessions hidden" — add secondary import path.
- **Must-have:** Swipe actions for archive (default) + delete (destructive, confirmation, cascade warning).
- **Must-have:** Error states — disconnected topic visible with disabled composer, bridge failure preserves draft.
- **Must-have:** Raw session keys never in normal UI, only in debug/diagnostics.
- **Correction:** macOS uses `lastActivityAt DESC` (chronological), not alphabetical. iOS should follow.
- **Should-have:** Rename from context menu, suggest name after first message.

---

## 1. Problem Statement

The iOS app currently displays **raw gateway sessions** in the sidebar. This is wrong for a user-facing chat app. The `sessions.list` API returns every OpenClaw session — cron jobs, sub-agent runs, agent background sessions, and the current webchat — all dumped into one flat list labelled "Topics."

BeeChat macOS solved this exact problem with a **Topic layer** that sits between the user and the gateway. The iOS app must adopt the same architecture.

### What users see now (broken)

| Raw session key | What it actually is |
|---|---|
| `agent:main:cron:b4dd24c3...` | Solar Widget cron job |
| `agent:main:2c5db042...` | This webchat session |
| `agent:luna:main` | Luna's background session |
| `agent:kieran:main` | Kieran's background session |
| `agent:q:main` | Q's background session |
| `agent:main:cron:dff66626...` | Email Monitor cron job |
| `agent:main:main` | Bee's main session (iMessage) |

None of these should appear as "Topics" in a chat app.

### What users should see (correct)

| Topic name | Mapped session key | Created by |
|---|---|---|
| "Project Alpha Discussion" | `agent:main:a1b2c3d4...` | User created |
| "Weekly Review" | `agent:main:e5f6g7h8...` | User created |
| (empty) | — | "No conversations yet" empty state |

**Topics are user-created conversations. Sessions are an implementation detail.** The sidebar shows Topics. The user never sees raw session keys.

---

## 2. How BeeChat macOS Solves This

The v5 macOS app has a complete Topic architecture that the iOS app must adopt. It already exists in the shared `BeeChatPersistence` package:

### 2.1 Data Model (already in v5)

```
┌──────────────────┐        ┌────────────────────────────┐
│     Topic        │        │    TopicSessionBridge       │
├──────────────────┤        ├────────────────────────────┤
│ id: String       │◄───────┤ topicId: String (PK)       │
│ name: String     │        │ spaceId: String (default)  │
│ sessionKey: String?───────┤ openclawSessionKey: String  │
│ lastMessagePreview│      │ status: String (active)     │
│ lastActivityAt   │        │ bridgeVersion: Int          │
│ unreadCount: Int │        │ lastSyncAt: Date?           │
│ isArchived: Bool │        └────────────────────────────┘
│ messageCount: Int│
│ metadataJSON: String?    Key relationship:
│ createdAt: Date  │        Topic.sessionKey → direct link
│ updatedAt: Date  │        TopicSessionBridge → fallback link
└──────────────────┘
```

**Two-level lookup:**
1. `Topic.sessionKey` — direct link (fast path)
2. `TopicSessionBridge` — bridge table (reliable fallback, handles key format differences)

### 2.2 Session Key Resolution (already in v5)

`TopicRepository.resolveSessionKey(topicId:)` tries direct lookup first, then falls back to the bridge table.

`TopicRepository.resolveTopicId(for: sessionKey:)` does the reverse — given a gateway session key, find the local topic.

`SessionKeyNormalizer.stripPrefix("agent:main:xyz")` → `"xyz"` handles the gateway key format.

`BeeChatSessionFilter.isBeeChatSession(sessionKey)` returns `true` only if the session maps to a known topic.

### 2.3 New Topic Creation Flow (macOS)

1. User taps "New Topic" and enters a name
2. `Topic(name: "Project Alpha")` is saved to local DB with `sessionKey: nil`
3. User sends first message → `SyncBridge.sendMessage(sessionKey:, text:)` creates a gateway session
4. Gateway responds with the session key → `topicRepo.updateSessionKey(topicId:, sessionKey:)` links them
5. `topicRepo.saveBridge(topicId:, sessionKey:)` creates the bridge entry for future lookups

### 2.4 Session Filtering (macOS)

When `sessions.changed` fires or `sessions.list` returns data, `BeeChatSessionFilter.isBeeChatSession()` filters out:
- Cron jobs (`agent:*:cron:*`)
- Agent background sessions (`agent:luna:main`, `agent:q:main`, etc.)
- Sub-agent runs
- Any session not linked to a user-created Topic

Only sessions that map to Topics appear in the sidebar.

---

## 3. What iOS Needs

### 3.1 Already Available (in shared v5 packages)

All of the following exist in `BeeChatPersistence` and are already linked by the iOS app:

| Component | Status | Package |
|---|---|---|
| `Topic` model | ✅ Available | BeeChatPersistence |
| `TopicRepository` | ✅ Available | BeeChatPersistence |
| `TopicSessionBridge` model | ✅ Available | BeeChatPersistence |
| `BeeChatSessionFilter` | ✅ Available | BeeChatSyncBridge |
| `SessionKeyNormalizer` | ✅ Available | BeeChatSyncBridge |
| GRDB Migration005 (topics table) | ✅ Available | BeeChatPersistence |
| GRDB Migration006 (messages table) | ✅ Available | BeeChatPersistence |
| GRDB Migration007 (messageCount trigger) | ✅ Available | BeeChatPersistence |

**No new v5 code needed.** The iOS app just needs to USE these instead of raw sessions.

### 3.2 Changes Required in iOS Code

#### 3.2.1 ViewModel: Replace `sessions` with `topics`

**Current (broken):**
```swift
public var topics: [Session] = []  // Actually raw sessions, misnamed

// In start():
self.topics = try persistenceStore.fetchSessions(limit: 100, offset: 0)

// In connect():
let sessions = try await bridge.fetchSessions()
self.topics = sessions
```

**Required:**
```swift
public var topics: [Topic] = []  // Actual Topic objects from local DB

// In start():
self.topics = try topicRepo.fetchAllActive()

// In connect():
// 1. Fetch sessions from gateway
// 2. Filter: only keep sessions that map to known topics
// 3. Sync new messages for known topics
// 4. Update topic list from local DB (not from gateway)
```

#### 3.2.2 ViewModel: Add TopicRepository (injected, not per-call)

**Current:**
```swift
public let persistenceStore: BeeChatPersistenceStore
```

**Required:**
```swift
public let persistenceStore: BeeChatPersistenceStore
public let topicRepo: TopicRepository  // NEW — injected, shared instance
```

The `TopicRepository` is already in `BeeChatPersistence` — it just needs to be instantiated with the same `DatabaseManager`. **Critical (Kieran B1):** Do NOT create fresh `TopicRepository()` instances per filter call. The ViewModel's `topicRepo` instance must be injected into `BeeChatSessionFilter` calls, replacing the static-method-with-fresh-repo pattern.

#### 3.2.3 ViewModel: New Topic Creation (gateway key upfront)

**Required new method:**
```swift
/// Create a new topic. Gateway-format session key is generated immediately.
/// Follows macOS pattern: sessionKey = "agent:main:\(topicId.lowercased())"
public func createTopic(name: String) throws -> Topic {
    let topicId = UUID().uuidString
    let gatewayKey = "agent:main:\(topicId.lowercased())"
    let topic = Topic(id: topicId, name: name, sessionKey: gatewayKey)
    try topicRepo.save(topic)
    try topicRepo.saveBridge(topicId: topicId, sessionKey: gatewayKey)
    self.topics = try topicRepo.fetchAllActive()
    return topic
}
```

**Kieran B2/B3 fix:** The original spec proposed `sessionKey: nil` and resolving on first message send. This is fragile — the gateway expects `agent:main:<id>` format, and a nil session key means messages can't be routed. The macOS app generates the gateway-format key upfront (`agent:main:\(topicId.lowercased())`) and never has a nil session key. iOS must follow the same pattern.

**No resolve-on-response needed:** Because the session key is generated upfront in gateway format, the bridge entry is created immediately, and there's no window where the topic has no session key.

#### 3.2.4 ViewModel: Session Filtering on Connect (with migration)

**Current (broken):**
```swift
let sessions = try await bridge.fetchSessions()
self.topics = sessions  // Raw sessions — WRONG
```

**Required:**
```swift
// Step 1: Migrate existing Session entries to Topic entries (Kieran B4)
migrateSessionsToTopics()

// Step 2: Fetch sessions from gateway
let sessions = try await bridge.fetchSessions()

// Step 3: Update topic metadata from matching sessions
for session in sessions {
    if let topicId = try? topicRepo.resolveTopicId(for: session.id) {
        // Update lastMessagePreview, unreadCount, lastActivityAt from session data
        // (future: use ValueObservation for live updates)
    }
}

// Step 4: Refresh topic list from local DB (not from gateway)
self.topics = try topicRepo.fetchAllActive()
```

**Migration step (Kieran B4):** On first launch after the Gate 2B → 2B.5 update, existing `Session` entries in the DB have no corresponding `Topic` entries. The migration converts them:
```swift
private func migrateSessionsToTopics() {
    // Check if migration is needed
    let existingTopics = try? topicRepo.fetchAllActive()
    if let topics = existingTopics, !topics.isEmpty { return } // Already migrated
    
    // Convert all existing sessions to topics
    let sessions = try persistenceStore.fetchSessions(limit: 100, offset: 0)
    for session in sessions {
        let gatewayKey = "agent:main:\(session.id.lowercased())"
        let topic = Topic(
            id: session.id,
            name: session.title ?? session.customName ?? session.id,
            sessionKey: gatewayKey,
            lastMessagePreview: session.lastMessagePreview,
            lastActivityAt: session.lastMessageAt ?? session.updatedAt,
            messageCount: session.messageCount
        )
        try? topicRepo.save(topic)
        try? topicRepo.saveBridge(topicId: topic.id, sessionKey: gatewayKey)
    }
}
```

**Kieran B1 fix:** `BeeChatSessionFilter.isBeeChatSession()` must use the ViewModel's injected `topicRepo` instance, not create a fresh one per call. The static method pattern is fine for macOS (rare, background) but causes MainActor blocking on iOS.

#### 3.2.5 TopicListView: Add "New Topic" Button (Mel UX)

**Current:** Just a list of sessions.

**Required:**
- Toolbar button (`+`) to create new topic
- **iPhone:** Compact sheet with text field "What would you like to talk about?" and Create/Cancel buttons
- **iPad:** Popover anchored from the `+` button, preserving split-view context
- After creation, auto-select the new topic and navigate to chat view
- Show "No conversations yet" empty state with prominent "Start a conversation" button when topics list is empty
- **Secondary path (if legacy sessions exist):** Offer "Import recent sessions" below the main CTA

**Swipe actions (Mel must-have):**
- Archive: default/non-destructive swipe action
- Delete: destructive swipe with confirmation alert ("This will permanently delete this conversation and all its messages.")

#### 3.2.6 BeeChatView: Message sending uses topic-resolved session key

**Current:**
```swift
try await bridge.sendMessage(sessionKey: sessionId, text: text)
```

**Required:**
```swift
// Resolve the topic's session key — always populated (Kieran B2/B3 fix)
guard let topicId = selectedTopicId,
      let topic = topics.first(where: { $0.id == topicId }) else { return }
let sessionKey = topic.sessionKey  // Always "agent:main:<id>" format

// Send message
_ = try await bridge.sendMessage(sessionKey: sessionKey, text: text)
```

No fallback to bare UUID needed — topics are created with gateway-format keys upfront.

---

## 4. Impact on Existing Gates

### 4.1 Gate 2B (Current — Connection)

**Changes required:**

| Item | Change | Risk |
|---|---|---|
| ViewModel.topics type | `[Session]` → `[Topic]` | Low — Topic model is already in v5 |
| ViewModel init | Add `TopicRepository` | Low — same DBManager |
| Session list → Topic list | Use `topicRepo.fetchAllActive()` instead of `fetchSessions()` | Low — already tested in macOS |
| New Topic creation | New method + UI button | Medium — new flow, but pattern exists in macOS |
| Session filtering | Use `BeeChatSessionFilter.isBeeChatSession()` | Low — already in v5 |
| TopicListView | Add "+" button, empty state | Medium — new UI, but straightforward SwiftUI |

**Gate 2B remains largely the same** — the connection, auth, and streaming work is done. The Topic layer is additive on top of the working connection.

### 4.2 Gate 2C (Send/Receive)

**Changes required:**

| Item | Change | Risk |
|---|---|---|
| Send message | Use topic-resolved session key, not raw session ID | Medium — needs bridge update on first send |
| First message in new topic | Create gateway session + bridge entry | Medium — new flow |
| `sendMessage` response | Update topic's session key if gateway created one | Low — pattern exists in macOS |

**Gate 2C becomes cleaner** with Topics — messages are always associated with a topic, not an abstract session key.

### 4.3 Gate 2D (Reconnect)

**No changes required.** SyncBridge handles reconciliation. Topic metadata is local. The bridge table survives disconnects. Reconnection logic is unchanged.

### 4.4 Gate 3 (Mobile UX Shell)

**Topic architecture is essential for Gate 3.** Navigation, session switching, and the sidebar all need Topics, not raw sessions. This gate was already blocked without it.

---

## 5. Design Decisions for Review

### D1: Should iOS create topics exactly like macOS?

**Proposal:** Yes. Use the same `Topic(name:)` model, `TopicRepository`, and `TopicSessionBridge`. The data model, migrations, and repository code already exist in the shared v5 packages.

**Alternative:** Create an iOS-specific simplified topic model. **Rejected** — this would duplicate code and create divergence.

**Kieran question:** Are there edge cases in the macOS topic flow that iOS should handle differently? (e.g., session key normalization, bridge table staleness, orphaned topics)

### D2: Should the sidebar show only user-created topics, or also auto-discover sessions?

**Proposal:** Only user-created topics. Auto-discovery (showing existing gateway sessions as topics) was explored in macOS and abandoned — it creates noise and confuses users. The "New Topic" flow is simple and clean.

**Alternative:** Auto-discover existing webchat sessions and offer them as topics. **Considered but risky** — this would show cron jobs, agent sessions, etc. without careful filtering.

**Mel question:** What should the empty state look like? What's the UX for "New Topic"?

### D3: How should the first message in a new topic create the gateway session?

**Proposal:** Follow the macOS pattern:
1. User creates topic with name → stored locally with `sessionKey: nil`
2. User sends first message → `SyncBridge.sendMessage(sessionKey: topicId, text:)` — the topic ID serves as the initial session key
3. Gateway creates the session and may return a different key (`agent:main:<uuid>`)
4. On first response, update `topic.sessionKey` and create bridge entry

**Risk:** What if the gateway returns a different key format? The `SessionKeyNormalizer` and `TopicRepository.resolveTopicIdBySuffix()` handle this.

**Kieran question:** Is the session key normalization logic robust enough for the mobile case? Any edge cases with `agent:main:topicId` vs `agent:main:uuid`?

### D4: Should we filter sessions before storing, or store all and filter on display?

**Proposal:** Store all sessions from `sessions.list` in the local DB (for message history, delivery tracking). Filter only on display — the sidebar shows `TopicRepository.fetchAllActive()`, not raw sessions.

**Rationale:** Raw sessions are still needed for:
- Message history lookup (`messages` table uses `sessionId`)
- Delivery ledger tracking
- Reconciliation after reconnect

But the **sidebar only shows Topics**. This is the macOS pattern and it works well.

### D5: Should the iOS app seed test data as Topics?

**Proposal:** Yes, for Gate 2B.5 verification. Replace the current `seedTestData()` with:
```swift
// Create a test topic with a session
let testTopic = Topic(name: "Welcome to BeeChat", sessionKey: "seed-session-1")
try topicRepo.save(testTopic)
try topicRepo.saveBridge(topicId: testTopic.id, sessionKey: "seed-session-1")

// Create the session and messages as before
let session = Session(id: "seed-session-1", ...)
try persistenceStore.saveSession(session)
// ... messages ...
```

**After Gate 2B.5:** Remove seed data. The app should start with an empty "No conversations yet" state, and users create topics by tapping "+".

### D6: How does the "New Topic" flow work on mobile?

**Proposal:**

1. User taps "+" in toolbar
2. A sheet appears with a text field: "What would you like to talk about?"
3. User enters a name (e.g., "Project Alpha Discussion")
4. Topic is created locally with `sessionKey: nil`
5. Auto-select the new topic
6. Navigate to chat view
7. User types first message → creates gateway session → bridges topic

**Mel question:** Should this be a sheet, inline, or full-screen creation? What about topic naming suggestions?

### D7: What happens to existing sessions on first launch?

**Proposal:** On first launch after this update, the app will have no topics in the DB. The existing sessions from the gateway will be fetched, but since no topics reference them, they won't appear in the sidebar. The user sees an empty "No conversations yet" state and creates new topics.

**Alternative:** Offer a migration that creates topics from existing webchat sessions. **Considered but complex** — which sessions should become topics? Only `webchat` sessions? Only sessions with messages? This needs UX input.

**Mel question:** What's the right first-launch experience? Empty state with a prominent "Start a conversation" button? Or should we offer to import recent sessions?

---

## 6. Exit Criteria for Gate 2B.5

| # | Criterion | Validation |
|---|---|---|
| 1 | `TopicRepository` and `TopicSessionBridge` are used in ViewModel (not raw sessions) | Code review |
| 2 | Sidebar shows only user-created Topics (not raw sessions) | Manual: verify no cron/agent sessions appears |
| 3 | "New Topic" button in toolbar with name entry sheet | Manual: create a topic, verify it appears in sidebar |
| 4 | First message in new topic creates gateway session + bridge | Manual: send message in new topic, verify session key links |
| 5 | `sessions.changed` updates topic metadata (unreadCount, lastMessagePreview) | Manual: receive message, verify topic updates |
| 6 | Session filtering works: only sessions mapped to topics appear | Manual: verify cron/agent sessions are hidden |
| 7 | Empty state shows "No conversations yet" with "Start a conversation" button | Manual: fresh install, no topics |
| 8 | BeeChat macOS continues to work (no regression in v5) | Manual: verify macOS app still connects and shows topics |
| 9 | Seed data uses Topic model (not raw Session) | Code review |
| 10 | Kieran sign-off on adversarial review | Review |

---

## 7. Implementation Plan

### Phase 1: ViewModel Changes (Q)

1. Add `TopicRepository` to ViewModel
2. Change `topics: [Session]` → `topics: [Topic]`
3. Replace `fetchSessions()` with `topicRepo.fetchAllActive()`
4. Add `createTopic(name:)` method
5. Add session filtering on connect (use `BeeChatSessionFilter`)
6. Update message send to resolve topic → session key
7. Update session key after first message in new topic

### Phase 2: UI Changes (Q, guided by Mel)

1. Add "+" toolbar button in TopicListView
2. Create `NewTopicSheet.swift` (name entry, create button)
3. Create `EmptyTopicsView.swift` (centered "No conversations yet" + button)
4. Update `TopicRow` to use `Topic` model instead of `Session`
5. Update `BeeChatView` to use topic-resolved session key

### Phase 3: Testing (Bee validates, Adam approves)

1. Create topic → appears in sidebar
2. Send message in new topic → gateway session created, bridge entry created
3. Receive message → topic metadata updates
4. Verify no cron/agent sessions appear
5. Verify macOS BeeChat still works
6. Verify reconnection still works after Topic layer

---

## 8. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Topic ↔ Session bridge fails to create on first message | Medium — topic shows but messages don't appear | Low — pattern proven in macOS | Use `TopicSessionBridge` with fallback lookup via `resolveTopicIdBySuffix` |
| Session key format mismatch between iOS and macOS | Low — both use same `SessionKeyNormalizer` | Very low | Normalizer handles `agent:main:` prefix stripping and case-insensitive matching |
| GRDB migration 005/006/007 not running on iOS | High — topics table doesn't exist | Very low — migrations are already in v5 and run automatically | Verify in simulator: check `beechat.sqlite` schema after launch |
| Empty state UX confuses users | Medium — "where are my conversations?" | Medium | Mel review of empty state design; clear "Start a conversation" CTA |
| Divergence between macOS and iOS topic handling | Medium — different bugs in each | Low — shared v5 code | Both apps use `TopicRepository`, `BeeChatSessionFilter`, `SessionKeyNormalizer` |
| New topic creation feels slow (gateway round-trip) | Low — topic appears immediately, only session creation is async | Low | Optimistic local creation, session key update on response |

---

## 9. Questions for Team Review

### Kieran (Adversarial Reviewer)
1. Are there edge cases in the macOS topic flow that iOS should handle differently?
2. Is `SessionKeyNormalizer.resolveTopicIdBySuffix()` robust enough for mobile?
3. What happens if a user creates a topic, sends a message, but the gateway is offline? How should we handle the `sessionKey: nil` → gateway key transition on reconnect?
4. Should `BeeChatSessionFilter.isBeeChatSession()` also filter out the iOS device's own pairing session?

### Mel (Designer)
1. What should the "New Topic" sheet look like on iPhone? On iPad?
2. What's the right empty state? "No conversations yet" with a prominent button? Or a more guided onboarding?
3. Should we auto-suggest topic names based on context (time of day, recent activity)?
4. Topic list ordering: alphabetical by name (like macOS) or chronological by last activity?

### Gav (Researcher)
1. Are there any iOS-specific GRDB migration issues with the Topic/TopicSessionBridge tables?
2. Does `ValueObservation` work correctly for Topic queries on iOS (since macOS uses it for live sidebar updates)?
3. Any concerns about Keychain storage for topic-level metadata (unread counts, last activity)?

### Q (Builder)
1. Is the ViewModel change from `[Session]` to `[Topic]` straightforward, or are there hidden dependencies on the `Session` model in the UI layer?
2. The current `TopicRow` view uses `Session` properties (`.title`, `.customName`, `.lastMessageAt`). The `Topic` model has `.name`, `.lastMessagePreview`, `.lastActivityAt`. Is the property mapping clean?
3. How should `sendMessage` handle the topic → session key resolution when `sessionKey` is nil (new topic, first message)?

---

## 10. Relation to Existing Spec

This spec is **inserted between Gate 2B and Gate 2C** as **Gate 2B.5**. It does not replace or invalidate any existing Gate 2 spec content. The changes are additive:

- **Gate 2B** (connection) is complete and working — no changes needed
- **Gate 2B.5** (topic architecture) adds the Topic layer on top of the working connection
- **Gate 2C** (send/receive) proceeds on top of Gate 2B.5, using topic-resolved session keys

The original Gate 2 spec Section 4.2 (Gate 2B) and Section 4.3 (Gate 2C) are still valid. This spec adds:
- A new gate (2B.5) between them
- Updated ViewModel code examples that use `Topic` instead of `Session`
- Updated UI requirements (New Topic flow, empty state, filtering)

After this spec is approved and implemented, Gate 2C will use topic-resolved session keys for `sendMessage`, and the sidebar will show Topics instead of raw sessions.

---

## 11. Approval

| Role | Agent | Status |
|---|---|---|
| Coordinator | Bee | ✅ Drafted |
| Adversarial Reviewer | Kieran | ⏳ Pending |
| Designer | Mel | ⏳ Pending |
| Researcher | Gav | ⏳ Pending |
| Builder | Q | ⏳ Pending |
| Approver | Adam | ⏳ Pending |

No implementation begins until all five reviewers have signed off and Adam has approved.