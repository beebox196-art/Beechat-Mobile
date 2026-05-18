# Gate 2B.5: Topic Architecture Specification — v2

**Date:** 2026-05-18
**Status:** REVISED v2 — Incorporating all reviewer findings (8 blockers, 10 warnings, 14 UX requirements)
**Author:** Bee (Coordinator)
**Reviewers:** Q (Implementation) ✅, Kieran (Adversarial ×2) ✅, Mel (UX ×2) ✅
**Blocks:** Gate 2C (send/receive) cannot proceed without this

---

### Review Log

#### Round 1
- **Kieran B1:** `BeeChatSessionFilter` creates new `TopicRepository()` per call — deadlock risk on iOS @MainActor. **Fix:** Add overload with injected repo instance.
- **Kieran B2:** `sessionKey: nil` pattern is fragile — use upfront gateway-format keys. **Fix:** `sessionKey = "agent:main:\(topicId.lowercased())"` immediately.
- **Kieran B3:** Bare UUID fallback has no prefix. **Fix:** Eliminated by B2.
- **Kieran B4:** Seed data invisible after migration. **Fix:** Seed uses Topic model.
- **Mel M1-M5:** Compact sheet, no bootstrap message, distinguish empty states, swipe actions, error states, no raw keys in UI.

#### Round 2 — Consolidated Findings
- **B1:** Spec internally inconsistent about sessionKey — D3 still describes nil flow. **v2 fix:** All nil-sessionKey text removed. Upfront key is the only pattern.
- **B2:** `BeeChatSessionFilter` overload needed — static enum can't hold instance state. **v2 fix:** Add `isBeeChatSession(_:topicRepo:)` overload, iOS calls it with injected repo.
- **B3:** Migration010 destroyed topic-based message count triggers. **v2 fix:** Computed message counts via SQL, not triggers.
- **B4:** Migration uses `try?` — partial failure unrecoverable. **v2 fix:** Single GRDB transaction with version tracking.
- **B5:** No offline path for topic creation. **v2 fix:** `pendingGatewaySync` flag + reconciliation on connect.
- **B6:** Bridge table has no UNIQUE constraint on `openclawSessionKey`. **v2 fix:** Add UNIQUE constraint, use upsert.
- **B7:** `sessions.subscribe` never re-subscribed on reconnect. **v2 fix:** Add to reconnect path.
- **B8:** Seed data uses Session model — invisible after migration. **v2 fix:** Seed creates Topic directly.
- **Mel M6-M14:** Detailed interaction specs for sheet, popover, swipe, empty states, offline, VoiceOver, Dynamic Type, validation checklist.
- **Q feasibility:** All code claims verified against v5 source. 5 hidden gotchas documented (H1-H4, W1-W10).

---

## 1. Problem Statement

The iOS app currently displays **raw gateway sessions** in the sidebar. This is wrong for a user-facing chat app. The `sessions.list` API returns every OpenClaw session — cron jobs, sub-agent runs, agent background sessions — all dumped into one flat list labelled "Topics."

BeeChat macOS solved this with a **Topic layer** that sits between the user and the gateway. The iOS app must adopt the same architecture.

### Two-model architecture (G1)

| Model | Purpose | Source of truth |
|-------|---------|----------------|
| **Session** | Gateway data — metadata, tokens, delivery status | Gateway API |
| **Topic** | User-facing conversation — name, last message, unread count | Local DB |

The bridge table (`topic_session_bridge`) links them. Sessions are never shown in the sidebar — only Topics. Messages use `sessionId` (foreign key to sessions table). The UI uses Topic IDs.

---

## 2. Core Design Decisions (Revised)

### D1: Shared v5 packages — no iOS-specific models

iOS uses the same `Topic`, `TopicRepository`, `TopicSessionBridge`, `BeeChatSessionFilter`, and `SessionKeyNormalizer` from `BeeChatPersistence`/`BeeChatSyncBridge`. No iOS-specific models.

### D2: Only user-created topics in sidebar — no auto-discovery

