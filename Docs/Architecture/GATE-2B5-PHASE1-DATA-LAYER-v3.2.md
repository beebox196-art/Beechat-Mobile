# Gate 2B.5 — Phase 1: Data Layer (v3.2)

**Status:** Final — v3.2 (all blockers resolved, team-approved)
**Parent:** GATE-2B5-TOPIC-ARCHITECTURE-v2.md  
**Date:** 2026-05-18  
**Replaces:** GATE-2B5-PHASE1-DATA-LAYER-v2.md  
**Changes from v2:** All 5 blockers (B1–B3c from v2 review) resolved. All findings from Q's v2 review, Kieran's v2 review, and Mel's v2 review incorporated.  
**Changes from v3→v3.1:** B10 resolved (upsert claim corrected), W16/W19/W20 addressed.
**Changes from v3.1→v3.2:** B11 resolved (raw SQL upsert for bridge), B12 resolved (topic→session key resolution in loadMessages + streamingContent). Q W21/W23 addressed.

---

## 0. Review History & Resolution

| Finding | Source | v3 Resolution |
|---------|--------|---------------|
| **Q B1:** `dbManager` is `private` on `BeeChatPersistenceStore` | Q v2 review | Expose `topicRepo` as `public` property (§3.1) |
| **Q B2:** `upsertBridge()` uses `onConflict: ["id"]` but PK is `topicId` | Q v2 review | Remove `upsertBridge()` entirely; use existing `saveBridge()` with `upsertPreservingCreatedAt()` fix (§3.5) |
| **Q B3a:** `TopicListView` references `Session` properties (`.title`, `.customName`, `.lastMessageAt`) | Q v2 review | Allow minimal 3-line change in `TopicListView.swift` — Phase 1 scope exemption (§3.8) |
| **Q B3b:** Computed column alias `computedMessageCount` not decoded by GRDB | Kieran v2 | Rename alias to `messageCount` so GRDB's `CodingKeys` decodes it (§3.4) |
| **Q B3c:** `create(name:)` sets `pendingGatewaySync: false` but offline topics need `true` | Kieran v2 | Add `pendingGatewaySync` parameter to `create(name:pendingGatewaySync:)`, default `false` (§3.3) |
| **Kieran B5:** No offline path for topic creation | Kieran v2 | `pendingGatewaySync` flag + `reconcilePendingTopics()` on connect (§3.3, §3.6) |
| **Kieran B6:** Migration uses `try?` → partial failure unrecoverable | Kieran v2 | Single GRDB transaction + `_migration_metadata` version flag (§3.7) |
| **Kieran B7:** Bridge table no UNIQUE constraint on `openclawSessionKey` | Kieran v2 | Add UNIQUE index in Migration012 (§3.7) |
| **Kieran B8:** `sessions.subscribe` never re-subscribed on reconnect | Kieran v2 | Add `sessionsSubscribe()` call in reconnect path (§3.6) |
| **Kieran W9:** Foreign keys disabled — cascade deletes are manual | Kieran v2 | Document as known limitation; `deleteCascading()` already handles all related tables |
| **Kieran W10:** Gateway token in plaintext file | Kieran v2 | Defer to Gate 2C; document in §5 (Out of Scope) |
| **Kieran W11:** Case-sensitivity inconsistency in session key resolution | Kieran v2 | Document convention explicitly: Topic IDs are uppercase UUIDs, gateway keys use lowercase suffix (§3.9) |
| **Kieran W12:** `send()` needs Topic→session key resolution | Kieran v2 | Show resolved `send()` method (§3.8) |
| **Kieran W14:** macOS/iOS ordering divergence | Kieran v2 | Document as deliberate: macOS alphabetical, iOS chronological (§3.9) |
| **Mel M6-M14:** Detailed interaction specs | Mel v2 | Deferred to Phase 3 (UI). Phase 1 provides the data model hooks (`pendingGatewaySync`, `isArchived`) |
| **Q W1:** `TopicRow` property name refactor is larger than spec suggests | Q v2 | Minimal 3-line change exempted in Phase 1 (§3.8) |
| **Q W3:** `fetchSessions()` returns `[Session]` — sync metadata to topics | Q v2 | Add `syncMetadataFromSessions()` method (§3.4) |
| **Q W5:** `sendMessage` needs `topic` parameter for context injection | Q v2 | Add `topic` parameter to `send()` call (§3.8) |
| **Q H1:** `saveBridge()` uses `save()` not `upsert` — crashes on duplicate | Q v2 | Change to `upsertPreservingCreatedAt()` (§3.5) |
| **Kieran B10:** `upsertPreservingCreatedAt()` won't handle UNIQUE conflicts on `openclawSessionKey` | Kieran v3 review | Remove incorrect upsert claim; add do/catch around `saveBridge()` in `connect()` path (§3.5, §3.7) |
| **Kieran W16:** `try?` around bootstrap `sendMessage` swallows errors; `markSynced` called regardless | Kieran v3 review | Move `markSynced` inside success path, use `do/catch` (§3.7.2) |
| **Kieran W19:** `syncMetadataFromSessions()` processes all sessions, not just BeeChat ones | Kieran v3 review | Pass `beeChatSessions` instead of `sessions` (§3.7.2) |
| **Kieran W20:** `upsertPreservingCreatedAt()` uses `onConflict: ["id"]` but bridge PK is `topicId` | Kieran v3 review | Replaced with raw SQL upsert `ON CONFLICT(topicId)` (B11 fix, §3.5) |
| **Q B11:** `upsertPreservingCreatedAt()` hardcodes `onConflict: ["id"]` but bridge has no `id` column — PK is `topicId` | Q v3.1 review | Replace with raw SQL upsert using `ON CONFLICT(topicId)` (§3.5) |
| **Q B12:** After `topics: [Session] → [Topic]`, `loadMessages()` and `streamingContent` key by topicId but messages key by sessionId — blank message list | Q v3.1 review | Add topic→session key resolution in `loadMessages()` and `streamingContent` (§3.7.6) |
| **Q W21:** `bridge.rpcClient.sessionsSubscribe()` won't compile — `rpcClient` is `private` | Q v3.1 review | Redundant — `SyncBridge.start()` already subscribes. Remove from spec (§3.7.2) |
| **Q W22:** TopicListView is 4 changed lines, not 6 | Q v3.1 review | Corrected in §3.8 |
| **Q W23:** `messages(for sessionId:)` parameter name becomes misleading | Q v3.1 review | Add internal helper `sessionKey(for topicId:)` to clarify intent (§3.7.6) |
| **Kieran D1:** Raw SQL uses `strftime('%s','now')` but bridge columns are `.datetime` (ISO8601) | Kieran v3.2 review | Changed to `datetime('now')` — matches existing Migration005 convention (§3.5) |

