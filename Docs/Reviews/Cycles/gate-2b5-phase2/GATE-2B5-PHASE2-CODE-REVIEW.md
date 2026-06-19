# Gate 2B5 Phase 2 v3.1 — Code Review (Kieran, Adversarial)

**Date:** 2026-05-27 22:30 GMT+1
**Reviewer:** Kieran (Adversarial Code Review)
**Scope:** iPhone app — topic sync payload, reconciliation, message dedup
**Files reviewed:** 5 (1 new, 4 modified)

---

## Verdict

**4 Must-Fix blockers.** Do not merge until these are resolved.

| # | Severity | File | Issue |
|---|----------|------|-------|
| M1 | **M** | `BeeChatMobileViewModel.swift` | Staleness guard bypassed in `connect()` |
| M2 | **M** | `TopicSyncPayload.swift` | ISO8601 parser rejects timestamps without fractional seconds |
| M3 | **M** | `BeeChatMobileViewModel.swift` | `isReconciling` race on initial `connect()` |
| M4 | **M** | `BeeChatMobileViewModel.swift` | Archive sweep hard-caps at 100 topics |

---

## M1 — Staleness guard bypassed in `connect()` [BLOCKER]

**File:** `BeeChatMobileViewModel.swift`, `connect()` method, step 2.

`connect()` calls `bridge.fetchSyncPayload(sessionKey:)` **directly**, bypassing `readSyncPayload()`. The staleness guard that prevents re-processing the same payload lives entirely inside `readSyncPayload()`.

**Consequence:** On reconnect (disconnect → reconnect, or app backgrounding), the Mac may still have the same payload in `agent:main:beechat-sync`. Since `connect()` skips the staleness check, it re-reconciles the same payload. This causes:
- Unnecessary topic re-saves (N× topics written again)
- `self.topics` reloaded unnecessarily
- On first run, `lastSyncTimestamp` is 0.0 — any payload passes. But on reconnect, the stored timestamp is stale and should be checked.

**Evidence:**
```swift
// connect() — step 2, no staleness check:
if let content = try await bridge.fetchSyncPayload(sessionKey: "agent:main:beechat-sync") {
    if let payload = TopicSyncPayload.extract(from: content) {
        try await reconcileFromPayload(payload)  // ← no staleness guard!
    }
}
```

Contrast with `didReceiveSessionChange`, which correctly calls `readSyncPayload()` (which includes staleness checking).

**Fix:** Replace the direct `bridge.fetchSyncPayload()` call in `connect()` with `readSyncPayload()`:
```swift
// In connect(), step 2:
if let payload = try await readSyncPayload() {
    try await reconcileFromPayload(payload)
}
```

**Risk if unfixed:** Reconnect storms, unnecessary writes, potential UI flicker on topic list refresh.

---

## M2 — ISO8601 parser rejects timestamps without fractional seconds [BLOCKER]

**File:** `TopicSyncPayload.swift`, `timestampDate` computed property.

```swift
var timestampDate: Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: timestamp)
}
```

When `.withFractionalSeconds` is set, `ISO8601DateFormatter` **requires** fractional seconds. `"2026-05-27T20:00:00Z"` (no fractional seconds) returns `nil`. Only `"2026-05-27T20:00:00.000Z"` parses.

**Consequence:** The spec says "ISO 8601 with Z suffix (UTC)" — it does NOT mandate fractional seconds. If the Mac publishes `"2026-05-27T20:00:00Z"`, `timestampDate` returns `nil`, which causes:
1. The staleness guard in `readSyncPayload()` is silently bypassed (`if let payloadDate = ...` fails → no check)
2. `UserDefaults` is never updated with the timestamp
3. Every subsequent payload also bypasses staleness (stored value stays 0.0)

**Same bug exists in** `TopicPayloadItem.lastActivityDate` — same formatter, same issue.

**Fix:** Use two formatters with fallback:
```swift
var timestampDate: Date? {
    let baseOptions: ISO8601DateFormatter.FormatOptions = [.withInternetDateTime]
    
    // Try with fractional seconds first
    let fmt1 = ISO8601DateFormatter()
    fmt1.formatOptions = baseOptions.union([.withFractionalSeconds])
    if let date = fmt1.date(from: timestamp) { return date }
    
    // Fallback to no fractional seconds
    let fmt2 = ISO8601DateFormatter()
    fmt2.formatOptions = baseOptions
    return fmt2.date(from: timestamp)
}
```

