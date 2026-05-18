# Gate 2B.5 Topic Architecture — Consolidated Review Findings

**Date:** 2026-05-18
**Reviewers:** Q (Implementation), Kieran (Adversarial — Pass 2), Mel (UX — Pass 2)
**Status:** 🔴 BLOCKED — 8 blockers must be resolved before implementation

---

## Methodology

Three independent second-pass reviews:
- **Q** verified every spec claim against actual source code, checked implementation feasibility, and traced every code path
- **Kieran** did a deep adversarial pass on edge cases, security, data integrity, concurrency, and protocol robustness
- **Mel** did a detailed UX interaction design pass, defining exact behaviours for every screen state

This document consolidates all findings, deduplicates overlapping issues, and prioritises for implementation.

---

## BLOCKERS (Must fix before implementation starts)

### B1. 🔴 Spec is internally inconsistent about sessionKey

**Found by:** Q (B1), Mel (M13), Kieran (pass 1 B2/B3)

**Problem:** Section 3.2.3 says topics are created with gateway-format keys upfront (`agent:main:<topicId.lowercased()>`), but Section D3 and other parts still describe the old `sessionKey: nil` flow. Implementation team would follow the wrong text and reintroduce the nil-sessionKey bugs.

**Fix:** Remove ALL remaining `sessionKey: nil` text from the spec. The upfront-key approach (Kieran B2) is the only documented pattern. Audit every mention.

**Files affected:** Spec document sections D3, D6, Gate 2C impact, implementation plan step 7

---

### B2. 🔴 `BeeChatSessionFilter.isBeeChatSession()` creates new TopicRepository per call

**Found by:** Kieran (pass 1 B1, pass 2 B9), Q (B2)

**Problem:** The static method creates a fresh `TopicRepository()` every call. On iOS `@MainActor`, this can deadlock. The spec says "inject ViewModel's repo" but doesn't show how. The static enum can't hold instance state.

**Fix:** Add `isBeeChatSession(_ sessionKey: String, topicRepo: TopicRepository)` overload. iOS ViewModel calls the overload with its injected repo. macOS stays on the old path. No macOS code changes.

---

### B3. 🔴 Migration010 already destroyed topic-based message count triggers

**Found by:** Q (B3)

**Problem:** Migration010 dropped `trg_increment_message_count` and `trg_decrement_message_count` (topic-based) and replaced them with session-based triggers. If Gate 2B.5 makes Topic the primary UI model, `Topic.messageCount` will never auto-update.

**Fix:** Don't re-add triggers. Use computed message counts in `TopicRepository.fetchAllActive()` via SQL JOIN/subquery. Simpler, no trigger maintenance, no race conditions between two tables.

---

### B4. 🔴 Migration uses `try?` everywhere — partial failure is unrecoverable

**Found by:** Kieran (B6)

**Problem:** Every operation in `migrateSessionsToTopics()` uses `try?`. If migration fails halfway (disk full, constraint violation, interrupted), some sessions convert and others don't. On next launch, `fetchAllActive()` returns non-empty → migration guard skips retry. Permanently inconsistent state.

**Fix:** Wrap entire migration in a single GRDB transaction. Either all sessions convert or none do. Add `migrationVersion` metadata flag so failed migrations can be retried.

---

### B5. 🔴 No offline/deferrable path for topic creation

**Found by:** Kieran (B5)

**Problem:** If a user creates a topic while the gateway is disconnected, the topic exists locally but has no gateway session. Sending a message to `agent:main:<topicId>` fails silently because the gateway doesn't recognise the session key. No error indication, no retry.

**Fix:** Add `pendingGatewaySync` flag to Topic (or use `metadataJSON`). On `connect()`, reconcile pending topics by sending the bootstrap message for any topic whose session key hasn't been confirmed by the gateway. The macOS code already does `bridge.sendMessage(sessionKey: gatewayKey, text: "Start")` — iOS needs the same with offline resilience.

---

### B6. 🔴 `topic_session_bridge.openclawSessionKey` has no UNIQUE constraint

**Found by:** Kieran (B7)

**Problem:** Two different topics can bridge to the same session key. `resolveTopicId(for:)` uses `fetchOne` — returns whichever SQLite finds first. Non-deterministic. If migration runs twice before the guard is checked, duplicate bridges are created.

**Fix:** Add `UNIQUE(openclawSessionKey)` constraint to the bridge table. Change `saveBridge()` from `save()` (insert-only) to `upsertPreservingCreatedAt()`. The `TopicSessionBridge` struct already conforms to `UpsertableRecord`.

---

### B7. 🔴 `sessions.subscribe` never re-subscribed on gateway reconnect

**Found by:** Kieran (B8)