---

## 1. Context

### 1.1 Problem

The iOS app's `BeeChatMobileViewModel` currently treats `Session` objects as user-facing topics. After connecting to the gateway, `syncBridge.fetchSessions()` returns **all** gateway sessions — including cron jobs, background agent sessions, and system sessions. The sidebar shows these as "Topics" which is wrong for a user-facing chat app.

### 1.2 Existing Working Architecture (BeeChat macOS / BeeChat-v5)

The iOS app already links against `BeeChatPersistence`, which includes the complete Topic architecture from BeeChat macOS. The key components that **already exist**:

| Component | Location | Status |
|-----------|----------|--------|
| `Topic` model | `BeeChat-v5/Sources/BeeChatPersistence/Models/Topic.swift` | ✅ Exists — needs `pendingGatewaySync` field |
| `TopicSessionBridge` model | Same file as `Topic` | ✅ Exists — needs UNIQUE constraint |
| `TopicRepository` | `BeeChat-v5/Sources/BeeChatPersistence/Repositories/TopicRepository.swift` | ✅ Exists — needs 5 new methods |
| `BeeChatSessionFilter` | `BeeChat-v5/Sources/BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift` | ✅ Exists — needs overload with injected repo |
| `BeeChatPersistenceStore` | `BeeChat-v5/Sources/BeeChatPersistence/BeeChatPersistenceStore.swift` | ✅ Exists — `topicRepo` is `private`, needs `public` accessor |
| `Session` model | `BeeChat-v5/Sources/BeeChatPersistence/Models/Session.swift` | ✅ Exists — unchanged |
| Migrations 001–011 | `BeeChat-v5/Sources/BeeChatPersistence/Database/DatabaseManager.swift` | ✅ All registered — need Migration012 |
| `TopicListView` | `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/TopicListView.swift` | ⚠️ Uses `Session` model — needs minimal fix |

### 1.3 Goal for Phase 1

Switch the iOS ViewModel from `Session` to `Topic` as the primary data model, using the **existing** BeeChat-v5 persistence layer with minimal additions. No UI changes beyond the ~6-line type fix in `TopicListView`. The sidebar will show user-created Topics instead of raw gateway Sessions.

---

## 2. Codebase Audit (Verified Against Source)

### 2.1 Existing `Topic` Model — Exact Current State

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Models/Topic.swift`

```swift
public struct Topic: Codable, UpsertableRecord {
    public static let databaseTableName = "topics"
    
    public var id: String                    // UUID string
    public var name: String                   // ← NOT "title"
    public var lastMessagePreview: String?
    public var lastActivityAt: Date?          // ← NOT "lastMessageAt"
    public var unreadCount: Int = 0
    public var sessionKey: String?            // ← Currently optional
    public var isArchived: Bool = false
    public var createdAt: Date
    public var updatedAt: Date
    public var metadataJSON: String?
    public var messageCount: Int = 0
    
    // upsertColumns excludes messageCount
    public static let upsertColumns: [Column] = [
        Column("name"), Column("lastMessagePreview"), Column("lastActivityAt"),
        Column("unreadCount"), Column("sessionKey"), Column("isArchived"),
        Column("updatedAt"), Column("metadataJSON")
    ]
}
```

**Changes needed:** Add `pendingGatewaySync: Bool = false` field + add to `upsertColumns`.

### 2.2 Existing `TopicSessionBridge` Model — Exact Current State

```swift
public struct TopicSessionBridge: Codable, UpsertableRecord {
    public static let databaseTableName = "topic_session_bridge"
    
    public var topicId: String               // PRIMARY KEY (not "id")
    public var spaceId: String = "default"
    public var openclawSessionKey: String    // ← NO UNIQUE constraint currently
    public var bridgeVersion: Int = 1
    public var status: String = "active"
    public var createdAt: Date
    public var updatedAt: Date
    public var lastSyncAt: Date?
    public var lastError: String?
    public var retryCount: Int = 0
    
    // upsertColumns excludes topicId (primary key) and createdAt
    public static let upsertColumns: [Column] = [
        Column("spaceId"), Column("openclawSessionKey"), Column("bridgeVersion"),
        Column("status"), Column("updatedAt"), Column("lastSyncAt"),
        Column("lastError"), Column("retryCount")
    ]
}
```

**Key facts:**
- `topicId` is the PRIMARY KEY (not `id`)
- `openclawSessionKey` has NO UNIQUE constraint (Migration012 will add one)
- The struct is defined **inside `Topic.swift`**, not a separate file
- It already conforms to `UpsertableRecord`

### 2.3 Existing `TopicRepository` — Exact Current State

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Repositories/TopicRepository.swift`

