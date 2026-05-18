# Gate 2B.5 Phase 1 Data Layer — Q Review of v3.1

**Reviewer:** Q  
**Date:** 2026-05-18  
**Spec:** GATE-2B5-PHASE1-DATA-LAYER-v3.1.md  
**Verdict:** **NEEDS CHANGES** — 2 blockers, 3 warnings

---

## Blockers

### B11. `upsertPreservingCreatedAt()` uses `onConflict: ["id"]` — WRONG for `TopicSessionBridge`

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Utilities/GRDBUpsertHelpers.swift` (line 17)

The helper hardcodes `onConflict: ["id"]`. For `Topic`, this is correct — `Topic.id` is the primary key column named `id`. But `TopicSessionBridge` has **no column named `id`**; its primary key is `topicId`. When `upsertPreservingCreatedAt()` is called on a `TopicSessionBridge` instance, GRDB will try to resolve `onConflict: ["id"]` against a column that doesn't exist in the `topic_session_bridge` table.

The spec §3.5 claims:
> "GRDB maps this correctly for the PK-based upsert"

This is **incorrect**. GRDB's `onConflict` parameter maps to SQLite's `ON CONFLICT` conflict target, which must reference actual column names in the table. `topic_session_bridge` has no `id` column — it will throw a SQLite error at runtime.

The spec's W20 documentation acknowledges the limitation for UNIQUE on `openclawSessionKey` but **misses the more fundamental issue**: the upsert itself will fail on `topicId` conflicts too, because GRDB can't resolve the conflict target.

**Fix options:**
1. Add a `CodingKeys` to `TopicSessionBridge` that maps `id` → `topicId` (fragile, misleading)
2. Override `upsertPreservingCreatedAt` in `TopicSessionBridge` with `onConflict: ["topicId"]`
3. Create a `saveBridgeUpsert()` method in `TopicRepository` that uses raw SQL: `INSERT OR REPLACE INTO topic_session_bridge ...` or `INSERT ... ON CONFLICT(topicId) DO UPDATE ...`
4. Don't use `upsertPreservingCreatedAt()` for bridge records at all — use a custom upsert with the correct conflict target

**Recommendation:** Option 3 — write a targeted SQL upsert in `TopicRepository.saveBridge()`:
```swift
public func saveBridge(topicId: String, sessionKey: String) throws {
    try dbManager.write { db in
        try db.execute(sql: """
            INSERT INTO topic_session_bridge (topicId, spaceId, openclawSessionKey, bridgeVersion, status, createdAt, updatedAt)
            VALUES (?, 'default', ?, 1, 'active', datetime('now'), datetime('now'))
            ON CONFLICT(topicId) DO UPDATE SET
                openclawSessionKey = excluded.openclawSessionKey,
                updatedAt = datetime('now')
        """, arguments: [topicId, sessionKey])
    }
}
```

This avoids `upsertPreservingCreatedAt()` entirely for bridge records, handles the correct PK, and also correctly handles the `openclawSessionKey` UNIQUE constraint (it will still throw if a *different* topic tries to claim a session key that's already bridged — which is correct defensive behavior).

---

### B12. `BeeChatView` will break — `messages(for:)` and `streamingContent` use `topicId` as `sessionId`

**Files:** `BeeChatView.swift` (lines 69, 71, 101, 103), `BeeChatMobileViewModel.swift` (line 172)

After the `topics: [Session] → [Topic]` change, `viewModel.selectedTopicId` will hold a `Topic.id` (uppercase UUID), not a gateway session key. But:

1. **`BeeChatView.loadMessages()`** calls `viewModel.messages(for: topicId)` which calls `persistenceStore.fetchMessages(sessionId: topicId, ...)`. Messages are stored with `sessionId = "agent:main:<uuid-lowercase>"`, not the uppercase Topic UUID. **No messages will load.**

2. **`BeeChatView.mergedMessages`** accesses `viewModel.streamingContent[topicId]`. But `streamingContent` is keyed by `sessionKey` (set by `SyncBridge` delegate callbacks). After the Topic change, `topicId` ≠ `sessionKey`, so **streaming content will never display.**

3. **`BeeChatView.send()`** already calls `viewModel.send(text:to: topicId)`. The spec's §3.7.4 correctly resolves this by doing `topic.sessionKey` lookup. But `messages(for:)` and `streamingContent` have no such resolution.

The spec's §5 "Out of Scope" says:
> "Q note: BeeChatView not audited in Phase 1 scope — may also reference Session properties, needs checking during implementation"

**This is a compile/runtime blocker, not a future audit item.** If `topics` changes to `[Topic]`, `BeeChatView` doesn't compile against `Session`-specific properties, and even if it did, the key mismatch means messages won't load and streaming won't work.

**Fix:** Either:
1. Add a `sessionKey(for topicId:)` convenience method on the ViewModel that resolves `Topic.id → Topic.sessionKey`, and update `messages(for:)` to use it. Then update `BeeChatView` to use a computed `currentSessionKey` derived from the selected topic.
2. Change `BeeChatView` to resolve the session key inline:
```swift
// In BeeChatView
private var currentSessionKey: String? {
    viewModel.topics.first(where: { $0.id == viewModel.selectedTopicId })?.sessionKey
}
```
Then use `currentSessionKey` for `messages(for:)` and `streamingContent[...]`.

This is not a "6-line UI change" — it touches `BeeChatView` (message loading, streaming, send), the ViewModel (`messages(for:)`), and `TopicListView`. But it's a **direct consequence** of the `[Session] → [Topic]` type change, not scope creep.

---

## Warnings

### W21. `bridge.rpcClient.sessionsSubscribe()` won't compile — `rpcClient` is `private`

**Spec §3.7.2, step 8:**
```swift
try await bridge.rpcClient.sessionsSubscribe()
```

`SyncBridge.rpcClient` is declared `private` (line 19, `SyncBridge.swift`). This line will not compile.

However, `SyncBridge.start()` already calls `rpcClient.sessionsSubscribe()` internally (line 81). Since `connect()` calls `bridge.start()`, and `reconnect()` calls `disconnect()` then `connect()`, the subscription is already re-established on reconnect.

**Fix:** Remove step 8 from `connect()`. It's redundant and won't compile as written. Add a note that `SyncBridge.start()` handles re-subscription.

---

### W22. `TopicListView` is 4 lines, not 6

The spec §3.8 says "~6-line type + property name update (Q v3 correction — was estimated at 3 lines)". Checking the actual source:

| Line | Current | After | Changed? |
|------|---------|-------|----------|
| 63 | `let topic: Session` | `let topic: Topic` | ✅ |
| 38 | `?.title ?? "Chat"` | `?.name ?? "Chat"` | ✅ |
| 67 | `topic.title ?? topic.customName ?? "Untitled"` | `topic.name` | ✅ |
| 76 | `topic.lastMessageAt` | `topic.lastActivityAt` | ✅ |
| 69 | `topic.lastMessagePreview` | `topic.lastMessagePreview` | ❌ same |
| 80 | `topic.unreadCount` | `topic.unreadCount` | ❌ same |

That's **4 changed lines**, not 6. The "Q v3 correction" of 3→6 overshot. Minor but worth correcting for accuracy.

---

### W23. `messages(for:)` parameter name is misleading after the change

After the Topic change, `BeeChatMobileViewModel.messages(for sessionId:)` is called with a `topicId` from `BeeChatView`. Even after fixing B12 (resolving topicId→sessionKey), the method signature `messages(for sessionId:)` is confusing because the caller passes a `topicId` and expects it to be resolved internally.

**Suggestion:** Rename to `messages(for topicId:)` and resolve internally, matching the `send(text:to:)` pattern from §3.7.4.

---

## Previous Blockers — Verification

| # | Blocker | Resolved? | Evidence |
|---|---------|-----------|----------|
| B1 | `dbManager` private on `BeeChatPersistenceStore` | ✅ Yes | Spec §3.1: expose `topicRepo` as `public`. Verified `BeeChatPersistenceStore.swift` line 44 has `private let topicRepo`. |
| B2 | `upsertBridge()` uses `onConflict: ["id"]` | ✅ Yes | Spec §3.5 removes `upsertBridge()`, changes `saveBridge()` to `upsertPreservingCreatedAt()`. **But see B11 — this introduces a new variant of the same problem.** |
| B3a | `TopicListView` references `Session` properties | ✅ Yes | Spec §3.8 maps properties correctly. Verified against source. **But see B12 — BeeChatView also needs fixes.** |
| B3b | `computedMessageCount` alias not decoded | ✅ Yes | Spec §3.3.2 uses `messageCount` alias. Correct. |
| B3c | `pendingGatewaySync: false` for offline topics | ✅ Yes | Spec §3.3.1 adds parameter with default `false`. Correct. |
| B5 | No offline path for topic creation | ✅ Yes | Spec §3.3.1 + §3.7.2 step 1. Correct. |
| B6 | Migration `try?` partial failure | ✅ Yes | Single GRDB migrator transaction. Verified `DatabaseManager.swift` uses `DatabaseMigrator`. |
| B7 | Bridge table no UNIQUE on `openclawSessionKey` | ✅ Yes | Spec §3.6 Migration012 adds UNIQUE index. Correct. |
| B8 | `sessions.subscribe` not re-subscribed | ✅ Yes | Spec §3.7.2 step 8. **But see W21 — won't compile as written, and is redundant anyway.** |
| B10 | `upsertPreservingCreatedAt` won't handle UNIQUE on `openclawSessionKey` | ✅ Partially | Spec §3.5 documents as known limitation with do/catch. **But the bigger issue (B11) is that it won't handle the PK conflict correctly either.** |

---

## Spec Accuracy — Codebase Cross-Check

| Spec Claim | Verified | Notes |
|-----------|----------|-------|
| `Topic.name` (not `title`) | ✅ | Source: `public var name: String` |
| `Topic.lastActivityAt` (not `lastMessageAt`) | ✅ | Source: `public var lastActivityAt: Date?` |
| `TopicSessionBridge.topicId` is PK | ✅ | Source: `t.column("topicId", .text).primaryKey()` |
| `TopicSessionBridge` has no UNIQUE on `openclawSessionKey` | ✅ | Migration005 creates non-unique index |
| `BeeChatPersistenceStore.topicRepo` is `private` | ✅ | Source: `private let topicRepo = TopicRepository()` |
| `BeeChatSessionFilter` creates `TopicRepository()` per call | ✅ | Source: `let topicRepo = TopicRepository()` in `isBeeChatSession` |
| `saveBridge()` uses `save()` not upsert | ✅ | Source: `try bridge.save(db)` |
| `SyncBridge.sendMessage` has `topic: Topic?` parameter | ✅ | Source: `topic: Topic? = nil` |
| Migration012 registered in `migrate()` | ⚠️ | Spec says to add it after M011. `migrate()` is in `DatabaseManager.swift`. Verified location exists. |
| `SyncBridge.rpcClient` is `private` | ✅ | Source: `private let rpcClient: RPCClientProtocol` |

---

## Summary

| Category | Count | Items |
|----------|-------|-------|
| **Blockers** | 2 | B11 (`upsertPreservingCreatedAt` wrong conflict target for bridge), B12 (BeeChatView message/streaming key mismatch) |
| **Warnings** | 3 | W21 (private rpcClient), W22 (4 lines not 6), W23 (misleading param name) |
| **Previous blockers resolved** | 8/10 | B1-B8 resolved; B10 partially (see B11) |

**Verdict: NEEDS CHANGES.** B11 and B12 must be fixed before implementation. B11 is a runtime crash. B12 is a silent data loss bug (messages won't load, streaming won't display). Neither is cosmetic.