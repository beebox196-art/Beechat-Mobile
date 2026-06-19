# Gate 2B.5 — Phase 1: Data Layer (v2)

**Status:** Draft — awaiting team review  
**Parent:** GATE-2B5-TOPIC-ARCHITECTURE-v2.md  
**Date:** 2026-05-18  

---

## 1. Context

### 1.1 Problem

The iOS app's `BeeChatMobileViewModel` currently treats `Session` objects as user-facing topics. After connecting to the gateway, `syncBridge.fetchSessions()` returns **all** gateway sessions — including cron jobs, background agent sessions, and system sessions. The sidebar shows these as "Topics" which is wrong for a user-facing chat app.

### 1.2 Existing Working Architecture (BeeChat macOS / BeeChat-v5)

BeeChat-v5 already has a complete Topic architecture that solves this problem:

| Component | Location | Status |
|-----------|----------|--------|
| `Topic` model | `BeeChat-v5/Sources/BeeChatPersistence/Models/Topic.swift` | ✅ Exists |
| `TopicSessionBridge` model | `BeeChat-v5/Sources/BeeChatPersistence/Models/Topic.swift` | ✅ Exists |
| `TopicRepository` | `BeeChat-v5/Sources/BeeChatPersistence/Repositories/TopicRepository.swift` | ✅ Exists |
| `BeeChatSessionFilter` | `BeeChat-v5/Sources/BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift` | ✅ Exists (needs fix) |
| `Session` model | `BeeChat-v5/Sources/BeeChatPersistence/Models/Session.swift` | ✅ Exists (backend truth) |
| Migrations 001-011 | `BeeChat-v5/Sources/BeeChatPersistence/Database/DatabaseManager.swift` | ✅ All registered |

**The iOS app already links against BeeChatPersistence.** It just isn't using the Topic layer yet.

### 1.3 Goal for Phase 1

Make the iOS ViewModel use the **existing** Topic model and TopicRepository from BeeChat-v5, with minimal additions to support the iOS-specific needs. No UI changes — just the data layer.

---

## 2. Existing Codebase Audit

### 2.1 Existing `Topic` Model

```swift
// BeeChat-v5/Sources/BeeChatPersistence/Models/Topic.swift
public struct Topic: Codable, UpsertableRecord {
    public static let databaseTableName = "topics"
    
    public var id: String                    // UUID string
    public var name: String
    public var lastMessagePreview: String?
    public var lastActivityAt: Date?
    public var unreadCount: Int = 0
    public var sessionKey: String?           // ← optional (needs change)
    public var isArchived: Bool = false
    public var createdAt: Date
    public var updatedAt: Date
    public var metadataJSON: String?
    public var messageCount: Int = 0
    
    // Upsert columns (excludes messageCount — maintained by DB trigger)
    public static let upsertColumns: [Column] = [
        Column("name"), Column("lastMessagePreview"), Column("lastActivityAt"),
        Column("unreadCount"), Column("sessionKey"), Column("isArchived"),
        Column("updatedAt"), Column("metadataJSON")
    ]
}
```

### 2.2 Existing `TopicSessionBridge` Model

```swift
// BeeChat-v5/Sources/BeeChatPersistence/Models/Topic.swift
public struct TopicSessionBridge: Codable, UpsertableRecord {
    public static let databaseTableName = "topic_session_bridge"
    
    public var topicId: String
    public var spaceId: String = "default"
    public var openclawSessionKey: String
    public var bridgeVersion: Int = 1
    public var status: String = "active"
    public var createdAt: Date
    public var updatedAt: Date
    public var lastSyncAt: Date?
    public var lastError: String?
    public var retryCount: Int = 0
    
    public static let upsertColumns: [Column] = [
        Column("spaceId"), Column("openclawSessionKey"), Column("bridgeVersion"),
        Column("status"), Column("updatedAt"), Column("lastSyncAt"),
        Column("lastError"), Column("retryCount")
    ]
}
```