```swift
public class TopicRepository {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) { ... }
    
    // EXISTING methods:
    public func save(_ topic: Topic) throws { ... }
    public func fetchAllActive(limit: Int = 100) throws -> [Topic] { ... }  // orders by lastActivityAt DESC
    public func deleteCascading(_ id: String) throws { ... }                // deletes messages + bridge
    public func updateSessionKey(topicId:String, sessionKey: String) throws { ... }
    public func saveBridge(topicId: String, sessionKey: String) throws { ... }  // ← uses save(), NOT upsert
    public func resolveSessionKey(topicId: String) throws -> String? { ... }
    public func resolveTopicId(for sessionKey: String) throws -> String? { ... }
    public func resolveTopicIdBySuffix(gatewayKey:String, stripped:String) throws -> String? { ... }
    public func listAllBridgeSessionKeys() throws -> [(String, String)] { ... }
}
```

**Changes needed:** Add 5 new methods + fix `saveBridge()` to use `upsertPreservingCreatedAt()`.

### 2.4 Existing `BeeChatPersistenceStore` — Exact Current State

```swift
public class BeeChatPersistenceStore {
    private let dbManager: DatabaseManager       // ← PRIVATE
    private let sessionRepo: SessionRepository
    private let messageRepo: MessageRepository
    private let attachmentRepo: AttachmentRepository
    
    // NOTE: topicRepo is also private, created with default DatabaseManager.shared
    private let topicRepo = TopicRepository()   // ← PRIVATE, uses .shared
    
    // ... methods for sessions, messages, topics, attachments ...
}
```

**Key blocker (B1):** `dbManager` and `topicRepo` are both `private`. The iOS ViewModel needs access to a `TopicRepository` instance that uses the **same** `DatabaseManager` as `persistenceStore`. Since `persistenceStore` is the ViewModel's entry point, we need to expose `topicRepo` as a public property.

### 2.5 Existing `BeeChatSessionFilter` — Exact Current State

**File:** `BeeChat-v5/Sources/BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift`

```swift
public enum BeeChatSessionFilter {
    // Creates TopicRepository() per call — DEADLOCK on iOS @MainActor
    public static func isBeeChatSession(_ sessionKey: String) throws -> Bool { ... }
    public static func normalize(_ gatewayKey: String) throws -> String { ... }
}
```

**Changes needed:** Add 2 overloaded methods that accept an injected `TopicRepository`.

### 2.6 Existing `BeeChatMobileViewModel` — Exact Current State

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

```swift
@Observable @MainActor
public final class BeeChatMobileViewModel {
    public var topics: [Session] = []           // ← WRONG: should be [Topic]
    public var selectedTopicId: String? = nil
    // ...
    public func start() async throws {
        try persistenceStore.openDatabase(at: config.dbPath)
        let existing = try persistenceStore.fetchSessions(limit: 1, offset: 0)
        if existing.isEmpty { try seedTestData() }
        self.topics = try persistenceStore.fetchSessions(limit: 100, offset: 0)
        // ...
    }
    public func send(text: String, to sessionId: String) async throws {
        // Uses sessionId directly — no topic resolution
        _ = try await bridge.sendMessage(sessionKey: sessionId, text: text)
    }
    private func seedTestData() throws {
        // Creates Session objects, not Topic objects
    }
    private func refreshTopics() {
        self.topics = try persistenceStore.fetchSessions(limit: 100, offset: 0)
    }
}
```

### 2.7 Existing `TopicListView` — Exact Current State

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/TopicListView.swift`

```swift
struct TopicRow: View {
    let topic: Session    // ← WRONG: should be Topic

    var body: some View {
        // Uses: topic.title (→ Topic.name)
        //       topic.customName (→ no Topic equivalent, use topic.name)
        //       topic.lastMessageAt (→ Topic.lastActivityAt)
        //       topic.lastMessagePreview (→ same)
        //       topic.unreadCount (→ same)
    }
}
```

**Minimal fix:** Change `Session` to `Topic`, update 3 property names.

### 2.8 Migrations 001–011 — Verified

Migrations are registered inline in `DatabaseManager.swift` inside `migrate()`. There is **no** `Migrator.swift` file. Key migrations:

- **M005:** Creates `topics` + `topic_session_bridge` tables
- **M010:** Replaces topic-based message triggers with session-based triggers (this is why `Topic.messageCount` won't auto-update)
- **M011:** Adds `agentId` column to messages

Migration012 must be registered in the same `migrate()` method.

---

## 3. Phase 1 Changes

### 3.1 Expose `topicRepo` on `BeeChatPersistenceStore`

**File:** `BeeChat-v5/Sources/BeeChatPersistence/BeeChatPersistenceStore.swift`

**Change:** Make `topicRepo` public (not private).

```swift
// BEFORE:
private let topicRepo = TopicRepository()

// AFTER:
public let topicRepo: TopicRepository   // ← public, not private
```

**Also change the init** so it uses the same `dbManager`:

```swift
// BEFORE:
public init(dbManager: DatabaseManager = .shared) {
    self.dbManager = dbManager
    self.sessionRepo = SessionRepository(dbManager: dbManager)
    self.messageRepo = MessageRepository(dbManager: dbManager)
    self.attachmentRepo = AttachmentRepository(dbManager: dbManager)
}

// AFTER:
public init(dbManager: DatabaseManager = .shared) {
    self.dbManager = dbManager
    self.sessionRepo = SessionRepository(dbManager: dbManager)
    self.messageRepo = MessageRepository(dbManager: dbManager)
    self.attachmentRepo = AttachmentRepository(dbManager: dbManager)
    self.topicRepo = TopicRepository(dbManager: dbManager)  // ← same dbManager
}
```

**Rationale:** The iOS ViewModel creates `persistenceStore = BeeChatPersistenceStore()` then calls `persistenceStore.openDatabase(at:)`. After opening, `persistenceStore.topicRepo` will use the same `DatabaseManager.shared` singleton (which has the open DB pool). This eliminates the deadlock risk from creating fresh `TopicRepository()` instances.

**Note:** `dbManager` remains `private` — we don't need to expose it. Only `topicRepo` needs to be public.

### 3.2 Add `pendingGatewaySync` Field to `Topic` Model

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Models/Topic.swift`

