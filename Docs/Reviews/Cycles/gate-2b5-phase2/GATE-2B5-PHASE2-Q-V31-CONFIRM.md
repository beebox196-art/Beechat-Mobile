# Gate 2B5 Phase 2 — v3.1 Review (Q — Blockers Only)

**Date:** 2026-05-27
**Reviewer:** Q
**Previous Review:** v3 (4 blockers, 7 warnings, 10 concerns)
**Spec:** `GATE-2B5-PHASE2-SPEC-v3.1.md`

---

## B1 — MISSING TOPICSYNCPAYLOAD FILE

**v3 finding:** TopicSyncPayload type/file was mentioned but not listed in §4 implementation scope.

**v3.1 check:** ✅ RESOLVED.

- §4 item #2 explicitly lists: "**`TopicSyncPayload.swift`** — New file: `Codable` struct for the JSON payload, with `extract(from:)` method that parses `ChatMessagePayload.content` as JSON"
- §4 item #7 explicitly lists: "**Xcode project** — Add `TopicSyncPayload.swift` to build sources"
- Struct contract is described: `Codable`, `extract(from:)` method that takes `ChatMessagePayload.content` and returns `TopicSyncPayload?`
- The `extract(from:)` method is referenced in `readSyncSession()` pseudocode

**Confirmation:** The file is now in scope, with a defined contract and a build-system update. No blocker.

---

## B2 — BRIDGE TABLE DUPLICATE KEYS

**v3 finding:** The reconciliation path used `resolveTopicId(for: sessionKey)` and then fell back to matching by `id`. If a topic was matched by `id` but had a different sessionKey, and then later matched by sessionKey for a different id, the bridge table could end up with a topic having two bridge entries or the same sessionKey pointing to two topics.

**v3.1 check:** ✅ RESOLVED.

- §2A Reconciliation rules now specify a strict order:
  1. **Match by `sessionKey` first** — `resolveTopicId(for: sessionKey)`
  2. **Then match by `id`** — if no sessionKey match, check if topic with same `id` exists locally
  3. **If matched by sessionKey or id** → update (not create)
  4. **If no match** → create new topic

- The rules are explicit that match-by-sessionKey takes priority over match-by-id. This prevents the dual-key collision: if a topic already has a sessionKey bridge, it is found via rule #1 and updated (rule #3), never re-matched by id (rule #2 is skipped) and never created as duplicate (rule #4 is skipped).

- The "Migration note" also confirms intent: "Existing iPhone installations may have topics with `origin: nil` from the old `reconcileFromGateway()` path. These will NOT match Mac topics by id (different UUIDs) but MAY match by `sessionKey`. The reconciliation rule #1 handles this."

**Edge case handled:** What if `resolveTopicId()` returns nil, match-by-id succeeds, and the topic has a DIFFERENT sessionKey from the payload? The spec says "update its `name`, `isArchived`, `lastActivityAt`, `lastMessagePreview`, set `origin = 'mac'`" — it does NOT say update the sessionKey. This is correct: the bridge table entry (topic id ↔ session key) is unchanged. The payload's sessionKey may differ from the stored bridge, but the stored bridge remains authoritative for that topic. This is acceptable because sessionKey is a stable identifier for the gateway session; if Mac changed it, that's a new topic. The spec doesn't say to update the bridge table, which is correct.

**Confirmation:** Duplicate-key risk is eliminated by ordered matching (sessionKey first, id second, never both). No blocker.

---

## B3 — MESSAGEMAPPER ≥20 CHARACTER GUARD

**v3 finding:** The MessageMapper dedup logic needed a minimum content-length guard (≥20 chars) to avoid deduping short messages like "yes", "ok".

**v3.1 check:** ✅ RESOLVED.

