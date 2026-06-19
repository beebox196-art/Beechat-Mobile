# Gate 2B.5 Topic Architecture — Q (Builder) Review

**Date:** 2026-05-18
**Reviewer:** Q (Code Implementer)
**Status:** 🔴 BLOCKED — 3 blockers must be resolved before implementation starts
**Confidence:** High — verified against actual source code

---

## Executive Summary

The spec is directionally correct but contains **serious claims about existing code that don't match reality**. The biggest risks are around (1) a spec/code mismatch that would cause a build failure, (2) a GRDB trigger conflict that would silently corrupt message counts, and (3) an understated migration story that would break existing users on first launch. The good news: the core architecture is sound, and most issues are fixable in a day or two.

**Verdict:** Fix the 3 blockers, address the 5 warnings, then proceed. Do not start coding before blockers are resolved.

---

## 1. BLOCKERS — Must Fix Before Implementation

### B1. 🔴 Spec claims `sessionKey: nil` for new topics — but Kieran B2 fix was NOT applied to the spec text

**What the spec says (Section 3.2.3):**
> `let gatewayKey = "agent:main:\(topicId.lowercased())"`
> `let topic = Topic(id: topicId, name: name, sessionKey: gatewayKey)`

**What the spec ALSO says (Section 5, Design Decision D3):**
> "User creates topic with name → stored locally with `sessionKey: nil`"
> "User sends first message → creates gateway session → bridges topic"

**Verdict:** The spec is **internally inconsistent**. Section 3.2.3 correctly implements Kieran B2 (gateway key upfront). Section D3 still describes the old nil-sessionKey flow that Kieran B2/B3 eliminated. This must be harmonised — **the Kieran B2 approach (gateway key upfront) is correct** and must be the only documented pattern. The D3 text should be deleted or rewritten to describe the upfront-key flow.

**Impact if uncaught:** Implementation team would follow D3, reintroducing B2/B3 bugs.

---

### B2. 🔴 `BeeChatSessionFilter` has the deadlock bug — but the spec's proposed fix is underspecified

**Confirmed in code (`SessionKeyNormalizer.swift:53-66`):**
```swift
public static func isBeeChatSession(_ sessionKey: String) throws -> Bool {
    let topicRepo = TopicRepository()  // ← FRESH INSTANCE PER CALL
    // ...
}
```

**Spec fix (Kieran B1):** "Inject ViewModel's existing repo instance"

**Problem:** The spec does not show HOW. `BeeChatSessionFilter` is a static enum (no stored state by design, to avoid Sendable issues). It cannot hold a reference to a TopicRepository (which is a non-Sendable class). Changing it to an instance-based struct would break every call site in macOS.

**Real fix needed:** One of:
1. Add `isBeeChatSession(_ sessionKey: String, topicRepo: TopicRepository)` overload — pass repo from ViewModel
2. Make `TopicRepository` an `@unchecked Sendable` singleton and fix the `@MainActor` deadlock in DatabaseManager
3. Replace static enum with a `protocol BeeChatSessionFiltering` + instance injection

**Recommended:** Option 1 (overload) is the surgical fix. Change iOS ViewModel to call the overload, leave macOS on the old path until it can be migrated. This avoids touching macOS code.

---

### B3. 🔴 Migration010 already destroyed topic-based message count triggers — spec's Migration007 claim is wrong

**Spec claims (Section 3.1):**
> "GRDB Migration007 (messageCount trigger) ✅ Available"

**Reality (DatabaseManager.swift:Migration010):**
```swift
// Step 5: Replace topic-based message count triggers with session-based triggers
// Drop old triggers that reference the topics table
try db.execute(sql: "DROP TRIGGER IF EXISTS trg_increment_message_count")
try db.execute(sql: "DROP TRIGGER IF EXISTS trg_decrement_message_count")

// Create new triggers that reference the sessions table
try db.execute(sql: """
    CREATE TRIGGER trg_session_increment_message_count
    AFTER INSERT ON messages
    BEGIN
        UPDATE sessions SET messageCount = messageCount + 1 WHERE id = NEW.sessionId;
    END
    """)
```

