# Gate 2B.5 — Phase 1: Kieran's v3.2 Delta Review

**Reviewer:** Kieran (Adversarial Reviewer)
**Date:** 2026-05-18T22:00 BST
**Spec:** GATE-2B5-PHASE1-DATA-LAYER-v3.2.md
**Scope:** Delta review of v3.1 → v3.2 changes only — B11 (raw SQL upsert), B12 (topic→session key resolution), W21 removal, §6.5/§6.6 success criteria updates.
**Previous review:** GATE-2B5-PHASE1-KIERAN-REVIEW-V31.md (v3.1 — APPROVED with W20/W21/W17/W18)

---

## Executive Summary

The v3.2 spec correctly resolves B11 and B12 — the two remaining blockers from Q's v3.1 review. The raw SQL upsert is safer than the broken `upsertPreservingCreatedAt()` it replaces, and the `sessionKey(for:)` resolution pattern is clean and correct.

**One genuine issue found:** the raw SQL `strftime('%s','now')` produces Unix timestamps (integer strings), but the `topic_session_bridge` table declares `.datetime` columns, and GRDB's default date storage expects ISO8601 text format. This will cause `createdAt` and `updatedAt` to be read as `nil` or wrong values when decoding `TopicSessionBridge` from the DB.

**Verdict: NEEDS CHANGES** — 1 fix required, 2 minor notes.

---

## 1. B11 Fix — Raw SQL Upsert (§3.5)

### What Changed

Replaced `upsertPreservingCreatedAt()` (broken — hardcoded `onConflict: ["id"]` but bridge table has no `id` column) with raw SQL:

```sql
INSERT INTO topic_session_bridge
    (topicId, spaceId, openclawSessionKey, bridgeVersion, status, createdAt, updatedAt)
VALUES
    (?, 'default', ?, 1, 'active', strftime('%s','now'), strftime('%s','now'))
ON CONFLICT(topicId) DO UPDATE SET
    openclawSessionKey = excluded.openclawSessionKey,
    updatedAt = excluded.updatedAt
```

### 1.1 Conflict Clause — ✅ Correct

`ON CONFLICT(topicId)` matches the actual PRIMARY KEY (`t.column("topicId", .text).primaryKey()` in Migration005). This is correct — the root cause of B11 is fully resolved.

### 1.2 SQL Injection — ✅ Safe

Both values (`topicId`, `sessionKey`) are bound as parameters via `arguments: [topicId, sessionKey]`. No interpolation into the SQL string. Safe.

### 1.3 Date Format — 🔴 ISSUE

**The columns are declared as `.datetime`:**
```swift
t.column("createdAt", .datetime).notNull()
t.column("updatedAt", .datetime).notNull()
```

**GRDB's default date storage for `.datetime` columns is ISO8601 text** (e.g. `"2026-05-18T21:00:00.000"`), not Unix timestamp integers.

**The raw SQL uses:** `strftime('%s','now')` → produces `"1747588800"` (seconds since epoch as a string).

When GRDB decodes a `Date` from a `.datetime` column containing `"1747588800"`, it will try to parse it as an ISO8601 datetime string. **This will fail** — the result depends on GRDB's version but typically produces either `nil`, `Date.distantPast`, or a decoding error.

**Concrete impact:**
- `TopicSessionBridge.createdAt` and `updatedAt` will be wrong/nil after a raw SQL insert
- If any code reads `bridge.createdAt` or `bridge.updatedAt`, it gets garbage
- The `ON CONFLICT` update also uses `strftime('%s','now')` for `updatedAt`, so upserted rows are equally affected

**Fix:** Use `datetime('now')` instead of `strftime('%s','now')`:

```sql
-- BEFORE (wrong):
VALUES (?, 'default', ?, 1, 'active', strftime('%s','now'), strftime('%s','now'))

-- AFTER (correct — matches GRDB's ISO8601 expectation):
VALUES (?, 'default', ?, 1, 'active', datetime('now'), datetime('now'))
```

