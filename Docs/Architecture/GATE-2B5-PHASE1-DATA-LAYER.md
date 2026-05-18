# Gate 2B.5 — Phase 1: Data Layer Spec

**Status:** DRAFT — Pending team review  
**Date:** 2026-05-18  
**Depends on:** Gate 2B (live gateway connection) ✅  
**Blocks:** Phase 2 (ViewModel wiring), Phase 3 (UI overhaul), Phase 4 (Integration test)

---

## Purpose

Phase 1 builds the data foundation: Topic model, TopicRepository, database migration, bridge table, and session filter. No UI changes. No ViewModel changes. The app should look and behave exactly as it does now after Phase 1 — but the data layer underneath will be ready for Phase 2 to switch on.

**Key principle:** Phase 1 must not break the existing app. All new code runs alongside existing code. The switch from Sessions to Topics happens in Phase 2.

---

## 1. Topic Model

### 1.1 Definition

Add `Topic` to `BeeChatPersistence` (shared v5 package) alongside the existing `Session` model. Do NOT remove or modify `Session`.

```swift
// BeeChatPersistence/Models/Topic.swift

struct Topic: Codable, Equatable, Identifiable {
    var id: UUID                    // Primary key
    var name: String               // User-visible topic name (max 80 chars)
    var sessionKey: String         // Gateway session key format: "agent:main:<topicIdLowercased>"
    var isArchived: Bool           // Soft delete — hidden from topic list
    var pendingGatewaySync: Bool    // Created offline, needs reconciliation on connect
    var createdAt: Date            // Topic creation timestamp
    var lastActivityAt: Date       // Updated on every message send/receive
    var lastMessagePreview: String? // Truncated preview of last message (max 100 chars)
}
```

### 1.2 Design Decisions

| Decision | Rationale |
|----------|-----------|
| `sessionKey` is never nil | Eliminates B1/B3 blocker. Generated upfront as `"agent:main:\(id.uuidString.lowercased())"`. |
| `pendingGatewaySync` flag | Handles B5 blocker. Offline-created topics reconcile on reconnect. |
| `lastActivityAt` not `updatedAt` | Matches macOS convention and Mel's M2 (chronological ordering). |
| `lastMessagePreview` on Topic | Avoids JOIN for sidebar previews. Updated by message sends. |
| No `messageCount` column | B3 blocker: triggers are unreliable. Computed via SQL in repository. |

### 1.3 Session Key Format

```swift
// Topic.swift — computed property for consistency
extension Topic {
    var resolvedSessionKey: String {
        // Always returns the gateway-format key
        // Format: "agent:main:<topicIdLowercased>"
        return sessionKey  // Already in gateway format, never nil
    }
}
```

The session key is generated at topic creation time:
```swift
let topicId = UUID()
let sessionKey = "agent:main:\(topicId.uuidString.lowercased())"
let topic = Topic(id: topicId, name: name, sessionKey: sessionKey, ...)
```

---

## 2. TopicRepository

### 2.1 Interface

```swift
// BeeChatPersistence/Repositories/TopicRepository.swift

final class TopicRepository {
    init(db: DatabaseWriter)  // Single instance, injected into ViewModel
    
    // Core CRUD
    func create(name: String) throws -> Topic
    func fetchAllActive() throws -> [Topic]       // WHERE isArchived = false, ORDER BY lastActivityAt DESC
    func fetchAll() throws -> [Topic]               // Including archived
    func fetch(byId: UUID) throws -> Topic?
    func fetch(bySessionKey: String) throws -> Topic?
    func archive(id: UUID) throws                  // Soft delete
    func unarchive(id: UUID) throws
    func delete(id: UUID) throws                    // Hard delete — cascading
    func updateLastActivity(id: UUID, preview: String?) throws
    func markSynced(id: UUID) throws                // pendingGatewaySync = false
    func fetchPendingSync() throws -> [Topic]       // WHERE pendingGatewaySync = true
}
```

