# Gate 2B5 Phase 2 - Mel UX Review (v3)

**Date:** 2026-05-27  
**Reviewer:** Mel  
**Scope:** iPhone-only UX review for topic sync and message ordering dedup  
**Spec reviewed:** `GATE-2B5-PHASE2-SPEC-v3.md`  
**Verdict:** APPROVED with concerns and suggestions

---

## Summary

The v3 approach is directionally right for UX: the iPhone should show the Mac's intentional topic list, not infer topics from every gateway session. Using a Mac-authored topic payload avoids the worst previous behavior, where the iPhone could surface cron, subagent, and boot sessions as user-facing topics.

The remaining UX risk is not the data transport. It is whether the user understands what changed: where the Mac topics came from, why some topics appeared or disappeared, whether sync is current, and why the message list may briefly correct itself after gateway history arrives.

No blocker from Mel. The items below are concerns and suggestions only.

---

## Concerns

### C1 - Sync can happen invisibly

The spec says the iPhone reads the sync payload on connect and on `sessions.changed`, then reconciles local topics. That gets the data right, but it does not define any user-facing feedback when Mac topics appear, update, or fail to load.

UX impact:
- A user opening BeeChat on iPhone may suddenly see Mac topics without knowing they synced.
- If the payload is missing, malformed, stale, or unavailable, the app falls back to local topics only. That is safe, but the user has no way to distinguish "standalone mode" from "Mac sync has not arrived yet."
- If the Mac archives a topic, it may disappear from the active list with no visible explanation.

Recommendation: add a lightweight sync affordance somewhere in the topic list UI, even if only in debug/M10 form. Examples: "Synced from Mac just now", "Local topics only", or a small last-sync timestamp in the sidebar/list footer. This does not need to be a modal or alert.

### C2 - Topic origin and naming need a display rule

The reconciliation model distinguishes `origin: "mac"` from local/iPhone topics, but the spec does not define how this appears to the user. If Mac topics and iPhone-created topics are shown together with no provenance, duplicate or near-duplicate names can become confusing.

Edge cases to account for:
- Mac payload contains "Project Status" and iPhone already has a local "Project Status".
- Seed topics remain visible alongside newly synced Mac topics.
- A Mac topic is renamed and appears to the user as a different topic unless the update is visually smooth.
- Two Mac topics have similar names but different session keys.

Recommendation: define a display rule for duplicate names. The simplest acceptable rule is to allow duplicates but show secondary text such as last message preview, last activity, or source context so the user can tell them apart. If the product does not want visible "Mac" labels everywhere, use provenance only when ambiguity exists.

### C3 - Topic ordering is underspecified

The payload includes `lastActivityAt`, but the spec does not explicitly say how reconciled topics are ordered after sync. This matters because topic discovery is a list-navigation experience: if newly synced topics appear in unexpected positions, the user may not notice them or may think the list jumped.

Recommendation: specify that active topics sort by `lastActivityAt` descending, with stable tie-breaking. If local-only topics are mixed with Mac topics, define whether they participate in the same sort or appear in a separate local section. I would prefer one unified list sorted by activity for M10, with enough secondary metadata to disambiguate.

### C4 - Archived Mac topics may feel like silent deletion

Archiving missing or archived Mac-origin topics is safer than deleting them, but if archived topics are hidden from the active topic list, the user's visible experience is still "the topic disappeared."

Recommendation: if a topic is archived due to Mac sync, avoid using the same UX language as a user-initiated iPhone archive. It should not look like the user just did something. A subtle status or recoverability path is enough: archived topics should remain findable from an archive view, or a sync status should explain that Mac archived topics are hidden.

### C5 - Message dedup may create a visible correction

The ordering fix is sensible: keep the gateway message and remove the local duplicate after `fetchHistory()`. From the user's perspective, though, this can still cause a brief correction in the transcript.

Possible UX artifacts:
- The user's local message appears, then shifts when the gateway copy replaces it.
- A duplicate appears briefly and then disappears.
- The scroll position changes after dedup, especially near the bottom during an active reply.

Recommendation: add UX validation criteria for the visual behavior, not just the final data state. "Replies always appear below the user's message" is necessary, but also verify "no duplicate user message remains visible after history refresh" and "scroll stays anchored to the active exchange."

---

## Suggestions

### S1 - Add sync state copy to empty and local-only states

The standalone fallback is good, but the empty state should distinguish:
- no local topics yet
- checking Mac topics
- Mac sync unavailable
- Mac sync available but payload has no topics

This can be very small copy. The important part is preventing the user from thinking the app is broken when the Mac topic list has not arrived.

### S2 - Treat malformed and empty payloads differently in UI/logging

The safety rule says empty or malformed payloads do nothing. That is correct for data safety. For UX/debuggability, empty and malformed mean different things:
- Empty payload: Mac has no publishable topics, or publishing is not ready.
- Malformed payload: sync exists but failed.

Suggestion: keep the data behavior identical, but expose different internal state so the UI or diagnostics can say the right thing later.

### S3 - Use `lastMessagePreview` carefully

`lastMessagePreview` is useful for topic discovery, especially when names are generic. It should be truncated consistently and treated as optional. If the preview is stale or missing, the row should still look intentional, not broken.

Suggestion: define fallback row metadata: `lastActivityAt` if preview is missing; source/provenance only if needed for disambiguation.

### S4 - Add a duplicate-name test case

The success criteria cover topic discovery and archival, but not naming ambiguity. Add one UX-facing test case:

> Given a local iPhone topic and a Mac topic with the same display name, both remain accessible and visually distinguishable.

This catches the highest-probability confusion case without changing the sync model.

### S5 - Validate message ordering with short-message edge cases

The dedup rule intentionally ignores user messages under 20 characters. That is safer for accidental deletion, but many real chat messages are short: "yes", "ok", "try now", "fixed?", "what changed?"

Suggestion: include manual UX validation for short messages. The system may not dedup them, but the transcript should still avoid the reply-above-user-message failure mode for common short replies.

---

## Final Assessment

Approved from a UX perspective. The spec fixes the biggest discovery problem by making the Mac's topic list authoritative instead of guessing from gateway sessions.

Before implementation, I would tighten the spec in three places:
1. Define topic ordering after sync.
2. Define what the user sees when sync succeeds, is unavailable, or silently falls back.
3. Add validation for duplicate topic names and visible message-list stability after dedup.

None of these require changing the core architecture.
