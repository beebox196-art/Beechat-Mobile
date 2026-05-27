# GATE-2B5-PHASE2 — Kieran Adversarial Review (v3 Spec)

**Date:** 2026-05-27 21:57 BST
**Reviewer:** Kieran (Adversarial Reviewer)
**Spec:** `/Users/openclaw/Projects/BeeChat-Mobile/Docs/Architecture/GATE-2B5-PHASE2-SPEC-v3.md`
**Scope:** iPhone-only changes (no Mac app changes)

---

## Summary

This is a materially better spec than v1/v2 — the circular-filter problem is correctly identified, the payload approach is sound in principle, and the reconciliation rules respect origin boundaries. However, there are **3 Blockers** and **5 Conditions** that must be resolved before build. The spec also contains one **factual contradiction** about where dedup runs.

---

## BLOCKERS (B) — Must fix before build

### B1. No plan to remove or deprecate `reconcileFromGateway()` — reconciliation-loop risk

**Problem:** The spec says to *replace* `reconcileFromGateway()` with `reconcileFromPayload()`, but the current `connect()` flow calls `reconcileFromGateway(sessionInfos)` (line ~90 of ViewModel) AND the `didReceiveSessionChange` delegate also calls it. The new `readSyncSession()` + `reconcileFromPayload()` calls are described but there is no plan to remove the old path.

**Risk:** Both reconciliation paths run simultaneously. `reconcileFromPayload` creates topics from the Mac's payload. Then `reconcileFromGateway` runs and uses `BeeChatSessionFilter.isBeeChatSession()` — which checks the topic repo for a bridge entry. The newly-created topics now have bridge entries, so `isBeeChatSession` returns true for their session keys. This means `reconcileFromGateway` may attempt to re-reconcile topics it just created, potentially overwriting `origin` values, double-creating, or creating duplicate bridge entries.

**Fix:** The spec must explicitly state that `reconcileFromGateway()` is removed from both `connect()` and `didReceiveSessionChange`, replaced entirely by `readSyncSession()` → `reconcileFromPayload()`. If `readSyncSession()` finds no payload (standalone mode), the old path must NOT be called as a fallback — it should simply skip.

### B2. `lastSyncTimestamp` is mentioned but never defined — stale-overwrite protection is missing