### 2.2 Computed Message Count

No `messageCount` column on Topic. No triggers. Computed via SQL at query time:

```swift
func fetchAllActive() throws -> [Topic] {
    try db.read { db in
        let sql = """
            SELECT t.*, COUNT(m.id) as messageCount
            FROM topic t
            LEFT JOIN message m ON m.topicId = t.id
            WHERE t.isArchived = false
            GROUP BY t.id
            ORDER BY t.lastActivityAt DESC
        """
        return try Row.fetchAll(db, sql: sql).map { row in
            Topic(
                id: row["id"],
                name: row["name"],
                sessionKey: row["sessionKey"],
                isArchived: row["isArchived"],
                pendingGatewaySync: row["pendingGatewaySync"],
                createdAt: row["createdAt"],
                lastActivityAt: row["lastActivityAt"],
                lastMessagePreview: row["lastMessagePreview"]
            )
        }
    }
}
```

**Note:** The `messageCount` is computed but not stored on `Topic`. It's returned separately or via a `TopicWithCount` wrapper if the UI needs it. This avoids the B3 blocker (trigger reliability).

### 2.3 Injection Pattern

`TopicRepository` is a single instance created in `BeeChatApp` and injected into the ViewModel:

```swift
// BeeChatApp.swift
@StateObject private var viewModel: ChatViewModel

init() {
    let db = /* existing database setup */
    let topicRepo = TopicRepository(db: db)
    _viewModel = StateObject(wrappedValue: ChatViewModel(topicRepository: topicRepo))
}
```

This solves B2 blocker — no per-call instantiation, no deadlock risk.

---

## 3. Database Migration

### 3.1 Migration010 — Create Topics Table

```swift
// BeeChatPersistence/Migrations/Migration010_CreateTopics.swift

static let createTopics = Migration(
    "010_CreateTopics"
) { db in
    // Create topic table
    try db.create(table: "topic") { t in
        t.column("id", .text).primaryKey()  // UUID as text
        t.column("name", .text).notNull()
        t.column("sessionKey", .text).notNull()
        t.column("isArchived", .boolean).notNull().defaults(to: false)
        t.column("pendingGatewaySync", .boolean).notNull().defaults(to: false)
        t.column("createdAt", .datetime).notNull()
        t.column("lastActivityAt", .datetime).notNull()
        t.column("lastMessagePreview", .text)
    }
    
    // Create bridge table
    try db.create(table: "topic_session_bridge") { t in
        t.column("id", .text).primaryKey()  // UUID as text
        t.column("topicId", .text).notNull().references("topic", onDelete: .cascade)
        t.column("openclawSessionKey", .text).notNull().unique()  // B6: UNIQUE constraint
        t.column("createdAt", .datetime).notNull()
    }
    
    // Indexes for lookups
    try db.create(index: "idx_topic_sessionKey", on: "topic", columns: ["sessionKey"])
    try db.create(index: "idx_topic_isArchived", on: "topic", columns: ["isArchived"])
    try db.create(index: "idx_topic_lastActivityAt", on: "topic", columns: ["lastActivityAt"])
    try db.create(index: "idx_bridge_topicId", on: "topic_session_bridge", columns: ["topicId"])
    try db.create(index: "idx_bridge_sessionKey", on: "topic_session_bridge", columns: ["openclawSessionKey"])
    
    // Convert existing Session seed data to Topics (B8)
    // Only if session table has seed data
    let sessions = try Session.fetchAll(db)
    for session in sessions {
        let topicId = UUID()
        let sessionKey = "agent:main:\(topicId.uuidString.lowercased())"
        try db.execute(
            sql: "INSERT INTO topic (id, name, sessionKey, isArchived, pendingGatewaySync, createdAt, lastActivityAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [topicId.uuidString, session.title ?? "Untitled", sessionKey, false, false, session.createdAt, session.lastMessageAt ?? session.createdAt]
        )
        
        // Create bridge entry
        let bridgeId = UUID()
        try db.execute(
            sql: "INSERT INTO topic_session_bridge (id, topicId, openclawSessionKey, createdAt) VALUES (?, ?, ?, ?)",
            arguments: [bridgeId.uuidString, topicId.uuidString, session.key, Date()]
        )
    }
}
```