Add one field to the existing `Topic` struct:

```swift
public var pendingGatewaySync: Bool = false
```

Update `init` to include it:

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
) {
    // ... existing assignments ...
    self.pendingGatewaySync = pendingGatewaySync
}
```

Update `upsertColumns`:

```swift
public static let upsertColumns: [Column] = [
    Column("name"), Column("lastMessagePreview"), Column("lastActivityAt"),
    Column("unreadCount"), Column("sessionKey"), Column("isArchived"),
    Column("updatedAt"), Column("metadataJSON"),
    Column("pendingGatewaySync")            // NEW
]
```

**Rationale:** Kieran B5 — offline topic creation. Topics created while disconnected need a flag so the `connect()` flow can reconcile them with the gateway.

### 3.3 Add 5 New Methods to `TopicRepository`

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Repositories/TopicRepository.swift`

#### 3.3.1 `create(name:pendingGatewaySync:)` — Create topic with upfront gateway key

```swift
/// Create a new topic with an upfront gateway-format session key.
/// The key is generated as "agent:main:<topicId>" (lowercase) to match
/// gateway conventions. No nil sessionKey window.
///
/// Convention: Topic IDs are uppercase UUIDs. Gateway keys use the lowercase
/// form: "agent:main:<topicId.lowercased()>".
/// resolveTopicIdBySuffix() handles case-insensitive lookup.
///
/// - Parameter name: Display name for the topic (non-empty, max 80 chars)
/// - Parameter pendingGatewaySync: true if created offline (needs reconciliation on connect)
/// - Returns: The created Topic with its generated session key
public func create(name: String, pendingGatewaySync: Bool = false) throws -> Topic {
    let topicId = UUID().uuidString
    let gatewayKey = "agent:main:\(topicId.lowercased())"
    
    let topic = Topic(
        id: topicId,
        name: name,
        sessionKey: gatewayKey,
        pendingGatewaySync: pendingGatewaySync
    )
    
    try save(topic)
    try saveBridge(topicId: topicId, sessionKey: gatewayKey)
    
    return topic
}
```

**Key decisions:**
- `sessionKey` is **always** set upfront — no nil window (Kieran B2)
- `pendingGatewaySync` defaults to `false` for normal creation, `true` for offline creation
- Topic ID is uppercase UUID, gateway key is `agent:main:<lowercase>` — consistent with macOS

#### 3.3.2 `fetchAllActiveWithCounts()` — Computed message counts

```swift
/// Fetch active topics with computed message counts via SQL JOIN.
/// M010 replaced topic-based triggers with session-based triggers,
/// so Topic.messageCount must be computed from the messages table.
///
/// The computed column is aliased as "messageCount" (matching Topic's
/// CodingKeys) so GRDB decodes it correctly into the Topic struct.
///
/// Ordering: lastActivityAt DESC (chronological, most recent first).
/// NULL lastActivityAt rows sort last (COALESCE fallback to createdAt).
public func fetchAllActiveWithCounts(limit: Int = 100) throws -> [Topic] {
    try dbManager.reader.read { db in
        try Topic.fetchAll(db, sql: """
            SELECT t.*,
                   COALESCE((
                       SELECT COUNT(*) FROM messages m
                       JOIN topic_session_bridge b ON b.openclawSessionKey = m.sessionId
                       WHERE b.topicId = t.id
                   ), 0) as messageCount
            FROM topics t
            WHERE t.isArchived = 0
            ORDER BY COALESCE(t.lastActivityAt, t.createdAt) DESC
            LIMIT \(limit)
        """)
    }
}
```

**Key decisions:**
- Column alias is `messageCount` (not `computedMessageCount`) — GRDB decodes via `CodingKeys`
- JOIN uses `topic_session_bridge` because messages have `sessionId`, not `topicId`
- `COALESCE(t.lastActivityAt, t.createdAt)` handles NULL ordering — Mel's recommendation

#### 3.3.3 `markSynced(topicId:)` — Clear pending sync flag

```swift
/// Clear the pendingGatewaySync flag after successful reconciliation with the gateway.
public func markSynced(topicId: String) throws {
    try dbManager.write { db in
        try db.execute(
            sql: "UPDATE topics SET pendingGatewaySync = 0, updatedAt = ? WHERE id = ?",
            arguments: [Date(), topicId]
        )
    }
}
```

#### 3.3.4 `fetchPendingSyncTopics()` — Get topics needing reconciliation

```swift
/// Fetch all topics with pendingGatewaySync = true.
/// Called on connect to reconcile offline-created topics with the gateway.
public func fetchPendingSyncTopics() throws -> [Topic] {
    try dbManager.reader.read { db in
        try Topic.filter(Column("pendingGatewaySync") == true).fetchAll(db)
    }
}
```

#### 3.3.5 `syncMetadataFromSessions()` — Update topics from gateway session data

```swift
/// Update topic metadata from gateway session data.
/// Called after fetchSessions() to sync the latest title, preview, unread count, etc.
///
/// Session = gateway truth (server-side data).
/// Topic = user-facing truth (local data + metadata from server).
/// This method merges server-side metadata into local topics.
///
/// IMPORTANT: Pass only BeeChat sessions (filtered via BeeChatSessionFilter),
/// not all gateway sessions. Non-BeeChat sessions (cron, system, etc.) won't have
/// bridge entries and would be skipped, but filtering at the call site avoids
/// unnecessary DB lookups (W19).
public func syncMetadataFromSessions(_ sessions: [Session]) throws {
    try dbManager.write { db in
        for session in sessions {
            // Find the topic for this session via bridge table
            guard let topicId = try String.fetchOne(db, sql:
                "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?",
                arguments: [session.id]
            ) else { continue }
            
            // Update topic metadata from session data
            try db.execute(sql: """
                UPDATE topics SET
                    lastMessagePreview = ?,
                    lastActivityAt = ?,
                    unreadCount = ?,
                    updatedAt = ?
                WHERE id = ?
            """, arguments: [
                session.lastMessagePreview,
                session.lastMessageAt ?? session.updatedAt,
                session.unreadCount,
                Date(),
                topicId
            ])
        }
    }
}
```