`datetime('now')` produces `"2026-05-18 21:00:00"` (SQLite's default ISO8601-ish format), which GRDB can decode into a `Date` correctly. This is also consistent with existing code in the codebase — Migration005's seed data uses `datetime('now')` for the same columns.

**Severity:** Medium. Won't crash (the `topicId` PK is still correct, and `openclawSessionKey` is fine), but any code that reads `createdAt`/`updatedAt` from a bridge row gets wrong data.

### 1.4 Preserved `createdAt` Semantics — ✅ Correct

The `ON CONFLICT ... DO UPDATE SET` clause updates `openclawSessionKey` and `updatedAt` but does **not** update `createdAt`. This correctly preserves the original creation timestamp, matching the intent of `upsertPreservingCreatedAt()`.

### 1.5 W20 Resolution — ✅ Resolved

The v3.1 warning W20 (`upsertPreservingCreatedAt()` uses `onConflict: ["id"]` but bridge PK is `topicId`) is fully resolved by replacing with raw SQL. Remove W20 from Known Limitations.

---

## 2. B12 Fix — Topic→Session Key Resolution (§3.7.6)

### What Changed

Added `sessionKey(for topicId:)` helper + updated `loadMessages()` and `streamingContent` to resolve topic IDs to session keys before querying.

### 2.1 Correctness — ✅ Correct

The resolution path is clean:
```swift
private func sessionKey(for topicId: String) -> String? {
    return topics.first(where: { $0.id == topicId })?.sessionKey
}
```

This returns `nil` for unknown topics (graceful, no crash), and returns the `sessionKey` from the in-memory `topics` array. The key is set upfront by `create(name:)` (§3.3.1) as `"agent:main:<uuid>"`, which matches the `messages.sessionId` format.

### 2.2 Staleness Risk — Minor Note

The helper reads from `self.topics` (in-memory array). If `topics` hasn't been refreshed since a session key changed, the resolution returns a stale key. **This is not a new risk** — it already existed in v3.1 where `selectedTopicId` was used directly. The resolution adds correctness (prevents blank message lists) without introducing new stale-data risk.

**Recommendation:** Not a blocker for Phase 1, but worth noting that a more robust approach would be `topicRepo.resolveSessionKey(topicId:)` (DB lookup) instead of in-memory array lookup. This could be a Phase 2 improvement if session key changes become a real scenario.

### 2.3 `streamingContent` Keying — ✅ Correct

The change from `streamingContent[selectedTopicId]` to `streamingContent[sessionKey]` is correct. Streaming content arrives keyed by session key (from the gateway), so the dictionary must use session keys to match incoming updates.

---

## 3. W21 Removal

**Finding:** The spec correctly removes `bridge.rpcClient.sessionsSubscribe()` from §3.7.2. `SyncBridge.start()` already handles session subscription, and `rpcClient` is `private`. This is a cleanup, not a behavioural change.

**Assessment:** ✅ Correct removal. No regression risk.

---

## 4. Success Criteria Updates (§6.5, §6.6)

### 4.1 Bridge Table Criteria (§6.5) — ✅ Correct

New criteria:
- `saveBridge()` uses raw SQL upsert with `ON CONFLICT(topicId)` ✅
- Duplicate `topicId` upserts correctly ✅
- UNIQUE constraint prevents two topics sharing a session key ✅
- `do/catch` handles UNIQUE violations gracefully ✅

All verifiable and aligned with the implementation spec.

### 4.2 Message Loading Criteria (§6.6) — ✅ Correct

New criteria:
- `loadMessages()` resolves topic ID to session key ✅
- `streamingContent` keyed by session key ✅
- `sessionKey(for:)` returns `nil` gracefully ✅

All verifiable.

---

## 5. Carried-Forward Items from v3.1

| Item | Status | Notes |
|------|--------|-------|
| **W17** (`connect()` idempotency) | Deferred to Phase 2 | Still safe to defer |
| **W18** (retry limit for stuck topics) | Deferred to Phase 2 | Still safe to defer |
| **W20** (upsertPreservingCreatedAt runtime) | **✅ Resolved** | Raw SQL replaces it |
| **W21** (orphaned topic on partial bridge failure) | **Still applies** | Same issue — `save(topic)` + `saveBridge()` not transactional. Still low-severity, still self-heals. |
| **`fetchAllActive()` macOS audit** | **Still applies** | v3.1 noted macOS callers may read stale `messageCount`. Not addressed in v3.2. |

---

## 6. Issue Summary

| # | Severity | Category | Description |
|---|----------|----------|-------------|
| **D1** | **MEDIUM** | Date format | Raw SQL `strftime('%s','now')` incompatible with GRDB `.datetime` columns — use `datetime('now')` |
| **N1** | Low | Freshness | `sessionKey(for:)` reads from in-memory array — DB lookup would be more robust (Phase 2 note) |
| **N2** | Low | Cleanup | W21 orphaned topic pattern unchanged from v3.1 (carry-forward) |

---

## 7. Verdict: NEEDS CHANGES

**Fix D1** (date format) is required before implementation. It's a one-line change in §3.5's raw SQL:

```
strftime('%s','now') → datetime('now')
```

Two occurrences in the `saveBridge()` SQL statement (VALUES clause and DO UPDATE SET clause). The `DO UPDATE SET` only updates `updatedAt`, so fix that one occurrence. The VALUES clause has both `createdAt` and `updatedAt`.

After this fix, the spec is clean for implementation.

**Implementation checklist for Q:**
- [x] B11 resolved (raw SQL upsert)
- [x] B12 resolved (session key resolution)
- [x] W21 removal (redundant subscribe)
- [ ] **Fix D1:** Replace `strftime('%s','now')` with `datetime('now')` in `saveBridge()` raw SQL
- [ ] Consider W21 cleanup: delete orphaned topic if bridge creation fails (optional)
- [ ] Audit `fetchAllActive()` callers on macOS for stale `messageCount` (carry-forward from v3.1)

---

*Review completed: 2026-05-18T22:00 BST*
