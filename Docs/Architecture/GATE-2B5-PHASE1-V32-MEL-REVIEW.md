# Gate 2B.5 Phase 1 Data Layer v3.2 — Mel Delta Review

**Date:** 2026-05-18  
**Reviewer:** Mel  
**Scope:** v3.1 -> v3.2 delta only: Q B12 topic-to-session message resolution and removal of redundant direct `sessionsSubscribe()` call.  
**Verdict:** APPROVED

## Findings

v3.2 resolves the B12 UX blocker. `selectedTopicId` is allowed to remain a Topic UUID for UI state, while message loading and live streaming display resolve it to the Topic's `sessionKey` before touching persisted messages or `streamingContent`.

This removes the two user-visible gaps from v3.1:

- Persisted messages no longer disappear into a blank list after the `topics: [Session]` -> `[Topic]` switch.
- In-flight assistant responses continue to display because `streamingContent` is read by session key, matching the SyncBridge delegate/polling key.

The unknown-topic path returns `nil` and fails gracefully, which is acceptable for Phase 1. It avoids a crash and prevents stale or mismatched messages from appearing under the wrong topic.

Removing the direct `bridge.rpcClient.sessionsSubscribe()` call is also acceptable. `SyncBridge.start()` already owns subscription setup, and keeping the call out of the ViewModel avoids the private `rpcClient` access issue without changing UX.

## Implementation Note

Apply the resolved session key consistently at every selected-topic lookup site, including `loadMessages()` and the merged streaming-message path. If the helper stays `private` on the ViewModel, expose a ViewModel method that performs the lookup internally rather than making the view index `streamingContent` by raw `selectedTopicId`.

## Result

APPROVED — no remaining UX blocker in the v3.2 delta.