### 2.3 Existing `TopicRepository`

```swift
// BeeChat-v5/Sources/BeeChatPersistence/Repositories/TopicRepository.swift
public class TopicRepository {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager = .shared)
    public func save(_ topic: Topic) throws
    public func fetchAllActive(limit: Int = 100) throws -> [Topic]
    public func deleteCascading(_ id: String) throws
    public func updateSessionKey(topicId: String, sessionKey: String) throws
    public func saveBridge(topicId: String, sessionKey: String) throws
    public func resolveSessionKey(topicId: String) throws -> String?
    public func resolveTopicId(for sessionKey: String) throws -> String?
    public func resolveTopicIdBySuffix(gatewayKey: String, stripped: String) throws -> String?
    public func listAllBridgeSessionKeys() throws -> [(String, String)]
}
```

**Key detail:** `fetchAllActive()` returns topics ordered by `lastActivityAt DESC` — chronological, most recent first. This matches the UX requirement (Mel's M2).

### 2.4 Existing `BeeChatSessionFilter`

```swift
// BeeChat-v5/Sources/BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift
public enum BeeChatSessionFilter {
    public static func isBeeChatSession(_ sessionKey: String) throws -> Bool
    public static func normalize(_ gatewayKey: String) throws -> String
}
```

**⚠️ BLOCKER (B1):** Both methods create `TopicRepository()` inline. This will deadlock on iOS `@MainActor`. Needs an overload that accepts an injected `TopicRepository` instance.

### 2.5 Existing `Session` Model

```swift
// BeeChat-v5/Sources/BeeChatPersistence/Models/Session.swift
public struct Session: Codable, UpsertableRecord {
    public static let databaseTableName = "sessions"
    
    public var id: String
    public var agentId: String
    public var channel: String?
    public var title: String?
    public var lastMessageAt: Date?
    public var unreadCount: Int = 0
    public var isPinned: Bool = false
    public var updatedAt: Date
    public var createdAt: Date
    public var customName: String?
    public var lastMessagePreview: String?
    public var messageCount: Int = 0
    public var totalTokens: Int?
    public var isArchived: Bool = false
}
```

Sessions remain the backend truth — they are the gateway's representation of conversations. Topics are the user-facing representation.

### 2.6 Existing `Session` Model

```swift
// BeeChat-v5/Sources/BeeChatPersistence/Models/Session.swift
public struct Session: Codable, UpsertableRecord {
    public static let databaseTableName = "sessions"
    
    public var id: String
    public var agentId: String
    public var channel: String?
    public var title: String?
    public var lastMessageAt: Date?
    public var unreadCount: Int = 0
    public var isPinned: Bool = false
    public var updatedAt: Date
    public var createdAt: Date
    public var customName: String?
    public var lastMessagePreview: String?
    public var messageCount: Int = 0
    public var totalTokens: Int?
    public var isArchived: Bool = false
}
```

Sessions remain the backend truth — they are the gateway's representation of conversations. Topics are the user-facing representation.

### 2.6 Existing `BeeChatMobileViewModel` (iOS)

```swift
// BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift
@Observable @MainActor
public final class BeeChatMobileViewModel {
    public var topics: [Session] = []           // ← WRONG: uses Session model
    public var selectedTopicId: String? = nil
    
    public func start() async throws {
        try persistenceStore.openDatabase(at: config.dbPath)
        let existing = try persistenceStore.fetchSessions(limit: 1, offset: 0)
        if existing.isEmpty { try seedTestData() }  // ← seeds Session, not Topic
        self.topics = try persistenceStore.fetchSessions(limit: 100, offset: 0)
    }
    
    public func connect() async {
        // ... creates SyncBridge, fetches sessions from gateway
        let sessions = try await bridge.fetchSessions()
        self.topics = sessions  // ← gateway sessions, not topics
    }
    
    private func seedTestData() throws {
        let session = Session(id: "seed-session-1", agentId: "bee", title: "Welcome to BeeChat", ...)
        try persistenceStore.saveSession(session)
        // ... saves test messages
    }
}
```

**Key issue:** The ViewModel's `topics` property is typed as `[Session]`. It needs to be `[Topic]`. The `seedTestData()` method creates `Session` objects, not `Topic` objects.

### 2.7 Existing Migrations (M001–M011)

| Migration | What it does |
|-----------|-------------|
| M001 | Create `sessions` table |
| M002 | Create `messages` + `attachments` tables |
| M003 | Create `attachments` if missing (idempotent) |
| M004 | Create `delivery_ledger` table |
| M005 | Create `topics` + `topic_session_bridge` tables |
| M006 | Recreate `messages` (always use `sessionId`, add indexes) |
| M007 | Add `messageCount` column to sessions + triggers |
| M008 | Create `bookmarks` table |
| M009 | Add `originalContent` column to messages |
| M010 | Session Key Alignment Schema — adds `session_key_mapping`, `customName`/`lastMessagePreview`/`messageCount`/`totalTokens`/`isArchived` to sessions, replaces topic-based message triggers with session-based triggers, creates `_migration_metadata` table, sets `session_key_alignment_pending = "1"` |
| M011 | Add `agentId` column to messages |

**M010 detail:** The session-based message count triggers (`trg_session_increment_message_count`, `trg_session_decrement_message_count`) fire on `messages.sessionId` → `sessions.id`. Topic-based triggers were dropped. This means `Topic.messageCount` is **not** maintained by triggers anymore.

### 2.8 Existing `BeeChatPersistenceStore`

```swift
// BeeChat-v5/Sources/BeeChatPersistence/BeeChatPersistenceStore.swift
public class BeeChatPersistenceStore {
    public func openDatabase(at path: String) throws
    public func fetchSessions(limit: Int, offset: Int) throws -> [Session]
    public func fetchMessages(sessionId: String, limit: Int, before: Date?) throws -> [Message]
    public func saveMessage(_ message: Message) throws
    public func saveSession(_ session: Session) throws
    // ... more methods
}
```

The iOS ViewModel uses this wrapper. The underlying `TopicRepository` is accessible via `DatabaseManager.shared`.

---

## 3. Phase 1 Changes

### 3.1 `Topic` Model — Add `pendingGatewaySync` Field

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Models/Topic.swift`

Add one new field to the existing `Topic` struct:

```swift
public var pendingGatewaySync: Bool = false
```

Update `init` and `upsertColumns`:

```swift
public init(
    id: String = UUID().uuidString,
    name: String,
    lastMessagePreview: String? = nil,
    lastActivityAt: Date? = nil,
    unreadCount: Int = 0,
    sessionKey: String? = nil,
    isArchived: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    metadataJSON: String? = nil,
    messageCount: Int = 0,
    pendingGatewaySync: Bool = false       // NEW
)

public static let upsertColumns: [Column] = [
    Column("name"), Column("lastMessagePreview"), Column("lastActivityAt"),
    Column("unreadCount"), Column("sessionKey"), Column("isArchived"),
    Column("updatedAt"), Column("metadataJSON"),
    Column("pendingGatewaySync")            // NEW
]
```

**Rationale:** Supports offline topic creation (Blocker B5 from consolidated review). When a topic is created while offline, `pendingGatewaySync = true`. On reconnect, the sync layer reconciles and sets it to `false`.

### 3.2 `TopicRepository` — New Methods

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Repositories/TopicRepository.swift`

Add these methods to the **existing** `TopicRepository`:

#### 3.2.1 `create(name:)` — Create topic with upfront gateway key

```swift
/// Create a new topic with an upfront gateway-format session key.
/// The key is generated as "agent:main:<topicId>" (lowercase) to match
/// gateway conventions. No nil sessionKey window.
public func create(name: String) throws -> Topic {
    let topicId = UUID().uuidString
    let gatewayKey = "agent:main:\(topicId.lowercased())"
    
    let topic = Topic(
        id: topicId,
        name: name,
        sessionKey: gatewayKey,
        pendingGatewaySync: false
    )
    
    try save(topic)
    try saveBridge(topicId: topicId, sessionKey: gatewayKey)
    
    return topic
}
```

#### 3.2.2 `fetchAllActiveWithCounts()` — Computed message counts

```swift
/// Fetch active topics with computed message counts (via SQL JOIN).
/// M010 destroyed topic-based triggers, so messageCount must be computed.
public func fetchAllActiveWithCounts(limit: Int = 100) throws -> [Topic] {
    try dbManager.reader.read { db in
        try Topic.fetchAll(db, sql: """
            SELECT t.*, COALESCE((
                SELECT COUNT(*) FROM messages m
                JOIN topic_session_bridge b ON b.openclawSessionKey = m.sessionId
                WHERE b.topicId = t.id
            ), 0) as computedMessageCount
            FROM topics t
            WHERE t.isArchived = 0
            ORDER BY t.lastActivityAt DESC
            LIMIT \(limit)
        """)
    }
}
```

#### 3.2.3 `markSynced(topicId:)` — Clear pending sync flag

```swift
/// Clear the pendingGatewaySync flag after successful reconciliation.
public func markSynced(topicId: String) throws {
    try dbManager.write { db in
        try db.execute(
            sql: "UPDATE topics SET pendingGatewaySync = 0, updatedAt = ? WHERE id = ?",
            arguments: [Date(), topicId]
        )
    }
}
```

#### 3.2.4 `upsertBridge(topicId:sessionKey:)` — Upsert bridge entry

```swift
/// Insert or update a bridge entry. Uses the existing upsertColumns
/// on TopicSessionBridge to avoid duplicates.
public func upsertBridge(topicId: String, sessionKey: String) throws {
    try dbManager.write { db in
        var bridge = TopicSessionBridge(
            topicId: topicId,
            openclawSessionKey: sessionKey
        )
        try bridge.upsertPreservingCreatedAt(db)
    }
}
```

### 3.3 `BeeChatSessionFilter` — Injected Repository Overload

**File:** `BeeChat-v5/Sources/BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift`

Add overloaded methods that accept an existing `TopicRepository` instance:

```swift
public enum BeeChatSessionFilter {
    // ... existing methods unchanged ...
    
    /// Check whether a session key maps to a known BeeChat topic,
    /// using an injected TopicRepository to avoid deadlock on @MainActor.
    public static func isBeeChatSession(_ sessionKey: String, topicRepo: TopicRepository) throws -> Bool {
        if try topicRepo.resolveTopicId(for: sessionKey) != nil {
            return true
        }
        let stripped = SessionKeyNormalizer.stripPrefix(sessionKey)
        if stripped != sessionKey,
           try topicRepo.resolveTopicIdBySuffix(gatewayKey: sessionKey, stripped: stripped) != nil {
            return true
        }
        return false
    }
    
    /// Normalize a gateway session key to the local topic ID,
    /// using an injected TopicRepository.
    public static func normalize(_ gatewayKey: String, topicRepo: TopicRepository) throws -> String {
        let stripped = SessionKeyNormalizer.stripPrefix(gatewayKey)
        if let topicId = try topicRepo.resolveTopicIdBySuffix(gatewayKey: gatewayKey, stripped: stripped) {
            return topicId
        }
        return gatewayKey
    }
}
```

**Rationale:** Blocker B2. The original methods create `TopicRepository()` inline, which can deadlock on iOS `@MainActor`. The overload uses an injected instance.

### 3.4 Migration012 — Add `pendingGatewaySync` Column

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Database/DatabaseManager.swift`

Register a new migration after M011:

```swift
migrator.registerMigration("Migration012_AddPendingGatewaySync") { db in
    guard try db.tableExists("topics") else { return }
    
    let columns = try db.columns(in: "topics").map { $0.name }
    if !columns.contains("pendingGatewaySync") {
        try db.alter(table: "topics") { t in
            t.add(column: "pendingGatewaySync", .boolean).defaults(to: false)
        }
    }
    
    // Add UNIQUE constraint on openclawSessionKey in bridge table
    // (Blocker B6 — prevents non-deterministic lookups)
    if try db.tableExists("topic_session_bridge") {
        // SQLite doesn't support ADD UNIQUE, so we recreate the index
        try db.execute(sql: "DROP INDEX IF EXISTS idx_bridge_session_key")
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_bridge_session_key ON topic_session_bridge(openclawSessionKey)")
    }
}
```

**Rationale:** Adds the new column and the UNIQUE constraint (Blocker B6). Uses ALTER TABLE (safe, preserves existing data) rather than recreate.

### 3.5 Seed Data — Create Topics, Not Sessions

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

Replace `seedTestData()` to create `Topic` objects instead of `Session` objects:

```swift
private func seedTestData() throws {
    let topicRepo = TopicRepository(dbManager: persistenceStore.dbManager)
    
    // Create 3 seed topics with gateway-format keys
    let topic1 = try topicRepo.create(name: "Welcome to BeeChat")
    let topic2 = try topicRepo.create(name: "Solar Dashboard Help")
    let topic3 = try topicRepo.create(name: "Project Planning")
    
    // Save test messages linked to topic1's session key
    let msgs: [BeeChatPersistence.Message] = [
        BeeChatPersistence.Message(id: "m1", sessionId: topic1.sessionKey!, role: "user", content: "Hello Bee! How are you today?", senderName: "Adam", senderId: "adam", timestamp: Date().addingTimeInterval(-10)),
        BeeChatPersistence.Message(id: "m2", sessionId: topic1.sessionKey!, role: "assistant", content: "Hey Adam! I'm doing great - ready to help with anything you need. 🐝", senderName: "Bee", senderId: "bee", timestamp: Date().addingTimeInterval(-5)),
        BeeChatPersistence.Message(id: "m3", sessionId: topic1.sessionKey!, role: "user", content: "Can you show me my sessions list?", senderName: "Adam", senderId: "adam", timestamp: Date()),
    ]
    for m in msgs { try persistenceStore.saveMessage(m) }
}
```

**Rationale:** Blocker B8. Seed data must use Topic model so it's visible in the Topic-based UI. Messages are linked via the topic's `sessionKey` (which matches `messages.sessionId`).

### 3.6 ViewModel — Switch to Topic-Based Data

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

#### 3.6.1 Add TopicRepository instance

```swift
public final class BeeChatMobileViewModel {
    // ... existing properties ...
    public var topics: [Topic] = []          // ← Changed from [Session] to [Topic]
    private var topicRepo: TopicRepository!  // ← Added
    
    public func start() async throws {
        try persistenceStore.openDatabase(at: config.dbPath)
        self.topicRepo = TopicRepository(dbManager: persistenceStore.dbManager)
        
        let existingTopics = try topicRepo.fetchAllActive()
        if existingTopics.isEmpty {
            try seedTestData()
        }
        
        // Load topics from local DB
        self.topics = try topicRepo.fetchAllActive()
        
        // Auto-select first topic
        if selectedTopicId == nil, let first = topics.first {
            selectedTopicId = first.id
        }
    }
}
```

#### 3.6.2 Refresh topics via TopicRepository

```swift
private func refreshTopics() {
    do {
        self.topics = try topicRepo.fetchAllActive()
    } catch {
        print("[ViewModel] Failed to refresh topics: \(error)")
    }
}
```

#### 3.6.3 Session filtering on gateway fetch (using injected repo)

```swift
// In connect():
let sessions = try await bridge.fetchSessions()

// Filter to only BeeChat sessions using injected repo
let beeChatSessions = sessions.filter { session in
    try? BeeChatSessionFilter.isBeeChatSession(session.id, topicRepo: topicRepo) == true
} ?? []

// Merge gateway sessions with local topics
for gatewaySession in beeChatSessions {
    // Check if we already have a topic for this session
    if try topicRepo.resolveTopicId(for: gatewaySession.id) == nil {
        // New gateway session → create topic
        let topic = Topic(
            id: UUID().uuidString,
            name: gatewaySession.title ?? "Conversation",
            sessionKey: gatewaySession.id,
            lastActivityAt: gatewaySession.lastMessageAt,
            lastMessagePreview: gatewaySession.lastMessagePreview,
            messageCount: gatewaySession.messageCount,
            unreadCount: gatewaySession.unreadCount
        )
        try topicRepo.save(topic)
        try topicRepo.saveBridge(topicId: topic.id, sessionKey: gatewaySession.id)
    }
}

// Reload topics
self.topics = try topicRepo.fetchAllActive()
```

---

## 4. Success Criteria

### 4.1 Build

- [ ] BeeChat-v5 compiles (macOS, iOS)
- [ ] BeeChat-Mobile compiles (iOS simulator)

### 4.2 Database

- [ ] Migration012 runs without errors on existing database
- [ ] Fresh install: database has `topics` table with `pendingGatewaySync` column
- [ ] Fresh install: `topic_session_bridge` has UNIQUE index on `openclawSessionKey`
- [ ] Upgrade: existing topics are preserved, new column added with `false` default

### 4.3 Seed Data

- [ ] Fresh install creates 3 seed topics (not sessions)
- [ ] Topics have gateway-format session keys (`agent:main:<uuid>`)
- [ ] Test messages are linked to topic1's session key
- [ ] Topics appear in `topicRepo.fetchAllActive()`

### 4.4 ViewModel

- [ ] `start()` loads topics from TopicRepository (not SessionRepository)
- [ ] `refreshTopics()` returns Topic array
- [ ] `topics` property is `[Topic]` not `[Session]`
- [ ] `BeeChatSessionFilter` uses injected repo (no deadlock)

### 4.5 macOS Regression

- [ ] BeeChat macOS still builds and runs
- [ ] macOS app still shows topics correctly
- [ ] No change to macOS Topic architecture

---

## 5. Scope Boundary

### In Scope

- Topic model extension (1 new field)
- TopicRepository additions (4 new methods)
- BeeChatSessionFilter overload (2 new methods)
- Migration012 (ALTER TABLE + UNIQUE index)
- Seed data rewrite (Topics not Sessions)
- ViewModel switch to TopicRepository

### Out of Scope

- UI changes (Phase 3)
- New Topic creation UI (Phase 2)
- Swipe actions, empty states (Phase 3)
- Offline reconciliation logic (Phase 2)
- GRDB ValueObservation replacement (deferred)
- Keychain token storage (deferred)

---

## 6. Implementation Steps (Q)

1. Add `pendingGatewaySync` to `Topic` model + update `upsertColumns`
2. Add 4 new methods to `TopicRepository`
3. Add 2 overloaded methods to `BeeChatSessionFilter`
4. Register `Migration012` in `DatabaseManager.migrate()`
5. Rewrite `seedTestData()` in iOS ViewModel
6. Update iOS ViewModel `topics` property type to `[Topic]`
7. Update `start()` to use `TopicRepository`
8. Update `refreshTopics()` to use `TopicRepository`
9. Update `connect()` session filtering to use injected repo
10. Build and test on iOS simulator
11. Verify macOS BeeChat still works

---

## 7. Rollback

If Phase 1 causes issues:

```bash
# BeeChat-v5
cd /Users/openclaw/Projects/BeeChat-v5
git log --oneline -5   # find pre-Phase-1 commit
git checkout <commit>

# BeeChat-Mobile
cd /Users/openclaw/Projects/BeeChat-Mobile
git log --oneline -5   # find pre-Phase-1 commit
git checkout <commit>

# Reset database (if migration corrupted)
rm ~/Library/Containers/<app>/Data/Library/Application\ Support/BeeChat.db
```

The rollback baseline commit will be recorded after Q's changes are committed.