### 3.2 Migration Safety (B4)

The entire migration runs inside a single GRDB transaction. If any step fails, the database version is NOT incremented, and the migration re-runs on next launch.

GRDB already wraps each `Migration` in a transaction. Do NOT use `try?` — let errors propagate so GRDB rolls back and retries.

**CRITICAL:** Do not wrap sub-operations in `try?`. Let GRDB's transaction handling manage rollback:

```swift
// ✅ CORRECT — errors propagate, GRDB rolls back
try db.create(table: "topic") { ... }

// ❌ WRONG — silently swallows errors
try? db.create(table: "topic") { ... }
```

### 3.3 Migration Test Criteria

| Test | Expected Result |
|------|----------------|
| Fresh install | 3 seed topics visible in topic table, bridge entries point to session keys |
| Upgrade from Gate 2B state | Existing session seed data converted to topics, bridge entries created |
| Upgrade with no sessions | Topic table empty, no crash |
| Partial migration failure | Database version NOT incremented, migration re-runs on next launch |

---

## 4. Bridge Table (TopicSessionBridge)

### 4.1 Purpose

The bridge maps between the user-facing `Topic.id` and the gateway's `openclawSessionKey`. This is needed because:
- Topics are created before their gateway session exists (offline creation)
- A topic's gateway key is deterministic (`agent:main:<topicIdLowercased>`) but the bridge provides a lookup for legacy session keys
- The bridge enables filtering gateway sessions to only show topic-mapped sessions

### 4.2 Schema

```sql
CREATE TABLE topic_session_bridge (
    id TEXT PRIMARY KEY,
    topicId TEXT NOT NULL REFERENCES topic(id) ON DELETE CASCADE,
    openclawSessionKey TEXT NOT NULL UNIQUE,  -- B6: UNIQUE constraint
    createdAt DATETIME NOT NULL
);
```

### 4.3 Bridge Operations

```swift
// BeeChatPersistence/Repositories/TopicSessionBridge.swift

struct TopicSessionBridge {
    static func createBridge(topicId: UUID, sessionKey: String, db: Database) throws -> BridgeEntry
    static func resolveTopicId(for sessionKey: String, db: Database) throws -> UUID?
    static func resolveSessionKey(for topicId: UUID, db: Database) throws -> String?
    static func upsertBridge(topicId: UUID, sessionKey: String, db: Database) throws -> BridgeEntry  // B6: upsert on UNIQUE conflict
    static func removeOrphanedBridges(db: Database) throws  // W3: cleanup
}
```

### 4.4 Upsert Pattern (B6)

When creating a bridge entry where `openclawSessionKey` might already exist:

```swift
static func upsertBridge(topicId: UUID, sessionKey: String, db: Database) throws -> BridgeEntry {
    let id = UUID()
    try db.execute(
        sql: """
            INSERT INTO topic_session_bridge (id, topicId, openclawSessionKey, createdAt)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(openclawSessionKey) DO UPDATE SET topicId = excluded.topicId
        """,
        arguments: [id.uuidString, topicId.uuidString, sessionKey, Date()]
    )
    // ...
}
```

---

## 5. BeeChatSessionFilter Update (B2)

### 5.1 Current Problem

The existing `BeeChatSessionFilter.isBeeChatSession()` creates a new `TopicRepository()` on every call. On iOS `@MainActor`, this can deadlock because `TopicRepository` init requires database access on the same thread.

### 5.2 Fix: Injected Overload

Add an overload that accepts an existing `TopicRepository` instance:

```swift
// BeeChatPersistence/Filters/BeeChatSessionFilter.swift

extension BeeChatSessionFilter {
    // Existing method — macOS only (creates its own repo)
    static func isBeeChatSession(_ session: Session) -> Bool {
        // ... existing implementation for macOS
    }
    
    // NEW: Injected overload — iOS uses this
    static func isBeeChatSession(_ session: Session, topicRepo: TopicRepository) -> Bool {
        // Check if session maps to a known topic via bridge table
        do {
            let topic = try topicRepo.fetch(bySessionKey: session.key)
            return topic != nil && !(topic?.isArchived ?? true)
        } catch {
            return false
        }
    }
}
```

### 5.3 Usage

The iOS ViewModel calls the injected overload:
```swift
let filtered = sessions.filter { session in
    BeeChatSessionFilter.isBeeChatSession(session, topicRepo: self.topicRepo)
}
```

The macOS app continues using the original method without changes.

---

## 6. Seed Data (B8)

### 6.1 Current Problem

Seed data uses `Session` model. After Migration010, the topic list reads from the `topic` table, not the `session` table. Seed data created as `Session` entries become invisible.

### 6.2 Fix

Change seed data creation to use `Topic` model directly:

```swift
// BeeChatPersistence/Seed/SeedData.swift

static func createSeedTopics(in db: Database) throws {
    let now = Date()
    let seeds: [(name: String, sessionKey: String)] = [
        ("General", "agent:main:general"),
        ("Project Ideas", "agent:main:project-ideas"),
        ("Quick Chat", "agent:main:quick-chat")
    ]
    
    for seed in seeds {
        let topicId = UUID()
        try db.execute(
            sql: "INSERT INTO topic (id, name, sessionKey, isArchived, pendingGatewaySync, createdAt, lastActivityAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [topicId.uuidString, seed.name, seed.sessionKey, false, false, now, now]
        )
        
        let bridgeId = UUID()
        try db.execute(
            sql: "INSERT INTO topic_session_bridge (id, topicId, openclawSessionKey, createdAt) VALUES (?, ?, ?, ?)",
            arguments: [bridgeId.uuidString, topicId.uuidString, seed.sessionKey, now]
        )
    }
}
```

### 6.3 Idempotency

Seed creation must be idempotent — running it twice should not create duplicates:

```swift
static func createSeedTopics(in db: Database) throws {
    // Check if seeds already exist
    let existingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM topic WHERE sessionKey IN ('agent:main:general', 'agent:main:project-ideas', 'agent:main:quick-chat')") ?? 0
    guard existingCount == 0 else { return }
    
    // ... create seeds
}
```

---

## 7. TopicRepository Unit Tests

Phase 1 must include unit tests for the TopicRepository. These are the validation gate.

### 7.1 Test Cases

| # | Test | Input | Expected |
|---|------|-------|----------|
| T1 | Create topic | `create(name: "Test")` | Topic returned with generated UUID, sessionKey `"agent:main:<uuid>"`, `pendingGatewaySync = false` |
| T2 | Create topic offline | `create(name: "Offline", offline: true)` | `pendingGatewaySync = true` |
| T3 | Fetch all active | 3 topics, 1 archived | Returns 2, ordered by `lastActivityAt DESC` |
| T4 | Fetch by session key | Known session key | Returns matching topic |
| T5 | Fetch by session key (unknown) | Unknown key | Returns nil |
| T6 | Archive topic | Archive a topic | `isArchived = true`, not in `fetchAllActive()` |
| T7 | Unarchive topic | Unarchive an archived topic | `isArchived = false`, back in `fetchAllActive()` |
| T8 | Delete topic | Delete a topic | Removed from all queries, bridge entries cascade deleted |
| T9 | Update last activity | Update timestamp and preview | `lastActivityAt` and `lastMessagePreview` updated |
| T10 | Mark synced | `markSynced(id:)` | `pendingGatewaySync = false` |
| T11 | Fetch pending sync | 2 topics with `pendingGatewaySync = true` | Returns both |
| T12 | Bridge upsert (duplicate key) | Insert bridge with same `openclawSessionKey` | No error, existing entry updated |
| T13 | Computed message count | Topic with 5 messages | `fetchAllActive()` includes count = 5 |
| T14 | Empty topic list | No topics | Returns empty array, no crash |
| T15 | Seed data idempotency | Run `createSeedTopics` twice | No duplicates, 3 topics total |