**What this means:** Migration010 **dropped the topic-based triggers** and replaced them with session-based triggers. If Gate 2B.5 reintroduces `Topic` as the primary model, message counts on Topics will **never update automatically** after Migration010 has run. The `Topic.messageCount` field will become stale.

**Fix required:** Either:
1. Re-add topic-based triggers in a new migration (Migration012), AND make them coexist with session-based triggers (both update their respective tables)
2. Abandon DB triggers for topic messageCount and compute it in `TopicRepository.fetchAllActive()` via SQL COUNT subquery
3. Keep session-based triggers as source of truth, and backfill `Topic.messageCount` from `sessions.messageCount` during sync

**Recommended:** Option 2 — drop the complexity of dual triggers entirely. `TopicRepository.fetchAllActive()` can include a computed `messageCount` via SQL JOIN or subquery. Simpler, no trigger maintenance, no race conditions between two tables.

---

## 2. WARNINGS — Should Fix Before or During Implementation

### W1. 🟡 `TopicRow` uses `Session` model — spec says this is a simple rename. It's not.

**Current code (`TopicListView.swift:62-81`):**
```swift
struct TopicRow: View {
    let topic: Session  // ← Session, not Topic
    // uses: topic.title, topic.customName, topic.lastMessageAt, topic.unreadCount
}
```

**Spec says:** "The property mapping is clean"

**Reality:** The property names don't match:

| What `TopicRow` reads from `Session` | What `Topic` has |
|---|---|
| `.title` | `.name` |
| `.customName` | ❌ No such field |
| `.lastMessageAt` | `.lastActivityAt` |
| `.lastMessagePreview` | ✅ Same name |
| `.unreadCount` | ✅ Same name |

**Impact:** This is a real refactor, not a rename. `TopicRow` needs rewriting. Also `BeeChatView` reads `topic.title` for the navigation title (`TopicListView.swift:40`). Every `Session` property access in the UI layer needs auditing.

**Fix:** Straightforward but tedious. Audit all UI files for `Session` property access. Update to `Topic` equivalents. Add a helper if needed:
```swift
extension Topic {
    var displayName: String { name }
    var lastMessageFormatted: String? { lastActivityAt?.formatted(...) }
}
```

---

### W2. 🟡 `BeeChatSessionFilter` is in `BeeChatSyncBridge` — iOS ViewModel currently doesn't import it

**Current iOS ViewModel imports:**
```swift
import BeeChatPersistence
import BeeChatGateway
import BeeChatSyncBridge
```

Wait — `BeeChatSyncBridge` IS imported. So `BeeChatSessionFilter` is accessible. But the ViewModel never calls it. The spec's session filtering on connect (Section 3.2.4) is new code, not a refactor.

**Impact:** Low — it's a new call site, not a breaking change. But needs implementation.

---

### W3. 🟡 `syncBridge.fetchSessions()` returns `[Session]`, not `[Topic]` — the spec's connect() flow needs rethinking

**Current flow:**
```swift
let sessions = try await bridge.fetchSessions()
self.topics = sessions  // [Session] assigned to topics
```

**Spec says:** Fetch sessions, filter them, update topic metadata, refresh topics from local DB.

**Problem:** `fetchSessions()` upserts to `sessions` table, not `topics` table. After the spec's filtering step, the ViewModel needs to:
1. Map each `Session` to a `Topic` (via bridge table or sessionKey)
2. Update the `Topic` row with metadata from the `Session`
3. Then fetch `[Topic]` from local DB

This is more work than the spec suggests. The spec hand-waves it as "update lastMessagePreview, unreadCount, lastActivityAt from session data" but doesn't show the actual SQL/GRDB calls.