**Rationale:** Q W3 — `fetchSessions()` returns `[Session]`, not `[Topic]`. The ViewModel needs a way to merge gateway metadata into local topics. This method keeps the sync logic in the repository layer.

### 3.4 Add `BeeChatSessionFilter` Overloads

**File:** `BeeChat-v5/Sources/BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift`

Add 2 overloaded methods that accept an injected `TopicRepository`:

```swift
extension BeeChatSessionFilter {
    /// Check whether a session key maps to a known BeeChat topic,
    /// using an injected TopicRepository to avoid deadlock on iOS @MainActor.
    ///
    /// Use this overload on iOS where the ViewModel holds a reference to
    /// the shared TopicRepository. The parameterless overload remains
    /// available for macOS (which doesn't have @MainActor constraints).
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

**Rationale:** Q B2 / Kieran B9 — the existing `isBeeChatSession()` creates a fresh `TopicRepository()` per call, which can deadlock on iOS `@MainActor`. The overload accepts an injected instance. macOS stays on the old path. No macOS code changes needed.

### 3.5 Fix `saveBridge()` — Use Upsert Instead of Insert

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Repositories/TopicRepository.swift`

**Change:** Replace `save()` with `upsertPreservingCreatedAt()`:

```swift
// BEFORE:
public func saveBridge(topicId: String, sessionKey: String) throws {
    try dbManager.write { db in
        var bridge = TopicSessionBridge(
            topicId: topicId,
            openclawSessionKey: sessionKey
        )
        try bridge.save(db)  // ← INSERT ONLY — crashes on duplicate
    }
}

// AFTER:
public func saveBridge(topicId: String, sessionKey: String) throws {
    try dbManager.write { db in
        // Raw SQL upsert — `upsertPreservingCreatedAt()` hardcodes `onConflict: ["id"]`
        // but TopicSessionBridge has no `id` column (PK is `topicId`).
        // B11 fix: use explicit ON CONFLICT(topicId) clause.
        try db.execute(sql: """
            INSERT INTO topic_session_bridge
                (topicId, spaceId, openclawSessionKey, bridgeVersion, status, createdAt, updatedAt)
            VALUES
                (?, 'default', ?, 1, 'active', datetime('now'), datetime('now'))
            ON CONFLICT(topicId) DO UPDATE SET
                openclawSessionKey = excluded.openclawSessionKey,
                updatedAt = excluded.updatedAt
        """, arguments: [topicId, sessionKey])
    }
}
```

**Rationale:** Q H1 + Q B11 — the original `save()` was insert-only (crashed on duplicate). `upsertPreservingCreatedAt()` was evaluated as a replacement, but it hardcodes `onConflict: ["id"]` and `TopicSessionBridge` has no `id` column — its PK is `topicId`. GRDB passes the `onConflict` columns directly to SQLite's `ON CONFLICT` clause, so `ON CONFLICT(id)` would fail at runtime because the column doesn't exist. The raw SQL upsert uses `ON CONFLICT(topicId)` which matches the actual primary key.

**⚠️ UNIQUE constraint on `openclawSessionKey`:** The `ON CONFLICT(topicId)` clause handles duplicate `topicId` entries (same topic re-bridged). If a **different** topic tries to bridge to a session key that already has a bridge entry, the UNIQUE index on `openclawSessionKey` (added by Migration012) will cause an `SQLITE_CONSTRAINT_UNIQUE` error. This is **correct defensive behaviour** — two topics should never share a session key. The application logic in `connect()` (step 4) checks `resolveTopicId()` before creating, which prevents this at the app layer. If it still occurs (e.g., race condition), the `do/catch` in the `connect()` path (§3.7.2) handles it gracefully.

