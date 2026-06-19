# Gate 2B.5 — Phase 1 Data Layer v3.2 — Q Review

**Reviewer:** Q
**Date:** 2026-05-18
**Status:** APPROVED
**Scope:** Delta review — B11, B12, W21, W22, W23 only

---

## Verdict: APPROVED

All blockers from Q's v3.1 review are correctly resolved. No new compile blockers or spec/code mismatches introduced.

---

## B11 Resolution — Raw SQL upsert for `saveBridge()` ✅

**Spec §3.5:**
- `saveBridge()` now uses raw SQL `ON CONFLICT(topicId)` instead of `upsertPreservingCreatedAt()`
- Correctly notes that `upsertPreservingCreatedAt()` hardcodes `onConflict: ["id"]` but `TopicSessionBridge` has no `id` column (PK is `topicId`)
- SQL upsert syntax:
  ```sql
  INSERT INTO topic_session_bridge (...)
  VALUES (?, ...)
  ON CONFLICT(topicId) DO UPDATE SET
      openclawSessionKey = excluded.openclawSessionKey,
      updatedAt = excluded.updatedAt
  ```
- Verified: `ON CONFLICT(topicId)` matches the actual PK name
- Documented defensive behaviour for UNIQUE constraint on `openclawSessionKey` (Migration012) — two topics can't share a session key, handled via `do/catch` in `connect()`

**Verdict:** Correctly resolved. No new issues.

---

## B12 Resolution — Topic→session key resolution ✅

**Spec §3.7.6:**
- Added `sessionKey(for topicId:)` helper to ViewModel:
  ```swift
  private func sessionKey(for topicId: String) -> String? {
      return topics.first(where: { $0.id == topicId })?.sessionKey
  }
  ```
- `loadMessages()` updated:
  ```swift
  guard let key = sessionKey(for: selectedTopicId) else { return [] }
  let messages = try persistenceStore.fetchMessages(for: key)
  ```
- `streamingContent` dictionary keying updated:
  ```swift
  if let key = sessionKey(for: selectedTopicId) {
      streamingContent[key]
  }
  ```
- Explains why: messages are keyed by `sessionId` (gateway key), not `topicId` — resolution is necessary

**Verdict:** Correctly resolved. Resolution path is clear and doesn't break `messages(for sessionId:)` semantics.

---

## W21 Resolution — Removed redundant `sessionsSubscribe()` ✅

**Spec §3.7.2:**
- Removed `bridge.rpcClient.sessionsSubscribe()` call from `connect()`
- Correctly notes that `SyncBridge.start()` already handles subscription
- Correctly notes `rpcClient` is `private`, so the old call wouldn't compile anyway

**Verdict:** Correctly resolved. No loss of functionality.

---

## W22 Resolution — TopicListView line count ✅

**Spec §3.8:**
- Corrected to 4 changed lines (not 6)
- Changed `Session` → `Topic`, `.title/.customName` → `.name`, `.lastMessageAt` → `.lastActivityAt`

**Verdict:** Corrected.

---

## W23 Resolution — `sessionKey(for:)` helper ✅

**Spec §3.7.6:**
- The helper method name `sessionKey(for:)` makes the resolution intent explicit
- The `messages(for sessionId:)` parameter name stays correct — messages ARE keyed by sessionId
- The helper bridges the gap between ViewModel's topic-centric state and DB's session-centric storage

**Verdict:** Correctly resolved. No parameter rename needed.

---

## New Issues Check

| Check | Result |
|---|---|
| New compile blockers | None — all fixes use valid Swift/GRDB/SQL patterns |
| Spec/code mismatches | None — all referenced types, properties, and methods exist in the current codebase |
| Unresolved references | None — `Topic`, `TopicRepository`, `TopicSessionBridge`, `BeeChatSessionFilter`, `BeeChatPersistenceStore` all exist and have the stated signatures |
| Breaking changes to macOS | None — `BeeChatSessionFilter` overloads are additive; macOS keeps existing static methods |
| Migration risk | Low — Migration012 uses safe `ALTER TABLE` + `IF NOT EXISTS`; idempotent if re-run |
| `saveBridge()` raw SQL | Correct — `ON CONFLICT(topicId)` matches actual PK; `VALUES` clause matches columns |

---

## Notes

1. **Confidence level:** High — this is a focused delta review, not a full pass. The changes are surgical and well-scoped.
2. **Phase 2 readiness:** No blockers from Q's side. Proceed to implementation.
3. **One watch item:** `BeeChatView` (not `TopicListView`) was noted as not audited — may also reference `Session`. Flagged in §5 Known Limitations. Non-blocking for Phase 1.

---

## Signature

APPROVED for Phase 1 implementation.

Q | 2026-05-18