**Fix:** Add a `TopicRepository.syncMetadataFromSessions(sessions: [Session])` method that updates topics from session data where the sessionKey matches. This keeps the sync logic in the repository layer where it belongs.

---

### W4. 🟡 Seed data migration from `Session` to `Topic` — the spec's migration code won't compile

**Spec's migration code (Section 3.2.4):**
```swift
let topic = Topic(
    id: session.id,
    name: session.title ?? session.customName ?? session.id,
    sessionKey: gatewayKey,
    lastMessagePreview: session.lastMessagePreview,
    lastActivityAt: session.lastMessageAt ?? session.updatedAt,
    messageCount: session.messageCount
)
```

**Problem:** `Topic.init()` does not have these parameter names in that order. The actual init signature is:
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
    messageCount: Int = 0
)
```

The spec uses positional/named hybrid that doesn't match. Minor, but will fail to compile.

---

### W5. 🟡 `sendMessage` in ViewModel uses `sessionId` directly — spec's topic-resolved key is clean but needs more wiring

**Current code:**
```swift
public func send(text: String, to sessionId: String) async throws {
    // ...
    _ = try await bridge.sendMessage(sessionKey: sessionId, text: text)
}
```

**BeeChatView calls:**
```swift
try await viewModel.send(text: draft.text, to: topicId)
```

**Problem:** `topicId` is the topic UUID, not the session key. If the topic was created with `sessionKey = "agent:main:<topicId>"`, then `topicId == SessionKeyNormalizer.stripPrefix(sessionKey)` only if the UUID part matches. With Kieran B2's upfront-key approach, `sessionKey` IS `agent:main:<topicId>`, so stripping the prefix gives `topicId.lowercased()`. If `topicId` has uppercase letters (UUIDs are typically uppercase), the match would fail unless `resolveTopicIdBySuffix` does case-insensitive matching.

**Verified:** `resolveTopicIdBySuffix` DOES do `UPPER(id)` matching — this handles the case. But the spec should document this explicitly. The `sendMessage` flow should use `topic.sessionKey!` directly (it's non-nil with B2 fix), not re-derive it.

**Fix:** Update ViewModel to:
```swift
public func send(text: String, to topicId: String) async throws {
    guard let topic = topics.first(where: { $0.id == topicId }),
          let sessionKey = topic.sessionKey else { return }
    _ = try await bridge.sendMessage(sessionKey: sessionKey, text: text)
}
```

---

## 3. FEASIBILITY NOTES — Works But Needs Care

### F1. ✅ GRDB `ValueObservation` works on iOS — confirmed in existing code

`SyncBridge.messageStream()` already uses `ValueObservation.tracking` with `.mainActor` scheduling. This proves `ValueObservation` works correctly on iOS. The spec's W1 (replace 500ms polling) is feasible.

**Note:** The current iOS ViewModel uses a 500ms polling loop (`startMessageObservation()`). Replacing it with `ValueObservation` would eliminate that. But this is a nice-to-have optimization, not a blocker.

---

### F2. ✅ `TopicRepository` can be injected into ViewModel — straightforward

`TopicRepository` init is:
```swift
public init(dbManager: DatabaseManager = .shared)
```

The ViewModel already opens the database via `persistenceStore.openDatabase(at:)`. The `DatabaseManager.shared` singleton will pick up the same pool. So injecting `TopicRepository()` into the ViewModel is safe — it will use the already-opened database.

**However:** The spec should explicitly show `TopicRepository` being created AFTER `openDatabase()` in `start()`, not in `init()`. Creating it before the DB is open would be a subtle bug.

---

### F3. ✅ Gateway session key format `agent:main:<uuid>` — confirmed

`SessionKeyNormalizer.prefix = "agent:main:"` — confirmed.
`SyncBridge.normalizedSessionKey()` strips this prefix — confirmed.
`rpcClient.chatSend()` accepts any string as `sessionKey` — confirmed.

The spec's Kieran B2 approach (generate `agent:main:<topicId>` upfront) is fully compatible with the gateway protocol. No gateway changes needed.

---

### F4. ⚠️ TopicSessionBridge model file doesn't exist where spec claims

**Spec claims:** `TopicSessionBridge` model exists in `BeeChatPersistence`

**Reality:** The `TopicSessionBridge` struct is defined **inside `Topic.swift`** (same file as `Topic`), not in a separate file. The model exists, but not at the path the spec implies.

**Impact:** None for compilation. But the spec should be precise about file locations for future maintainers.

---

### F5. ⚠️ `BeeChatSessionFilter` does NOT have `resolveTopicIdBySuffix()` — that's on `TopicRepository`

**Spec claims (Section 2.2):**
> `SessionKeyNormalizer.resolveTopicIdBySuffix("agent:main:xyz")` → `"xyz"`

**Reality:** `resolveTopicIdBySuffix` is a method on `TopicRepository`, not `SessionKeyNormalizer`. `SessionKeyNormalizer` only has `stripPrefix()`, `hasPrefix()`, and `variants()`.

**Impact:** Spec misattributes the method. The code works, but the spec description is confusing.

---

## 4. SPEC GAPS — Things Not Covered That Should Be

### G1. 📝 What happens to `SessionRepository` and `Session` model after migration?

The spec says iOS should use `Topic` instead of `Session`. But `SyncBridge.fetchSessions()` still upserts to the `sessions` table. The `sessions` table is still used for:
- Gateway session metadata (title, totalTokens, etc.)
- Message lookup by `sessionId`
- `SessionResetManager` usage checks

**Question not answered:** Is `Session` now a "backend" model (for gateway sync) and `Topic` the "frontend" model (for UI)? If so, the spec should document this two-model architecture clearly.

**Recommendation:** Keep both. `Session` = gateway truth. `Topic` = user-facing conversation. The bridge table links them. Document this explicitly.

---

### G2. 📝 `sessions.changed` event handling is not mentioned

When the gateway fires `sessions.changed`, the iOS app needs to:
1. Re-fetch sessions via `fetchSessions()`
2. Update `sessions` table
3. Sync metadata to `topics` table (via bridge)
4. Refresh the sidebar

The spec covers Gate 2B.5 as "local architecture" but doesn't address how live gateway events propagate through the Topic layer. This is critical for Gate 2C/2D.

---

### G3. 📝 `contextInjectedKeys` and topic switching

`SyncBridge` has `contextInjectedKeys: Set<String>` that tracks which sessions have received `[TOPIC-CONTEXT]` injection. When a user switches topics, `clearPendingResetContext(except:)` is called. But `contextInjectedKeys` is NOT cleared on topic switch.

**Impact:** If a user switches from Topic A to Topic B (both mapped to different session keys), the new session won't get topic context injection because `contextInjectedKeys` already contains the old session key. Wait — no, they're different keys. OK, this is actually fine for different session keys.

But what if two topics map to the SAME session key? (Shouldn't happen with B2, but the bridge table could theoretically allow it.) Then context injection would be skipped for the second topic.

**Spec gap:** Should document that one topic = one session key = one context injection lifetime. No reuse, no sharing.

---

### G4. 📝 `isTopicContextEnabled` feature flag interaction

The spec doesn't mention the `isTopicContextEnabled` UserDefaults flag in `SyncBridge`. If this flag is disabled, topic context injection is skipped. This is a macOS feature that might not apply to iOS, but if the same `SyncBridge` code is used, the flag affects both platforms.

**Question:** Should iOS disable topic context injection (since mobile UX is simpler), or keep it? The spec is silent.

---

### G5. 📝 `Topic.name` is `String` (non-optional) but `Session.title` is `String?`

The spec's migration code does `session.title ?? session.customName ?? session.id`. But `Topic.name` is non-optional. What if a migrated session has no title AND no customName? The migration uses `session.id` as fallback, which is fine. But what about NEW topics? The "New Topic" sheet should validate that the user enters a non-empty name, or provide a default like "New Conversation".

---

## 5. REVIEW OF KIERAN BLOCKERS (B1-B4)

| Blocker | Spec Incorporation | Q's Assessment |
|---|---|---|
| **B1** Fresh `TopicRepository()` per call | ✅ Fixed: "Inject ViewModel's existing repo instance" | 🔴 **Underspecified.** Static enum can't hold instance. Needs overload or protocol refactor. |
| **B2** `sessionKey: nil` is fragile | ✅ Fixed: upfront `agent:main:` key generation | ✅ **Correct fix.** But D3 text still describes old nil flow — must remove. |
| **B3** Bare UUID fallback | ✅ Fixed: eliminated by B2 | ✅ **Correct.** No bare UUIDs with upfront key. |
| **B4** First launch loses seed data | ✅ Fixed: Migration from Session to Topic | 🟡 **Partially correct.** Migration code in spec won't compile (parameter names). Also Migration010 destroyed topic triggers, so messageCount won't auto-update post-migration. |

---

## 6. REVIEW OF MEL UX FINDINGS (M1-M5)

| Finding | Spec Incorporation | Q's Assessment |
|---|---|---|
| **M1** Compact sheet (iPhone) / popover (iPad) | ✅ Section 3.2.5 | ✅ Feasible. Standard SwiftUI sheet + `.popover` conditional on horizontalSizeClass. |
| **M2** No fake "Start" bootstrap — upfront key | ✅ Combined with Kieran B2 | ✅ Correct. No bootstrap message needed. |
| **M3** Distinguish fresh install vs "existing sessions hidden" | ✅ Secondary import path mentioned | 🟡 Needs implementation detail: where does "Import recent sessions" UI live? What sessions are imported? How do we know which gateway sessions are "recent"? |
| **M4** Swipe actions (archive + delete) | ✅ Listed as must-have | ✅ Feasible with `.swipeActions` in SwiftUI List. Cascade delete warning needs `TopicRepository.deleteCascading()` which already exists. |
| **M5** Error states (disconnected, bridge failure) | ✅ Listed | 🟡 Needs spec detail: what does "disabled composer" look like in Exyte Chat? Exyte's `ChatView` doesn't have a built-in disabled state. We'd need to wrap it or modify the input area. |

**Additional Mel corrections:**
- macOS uses `lastActivityAt DESC` — ✅ Spec updated to match
- Raw session keys never in normal UI — ✅ Spec documents this
- Rename from context menu, suggest name after first message — Noted as should-have. Feasible but not trivial (needs UI + LLM integration for suggestion). Can be punted post-Gate 2B.5.

---

## 7. HIDDEN GOTCHAS Q FOUND

### H1. `TopicRepository.saveBridge()` uses `save(db)`, not `upsert`

```swift
public func saveBridge(topicId: String, sessionKey: String) throws {
    try dbManager.write { db in
        var bridge = TopicSessionBridge(...)
        try bridge.save(db)  // ← save = insert only, will fail on duplicate
    }
}
```

If `saveBridge()` is called twice for the same topic (e.g., reconnect + sync), it will throw a unique constraint violation. Should use `upsert` or `INSERT OR REPLACE`.

**Fix:** Change to `try bridge.upsert(db)` or `INSERT OR REPLACE INTO topic_session_bridge ...`

---

### H2. `Session` model has `customName`, `isPinned`, `totalTokens` — `Topic` does not

After migration, these session properties are lost in the UI because `Topic` doesn't have them. `customName` was specifically added in Migration010 for the session key alignment. If iOS abandons `Session` for UI, these fields become orphaned.

**Question:** Does `Topic` need `customName` and `totalTokens` fields? Or should the UI fetch session metadata separately?

**Recommendation:** Add `customName: String?` and `totalTokens: Int?` to `Topic` model, or create a view model that composes `Topic + Session` data for the UI.

---

### H3. `@Observable` + `@MainActor` + GRDB `ValueObservation` scheduling

The ViewModel is `@Observable @MainActor`. `ValueObservation` with `.mainActor` scheduling should work fine. But if we switch to `ValueObservation` for topics, the observation will fire on `MainActor`, which is correct. However, the topic fetch (`fetchAllActive()`) runs inside a `dbManager.reader.read` block. GRDB's `DatabasePool` uses concurrent readers — this is safe.

**One concern:** If `fetchAllActive()` is called from `ValueObservation` and also from user-initiated refresh, there could be reader contention. Unlikely on iOS with a single user, but worth noting.

---

### H4. `SyncBridge.sendMessage()` takes a `Topic?` parameter for context injection

```swift
public func sendMessage(sessionKey: String, text: String, ..., topic: Topic? = nil) async throws -> String
```

The spec's `sendMessage` flow (Section 3.2.6) doesn't pass the `topic` parameter. This means topic context injection (`[TOPIC-CONTEXT]`) won't fire for iOS sends unless the ViewModel passes the topic.

**Fix:** Update ViewModel's `send(text:to:)` to find the Topic and pass it to `bridge.sendMessage(..., topic: topic)`.

---

## 8. IMPLEMENTATION RISK MATRIX

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Migration010 already ran on existing installs — topic triggers gone | High | Certain (if app was used) | Add Migration012 to re-add topic triggers or switch to computed counts |
| `BeeChatSessionFilter` deadlock on iOS | High | High (every connect) | Add overload with injected repo |
| `TopicRow` property refactor is larger than spec suggests | Medium | Certain | Budget 2-3 hours for UI audit + update |
| `saveBridge()` unique constraint crash | Medium | Medium (on reconnect) | Change to upsert |
| Seed data migration code doesn't compile | Low | Certain if copy-pasted | Fix parameter names |
| macOS regression from iOS changes | Low | Low (shared code untouched) | Verify macOS still builds after any shared changes |
| `contextInjectedKeys` not cleared on topic switch | Low | Low | Document: one topic = one key |

---

## 9. RECOMMENDED PRE-IMPLEMENTATION FIXES

1. **Harmonise spec text:** Remove D3's nil-sessionKey flow. Make Kieran B2 (upfront key) the only documented pattern.
2. **Fix `BeeChatSessionFilter`:** Add `isBeeChatSession(_:topicRepo:)` overload. Update spec Section 3.2.4 with exact call pattern.
3. **Fix messageCount architecture:** Decide between triggers (add Migration012) vs computed counts (update `fetchAllActive()`). Document decision.
4. **Fix `saveBridge()`:** Change to upsert. This is a one-line change.
5. **Add `syncMetadataFromSessions()` to `TopicRepository`:** New method to update topics from session data. Document in spec.
6. **Audit all `Session` property access in UI layer:** List every file that touches `.title`, `.customName`, `.lastMessageAt`, etc.
7. **Verify macOS still compiles:** After any shared code changes (TopicRepository, BeeChatSessionFilter), run macOS build.

---

## 10. FINAL VERDICT

| Aspect | Score | Notes |
|---|---|---|
| Architecture soundness | ✅ Good | Topic layer is the right abstraction |
| Code claims accuracy | 🔴 Poor | Multiple mismatches with actual v5 code |
| Kieran blockers addressed | 🟡 Partial | B1 fix underspecified, B4 triggers broken by M010 |
| Mel UX incorporated | ✅ Good | All must-haves included, should-haves noted |
| Implementation risk | 🟡 Medium | 3 blockers + 5 warnings to resolve first |
| Estimated fix time | 1-2 days | Blockers are all small, just need decisions |

**Overall: Do not start implementation until B1-B3 blockers are resolved and the spec text is harmonised. Once fixed, this is a straightforward 3-5 day build.**

---

*Q — 2026-05-18*