- §2B MessageMapper dedup specifies: "New: dedup by role+content within 10-second window, **minimum 20 characters**, user-role only"
- §2B SyncBridge dedup SQL query also specifies: "Finds local user-role messages with content **≥20 chars** that don't have a matching gateway message"
- §2B also: "Matches by: same session key, user role, **content prefix (first 20 chars)**, timestamp within 10 seconds"
- §3 Success Criteria #5: "Replies always appear below the user's message"
- §6 Risks: "Short messages (<20 chars) not deduped — Acceptable — MessageMapper dedup catches some; SQL dedup is belt-and-suspenders"

**Confirmation:** The ≥20 char guard is specified in both the MessageMapper dedup and the SQL-level dedup. Risk is acknowledged and accepted. No blocker.

---

## B4 — ORIGIN HARDCODED TO "LOCAL"

**v3 finding:** `TopicRepository.create()` hardcodes `origin: "local"`. Payload-derived topics would incorrectly get `origin: "local"` instead of `"mac"`.

**v3.1 check:** ✅ RESOLVED.

- §2A Reconciliation rule #4 explicitly states: "create new topic with `origin: 'mac'` using `Topic.init(...)` + `topicRepo.save()` (NOT `topicRepo.create()` which hardcodes `origin: 'local'`)"
- §2A Reconciliation rule #3 also states: "If matched by sessionKey or id → update its ... set `origin = 'mac'`"
- §4 Implementation scope item #6: "**`TopicRepository.swift`** — No changes needed; use `Topic.init(...)` + `save()` instead of `create()` for payload-derived topics"
- §6 Risks table last row: "`TopicRepository.create()` hardcodes `origin: 'local'` — Use `Topic.init(...)` + `save()` for payload-derived topics"

**Confirmation:** The spec clearly instructs the implementer to bypass `create()` and use `init + save()` for all payload-derived topics. Both creation and update paths set `origin = "mac"`. No blocker.

---

## REMOVAL LIST CLARITY (§4)

**Question:** Is the removal list clear about what code is being deleted?

**Check:** §4 lists four removals under "Removed from iPhone":

1. `reconcileFromGateway()` method — deleted entirely
2. `BeeChatSessionFilter.isBeeChatSession()` usage in `connect()` and `didReceiveSessionChange` — removed
3. `fetchSessionInfos()` call in `connect()` — removed (only used by old reconciliation path)
4. `syncMetadataFromSessions()` call in `connect()` — removed

**Assessment:** ✅ CLEAR.

Each item names a specific method or call site. Items 2–4 specify which caller is affected (`connect()` and `didReceiveSessionChange`). Item 3 includes a rationale ("only used by old reconciliation path") which helps the implementer confirm it's safe to remove. Item 4 is a companion to item 3.

**One minor note:** Item 2 says "`BeeChatSessionFilter.isBeeChatSession()` usage in `connect()` and `didReceiveSessionChange` — removed". This is slightly ambiguous: is the `isBeeChatSession()` method itself being deleted, or just its call sites? Given the context (the old path is deleted entirely), the call sites are removed. Whether the method itself should be deleted (it might be used elsewhere) is not addressed. The spec could be clearer, but this is a **minor wording issue, not a blocker**. The implementer can easily check whether `isBeeChatSession()` has other callers.

---

## SUMMARY

| Blocker | Status | Notes |
|---------|--------|-------|
| B1 — Missing TopicSyncPayload file | ✅ Resolved | Listed as item #2 in §4, with build update #7 |
| B2 — Bridge table duplicate keys | ✅ Resolved | Ordered matching (sessionKey first, id second) eliminates collision |
| B3 — MessageMapper ≥20 char guard | ✅ Resolved | Specified in MessageMapper (§2B) and SQL dedup (§2B) |
| B4 — Origin hardcoded to "local" | ✅ Resolved | Explicit instruction to use `init + save()` instead of `create()` |

**All 4 blockers from v3 are resolved in v3.1.**

**Removal list:** Clear and actionable. Minor ambiguity on whether `isBeeChatSession()` method itself is deleted vs. just call sites — not a blocker.

**Recommendation:** Spec is approved for implementation. No blockers remain.

---

*Review completed: 2026-05-27*