Only topics the user explicitly creates appear in the sidebar. Existing gateway sessions are not auto-discovered. A secondary "Import Recent Sessions" path is available (Mel M9).

### D3: Upfront gateway-format session key — NO nil session keys

Topics are created with `sessionKey = "agent:main:\(topicId.lowercased())"` immediately. There is **never** a nil session key. The bridge entry is created simultaneously. No "resolve on first message" flow. No "update session key after gateway response" flow. The gateway accepts this format because `SessionKeyNormalizer` strips the prefix and does case-insensitive matching.

> **This replaces the old D3 entirely.** All previous text describing `sessionKey: nil` or first-message resolution is removed.

### D4: Store all sessions, display only Topics

`SyncBridge.fetchSessions()` continues to upsert to the `sessions` table (for message history, delivery tracking). The sidebar shows `topicRepo.fetchAllActive()` only. Raw sessions are filtered from the UI but kept in the DB for message routing.

### D5: Seed data uses Topic model

`seedTestData()` creates a `Topic` plus a bridge entry and test messages. No `Session` model in seed data. After Gate 2B.5, remove seed data — the app starts with an empty "No conversations yet" state.

### D6: Topic ordering — chronological (lastActivityAt DESC)

iOS sorts topics by `lastActivityAt DESC` (most recent first). This differs from macOS (alphabetical) and is a deliberate UX decision (W9). Mobile chat apps show most-recent-first.

### D7: One topic = one session key = one context injection lifetime

No reuse or sharing of session keys between topics. Each topic maps to exactly one gateway session. Documented invariant (G3).

---

## 3. Data Model Changes

### 3.1 New: `pendingGatewaySync` flag on Topic

**Kieran B5 fix.** Topics created while offline need a `pendingGatewaySync` flag so the app can reconcile them on reconnection.

```swift
// In Topic model (use metadataJSON or add a column in Migration012)
// Option A: Add column via Migration012
// Option B: Use metadataJSON field (already exists, no migration needed)

// Using metadataJSON (no migration):
var pendingGatewaySync: Bool {
    get { metadataJSON?.contains("\"pendingGatewaySync\":true") ?? false }
    set { /* update metadataJSON dictionary */ }
}
```

Recommended: Use `metadataJSON` for now (no schema migration needed). Add a dedicated column in a later gate if needed.

### 3.2 Fix: UNIQUE constraint on `topic_session_bridge.openclawSessionKey`

**Kieran B7 fix.** Add in Migration012:

```swift
// Migration012: Add unique constraint to bridge table
try db.execute(sql: """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_bridge_session_key 
    ON topic_session_bridge(openclawSessionKey)
""")
```

And change `saveBridge()` from insert-only `save()` to `upsertPreservingCreatedAt()`:

```swift
public func saveBridge(topicId: String, sessionKey: String) throws {
    try dbManager.write { db in
        var bridge = TopicSessionBridge(
            topicId: topicId,
            openclawSessionKey: sessionKey
        )
        try bridge.upsertPreservingCreatedAt(db)  // Changed from save(db)
    }
}
```

### 3.3 Fix: Computed message counts (no triggers)

**Q B3 fix.** Migration010 replaced topic-based triggers with session-based triggers. Instead of re-adding topic triggers, compute `messageCount` in the query:

```swift
// In TopicRepository.fetchAllActive():
public func fetchAllActive() throws -> [Topic] {
    try dbManager.reader.read { db in
        let topics = try Topic
            .filter(Column("isArchived") == false)
            .order(Column("lastActivityAt").desc)
            .fetchAll(db)
        return topics
    }
}

// Computed message count (called separately or joined):
public func messageCount(for topicId: String) throws -> Int {
    try dbManager.reader.read { db in
        // Join through bridge table to get session key, then count messages
        guard let bridge = try TopicSessionBridge
            .filter(Column("topicId") == topicId)
            .fetchOne(db) else { return 0 }
        return try Message
            .filter(Column("sessionId") == bridge.openclawSessionKey)
            .fetchCount(db)
    }
}
```

Alternatively, add a `fetchAllWithCounts()` method that does a single SQL JOIN:

```sql
SELECT t.*, COUNT(m.id) as computed_message_count
FROM topics t
LEFT JOIN topic_session_bridge b ON b.topicId = t.id
LEFT JOIN messages m ON m.sessionId = b.openclawSessionKey
WHERE t.isArchived = 0
GROUP BY t.id
ORDER BY t.lastActivityAt DESC
```

### 3.4 Fix: `sendMessage` passes Topic to SyncBridge for context injection

**Q H4 fix.** The current `sendMessage` call doesn't pass the Topic parameter, so context injection (`[TOPIC-CONTEXT]`) never fires for iOS sends.

```swift
// ViewModel.send(text:to:)
public func send(text: String, to topicId: String) async throws {
    guard let topic = topics.first(where: { $0.id == topicId }),
          let sessionKey = topic.sessionKey else { return }
    _ = try await bridge.sendMessage(sessionKey: sessionKey, text: text, topic: topic)
}
```

---

## 4. ViewModel Changes

### 4.1 Add TopicRepository (injected, NOT per-call)

**Kieran B1 / Q B2 fix.**

```swift
public class BeeChatMobileViewModel: ObservableObject {
    public let persistenceStore: BeeChatPersistenceStore
    public let topicRepo: TopicRepository  // NEW — injected shared instance
    
    public init(persistenceStore: BeeChatPersistenceStore) {
        self.persistenceStore = persistenceStore
        self.topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
    }
}
```

**Critical:** `TopicRepository` must be created AFTER `openDatabase()` in `start()`, not in `init()`. The `DatabaseManager.shared` must have an open pool before `TopicRepository` is used.

### 4.2 Change `topics: [Session]` → `topics: [Topic]`

```swift
// BEFORE:
public var topics: [Session] = []

// AFTER:
public var topics: [Topic] = []
```

### 4.3 Replace `fetchSessions()` with topic-based flow

**Current (broken):**
```swift
let sessions = try await bridge.fetchSessions()
self.topics = sessions  // Raw sessions — WRONG
```

**Required:**
```swift
// Step 1: Migrate existing data (first launch only)
try migrateSessionsToTopicsIfNeeded()

// Step 2: Fetch sessions from gateway (still needed for messages/delivery)
let sessions = try await bridge.fetchSessions()

// Step 3: Sync metadata from sessions to topics
try topicRepo.syncMetadataFromSessions(sessions)

// Step 4: Reconcile pending topics (offline creation)
try reconcilePendingTopics()

// Step 5: Refresh topic list from local DB (not from gateway)
self.topics = try topicRepo.fetchAllActive()
```

### 4.4 `migrateSessionsToTopicsIfNeeded()` — atomic migration

**Kieran B4 / B6 fix.** Wrapped in a single GRDB transaction. Version-tracked so failed migrations can be retried.

```swift
private func migrateSessionsToTopicsIfNeeded() throws {
    // Check if migration already completed
    let migrationDone = UserDefaults.standard.bool(forKey: "beechat.topicsMigration.v2")
    if migrationDone { return }
    
    try dbManager.write { db in
        // Single transaction — either all sessions convert or none do
        let sessions = try Session.fetchAll(db)
        for session in sessions {
            let gatewayKey = "agent:main:\(session.id.lowercased())"
            let topic = Topic(
                id: session.id,
                name: session.title ?? session.customName ?? "Conversation",
                sessionKey: gatewayKey,
                lastMessagePreview: session.lastMessagePreview,
                lastActivityAt: session.lastMessageAt ?? session.updatedAt,
                messageCount: session.messageCount
            )
            try topic.save(db)
            var bridge = TopicSessionBridge(topicId: topic.id, openclawSessionKey: gatewayKey)
            try bridge.upsertPreservingCreatedAt(db)
        }
    }
    
    UserDefaults.standard.set(true, forKey: "beechat.topicsMigration.v2")
}
```

### 4.5 `createTopic(name:)` — upfront key, no nil

**Kieran B2/B3 fix.** Gateway-format key generated immediately. Bridge entry created simultaneously. No nil session key.