### 3.6 Migration012 — Add `pendingGatewaySync` + UNIQUE Index

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Database/DatabaseManager.swift`

Register a new migration after M011, inside the existing `migrate()` method:

```swift
migrator.registerMigration("Migration012_AddPendingGatewaySync") { db in
    // 1. Add pendingGatewaySync column to topics table
    guard try db.tableExists("topics") else { return }
    
    let columns = try db.columns(in: "topics").map { $0.name }
    if !columns.contains("pendingGatewaySync") {
        try db.alter(table: "topics") { t in
            t.add(column: "pendingGatewaySync", .boolean).defaults(to: false)
        }
    }
    
    // 2. Add UNIQUE index on openclawSessionKey in bridge table
    // This prevents two topics from bridging to the same gateway session.
    if try db.tableExists("topic_session_bridge") {
        try db.execute(sql: "DROP INDEX IF EXISTS idx_bridge_session_key")
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_bridge_session_key
            ON topic_session_bridge(openclawSessionKey)
        """)
    }
}
```

**Key decisions:**
- Uses `ALTER TABLE` (safe, preserves existing data) rather than recreating the table
- Uses `GUARD` + `columns.contains()` for idempotency — safe to run on existing databases
- UNIQUE index on `openclawSessionKey` (Kieran B7) — prevents non-deterministic lookup
- **No data migration from Session to Topic** — the seed data is rewritten directly (§3.9), and fresh installs start with Topic-based data. Existing installs that already have Session data will see an empty topic list until they connect to the gateway (which creates topics via `syncMetadataFromSessions()`)

### 3.7 ViewModel — Switch to Topic-Based Data

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

#### 3.7.1 Change `topics` property type and add `topicRepo`

```swift
// BEFORE:
public var topics: [Session] = []

// AFTER:
public var topics: [Topic] = []          // ← Topic, not Session
```

Add `topicRepo` lazy initialization in `start()`:

```swift
public func start() async throws {
    try persistenceStore.openDatabase(at: config.dbPath)
    // topicRepo uses the same DatabaseManager as persistenceStore
    // (DatabaseManager.shared is a singleton that picks up the open DB pool)
    
    let existingTopics = try persistenceStore.topicRepo.fetchAllActive()
    if existingTopics.isEmpty {
        try seedTestData()
    }
    
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    
    if selectedTopicId == nil, let first = topics.first {
        selectedTopicId = first.id
    }
}
```

#### 3.7.2 Update `connect()` — Filter sessions + sync metadata + reconcile

```swift
public func connect() async {
    // ... (gateway config + bridge creation unchanged) ...
    
    do {
        try await bridge.start()
        
        // 1. Reconcile pending topics (offline creation)
        let pendingTopics = try persistenceStore.topicRepo.fetchPendingSyncTopics()
        for topic in pendingTopics {
            guard let sessionKey = topic.sessionKey else { continue }
            do {
                _ = try await bridge.sendMessage(sessionKey: sessionKey, text: "Start", topic: topic)
                // Only mark synced after confirmed success (W16)
                try persistenceStore.topicRepo.markSynced(topicId: topic.id)
            } catch {
                print("[ViewModel] Failed to reconcile topic \(topic.id): \(error)")
                // Leave pendingGatewaySync = true for next reconnect attempt
            }
        }
        
        // 2. Fetch sessions from gateway
        let sessions = try await bridge.fetchSessions()
        
        // 3. Filter to only BeeChat sessions (using injected repo)
        let beeChatSessions = sessions.filter { session in
            (try? BeeChatSessionFilter.isBeeChatSession(session.id, topicRepo: persistenceStore.topicRepo)) == true
        }
        
        // 4. For each BeeChat session without a topic, create one
        for gatewaySession in beeChatSessions {
            if try persistenceStore.topicRepo.resolveTopicId(for: gatewaySession.id) == nil {
                // New gateway session → create local topic
                let topic = Topic(
                    id: UUID().uuidString,
                    name: gatewaySession.title ?? gatewaySession.customName ?? "Conversation",
                    lastMessagePreview: gatewaySession.lastMessagePreview,
                    lastActivityAt: gatewaySession.lastMessageAt ?? gatewaySession.updatedAt,
                    unreadCount: gatewaySession.unreadCount,
                    sessionKey: gatewaySession.id
                )
                try persistenceStore.topicRepo.save(topic)
                do {
                    try persistenceStore.topicRepo.saveBridge(topicId: topic.id, sessionKey: gatewaySession.id)
                } catch {
                    // UNIQUE constraint on openclawSessionKey — another topic already bridges
                    // to this session key (shouldn't happen but defensive). Skip bridge creation.
                    print("[ViewModel] Bridge already exists for session \(gatewaySession.id): \(error)")
                }
            }
        }
        
        // 5. Sync metadata from BeeChat sessions to local topics (W19 — only BeeChat sessions)
        try persistenceStore.topicRepo.syncMetadataFromSessions(beeChatSessions)
        
        // 6. Refresh topic list
        self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
        
        // 7. Auto-select first topic
        if selectedTopicId == nil, let first = topics.first {
            selectedTopicId = first.id
        }
        
        // 8. Session subscription is handled by SyncBridge.start() (already called above)
        //    No separate sessionsSubscribe() call needed — rpcClient is private (Q W21)
        //    and start() already subscribes to session updates.
        
        startMessageObservation()
    } catch {
        connectionState = .error
        connectionError = error.localizedDescription
    }
}
```

#### 3.7.3 Update `refreshTopics()`

```swift
private func refreshTopics() {
    do {
        self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    } catch {
        print("[ViewModel] Failed to refresh topics: \(error)")
    }
}
```

#### 3.7.4 Update `send()` — Resolve Topic ID to session key

```swift
public func send(text: String, to topicId: String) async throws {
    // Resolve topic ID to session key
    guard let topic = topics.first(where: { $0.id == topicId }),
          let sessionKey = topic.sessionKey else {
        throw NSError(domain: "BeeChat", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Topic has no session key"
        ])
    }
    
    guard let bridge = syncBridge else {
        // Offline-only: write to local DB
        let idempotencyKey = UUID().uuidString
        let msg = BeeChatPersistence.Message(
            id: idempotencyKey,
            sessionId: sessionKey,
            role: "user",
            content: text,
            senderName: "Adam",
            senderId: "adam",
            timestamp: Date()
        )
        try persistenceStore.saveMessage(msg)
        return
    }
    
    // Pass topic for context injection (Q W5)
    _ = try await bridge.sendMessage(sessionKey: sessionKey, text: text, topic: topic)
}
```

**Key changes from v1/v2:**
- Parameter renamed from `sessionId` to `topicId` (clarity)
- Resolves topic ID → session key via `topic.sessionKey`
- Passes `topic` parameter to `sendMessage()` for context injection (Q W5)
- Offline fallback uses `sessionKey` (not raw `topicId`)

#### 3.7.5 Reconnect path — Re-subscribe + reconcile

The `reconnect()` method already calls `disconnect()` then `connect()`. With the `connect()` changes above (steps 1, 7, 8), this now:
1. Reconciles any pending offline topics
2. Re-subscribes to `sessions.subscribe`
3. Refreshes the topic list from local DB

No additional changes needed for reconnect.

### 3.8 Minimal UI Fix — `TopicListView`

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/TopicListView.swift`

This is the only UI change in Phase 1. It's a ~4-line type + property name update (Q v3.1 correction — 4 lines, not 6):

```swift
// BEFORE:
struct TopicRow: View {
    let topic: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.title ?? topic.customName ?? "Untitled")
            // ...
            Text(topic.lastMessageAt?.formatted(.relative(presentation: .named)) ?? "")
            // ...

// AFTER:
struct TopicRow: View {
    let topic: Topic

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.name)
            // ...
            Text(topic.lastActivityAt?.formatted(.relative(presentation: .named)) ?? "")
            // ...
```

**Property mapping:**

| `Session` property | `Topic` property | Notes |
|--------------------|------------------|-------|
| `.title ?? .customName ?? "Untitled"` | `.name` | Topic names are always set (non-optional) |
| `.lastMessageAt` | `.lastActivityAt` | Same semantics |
| `.lastMessagePreview` | `.lastMessagePreview` | Same name |
| `.unreadCount` | `.unreadCount` | Same name |

**Scope justification:** This is not a UI redesign — it's a type change from `Session` to `Topic` with property name mapping. The visual appearance is identical.

### 3.7.6 Message Loading — Topic→Session Key Resolution

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

After switching `topics` from `[Session]` to `[Topic]`, `selectedTopicId` holds a Topic UUID
(e.g. `"ABC123"`), but messages are keyed by `sessionId` (e.g. `"agent:main:abc123"`).
Without resolution, `loadMessages()` and `streamingContent` return nothing (Q B12).

Add a helper method on the ViewModel:

```swift
/// Resolve a Topic ID to the session key used for message lookups.
/// Messages are keyed by sessionId (gateway key), not topicId.
private func sessionKey(for topicId: String) -> String? {
    return topics.first(where: { $0.id == topicId })?.sessionKey
}
```

Update `loadMessages()` to use it:

```swift
// BEFORE:
let messages = try persistenceStore.fetchMessages(for: selectedTopicId)

// AFTER:
guard let key = sessionKey(for: selectedTopicId) else { return [] }
let messages = try persistenceStore.fetchMessages(for: key)
```

Update `streamingContent` dictionary keying:

```swift
// BEFORE:
streamingContent[selectedTopicId]

// AFTER:
if let key = sessionKey(for: selectedTopicId) {
    streamingContent[key]
}
```

**Rationale (Q B12 + Q W23):** The `messages(for sessionId:)` parameter name is correct —
messages ARE keyed by sessionId in the database. The ViewModel needs a resolution step
because its internal state (`selectedTopicId`) uses Topic IDs. The `sessionKey(for:)` helper
makes this explicit rather than hiding it in inline lookups.

### 3.8 Seed Data — Create Topics, Not Sessions

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

Replace `seedTestData()` entirely:

```swift
private func seedTestData() throws {
    let topicRepo = persistenceStore.topicRepo
    
    // Create 3 seed topics with gateway-format keys
    let topic1 = try topicRepo.create(name: "Welcome to BeeChat")
    let topic2 = try topicRepo.create(name: "Solar Dashboard Help")
    let topic3 = try topicRepo.create(name: "Project Planning")
    
    // Save test messages linked to topic1's session key
    guard let sessionKey = topic1.sessionKey else { return }
    let msgs: [BeeChatPersistence.Message] = [
        BeeChatPersistence.Message(
            id: "m1", sessionId: sessionKey, role: "user",
            content: "Hello Bee! How are you today?",
            senderName: "Adam", senderId: "adam",
            timestamp: Date().addingTimeInterval(-10)
        ),
        BeeChatPersistence.Message(
            id: "m2", sessionId: sessionKey, role: "assistant",
            content: "Hey Adam! I'm doing great - ready to help with anything you need. 🐝",
            senderName: "Bee", senderId: "bee",
            timestamp: Date().addingTimeInterval(-5)
        ),
        BeeChatPersistence.Message(
            id: "m3", sessionId: sessionKey, role: "user",
            content: "Can you show me my sessions list?",
            senderName: "Adam", senderId: "adam",
            timestamp: Date()
        ),
    ]
    for m in msgs { try persistenceStore.saveMessage(m) }
}
```

**Key decisions:**
- Uses `topicRepo.create(name:)` which generates upfront gateway keys
- Messages link via `sessionKey` (which matches `messages.sessionId`)
- No `Session` objects created — topics are the seed data
- Seed messages still use the `Message` model with `sessionId` (unchanged)

---

## 4. Conventions & Invariants

These are documented here to prevent future confusion:

### 4.1 Topic ID Convention

- Topic IDs are **uppercase UUIDs** (Swift's `UUID().uuidString` produces uppercase)
- Gateway session keys use the **lowercase suffix**: `agent:main:<topicId.lowercased()>`
- `resolveTopicIdBySuffix()` does `UPPER(id)` matching for case-insensitive lookup
- This is consistent with the macOS implementation

### 4.2 Two-Model Architecture

- **Session** = gateway truth (server-side data, synced from the gateway)
- **Topic** = user-facing truth (local data + metadata from server)
- Bridge table (`topic_session_bridge`) links them
- Messages have `sessionId` (gateway key), NOT `topicId`
- Message counts are computed via SQL JOIN through the bridge table

### 4.3 Ordering Convention

- **iOS:** `lastActivityAt DESC` (chronological, most recent first) — standard chat app UX
- **macOS:** `name.localizedCaseInsensitiveCompare()` (alphabetical) — desktop convention
- This divergence is **deliberate** and documented

### 4.4 Session Key Format

- Format: `agent:main:<uuid-lowercase>`
- `sessionKey` on Topic is **never nil** after creation (upfront key pattern)
- The `pendingGatewaySync` flag indicates whether the gateway has confirmed the session exists
- On `connect()`, pending topics are reconciled by sending a bootstrap message

---

## 5. Scope Boundary

### In Scope (Phase 1)

1. Add `pendingGatewaySync` to `Topic` model + update `upsertColumns`
2. Add 5 new methods to `TopicRepository`
3. Fix `saveBridge()` to use `upsertPreservingCreatedAt()`
4. Add 2 overloaded methods to `BeeChatSessionFilter`
5. Expose `topicRepo` as `public` on `BeeChatPersistenceStore`
6. Register `Migration012` in `DatabaseManager.migrate()`
7. Rewrite `seedTestData()` to create Topics
8. Update ViewModel: `topics: [Topic]`, topic-based `start()`, `connect()`, `send()`, `refreshTopics()`
9. Update `TopicListView`: ~6-line type/property fix (`Session` → `Topic`, 4 property name changes + navigation title + type declaration — Q v3 correction)

### Known Limitations (Deferred)

- **W17:** `connect()` should guard against double-invocation (add `guard connectionState != .connected else { return }`) — defer to Phase 2
- **W18:** No retry limit for stuck `pendingGatewaySync` topics — defer to Phase 2
- **W20:** `upsertPreservingCreatedAt()` may need custom upsert if UNIQUE on `openclawSessionKey` causes edge-case failures — Q must verify at runtime
- **Q note:** `BeeChatView` not audited in Phase 1 scope — may also reference `Session` properties, needs checking during implementation
- **Q B11:** Raw SQL upsert replaces `upsertPreservingCreatedAt()` for `saveBridge()` — verified correct for `topicId` PK
- **Q B12:** Topic→session key resolution required in `loadMessages()` and `streamingContent` — added §3.7.6

- New Topic creation UI (Phase 2)
- Swipe actions, archive, delete UI (Phase 3)
- Empty states (Phase 3)
- Offline/error states in UI (Phase 3)
- iPad popover (Phase 3)
- `ValueObservation` replacing 500ms polling (Phase 2 or later)
- Keychain token storage (Phase 2 or later)
- `sessions.changed` event propagation through Topic layer (Phase 2)
- Import recent sessions flow (Phase 3)
- VoiceOver / Dynamic Type (Phase 3)
- GRDB `ValueObservation` for live topic updates (Phase 2)

---

## 6. Success Criteria

### 6.1 Build

- [ ] BeeChat-v5 compiles (macOS + iOS)
- [ ] BeeChat-Mobile compiles (iOS simulator)

### 6.2 Database

- [ ] Migration012 runs without errors on existing database
- [ ] Fresh install: `topics` table has `pendingGatewaySync` column (default `false`)
- [ ] Fresh install: `topic_session_bridge` has UNIQUE index on `openclawSessionKey`
- [ ] Upgrade: existing data preserved, new column added with `false` default
- [ ] No data migration from Session → Topic (fresh Topic data only)

### 6.3 Seed Data

- [ ] Fresh install creates 3 seed **Topics** (not Sessions)
- [ ] Topics have gateway-format session keys (`agent:main:<uuid>`)
- [ ] Test messages are linked to topic1's session key
- [ ] Topics appear in `topicRepo.fetchAllActiveWithCounts()`

### 6.4 ViewModel

- [ ] `topics` property is `[Topic]` (not `[Session]`)
- [ ] `start()` loads topics from TopicRepository
- [ ] `connect()` filters sessions through `BeeChatSessionFilter.isBeeChatSession(_:topicRepo:)`
- [ ] `connect()` creates topics for new BeeChat sessions
- [ ] `connect()` syncs metadata from sessions to topics
- [ ] `connect()` reconciles pending offline topics
- [ ] `connect()` re-subscribes to `sessions.subscribe`
- [ ] `send(text:to:)` resolves topic ID → session key before sending
- [ ] `send()` passes topic for context injection

### 6.5 Bridge Table

- [ ] `saveBridge()` uses raw SQL upsert with `ON CONFLICT(topicId)` (not `upsertPreservingCreatedAt()`)
- [ ] Duplicate `topicId` upserts correctly (last-write-wins on `openclawSessionKey`)
- [ ] UNIQUE constraint on `openclawSessionKey` prevents two topics sharing a session key
- [ ] `do/catch` in `connect()` handles UNIQUE constraint violations gracefully

### 6.6 Message Loading

- [ ] `loadMessages()` resolves topic ID to session key before querying
- [ ] `streamingContent` dictionary keyed by session key, not topic ID
- [ ] `sessionKey(for:)` helper returns `nil` for unknown topics (graceful, no crash)

### 6.7 macOS Regression

- [ ] BeeChat macOS still builds and runs
- [ ] macOS app still shows topics correctly
- [ ] No change to macOS Topic architecture

---

## 7. Implementation Steps (Q)

1. Add `pendingGatewaySync` field to `Topic` struct + `init` + `upsertColumns`
2. Expose `topicRepo` as `public` on `BeeChatPersistenceStore` + update init
3. Add 5 methods to `TopicRepository`: `create(name:pendingGatewaySync:)`, `fetchAllActiveWithCounts()`, `markSynced(topicId:)`, `fetchPendingSyncTopics()`, `syncMetadataFromSessions(_:)`
4. Fix `saveBridge()` to use `upsertPreservingCreatedAt()`
5. Add 2 `BeeChatSessionFilter` overloads with `topicRepo` parameter
6. Register `Migration012` in `DatabaseManager.migrate()`
7. Rewrite `seedTestData()` in iOS ViewModel
8. Update iOS ViewModel: `topics` type, `start()`, `connect()`, `send()`, `refreshTopics()`
9. Update `TopicListView`: change `Session` → `Topic`, update 4 property names (Q W22)
10. Add `sessionKey(for topicId:)` helper to ViewModel + update `loadMessages()` and `streamingContent` keying (B12)
11. Build and test on iOS simulator
12. Verify macOS BeeChat still works

---

## 8. Rollback

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