**Problem:** Section 6 (Risks) says "Store `lastSyncTimestamp`, reject payloads older than last sync." But the spec never defines:
- Where `lastSyncTimestamp` is stored (UserDefaults? GRDB? in-memory?)
- What field on the payload is compared (`timestamp`? the payload's own timestamp field?)
- How the timestamp comparison works (what if Mac clock is skewed?)

Without this, the implementation could silently overwrite a fresh payload with a stale one from `chat.history(limit: 1)` returning an older message, or reprocess the same payload on every `sessions.changed` event.

**Fix:** Specify the storage location (recommend `UserDefaults` keyed by `"beechat_lastSyncTimestamp"`, since this is transient state that shouldn't survive app reinstall), the comparison field (`TopicSyncPayload.timestamp`), and the comparison logic (`if payload.timestamp <= storedTimestamp, skip`). Also handle the clock-skew case: if Mac and iPhone clocks differ by >5 minutes, the comparison becomes unreliable. Either use a monotonically increasing sequence number instead of a timestamp, or add a grace window.

### B3. SQL dedup runs in `processChatFinal`, NOT in `loadMessages()` — spec contradicts itself

**Problem:** Section 2B says "The dedup runs inside `loadMessages()` after `fetchHistory()` returns." But `loadMessages()` (in `BeeChatView.swift`, line 57) only calls `viewModel.messages(for: key)` — it reads from the database, it does NOT call `fetchHistory()`. The SQL dedup (`dedupLocalMessages`) is actually called in `SyncBridge.processChatFinal()` and `processChatError()` — which is correct timing, but the spec's description is wrong.

**This is a blocker** because if an implementer follows the spec literally and puts dedup in `loadMessages()`, it will either (a) never run (because `loadMessages` doesn't call `fetchHistory`), or (b) run at the wrong time (before gateway messages are persisted).

**Fix:** Correct the spec to say the SQL dedup runs in `SyncBridge.processChatFinal()` and `processChatError()`, after `fetchHistory()` upserts the gateway messages. Also verify that `MessageMapper`'s in-memory dedup runs in the same flow (it currently runs in the view layer when mapping, which is fine as a second layer of protection).

---

## CONDITIONS (C) — Fix before merge, but not blocking initial build test

### C1. Payload size limit not addressed — `chat.history(limit: 1)` could return a very large message

**Problem:** If the Mac has 50+ topics, the JSON payload could be several KB. The spec doesn't address:
- What happens if the payload exceeds a reasonable size?
- Should there be a size guard before parsing?
- What if `chat.history` returns the message wrapped in a chat-format envelope with extra metadata?

The spec mentions `TopicSyncPayload.extract(from:)` handles "both pure JSON and wrapped content" but doesn't define what "wrapped content" means.

**Fix:** Define the exact expected format. If the Mac writes the payload as a chat message, the content field will be a JSON string. If it writes it as a plugin metadata field, it's different. Also add a size guard: reject payloads >50KB (sanity check — 50 topics × ~200 bytes each ≈ 10KB, so 50KB is generous but catches runaway data).

### C2. Session-change reconciliation loop through `isReconciling` is fragile

**Problem:** The `isReconciling` flag in `didReceiveSessionChange` (ViewModel line ~290) is a `Bool` that prevents re-entry. But:
- If reconciliation throws, `defer { self.isReconciling = false }` handles it — OK.
- If `readSyncSession()` is added, it also needs to check `isReconciling`.
- If BOTH `readSyncSession()` and the session-info fetch run in the same delegate callback, one could still race past the other.

The spec doesn't clarify whether `readSyncSession()` runs inside `didReceiveSessionChange` or as a separate call.

**Fix:** Clarify that `readSyncSession()` is called from `didReceiveSessionChange` (replacing the current `fetchSessionInfos` + `reconcileFromGateway` flow), protected by the same `isReconciling` gate. Document the exact call order: `sessions.changed` → `didReceiveSessionChange` → guard `isReconciling` → `readSyncSession()` → `reconcileFromPayload()`.

### C3. `reconcileFromPayload()` reconciliation rules don't address name conflicts

**Problem:** The reconciliation rules say "If a topic from the payload has a matching `id` locally → update its name." But what if the user renamed the topic on iPhone? The spec says "one-way sync: Mac → iPhone" (Section 5), which is correct, but there's no explicit rule for what happens to iPhone-side renames. Currently, the spec would silently overwrite them.

**Fix:** This is acceptable for v3 (one-way sync is intentional), but the spec should explicitly document this as a known limitation: "iPhone-side topic renames are overwritten by Mac sync." If this is surprising to users, consider adding a `lastModifiedBy` field or a "Mac wins" comment in the reconciliation logic.

### C4. Standalone mode: `reconcileFromGateway` may still create topics even when no sync payload exists

**Problem:** If `readSyncSession()` finds no payload, the spec says "show local topics only." But the current `connect()` flow ALSO calls `fetchSessions()` and `fetchSessionInfos()` and `reconcileFromGateway()`. Even if the new path skips, the old path still runs and may create topics from gateway sessions (the circular filter problem, partially mitigated by existing bridge entries).

**Fix:** This is related to B1, but worth calling out separately: in standalone mode (no sync payload), the old reconciliation path should be completely bypassed. The spec should state: "If no sync payload is available, skip ALL gateway-based topic reconciliation. Only show locally-created topics."

### C5. `fetchHistory(sessionKey: "agent:main:beechat-sync", limit: 1)` — what if the session doesn't exist?

**Problem:** The spec says "Wrap in `try?`, treat as 'no sync data available'" (Section 6, Risk 3). But `fetchHistory` is currently `async throws` in `SyncBridge`. If the session doesn't exist on the gateway, the RPC call may return an error (not just empty results). The `try?` swallows all errors, including genuine connection failures.

**Fix:** Distinguish between "session doesn't exist" (expected, treat as standalone mode) and "network error" (log as warning, retry on next connect). Consider a specific check: if `fetchHistory` throws a "session not found" error, treat as standalone. If it throws a connection error, log and retry.

---

## WARNINGS (W) — Should fix, can defer

### W1. MessageMapper dedup is UI-layer only — doesn't prevent database-level duplicates

The current `MessageMapper.exyteMessages` dedup is a presentation-layer filter. It prevents duplicates from showing in the UI, but the database still contains both the local-UUID and gateway-UUID copies. The SQL dedup in `dedupLocalMessages` addresses this, but only for messages ≥20 chars. Short user messages ("Hi", "OK", "Thanks") remain duplicated in the database forever. The spec raises the minimum to 20 chars, which is good, but short messages are still vulnerable. **Acceptable for v3** — 20 chars is a reasonable cutoff, and short messages are less confusing when duplicated.

### W2. Payload timestamp uses ISO 8601 — timezone skew risk

If the Mac writes `"2026-05-27T20:00:00Z"` and the iPhone parses it with a slightly different locale or timezone setting, the comparison could be off. `ISO8601DateFormatter` defaults to UTC, which is correct, but the spec should explicitly require UTC format (the `Z` suffix).

### W3. No migration path for existing iPhone installations

iPhone users who already have the app installed will have topics created by the old `reconcileFromGateway` path, likely with `origin: nil`. When the new sync payload arrives, these topics won't match the Mac's topic IDs (because they were created independently). The spec says "If a local topic has `origin: nil` or `origin: 'local'` → never archive it." This means the user will see duplicate topics: their old local ones AND the new synced ones. **Acceptable** — users can manually archive old topics. But the spec should document this as a known migration issue.

### W4. `processChatFinal` calls `fetchHistory` and `dedupLocalMessages` in a detached Task

```swift
Task {
    do {
        _ = try await fetchHistory(sessionKey: sessionKey)
        try? config.persistenceStore.dedupLocalMessages(sessionKey: sessionKey)
    } catch {
        print("[SyncBridge] fetchHistory failed in processChatFinal: \(error)")
    }
}
```

If `fetchHistory` fails, `dedupLocalMessages` is never called (the `catch` skips it). This means a failed history fetch leaves duplicates in place. The `try?` on dedup also silently swallows dedup failures. **Acceptable** — failures are transient and will be retried on the next message exchange, but it means duplicates can persist longer than expected.

---

## Architecture Assessment

| Concern | Rating | Notes |
|---------|--------|-------|
| Topic discovery approach | ✅ Correct | Mac publishes, iPhone reads — gateway is dumb pipe. Solves the circular filter. |
| Origin-based archival | ✅ Correct | Local topics are protected. Mac-created topics can be archived. |
| Empty payload guard | ✅ Correct | Zero topics = no action, not "archive everything." |
| Message dedup (SQL) | ⚠️ Good but spec contradicts | Implementation exists and runs at the right time; spec description is wrong. |
| Message dedup (UI) | ⚠️ Adequate | 10s window, 20 chars is better than 2s. Still UI-only, not database-cleaning. |
| Standalone fallback | ⚠️ Unclear | Risk of old path running alongside new path (see B1/B4). |
| Mac-side deferred | ✅ Correct | No Mac changes in this spec. Good scope discipline. |

---

## Recommended Fix Priority

1. **B1** — Remove/replace `reconcileFromGateway()` entirely (prevents dual-path chaos)
2. **B3** — Fix spec contradiction about where dedup runs (prevents wrong implementation)
3. **B2** — Define `lastSyncTimestamp` storage and comparison (prevents stale overwrites)
4. **C4** — Clarify standalone mode behavior (no gateway reconciliation without payload)
5. **C1** — Define payload format and size limits (prevents parsing failures)
6. **C2** — Clarify `readSyncSession()` call flow (prevents race conditions)
7. **C5** — Distinguish "no session" from "network error" (better error handling)
8. **C3** — Document one-way sync overwrite behavior (user-facing clarity)
9. **W1-W4** — Minor, can defer to next gate

---

## Verdict

**SPEC NOT READY FOR BUILD** — 3 blockers. The core architecture is sound (payload-based sync is the right approach), but the spec's implementation details contain contradictions and gaps that could lead to data loss or duplicate topics if built as written.

After fixing B1, B2, B3, and clarifying C4, this spec should be buildable. The remaining conditions can be addressed during code review.