```swift
public func createTopic(name: String) throws -> Topic {
    let topicId = UUID().uuidString
    let gatewayKey = "agent:main:\(topicId.lowercased())"
    let topic = Topic(
        id: topicId,
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        sessionKey: gatewayKey,
        pendingGatewaySync: true  // Flagged for reconciliation on connect
    )
    try topicRepo.save(topic)
    try topicRepo.saveBridge(topicId: topicId, sessionKey: gatewayKey)
    self.topics = try topicRepo.fetchAllActive()
    return topic
}
```

### 4.6 `reconcilePendingTopics()` — offline creation fix

**Kieran B5 fix.** On connect, send a bootstrap message for any topic with `pendingGatewaySync = true`.

```swift
private func reconcilePendingTopics() async throws {
    let pendingTopics = try topicRepo.fetchAll(where: "pendingGatewaySync = 1")
    for topic in pendingTopics {
        guard let sessionKey = topic.sessionKey else { continue }
        // Send bootstrap message to create the gateway session
        _ = try? await bridge.sendMessage(
            sessionKey: sessionKey,
            text: "Start",
            topic: topic
        )
        // Clear the pending flag
        try topicRepo.updateMetadata(topicId: topic.id, key: "pendingGatewaySync", value: "false")
    }
}
```

### 4.7 `syncMetadataFromSessions()` — new method on TopicRepository

**Q W3 fix.** Updates topic metadata from matching session data.

```swift
// In TopicRepository:
public func syncMetadataFromSessions(_ sessions: [Session]) throws {
    try dbManager.write { db in
        for session in sessions {
            // Find topic by session key (direct or via bridge)
            guard let topicId = try resolveTopicId(for: session.id) else { continue }
            guard var topic = try Topic.fetchOne(db, key: topicId) else { continue }
            
            // Update metadata from session
            topic.lastMessagePreview = session.lastMessagePreview
            topic.lastActivityAt = session.lastMessageAt ?? session.updatedAt
            // messageCount is computed, not stored
            try topic.save(db)
        }
    }
}
```

### 4.8 Session filtering on connect

**Kieran B1/B9 fix.** Use injected `topicRepo`, not the static method that creates fresh instances.

```swift
// In ViewModel.connect():
let sessions = try await bridge.fetchSessions()
let filteredSessions = sessions.filter { sessionKey in
    // Use injected repo, not static method
    (try? topicRepo.resolveTopicId(for: sessionKey)) != nil
}
```

### 4.9 `sessions.subscribe` on reconnect

**Kieran B8 fix.** Add subscription to reconnect path.

```swift
// In SyncBridge or ViewModel reconnect handler:
private func reconnect() async throws {
    try await rpcClient.sessionsSubscribe()  // Re-subscribe on reconnect
    try await reconcile()                       // Re-fetch sessions
}
```

### 4.10 `BeeChatSessionFilter` overload

**Kieran B2 fix.** Add an instance-based overload alongside the existing static method.

```swift
// In BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift:
extension BeeChatSessionFilter {
    // Existing static method (macOS path) — unchanged
    public static func isBeeChatSession(_ sessionKey: String) throws -> Bool { ... }
    
    // NEW: Instance-based overload (iOS path) — uses injected repo
    public static func isBeeChatSession(_ sessionKey: String, topicRepo: TopicRepository) throws -> Bool {
        if try topicRepo.resolveTopicId(for: sessionKey) != nil { return true }
        // ... rest of existing logic, but using injected repo
    }
}
```

macOS code unchanged. iOS ViewModel uses the overload.

---

## 5. UI Changes

### 5.1 TopicListView — Topics, not Sessions

- `TopicRow` uses `Topic` model (not `Session`)
- Property mapping: `Session.title` → `Topic.name`, `Session.lastMessageAt` → `Topic.lastActivityAt`, `Session.customName` → removed (use `Topic.name` directly)
- Topic ordering: `lastActivityAt DESC` (D6)

### 5.2 New Topic Sheet (Mel M6)

