# Gate 2B5 Phase 1 Data Layer — v4 Kieran Review

**Reviewer:** Kieran (adversarial)  
**Date:** 2026-05-27  
**Spec:** `GATE-2B5-PHASE1-DATA-LAYER-v4.md`  
**Code under review:** `BeeChatMobileViewModel.swift` (current state + proposed changes)

---

## BLOCKERS (must fix before build)

### B1: `didReceiveSessionChange` uses `fetchSessions()` which filters out sessions the old `fetchSessionInfos()` would not

**The problem:** `fetchSessions()` (line 153 of `SyncBridge.swift`) applies `sessionShouldAppearByDefault()`, which returns `false` for any session with `totalTokens == 0` AND key != `"agent:main:main"`. This means **brand-new sessions** that haven't exchanged a message yet (0 tokens) will be silently excluded.

The old `didReceiveSessionChange` used `fetchSessionInfos()` which returned ALL sessions with `pluginExtensions`. The new path uses `fetchSessions()` which is a subset.

**Impact:** If the Mac creates a new session (or a new session appears on the gateway), and it has 0 tokens, `didReceiveSessionChange` will not see it → no topic gets created → topic appears to vanish until user reconnects.

**Fix:** In `didReceiveSessionChange`, call `rpcClient.sessionsList()` directly (same as `fetchSessionInfos()` does — both call `rpcClient.sessionsList()`) and map to `Session` without the `sessionShouldAppearByDefault()` filter. Or add a `fetchAllSessions()` method on `SyncBridge` that skips the filter. Alternatively, the `BeeChatSessionFilter.isBeeChatSession()` check already narrows to topics that exist locally, so for **new** sessions without a bridge entry, they'll never pass the filter anyway.

**Wait — re-examination:** The new `didReceiveSessionChange` spec iterates `beeChatSessions` (filtered through `BeeChatSessionFilter`), then checks `resolveTopicId(for:) == nil` to create topics for new ones. But if the session was filtered out by `sessionShouldAppearByDefault`, it never enters the list at all. So a brand-new BeeChat session with 0 tokens that was created elsewhere won't appear on iPhone until it gets a message or until `connect()` re-runs.

**This is a regression from v3.2.** The old `reconcileTopics` processed ALL `SessionInfo` objects regardless of token count.

**Severity:** Medium. Unlikely in practice (most sessions have tokens), but violates the "session change event means something happened" expectation.

**Fix:** Either:
- (a) Add an unfiltered variant of `fetchSessions()` to `SyncBridge`, OR  
- (b) In the new `didReceiveSessionChange`, call `bridge.fetchSessionInfos()` (which returns all SessionInfo) and map to Session manually without the `shouldAppear` filter.

The irony: the spec explicitly says `fetchSessionInfos()` is dead because metadata is useless, but it's **still the right way to get a complete session list**. The metadata is dead; the session list is not.

### B2: Spec duplication between `connect()` and `didReceiveSessionChange` — divergence risk

The new `didReceiveSessionChange` in the spec duplicates logic from `connect()` steps 3–6. This is acknowledged ("duplication is acceptable for now") but it's a correctness risk: if someone changes the topic-creation logic in `connect()`, the delegate won't match.

**Not a showstopper for Phase 1**, but the spec should at least note that steps 3–6 of `connect()` and the `didReceiveSessionChange` body are semantically identical and will need extraction in Phase 2. This is a WARNINGS item, but combined with B1 it becomes more dangerous because the two paths now use **different** session-fetching methods.

**Recommendation:** Extract a `private func reconcileFromGatewaySessions(_ sessions: [Session]) async throws` method and call it from both `connect()` and `didReceiveSessionChange`. This is a one-line extraction, not scope creep.

---

## WARNINGS (should fix, non-blocking)

### W1: `isReconciling` is never set during `connect()` — TOCTOU gap

**Timeline:**
1. `connect()` starts, creates `syncBridge`, calls `await bridge.setDelegate(self)`
2. `bridge.start()` is called
3. If a `sessions.changed` event fires during `bridge.start()` or the session fetch steps, `didReceiveSessionChange` runs concurrently
4. `isReconciling` guards the delegate, but `connect()` does NOT set `isReconciling`

**So the guard only protects `didReceiveSessionChange` from itself**, not from concurrent execution with `connect()`.

**In practice:** `connect()` is called sequentially (iOS UI), and the delegate callback happens after `setDelegate`. But if `bridge.start()` fires a `sessions.changed` event before `connect()` finishes its own reconciliation, you get two concurrent reconciliation passes.