**Problem:** After a gateway restart, the transport reconnects and `reconcile()` runs (fetches sessions list), but `sessions.subscribe` is never re-called. Live `sessions.changed` events stop. New sessions created by other agents never appear. User has to restart the app.

**Fix:** Call `sessionsSubscribe()` in the reconnect path. Make it idempotent (gateway already supports this). Add to `SyncBridge.reconnectWatchTask`.

---

### B8. 🔴 Seed data invisible after migration — uses `Session` model but UI shows `Topic`

**Found by:** Kieran (W15), Q (W4), Mel (M9)

**Problem:** `seedTestData()` creates a `Session`. After the Topic architecture, the sidebar shows Topics, not Sessions. The migration only runs for existing data. Fresh installs get "No conversations yet" despite seed data existing.

**Fix:** Change `seedTestData()` to create a `Topic` instead of a `Session`, plus the corresponding bridge entry and test messages.

---

## WARNINGS (Should fix, won't block starting)

### W1. TopicRow refactor is larger than spec suggests
**Found by:** Q (W1)

Property names don't match: `Session.title` → `Topic.name`, `Session.lastMessageAt` → `Topic.lastActivityAt`, `Session.customName` doesn't exist on `Topic`. Every UI file accessing `Session` properties needs auditing.

### W2. `fetchSessions()` returns `[Session]`, not `[Topic]`
**Found by:** Q (W3)

The spec hand-waves "update topic metadata from session data." Needs a concrete `TopicRepository.syncMetadataFromSessions()` method.

### W3. `sendMessage` needs Topic→session key resolution
**Found by:** Kieran (W12), Q (W5)

Current `send(text:to:)` takes a `sessionId` string. After Topic architecture, the caller passes a topic ID (UUID). Must resolve to session key via `topicRepo.resolveSessionKey()` before calling `bridge.sendMessage()`.