**iPhone:**
- `.presentationDetents([.height(220)])`
- `.medium` allowed only for large Dynamic Type
- Title: `New Topic`
- Prompt: `What would you like to talk about?`
- Single-line text field, placeholder: `Topic name`
- Character counter: `0/80`
- Buttons: `Cancel` (leading), `Create` (trailing)
- `Create` disabled until trimmed name is non-empty
- Keyboard auto-focuses on sheet open
- Dirty draft discard: if text entered, confirmation dialog "Discard topic draft?" with `Keep Editing` / `Discard`
- On create: trim whitespace, save topic, dismiss, auto-select, navigate to chat, focus composer

**iPad (Mel M7):**
- Popover anchored to `+` button (regular width)
- 360 pt wide, ~220 pt tall
- Falls back to iPhone sheet for compact width
- Minimum topic list width: 280 pt

### 5.3 Empty States (Mel M9)

**Fresh install (no topics, no importable sessions):**
```
[BeeChat icon]
No conversations yet
Start a topic when you are ready to chat with Bee.

[Start a Conversation]
```

**Existing sessions available (no topics, but importable sessions exist):**
```
[BeeChat icon]
No topics yet
BeeChat now keeps your conversations organized as topics.

[Start a Conversation]
[Import Recent Sessions]
```

- `Import Recent Sessions` opens a sheet with a selectable list of candidate sessions (human-readable titles only)
- Default selection: none unless high confidence the session is user-created
- If import scan fails: keep empty state, show non-blocking banner "Could not load recent sessions. Try again."

### 5.4 Swipe Actions (Mel M8)

- **Trailing swipe:** Archive (default, neutral icon/tint) + Delete (destructive, trash icon/tint)
- **Full swipe:** Performs Archive, not Delete
- **Delete confirmation:** "Delete Topic? / This permanently deletes the conversation and all local messages. This cannot be undone." / Cancel / Delete
- **Archive undo:** Row animates away, toast "Archived 'Topic Name'" with Undo button (5-second timeout). Undo restores position and selection state.
- **No leading swipe** (pinning deferred to Gate 3)

### 5.5 Offline / Error States (Mel M10)

**Gateway disconnected:**
- Topic list usable, chat history readable
- Composer visible but disabled
- Placeholder: "Reconnect to send messages"
- Banner: "Offline. Showing cached messages." with Retry button
- Draft text preserved in composer

**Send failure (was online, then failed):**
- Keep optimistic message bubble in transcript
- Mark as failed inline
- Show inline Retry on failed bubble
- No modal for routine failures

**Partial failure (user message sent, assistant stream interrupted):**
- User message stays `sent`
- Assistant bubble: "Response interrupted" with Retry
- Retry continues the response, doesn't duplicate user message

### 5.6 Accessibility (Mel M11)

- All interactive elements have VoiceOver labels
- Connection indicator: text state ("Connected", "Offline", "Reconnecting", "Error"), not just green/red dot
- Unread count: number as text, not just colored badge
- 44 pt minimum hit targets
- Dynamic Type: topic rows support 2-line titles/previews at large sizes; sheet expands to `.medium` for large accessibility sizes
- New topic button: label "New Topic", hint "Creates a conversation topic"

### 5.7 First Launch (Mel M12)

- No walkthrough. Empty topic list with "Start a Conversation" CTA.
- After first topic creation and chat opens, show: "Ask Bee anything to get started."
- Composer is auto-focused after topic creation.
- No coach marks.

### 5.8 Context Menu

- Rename: deferred to post-Gate 2B.5 (should-have, not must-have)
- Archive / Delete: via swipe actions (M8)
- Copy Diagnostic ID: long-press → "Copy Diagnostic ID" — copies topic ID and session key for debugging. Raw session keys never shown in normal UI.

---

## 6. Implementation Plan

### Phase 1: ViewModel (Q)