**Risk if unfixed:** Staleness guard completely ineffective for any Mac that doesn't include `.000` in timestamps. Data loss: stale payloads overwrite fresh reconciliations silently.

---

## M3 — `isReconciling` race on initial `connect()` [BLOCKER]

**File:** `BeeChatMobileViewModel.swift`

`connect()` runs reconciliation (step 2) **without** setting `isReconciling = true`. If a `didReceiveSessionChange` event fires during the async work in `connect()`, the delegate method sees `isReconciling == false` and starts a **second** reconciliation in parallel.

**Timeline:**
```
T0: connect() starts
T1: connect() calls reconcileFromPayload(payload1) — async, no isReconciling guard
T2: Gateway fires sessions.changed for beechat-sync
T3: didReceiveSessionChange reads readSyncPayload() → payload2
T4: reconcileFromPayload(payload2) starts — runs concurrently with T1's reconciliation
T5: payload2 finishes → archives topics not in payload2
T6: payload1 finishes → overwrites changes, re-creates topics payload2 archived
```

**Consequence:** Two concurrent reconciliations on the same topic database. Archive state can flip-flop. Topics can be un-archived then re-archived. `self.topics` list can end up in inconsistent state (two refreshes clobbering each other).

**Fix:** Set `isReconciling` around the reconciliation in `connect()`:
```swift
// In connect(), step 2:
isReconciling = true
do {
    if let payload = try await readSyncPayload() {
        try await reconcileFromPayload(payload)
    }
} catch {
    print("[ViewModel] Sync payload reconcile failed: \(error)")
} finally {
    isReconciling = false
}
```

**Risk if unfixed:** Concurrent write transactions on GRDB. Undefined behavior on topic archive state. Potential data corruption.

---

## M4 — Archive sweep hard-caps at 100 topics [BLOCKER]

**File:** `BeeChatMobileViewModel.swift`, `reconcileFromPayload()`, step 2.

```swift
let allTopics = try topicRepo.fetchAllActive()  // default limit: 100
for topic in allTopics where topic.origin == "mac" && !payloadKeys.contains(topic.sessionKey ?? "") {
    try topicRepo.archive(topicId: topic.id)
}
```

`fetchAllActive()` has a default `limit: 100`. If there are >100 active topics, topics 101+ are **never checked** for archival.

**Consequence:** Mac-origin topics beyond position 100 (ordered by `lastActivityAt DESC`) that the Mac has removed will **not be archived** on the iPhone. They remain visible as zombie topics — the user sees topics the Mac no longer has.

**Fix:** Explicitly pass a larger limit or use no limit:
```swift
// If the repo supports unlimited fetches:
let allTopics = try topicRepo.fetchAllActive(limit: Int.max)

// Or better, add a dedicated unlimited method to TopicRepository.
```

Also check `fetchAllActiveWithCounts(limit: 100)` calls in `connect()` (step 3) and `reconcileFromPayload()` (step 3) — same issue applies to topic list display.

**Risk if unfixed:** Zombie topics persist indefinitely. User sees stale Mac topics that no longer exist.

---

## S1 — Should Fix: Inconsistent staleness checking between code paths

**File:** `BeeChatMobileViewModel.swift`

Three code paths read the sync payload:
1. `connect()` → **no staleness check** (calls bridge directly) → see M1
2. `didReceiveSessionChange` → calls `readSyncPayload()` → has staleness check ✅
3. Direct calls elsewhere → unknown

After M1 is fixed, paths 1 and 2 both use `readSyncPayload()`. But `readSyncPayload()` itself has an issue: if timestamp parsing fails (M2), staleness is silently bypassed. After M2 is fixed, this resolves too.

**Fix:** Addressed by M1 + M2.

---

## S2 — Should Fix: `saveBridge` uses `try?` (silent failure)

**File:** `BeeChatMobileViewModel.swift`, `reconcileFromPayload()`, new topic creation:

```swift
try? topicRepo.saveBridge(topicId: topic.id, sessionKey: item.sessionKey)
```

If the bridge insert fails (constraint violation, DB error), the topic exists but has no bridge entry. Future message sends to this topic will fail with "no session key" errors.

**Fix:** Either:
- Remove `try?` and let the error propagate (reconciliation fails loudly)
- Or log the failure: `do { try topicRepo.saveBridge(...) } catch { print("[ViewModel] Bridge save failed for \(item.id): \(error)") }`

**Risk if unfixed:** Zombie topics with no bridge — user sees topic but can't send messages to it.

---

## S3 — Should Fix: Markdown extraction uses `...endRange.lowerBound` (fragile)

**File:** `TopicSyncPayload.swift`, `extract(from:)`:

```swift
let jsonString = String(content[range.lowerBound...endRange.lowerBound])
```

This uses a closed range ending at `lowerBound` of the `}` match. In the tested case (`{"v": 1}`), this works because `...lowerBound` includes the `}` character. But the idiomatic and safer form is:

```swift
let jsonString = String(content[range.lowerBound..<endRange.upperBound])
```

**Why this matters:** If the content has multiple `{` characters (e.g., nested JSON preceded by text like "Here's the payload: {"), the `range(of: "{")` finds the first `{`, not the one starting the JSON object. The extraction would grab from the wrong starting point.

**Fix:** Either use `..<endRange.upperBound` (safer), or better: parse the whole content as JSON first (already done), and only attempt markdown extraction as a true fallback for wrapped content.

**Risk if unfixed:** Low for pure JSON payloads. Moderate if Mac wraps content in explanatory text.

---

## N1 — Nice to have: `TopicPayloadItem.isArchived` optional but treated as `false`

**File:** `BeeChatMobileViewModel.swift`, `reconcileFromPayload()`:

```swift
updated.isArchived = item.isArchived ?? false
```

If the Mac omits `isArchived` from a topic item (e.g., initial version), it defaults to `false` (not archived). If a topic was previously archived on the iPhone and the Mac sends an update without `isArchived`, it gets un-archived.

**Spec alignment:** This is acceptable — the spec treats the Mac's payload as authoritative. But worth documenting as intentional.

---

## N2 — Nice to have: `connect()` step 3 reloads topics without considering new topics may have been created

After `reconcileFromPayload()` creates new topics, `connect()` step 3 calls `fetchAllActiveWithCounts()` which correctly picks them up. However, the auto-select logic (step 4) only fires if `selectedTopicId == nil`. If the user had a topic selected from the initial load, and that topic gets archived by reconciliation, the selection is not updated.

**Fix:** After reconciliation, check if `selectedTopicId` still points to an active topic:
```swift
if self.selectedTopicId != nil,
   self.topics.first(where: { $0.id == self.selectedTopicId }) == nil {
    self.selectedTopicId = self.topics.first?.id
}
```

**Risk if unfixed:** User sees an empty message list for an archived topic.

---

## N3 — Nice to have: `didReceiveSessionChange` uses substring match

```swift
guard sessionKeys.contains(where: { $0.contains("beechat-sync") }) else { return }
```

`contains` is a substring match, not equality. If any session key contains "beechat-sync" as a substring (unlikely but possible), it would trigger an unnecessary payload read.

**Fix:** Use equality:
```swift
guard sessionKeys.contains(Self.syncSessionKey) else { return }
```

**Risk if unfixed:** Negligible in practice. The well-known key is `agent:main:beechat-sync` and unlikely to be a substring of other keys.

---

## Summary

| Count | Severity |
|-------|----------|
| 4 | **Must Fix** (blocks deployment) |
| 3 | Should Fix (before merge) |
| 3 | Nice to Have (can defer) |

**Recommendation:** Fix M1–M4 before merging. The combination of M1 + M2 alone means the staleness guard could be completely ineffective in production, allowing stale payloads to overwrite fresh data. M3 introduces a genuine concurrent-write race condition. M4 means the system silently fails to archive topics beyond 100 — a silent correctness failure that worsens as the user accumulates topics.

S1–S3 should be addressed in the same PR for hygiene. N1–N3 can be deferred.