### W4. `saveBridge()` uses insert-only `save()` — will crash on duplicate
**Found by:** Q (W3 in Q's review)

Change to `upsertPreservingCreatedAt()`. The struct already conforms to `UpsertableRecord`.

### W5. Foreign keys disabled — cascade deletes are manual
**Found by:** Kieran (W9)

`PRAGMA foreign_keys=OFF`. Topic deletion cascade is manual. Future schema changes could silently break integrity. Low risk now, ticking time bomb later.

### W6. Gateway token stored in plaintext file
**Found by:** Kieran (W10)

`gateway-config.json` contains the token as unencrypted text. Should use `KeychainTokenStore` for the token, config file only for URL.

### W7. Case-sensitivity inconsistency in session key resolution
**Found by:** Kieran (W11)

Topic IDs are uppercase UUIDs, gateway keys use lowercase. `resolveTopicIdBySuffix()` does UPPER() fallback. Works but confusing for maintainers. Document the convention explicitly.

### W8. `SyncBridge` is an actor — delegate callbacks are asynchronous
**Found by:** Kieran (W13)

Callbacks arrive via `Task { @MainActor in ... }`. Works for single-session streaming but `isStreaming: Bool` state won't handle multi-session streaming. Use `Set<String>` for streaming sessions.

### W9. macOS/iOS ordering divergence needs documentation
**Found by:** Kieran (W14), Mel (M1)

macOS sorts alphabetically. iOS will sort chronologically (`lastActivityAt DESC`). This is a deliberate UX decision. Document it.

### W10. `isTopicContextEnabled` feature flag not mentioned in spec
**Found by:** Q (G4)

If `SyncBridge.isTopicContextEnabled` is disabled, topic context injection is skipped. The spec is silent on whether iOS should enable this.

---

## UX REQUIREMENTS (Must implement)

### M6. Define iPhone New Topic Sheet end-to-end
Compact sheet (`.height(220)`), single-line text field, 80-character limit, Cancel/Create buttons, Create disabled until valid, auto-focus keyboard, auto-navigate to chat on success, dirty-draft discard confirmation.

### M7. Clarify iPad popover and adaptive presentation
Popover anchored to `+` button on regular-width iPad. Fall back to iPhone sheet for compact width. Minimum topic list width 280pt.

### M8. Specify swipe actions and undo
Trailing swipe: Archive (default, with undo toast) + Delete (destructive, with confirmation). Full swipe = Archive. No leading swipe unless pinning ships (defer).

### M9. Define two empty states as concrete screens
Fresh install: "No conversations yet" + primary "Start a Conversation" button. Hidden sessions: secondary "Import Recent Sessions" button that opens a selection sheet.

### M10. Expand gateway disconnected and send failure UX
Disconnected: composer disabled, placeholder "Reconnect to send messages", draft preserved. Failed send: inline retry on bubble, no modal. Partial failure: user message stays "sent", assistant shows "Response interrupted" with retry.

### M11. Add VoiceOver and Dynamic Type acceptance criteria
Labels for all interactive elements. Connection state as text, not just color. 44pt minimum hit targets. Sheet expands to `.medium` for large accessibility sizes.

### M12. First-launch onboarding without walkthrough
Empty topic list + "Start a Conversation" CTA. After first topic: "Ask Bee anything to get started." prompt in chat. No coach marks.

### M13. Resolve internal spec contradictions
Remove all `sessionKey: nil` text. Document upfront-key flow as the ONLY pattern.

### M14. Add manual UX validation checklist
11-item checklist covering sheet, popover, archive, delete, empty states, offline, failed send, VoiceOver, Dynamic Type.

---

## SPEC GAPS (Need documentation)

### G1. Two-model architecture: Session (backend) vs Topic (frontend)
`Session` = gateway truth. `Topic` = user-facing conversation. Bridge table links them. Document explicitly.

### G2. `sessions.changed` event handling not specified
When gateway fires `sessions.changed`, iOS needs to re-fetch, update sessions table, sync metadata to topics, refresh sidebar. Critical for Gate 2C/2D.

### G3. One topic = one session key = one context injection lifetime
No reuse, no sharing. Document this invariant.

### G4. `isTopicContextEnabled` feature flag interaction
Should iOS enable topic context injection? Spec is silent.

### G5. `Topic.name` is non-optional but migrated sessions may have no title
Fallback to `session.id` works but spec should document the convention.

### G6. `TopicSessionBridge` struct lives inside `Topic.swift`, not a separate file
Spec should be precise about file locations.

### G7. `resolveTopicIdBySuffix()` is on `TopicRepository`, not `SessionKeyNormalizer`
Spec misattributes this method.

---

## REVIEW OF FIRST-PASS FINDINGS

### Kieran Pass 1
- **B1 (deadlock):** Confirmed and expanded in B2/B9. Needs overload, not just "inject repo."
- **B2 (nil sessionKey):** Fixed in spec §3.2.3, but D3 still contradicts. Now tracked as consolidated B1.
- **B3 (bare UUID):** Eliminated by B2 fix. No separate issue.
- **B4 (migration data loss):** Expanded in B4 and B8. Migration needs transaction + seed data update.

### Mel Pass 1
- **M1 (ordering):** Confirmed — iOS uses chronological, macOS uses alphabetical. Documented as deliberate divergence (W9).
- **M2 (empty state):** Expanded in M9 with concrete screen designs.
- **M3 (swipe actions):** Expanded in M8 with exact gesture specs.
- **M4 (error states):** Expanded in M10 with detailed offline/send failure behavior.
- **M5 (session key visibility):** Confirmed — never show raw keys in normal UI.

---

## RECOMMENDED PRE-IMPLEMENTATION ACTIONS

### Must do before Q starts coding:

1. **Rewrite spec §D3** to eliminate all `sessionKey: nil` references. Upfront gateway key is the only pattern.
2. **Add `isBeeChatSession(_:topicRepo:)` overload** to spec with exact call pattern.
3. **Decide messageCount strategy:** Computed via SQL (recommended) or re-add triggers in Migration012.
4. **Wrap migration in GRDB transaction** with version tracking.
5. **Add UNIQUE constraint** on `openclawSessionKey` in bridge table.
6. **Add offline topic creation flow** with `pendingGatewaySync` flag and reconciliation on connect.
7. **Add `sessionsSubscribe()`** to reconnect path.
8. **Change seed data** to create `Topic` instead of `Session`.
9. **Add `TopicRepository.syncMetadataFromSessions()`** method to spec.
10. **Update `send()` method** to show Topic ID → session key resolution.

### Should do during implementation:

11. Audit all UI files for `Session` property access.
12. Change `saveBridge()` to `upsertPreservingCreatedAt()`.
13. Add VoiceOver labels and Dynamic Type support per M11.
14. Implement swipe actions per M8.
15. Document ordering divergence (W9).

---

## REVIEWER SIGN-OFF

| Reviewer | Verdict | Key Concern |
|----------|---------|-------------|
| **Q** (Implementation) | 🔴 BLOCKED | Spec/code mismatches, migration safety, messageCount triggers |
| **Kieran** (Adversarial) | 🔴 FAIL | Offline creation, migration atomicity, bridge constraints, reconnect subscriptions |
| **Mel** (UX) | 🟡 Direction right, detail missing | Interaction specs need full definition before implementation |

**Overall:** Architecture is sound. The Topic layer is the right abstraction. But the spec needs a precision pass to resolve 8 blockers before implementation can safely begin. Estimated 1-2 days of spec revision, then 3-5 days of implementation.