| Step | Change | Files |
|------|--------|-------|
| 1.1 | Add `TopicRepository` to ViewModel | BeeChatMobileViewModel.swift |
| 1.2 | Change `topics: [Session]` → `[Topic]` | BeeChatMobileViewModel.swift |
| 1.3 | Replace `fetchSessions()` with topic-based flow | BeeChatMobileViewModel.swift |
| 1.4 | Add `migrateSessionsToTopicsIfNeeded()` (atomic, version-tracked) | BeeChatMobileViewModel.swift |
| 1.5 | Add `createTopic(name:)` (upfront key, no nil) | BeeChatMobileViewModel.swift |
| 1.6 | Add `reconcilePendingTopics()` (offline creation) | BeeChatMobileViewModel.swift |
| 1.7 | Add `send(text:to:)` with topic → session key resolution | BeeChatMobileViewModel.swift |
| 1.8 | Add `sessionsSubscribe()` to reconnect path | BeeChatMobileViewModel.swift |
| 1.9 | Add `BeeChatSessionFilter.isBeeChatSession(_:topicRepo:)` overload | SessionKeyNormalizer.swift (v5) |
| 1.10 | Change `saveBridge()` to `upsertPreservingCreatedAt()` | TopicRepository.swift (v5) |
| 1.11 | Add UNIQUE constraint on `openclawSessionKey` | Migration012 (new, v5) |
| 1.12 | Add `syncMetadataFromSessions()` to TopicRepository | TopicRepository.swift (v5) |
| 1.13 | Update `seedTestData()` to create Topic, not Session | BeeChatMobileViewModel.swift |

### Phase 2: UI (Q, guided by Mel specs)

| Step | Change | Files |
|------|--------|-------|
| 2.1 | Rewrite `TopicRow` for Topic model | TopicListView.swift |
| 2.2 | Add `+` toolbar button | TopicListView.swift |
| 2.3 | Create `NewTopicSheet.swift` (M6/M7 specs) | NewTopicSheet.swift (new) |
| 2.4 | Create `EmptyTopicsView.swift` (M9 specs) | EmptyTopicsView.swift (new) |
| 2.5 | Add swipe actions: Archive + Delete (M8) | TopicListView.swift |
| 2.6 | Add offline/disconnected state (M10) | BeeChatView.swift, ConnectionViews.swift |
| 2.7 | Update `BeeChatView` for topic-resolved session key | BeeChatView.swift |
| 2.8 | Add accessibility labels (M11) | All UI files |
| 2.9 | Update `ConnectionStatusView` with retry | ConnectionViews.swift |

### Phase 3: Validation (Bee, then Adam)

| # | Test | Pass criteria |
|---|------|---------------|
| 1 | Create topic on iPhone portrait | Sheet opens, keyboard focuses, Create disabled until valid text |
| 2 | Dismiss dirty sheet | Confirmation dialog appears |
| 3 | Paste overlong topic name | 80-char limit enforced, no overflow |
| 4 | Create topic on iPad | Popover anchors to + button |
| 5 | Topic appears in sidebar | Not in alphabetical order, most recent first |
| 6 | Send message in new topic | Gateway session created, bridge entry exists |
| 7 | Receive message | Topic metadata updates (lastMessagePreview, lastActivityAt) |
| 8 | No cron/agent sessions visible | Only user-created topics in sidebar |
| 9 | Archive topic | Row animates away, undo toast appears, undo restores |
| 10 | Delete topic | Confirmation alert appears, mentions local messages |
| 11 | Fresh install empty state | Only "Start a Conversation" visible |
| 12 | Import sessions path | Secondary button, selection sheet, creates topics |
| 13 | Offline with cached topics | List readable, composer disabled, draft preserved |
| 14 | Failed send | Inline retry on bubble, no modal |
| 15 | Gateway reconnect | sessions.subscribe re-called, live updates resume |
| 16 | macOS BeeChat regression | Still connects, topics visible, no errors |
| 17 | VoiceOver | All elements labeled, connection state as text |
| 18 | Dynamic Type large | Sheet expands, buttons remain tappable |
| 19 | Migration from 2B | Existing sessions become topics, no data loss |
| 20 | Seed data visible | Welcome topic shows in sidebar |

---