**Impact:** Two `fetchSessions()` calls, two topic-creation loops. The bridge UNIQUE constraint catches duplicate inserts (the spec acknowledges this in risk #2). The `syncMetadataFromSessions` call is idempotent (SQL UPDATE). The `fetchAllActiveWithCounts()` refresh overwrites the previous result.

**Verdict:** Benign. No data corruption, just wasted work. But the spec should note this as a known limitation rather than claim "isReconciling guard prevents concurrent reconciliation."

### W2: Error handling in `didReceiveSessionChange` — all errors are silent

```swift
} catch {
    print("[ViewModel] Failed to reconcile sessions: \(error)")
}
```

If `fetchSessions()` fails (network error, auth failure, gateway down), the error is printed and the topic list is stale. No `connectionState` update, no user-visible indicator.

**Comparison:** The old code had the same pattern. So this is not a regression. But the new code does **more work** in the critical path (fetch sessions → filter → create topics → sync metadata → refresh), so there are more failure surfaces.

**Specific concern:** If `syncMetadataFromSessions` fails mid-batch, the earlier topic creations have already committed. The topic list refresh (`fetchAllActiveWithCounts`) will reflect partial state.

**Fix:** Wrap each phase in its own `do/catch` so a metadata sync failure doesn't mask topic creation failures, or use a transaction. The existing code already has per-topic `do/catch` in `connect()` — apply the same pattern here.

### W3: `BeeChatSessionFilter.isBeeChatSession` creates a new `TopicRepository` for each call

The filter calls `topicRepo.resolveTopicId(for:)` which opens a DB read connection. For N sessions, this is N database reads, then potentially N more for `resolveTopicIdBySuffix`.

**In the new `didReceiveSessionChange`:** the filter already uses the injected `topicRepo` (`self.persistenceStore.topicRepo`), so no extra DB connections. But if sessions is large (hundreds), this is O(N) DB lookups.

**Impact:** Negligible for MVP (< 50 sessions). But worth noting for the spec's "future scope" section.

### W4: Orphan detection is lost

The old `reconcileTopics(from:)` Phase 2 had orphan detection: if a local topic's session key disappeared from the gateway session list, it was auto-archived.

The new `didReceiveSessionChange` **does not** have this. If a session is deleted on the Mac (or gateway), the iPhone will keep showing the topic forever.

**The spec says:** "Orphan detection" was part of the old `reconcileTopics`. It's silently dropped.

**Verdict:** Not a blocker — orphan detection was a "nice to have" that depended on having the full session list (which we don't get via `fetchSessions()` anyway). But the spec should explicitly acknowledge this as a **removed capability**, not an accidental omission.

### W5: `sessionKeys` parameter is unused

The delegate receives `[String]` of changed session keys but ignores them, fetching ALL sessions instead. This is O(N) when O(K) would suffice (K = number of changed sessions).

**In practice:** Gateway sends the keys that changed. We could look up just those sessions' metadata rather than refetching everything.

**Verdict:** Performance issue, not correctness. Acceptable for Phase 1 but should be tracked.

### W6: Topic creation in `didReceiveSessionChange` generates fresh UUIDs

Each new topic gets `UUID().uuidString` as ID. The old `reconcileTopics` used `metadata.topicId` from the Mac's metadata. Without metadata, the iPhone picks its own IDs.

**Impact:** If the same session appears on both Mac and iPhone, they'll have **different topic IDs**. The bridge table links them via session key, so messages still route correctly. But if sync-channel reconciliation is added later, ID mismatches will need resolution.

**Verdict:** Known and acceptable. The session key is the canonical link. But the spec should document this assumption explicitly.

---

## PASSES (verified correct)

### P1: Dead code audit — spec correctly identifies all dead paths

Checked the ViewModel. Only reference to `beechatMetadata` is inside `reconcileTopics(from:)` (line 522), which is the method being removed. No other code references `pluginExtensions`, `beechatMetadata`, or `fetchSessionInfos()` in the ViewModel.

**Pass confirmed.**

### P2: `syncMetadataFromSessions` works correctly without metadata

This method updates `lastMessagePreview`, `lastActivityAt`, and `unreadCount` from Session data — not from `beechatMetadata`. It uses the bridge table to map session→topic. Fully independent of the dead path.

**Pass confirmed.**

### P3: Bridge UNIQUE constraint protects against duplicate inserts

`saveBridge` creates a row in `topic_session_bridge` with a UNIQUE constraint on `openclawSessionKey`. If `connect()` and `didReceiveSessionChange` both try to create a topic for the same session, the second insert fails gracefully.

**Pass confirmed.**

### P4: Rollback plan is sufficient

All changes are in one file (`BeeChatMobileViewModel.swift`). `git checkout <commit> -- <file>` fully restores. No shared package changes, no migrations, no database schema changes.

**Pass confirmed.**

### P5: `connect()` session-based topic creation (steps 3–5) is unchanged

The spec correctly identifies this path as already working and not part of the changes. The only thing removed from `connect()` is the dead `fetchSessionInfos()` / `reconcileTopics()` call.

**Pass confirmed.**

### P6: `isReconciling` is cheap and correct as a self-guard

Even though it doesn't protect against concurrent execution with `connect()` (see W1), it does prevent rapid `sessions.changed` bursts from queuing up redundant work. The `defer` ensures it's always released, even on error.

**Pass confirmed.**

---

## SIMPLICITY VERDICT: **About right**

The spec does the right thing: strip the dead path, replace with the session-based approach that already works in `connect()`. The net change is "remove 3 things, rewrite 1 delegate" — proportional to the problem.

Two criticisms:
1. **B1** means the replacement delegate is not quite equivalent to the old behavior (session filtering gap). Fix is small.
2. **W4** (orphan detection dropped) is a feature loss that should be acknowledged, not hidden.

Neither invalidates the approach. The v4 spec is a genuine simplification over v3.2, and the remaining complexity is in the right places (session filtering, bridge management). The spec correctly identifies what's dead, what's alive, and draws a clean scope boundary.

**Recommendation:** Fix B1 (use unfiltered session list in `didReceiveSessionChange`), acknowledge W4, and approve.
