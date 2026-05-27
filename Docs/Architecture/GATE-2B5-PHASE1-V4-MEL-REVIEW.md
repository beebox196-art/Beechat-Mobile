# Gate 2B.5 Phase 1 Data Layer v4 - Mel UX Review

**Date:** 2026-05-27  
**Reviewer:** Mel  
**Scope:** UX implications of removing the dead `beechatMetadata` / `pluginPatch` reconciliation path from the mobile data layer.

## BLOCKERS (UX-breaking issues)

None.

Removing `reconcileTopics(from:)` does not remove a working UX capability because the Mac app cannot publish `beechat/metadata` through `sessions.pluginPatch`, and mobile therefore never had reliable metadata to reconcile. The user-facing topic list remains driven by local `Topic` rows plus gateway `Session` data, which is the only path that currently works.

## WARNINGS (UX concerns, non-blocking)

1. **Mac/mobile topic parity remains approximate.** Session-based reconciliation can mirror gateway-visible session title, preview, unread count, and last activity. It cannot mirror Mac-only topic semantics that are not present on sessions: custom topic grouping, ordering, archive/delete intent, or future topic-level presentation state. Users may still see mobile topics that do not exactly match the Mac app's topic list.

2. **Remote disappearance is not specified.** The v4 delegate creates missing topics and syncs metadata from fetched sessions, but it does not define what happens when a previously bridged session no longer appears in `fetchSessions()`. That is acceptable for Phase 1 because destructive disappearance would be worse than stale data, but users may see stale local topics until a later sync-channel spec defines deletion/archive semantics.

3. **Refresh failure is silent.** If `didReceiveSessionChange` fails during `fetchSessions()`, the app continues with the previous local list. That is the right data-layer fallback, but the UX will show stale title/preview/unread state with no visible freshness signal. This can stay out of Phase 1, but Phase 2/3 should consider a lightweight stale/syncing state if failures become common.

4. **Rapid session changes can be dropped while `isReconciling` is true.** The guard prevents concurrent work, which is good, but it also returns immediately instead of coalescing one follow-up refresh. In practice this means a new topic or unread count update may appear on the next event/connect rather than immediately. Non-blocking, but a future `needsRefreshAfterReconciling` flag would make the list feel more deterministic.

## PASSES (verified correct)

1. **No new empty-state regression.** The list still loads from `topicRepo.fetchAllActiveWithCounts()` on start. During reconcile, v4 refreshes from the local database after session sync instead of replacing the list with a transient empty gateway result.

2. **Topic creation remains user-visible in the right direction.** New BeeChat gateway sessions still become local topics. Removing metadata reconciliation does not make topics disappear; if anything, rewriting `didReceiveSessionChange` to use `fetchSessions()` makes live topic appearance more likely than the dead metadata path.

3. **Existing offline-topic UX hook is preserved.** Keeping `pendingGatewaySync` and pending reconciliation protects the offline-created-topic path. v4 does not collapse local topics back into raw gateway sessions.

4. **Topic list filtering remains intact.** v4 keeps `BeeChatSessionFilter`, so mobile should not regress to showing every gateway session as a user-facing topic.

5. **Future sync-channel UX gets easier.** Removing `pluginExtensions` assumptions leaves a cleaner baseline: local `Topic` remains the UI model, gateway `Session` remains the transport/session model, and a future dedicated sync channel can add real topic metadata without competing with dead `beechatMetadata` code.

## SIMPLICITY VERDICT

About right.

v4 is appropriately simple for a data-layer correction. It removes a broken metadata path, preserves the working session-based baseline, and avoids inventing UI states before the app has a real topic sync source of truth. The main UX limitation is not over-simplification in v4; it is the known absence of a real Mac-to-mobile topic metadata channel.