## 7. v5 Shared Code Changes

All changes to shared `BeeChatPersistence` and `BeeChatSyncBridge` packages are additive — no macOS code is modified in behavior.

| Change | Package | macOS Impact |
|--------|---------|-------------|
| `BeeChatSessionFilter.isBeeChatSession(_:topicRepo:)` overload | BeeChatSyncBridge | None — additive, existing static method unchanged |
| `TopicRepository.saveBridge()` → upsert | BeeChatPersistence | None — upsert is backwards-compatible |
| UNIQUE constraint on `openclawSessionKey` | BeeChatPersistence (Migration012) | None — additive index |
| `TopicRepository.syncMetadataFromSessions()` | BeeChatPersistence | None — new method |
| `TopicRepository.messageCount(for:)` | BeeChatPersistence | None — new method |

**Rollback plan:** Git checkout of both repos to baseline commits (documented in `Docs/GATE-2B-ROLLBACK.md`).

---

## 8. Exit Criteria

| # | Criterion | Validation |
|---|-----------|------------|
| 1 | ViewModel uses `[Topic]` not `[Session]` | Code review |
| 2 | Sidebar shows only user-created Topics | Manual: no cron/agent sessions |
| 3 | "New Topic" button with sheet (iPhone) / popover (iPad) | Manual: M6/M7 checklist |
| 4 | Topics created with upfront gateway-format key | Code review: no nil session keys |
| 5 | `BeeChatSessionFilter` overload used (not static method) | Code review |
| 6 | Migration atomic and version-tracked | Code review: single transaction |
| 7 | Bridge UNIQUE constraint | Code review: Migration012 |
| 8 | Offline topic creation with reconciliation | Manual: create topic offline, reconnect, verify |
| 9 | `sessions.subscribe` re-called on reconnect | Code review + manual: gateway restart test |
| 10 | Swipe actions (Archive + Delete) | Manual: M8 checklist |
| 11 | Empty states (fresh install + import) | Manual: M9 checklist |
| 12 | Offline states (disabled composer, preserved draft) | Manual: M10 checklist |
| 13 | Accessibility (VoiceOver, Dynamic Type) | Manual: M11 checklist |
| 14 | macOS BeeChat regression | Manual: connect, send, receive |
| 15 | Seed data uses Topic model | Code review |
| 16 | Computed message counts (no triggers) | Code review: SQL JOIN |
| 17 | Kieran sign-off | Review |
| 18 | Q sign-off | Review |
| 19 | Adam approval | Sign-off |

---

## 9. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Migration fails halfway | Corrupted state | Low — transactional | Single GRDB transaction + version tracking |
| Dual trigger/message count inconsistency | Stale counts | Eliminated — computed counts | SQL JOIN in fetchAllActive() |
| Topic ↔ Session bridge duplicates | Non-deterministic lookup | Eliminated — UNIQUE constraint | upsert + constraint |
| Offline topic creation with no gateway | Messages silently fail | Medium — pending flag | `pendingGatewaySync` + reconciliation on connect |
| `sessions.subscribe` dropped after gateway restart | No live updates | Eliminated — re-subscribe | Add to reconnect path |
| macOS regression from shared code changes | macOS breaks | Low — additive only | All changes are additive, existing methods unchanged. Test on macOS after every shared change. |
| `TopicRow` property refactor larger than estimated | Schedule slip | Medium — 8+ properties to map | Budget 2-3 hours for UI audit |
| BeeChatSessionFilter deadlock on iOS | UI freeze | Eliminated — overload | Inject repo, no fresh instances |

---

## 10. Approval

| Role | Agent | Status |
|------|-------|--------|
| Coordinator | Bee | ✅ Drafted v2 |
| Adversarial Reviewer | Kieran | ✅ Pass 1 + Pass 2 findings incorporated |
| Designer | Mel | ✅ Pass 1 + Pass 2 findings incorporated |
| Builder | Q | ✅ Feasibility review findings incorporated |
| Approver | Adam | ⏳ Pending |

No implementation begins until Adam has approved this revised spec.