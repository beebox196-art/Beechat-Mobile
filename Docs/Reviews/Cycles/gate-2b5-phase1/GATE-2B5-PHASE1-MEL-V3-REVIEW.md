# Gate 2B.5 Phase 1 Data Layer v3 — Mel UX Forward-Fit Review

**Date:** 2026-05-18  
**Reviewer:** Mel  
**Scope:** Phase 1 data-layer readiness for Phase 3 UI requirements: topic list, new topic sheet, swipe actions, empty states, offline/reconnect UX, and seed data.  
**Verdict:** APPROVED — no UX data-model blockers

## Summary

v3 resolves the UX-relevant gaps from v2. The `Topic` model now has the fields Phase 3 needs for the topic list and interaction states: `name`, `lastMessagePreview`, `lastActivityAt`, `unreadCount`, `messageCount`, `sessionKey`, `isArchived`, `metadataJSON`, and `pendingGatewaySync`.

The added repository methods also give Phase 2/3 enough foundation for the UI flows:

- `create(name:pendingGatewaySync:)` supports topic creation with an upfront gateway-format key.
- `fetchAllActiveWithCounts()` supports a performant topic list model.
- `fetchPendingSyncTopics()` and `markSynced(topicId:)` support reconnect UX.
- `syncMetadataFromSessions(_:)` supports live row metadata updates.
- `send(text:to:)` resolving topic ID to session key supports the Phase 2 send flow.
- The minimal `TopicRow` fix removes the remaining `Session`/`Topic` mismatch.

## Direct Answers

### 1. Does the data model have all fields needed for Phase 3 UI?

Yes.

| Phase 3 UI need | v3 support | Status |
|---|---|---|
| Topic row title | `Topic.name` | Supported |
| Topic row preview | `lastMessagePreview` | Supported |
| Relative timestamp | `lastActivityAt` | Supported |
| Unread badge and VoiceOver text | `unreadCount` | Supported |
| Message count / diagnostics | computed `messageCount` | Supported |
| Selection/navigation identity | `id` | Supported |
| Message routing | `sessionKey` + bridge table | Supported |
| Archive swipe | `isArchived` + active-topic filtering | Supported |
| Delete swipe | `deleteCascading(_:)` existing behavior | Supported, pending implementation verification |
| Offline-created topic indicator | `pendingGatewaySync` | Supported |
| Diagnostic copy action | `id` + `sessionKey` | Supported |

No topic icon/color or pinned/sort-order field is required for M6-M14. `metadataJSON` remains a reasonable escape hatch if a later Gate 3 decision adds per-topic appearance.

### 2. Does `pendingGatewaySync` support the offline UX requirements from M10?

Yes, at the data-model level.

M10 needs the app to let users keep reading cached topics while disconnected and preserve locally-created topics until reconnect. `pendingGatewaySync` plus `fetchPendingSyncTopics()` gives the ViewModel a clear way to find offline-created topics after reconnect, and `markSynced(topicId:)` gives it a clear completion state once the gateway session exists.

One implementation caution: the v3 `connect()` pseudocode marks a topic synced after a best-effort bootstrap send:

```swift
_ = try? await bridge.sendMessage(...)
try persistenceStore.topicRepo.markSynced(topicId: topic.id)
```

For the M10 UX, `markSynced` should only run after gateway confirmation. If the bootstrap send fails and the flag is cleared anyway, the UI loses the ability to show/retry pending sync accurately. This is not a data-model blocker; it is a Phase 2 flow requirement.

### 3. Does the Topic model support chronological ordering?

Yes. `lastActivityAt` is the correct primary sort field, and v3 improves the query with:

```sql
ORDER BY COALESCE(t.lastActivityAt, t.createdAt) DESC
```

That handles newly-created topics with no messages better than v2. I still recommend a deterministic secondary sort for row stability:

```sql
ORDER BY COALESCE(t.lastActivityAt, t.createdAt) DESC,
         t.createdAt DESC,
         t.id DESC
```

This prevents visible row jumping when multiple topics share the same timestamp, especially in seed data and rapid local creation.

### 4. Are there UX requirements from M6-M14 not yet supported by the data model?

No blockers.

The remaining items are implementation/API shape, not missing fields:

- **M6/M7 New Topic sheet:** supported by `create(name:pendingGatewaySync:)`. Phase 2 should enforce trimmed, non-empty, <=80-character names in the repository as well as the UI.
- **M8 Swipe actions:** archive and delete are supported. Phase 2 should verify `deleteCascading(_:)` removes the local transcript expected by the delete confirmation copy.
- **M9 Empty states / Import Recent Sessions:** the model supports this because `Session` and `TopicSessionBridge` are separate. Phase 2 should add a clean ViewModel/repository query for import candidates so the UI does not duplicate filtering rules.
- **M10 Offline/error states:** supported by `pendingGatewaySync`; see the mark-synced caution above.
- **M11 Accessibility:** required row data exists, including text-readable `unreadCount` and connection state handled outside the Topic model.
- **M12 First launch:** supported, but production first launch should still be able to start with zero topics.
- **Context menu diagnostic copy:** supported by `Topic.id` and `sessionKey`.

### 5. Is seed data sufficient for UX testing?

Sufficient for Phase 1 smoke testing and basic Phase 3 row layout testing, with caveats.

The three seed topics are enough to test list rendering, selection, empty previews, archive/delete transitions, and message-count display. The topic-based seed rewrite fixes the v2 concern that seeded `Session` rows would be invisible after the UI switches to `Topic`.

For richer Phase 3 UX testing, add or script extra fixtures:

- one topic with `unreadCount > 0`
- one topic with `pendingGatewaySync = true`
- one topic with a long but valid 80-character name
- one archived topic to verify it stays hidden from the active list
- staggered `lastActivityAt` values to prove chronological ordering

Seed data must remain debug/test-only. The real first-launch UX from M12 is still an empty topic list with the "Start a Conversation" CTA.

## Recommendations Before Phase 2/3

1. Add repository-level validation for topic names: trim whitespace, reject empty names, and enforce the 80-character limit.
2. Only clear `pendingGatewaySync` after confirmed gateway reconciliation.
3. Add deterministic tie-breaking to `fetchAllActiveWithCounts()` ordering.
4. Add a clean import-candidate query for M9 instead of making the UI reconstruct bridge filtering.
5. Verify `deleteCascading(_:)` removes all local messages linked through `topic_session_bridge.openclawSessionKey -> messages.sessionId`.

## Verdict

**APPROVED.**

The v3 Phase 1 data layer supports the Phase 3 UI requirements. The open items are implementation guardrails and test coverage, not blockers in the data model.
