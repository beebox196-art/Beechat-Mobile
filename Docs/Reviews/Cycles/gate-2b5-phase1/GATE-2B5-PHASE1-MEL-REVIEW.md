# Gate 2B.5 Phase 1 Data Layer — Mel UX Review

**Reviewer:** Mel  
**Date:** 2026-05-18  
**Scope:** Data-layer readiness for the later Topic UI phases. No Phase 1 UI changes reviewed.

## Findings

### BLOCKER — Topic has no unread state

The Phase 1 `Topic` model includes `lastMessagePreview`, `createdAt`, `lastActivityAt`, and archive/sync state, but it has no unread-count or read-position data. The v2 architecture defines Topic as the user-facing conversation with "name, last message, unread count," and the accessibility spec requires unread count to be exposed as text, not only a visual badge.

Computed `messageCount` is not a substitute for unread count. The UI will need to know how many messages are unread per topic, and preferably whether the unread boundary is after a specific message/timestamp. Without this, Phase 3 cannot correctly render unread badges, VoiceOver labels, or future notification-style state.

Recommended data support:
- Add `lastReadAt` or `lastReadMessageId` per topic, plus a repository method that returns computed unread counts.
- Return a UI-facing wrapper such as `TopicListItem` / `TopicWithMetadata` containing `topic`, `messageCount`, and `unreadCount`.
- Include tests for unread count calculation, mark-read behavior, and archived topics not contributing visible unread state.

### BLOCKER — Message count SQL conflicts with the v2 message/session architecture

The Phase 1 spec computes message counts with `LEFT JOIN message m ON m.topicId = t.id`, but the v2 architecture says messages use `sessionId` and the Topic layer maps to sessions through `topic_session_bridge`. If the underlying message table does not actually have `topicId`, the count cannot work, and the later UI will lose row metadata.

This also affects delete behavior. The v2 UX requires "Delete Topic" to permanently delete the conversation and all local messages. Phase 1 says `delete(id:)` is hard delete with cascading, but the shown schema only cascades bridge rows from `topic`; it does not show how local messages tied by `sessionId` are deleted.

Recommended fix:
- Make all count and delete examples join through `topic_session_bridge.openclawSessionKey -> messages.sessionId`.
- Specify whether topic delete removes local messages, the session row, bridge rows, or only the topic shell.
- Add tests proving delete removes the local transcript expected by the confirmation copy.

### WARNING — 80-character topic names need data-layer enforcement, not only UI enforcement

An 80-character limit is reasonable for mobile if rows support two-line titles at large Dynamic Type and the new-topic field remains single-line with a counter. The issue is enforcement: Phase 1 documents "max 80 chars" in comments and Phase 3 validates paste-overflow, but the repository and migration examples do not show trimming, clamping, validation errors, or a database constraint.

If imports, migrations, tests, or non-UI call sites can create longer names, Phase 3 may still encounter overflow even if the sheet behaves correctly.

Recommended fix:
- Enforce trimmed, non-empty, <=80-character names in `TopicRepository.create`.
- Decide whether overlong migrated/imported names are truncated or rejected.
- Add a DB `CHECK(length(name) <= 80)` if GRDB/migration compatibility allows it, or a repository-level invariant with tests.

### WARNING — `lastActivityAt DESC` needs deterministic tie-breaking

`lastActivityAt` is the right primary ordering field for a mobile chat list. It is sufficient conceptually, but the Phase 1 SQL only orders by `lastActivityAt DESC`. Seed creation sets all three seed topics to the same `now`, and rapid local creation/message updates can also share timestamp granularity.

The UI needs stable row ordering to avoid rows jumping unpredictably between refreshes.

Recommended fix:
- Order by `lastActivityAt DESC, createdAt DESC, id DESC` or another stable secondary key.
- Add a repository test where multiple topics share the same `lastActivityAt`.

### WARNING — Seed data conflicts with the desired first-launch UX

The v2 first-launch UX says no walkthrough and an empty topic list with a "Start a Conversation" CTA. It also says after Gate 2B.5 seed data should be removed so the app starts with "No conversations yet." Phase 1 success criteria still require three seed topics on fresh install: `General`, `Project Ideas`, and `Quick Chat`.

For a development-only validation gate this is acceptable, but it must not leak into the first real launch experience. If seed topics are visible in Phase 3, they erase the empty-state UX and make the app feel pre-populated with generic conversations.

Recommended fix:
- Mark seed topics as debug/test-only and disable them for production/TestFlight first-launch flows.
- Add an explicit success criterion for production/final build: fresh install starts with zero topics and shows the empty state.

### WARNING — Import/empty-state support is underspecified at the repository boundary

The v2 UX has two distinct empty states: no topics/no importable sessions, and no topics/importable sessions available. Phase 1 has topic CRUD and bridge lookup, but it does not define a clean data-layer method for finding importable sessions that are not already bridged.

The UI can probably derive this from `Session` plus bridge lookups, but without a repository-level API the import sheet risks duplicating filtering rules or accidentally exposing raw cron/agent sessions.

Recommended fix:
- Add a method such as `fetchImportCandidates()` or document the exact query/filter the ViewModel must use.
- Ensure returned candidates have human-readable titles only; raw session keys should remain diagnostic-only.

### NOTE — Preview data is present, but preview semantics should be nailed down

`lastMessagePreview` is the right field for the topic row and avoids an expensive join. The spec should clarify how previews are generated for user messages, assistant messages, failed sends, interrupted streams, attachments/tool output, and empty newly-created topics.

This is not a blocker for Phase 1 if Phase 2 owns message send/receive semantics, but it should be decided before row UI work starts.

### NOTE — Archive/delete data support is directionally right

`isArchived`, `archive`, `unarchive`, and `delete` support the swipe-action UX. Archive undo can work if `lastActivityAt` and selection state are preserved by the ViewModel. The remaining UX risk is delete semantics, covered in the blocker above.

## Direct Answers

1. **Does the Topic model have everything the UI will need in Phase 3?**  
   Not yet. It has name, preview, timestamps, archive state, and ordering support. It is missing unread state/read position, and message-count support is inconsistent with the session-based message model.

2. **Are there UX requirements from v2 the data layer does not support yet?**  
   Yes: unread counts, deterministic import candidates for the empty-state import path, and verified transcript deletion for the destructive delete confirmation.

3. **Is the seed data appropriate for first launch?**  
   No for production first launch. It is acceptable only as debug/test scaffolding. The actual first-launch UX should start empty.

4. **Does the 80-character topic name length make sense for mobile displays?**  
   Yes, if enforced and paired with two-line row support. The current spec needs repository/DB validation so UI validation is not the only guard.

5. **Is `lastActivityAt` sufficient for ordering?**  
   It is sufficient as the primary sort key, but not sufficient alone. Add a stable secondary sort to avoid nondeterministic row order when timestamps tie.

## Verdict

**BLOCKED**

Phase 1 should not proceed as-is for the Topic data layer. The unread-state gap and message/session count/delete mismatch will directly block Phase 3 UI behavior. Once those are fixed, the remaining warnings are straightforward spec clarifications.