### 7.2 Test Infrastructure

Tests should use an in-memory GRDB database:

```swift
class TopicRepositoryTests: XCTestCase {
    var dbQueue: DatabaseQueue!
    var repo: TopicRepository!
    
    override func setUp() {
        dbQueue = try! DatabaseQueue()
        var migrator = DatabaseMigrator()
        // Register all migrations including Migration010
        // ...
        try! migrator.migrate(dbQueue)
        repo = TopicRepository(db: dbQueue)
    }
}
```

---

## 8. What Does NOT Change in Phase 1

The following must remain **untouched** during Phase 1:

- `ChatViewModel.swift` — no changes
- `TopicListView.swift` / `TopicListView.swift` — no changes
- `ChatView.swift` — no changes
- `GatewayClient.swift` — no changes
- `SyncBridge.swift` — no changes
- Any UI file — no changes

Phase 1 only adds new files and modifies the `BeeChatPersistence` package. The app should compile and run exactly as before, with the new Topic model sitting unused until Phase 2 switches it on.

---

## 9. Success Criteria

Phase 1 is complete when ALL of the following are true:

| # | Criterion | How to Verify |
|---|-----------|--------------|
| SC1 | App compiles and runs on simulator | Build succeeds, app launches, looks identical to current state |
| SC2 | BeeChat macOS compiles and runs | No regression in shared v5 package |
| SC3 | Migration010 runs on fresh install | 3 seed topics in topic table, bridge entries present |
| SC4 | Migration010 runs on upgrade from Gate 2B state | Existing sessions converted to topics, bridge entries created |
| SC5 | All 15 unit tests pass | `xctest` runs green |
| SC6 | `BeeChatSessionFilter.isBeeChatSession(_:topicRepo:)` overload works | Unit test: filter returns true for topic-mapped sessions |
| SC7 | Bridge UNIQUE constraint enforced | Inserting duplicate `openclawSessionKey` upserts instead of crashing |
| SC8 | No `sessionKey: nil` anywhere in Topic code | Grep for `sessionKey.*nil` returns nothing |
| SC9 | Migration uses `try` not `try?` | Grep for `try?` in Migration010 returns nothing |

---

## 10. Rollback

If Phase 1 introduces any regression:

1. `git revert` the Phase 1 commit(s)
2. Delete the app from the simulator (database will be recreated from Migration009 state)
3. Rebuild and reinstall

No data loss risk — Phase 1 doesn't modify any existing tables or remove any existing code.

---

## 11. File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `BeeChatPersistence/Models/Topic.swift` | **NEW** | Topic model definition |
| `BeeChatPersistence/Repositories/TopicRepository.swift` | **NEW** | TopicRepository with computed counts |
| `BeeChatPersistence/Repositories/TopicSessionBridge.swift` | **NEW** | Bridge table operations with upsert |
| `BeeChatPersistence/Migrations/Migration010_CreateTopics.swift` | **NEW** | Database migration (topic table, bridge table, seed conversion) |
| `BeeChatPersistence/Seed/SeedData.swift` | **MODIFY** | Add `createSeedTopics()` method |
| `BeeChatPersistence/Filters/BeeChatSessionFilter.swift` | **MODIFY** | Add injected overload for iOS |
| `BeeChatPersistence/Migrations/Migrator.swift` (or equivalent) | **MODIFY** | Register Migration010 |

**Total: 4 new files, 3 modified files. Zero UI changes.**