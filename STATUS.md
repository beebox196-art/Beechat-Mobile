# BeeChat Mobile Status

**Phase:** Gate 2 — Real Data Pipeline (Gate 2A ✅, Gate 2B 🔄 IN PROGRESS — device paired, connected to gateway)
**Last Updated:** 2026-05-18

## Research-First Gate
- [x] Phase 0 Prior Art Survey complete
- [x] Research report approved (Adam: "Great review. Let's make a start")
- [x] Validated repos identified (Exyte/Chat, SwiftyChat, Valet)
- [ ] Attribution tracker ready

**Research Report:** [PHASE0-RESEARCH-REPORT.md](Docs/Vision/PHASE0-RESEARCH-REPORT.md)

---

## Phased Build Plan

### Gate 0: Core Package iOS Audit ✅ PASSED
**Goal:** Verify BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge compile for iOS without modification.
**Exit criteria:**
- [x] All three packages compile in an iOS 17+ target (Package.swift updated, `swift build` passed)
- [x] No macOS-only imports (AppKit, NSWindow, etc.) — none found
- [x] No macOS-only API calls (unconditional) — none found
- [x] GRDB works on iOS — confirmed platform-agnostic
- [x] URLSessionWebSocketTask works on iOS — confirmed
- [x] Document every platform issue found and how to resolve it — audit report + fixes doc written

**Audit report:** `Docs/Architecture/GATE0-AUDIT-REPORT.md`
**Fixes applied:** `Docs/Architecture/GATE0-FIXES.md`
**Changes:** Package.swift + `.iOS(.v17)`, DeviceCrypto.swift + GatewayClient.swift platform conditionals
**Validation:** `swift build` passed in 4.24s, no regressions

### Gate 1: Exyte/Chat Integration Spike ✅ PASSED
**Goal:** Prove Exyte/Chat renders messages in an iOS app before committing.
**Exit criteria:**
- [x] Exyte/Chat added as SPM dependency, compiles for iOS
- [x] Hardcoded BeeChat-style messages render in simulator (text + assistant) — build succeeds, manual visual verification pending
- [x] Input bar works (type + send) — demo code implements send callback
- [x] Streaming text update works (mock agent reply) — Timer-based character-by-character streaming implemented
- [x] No showstoppers in 1 day — SwiftyChat fallback not needed

**Spike report:** `Docs/Architecture/GATE1-SPIKE-REPORT.md`
**✅ Manual verification done:** App builds and runs on iPhone 17 simulator (iOS 26.2). Two hardcoded messages render with proper bubbles, input bar with attach/emoji/camera/mic buttons, streaming text timer working. Stray "B" avatar initial on assistant messages (cosmetic, not blocker).

### Gate 2: Real Data Pipeline
**Goal:** Connect Exyte UI to real BeeChat data through Core packages.
**Spec:** [GATE2-SPEC.md](Docs/Architecture/GATE2-SPEC.md) — **APPROVED by Adam, fully reviewed by team**
**Sub-gates:**

#### Gate 2A: AnyCodable Fix + Persistence Layer ✅ VALIDATED + TEAM-AUDITED
**Goal:** Make v5 Core packages compile for iOS, read cached data from GRDB, render in Exyte UI. No network needed.
- [x] v5 packages compile in iOS target
- [x] AnyCodable Equatable fix applied to v5 repo (type-explicit switch, not NSNumber)
- [x] Package.swift refactored (swift-tools-version 6.0, Exyte pinned 2.7.10)
- [x] project.yml: 3-target module structure (BeeChatMobileKit, BeeChatUI, BeeChatMobile app)
- [x] GRDB schema migrations run on iOS
- [x] Sessions list displays from local DB
- [x] Messages display in Exyte ChatView from local DB
- [x] Offline banner shows above session list (not overlapping)
- [x] Error alerts wired up (startup errors shown to user)
- [x] Kieran review blockers fixed (B1-B4: data race, error handling, error display, connection views wired)
- [x] 9 must-fix items (F1-F9) applied
- [x] 13 should-fix items (S1-S13) applied where relevant
- [x] Build succeeds on iPhone 17 Pro simulator (iOS 26.2)
- [x] App runs, seeds test data, shows session list and messages
- [x] Database verified: 1 session, 3 messages in GRDB
- [x] Kieran adversarial review: PASS (8 minor deviations tracked, none blocking)
- [x] Recovery executed: working tree restored from HEAD, Q rebuilt, Kieran validated

**Recovery:** 2026-05-16 — Bee breached protocol (implemented instead of orchestrating), team audit confirmed salvageable. Recovery: `git restore` → Q rebuilt → Kieran validated. Commit: `8feebb4`.

#### Gate 2B: Live Gateway Connection ✅ FUNCTIONALLY COMPLETE
**Goal:** Connect to real OpenClaw gateway, receive messages in real-time. Send not required.
- [x] Fix default gateway port (:3000 → :18789)
- [x] Fix localhost → 127.0.0.1 (iOS simulator IPv6)
- [x] App connects to gateway on launch
- [x] Connection state visible in UI (disconnected → connecting → connected / error)
- [x] Offline banner with retry action (spec text: "Offline. Showing cached messages.")
- [x] ConnectionStatusView tappable with retry (Kieran #3)
- [x] Sessions → Topics rename throughout UI
- [x] GatewayConfigLoader reads from env vars or file (iOS sandbox safe)
- [x] Device identity sent on handshake (deviceFamily: "mobile" added to ClientInfo)
- [x] Gateway auto-pairing works for local connections (device approved, full scopes granted)
- [x] App shows 🟢 Online status when connected
- [x] Cached data shows immediately on launch (offline-first)

**Remaining 2B testing (deferred to 2B.5 verification):**
- [ ] Incoming messages render in real-time
- [ ] Streaming text (delta events) updates character-by-character
- [ ] Topic list updates on sessions.changed
- [ ] Reconnect works after brief disconnect

**Current state:** App connects to gateway with full operator scopes. 🟢 Online status confirmed. Remaining functional testing (real-time messages, streaming) deferred to Gate 2B.5 verification phase.

#### Gate 2B.5: Topic Architecture 🟡 SPEC v2 READY — AWAITING ADAM APPROVAL
**Goal:** Replace raw session list with proper Topic layer (same as macOS BeeChat). Sidebar shows user-created Topics, not gateway sessions.
**Spec v1:** [GATE-2B5-TOPIC-ARCHITECTURE.md](Docs/Architecture/GATE-2B5-TOPIC-ARCHITECTURE.md)
**Spec v2 (revised):** [GATE-2B5-TOPIC-ARCHITECTURE-v2.md](Docs/Architecture/GATE-2B5-TOPIC-ARCHITECTURE-v2.md)
**Consolidated review:** [GATE-2B5-CONSOLIDATED-REVIEW.md](Docs/Architecture/GATE-2B5-CONSOLIDATED-REVIEW.md)
**Reviewer reports:** [Q](Docs/Architecture/GATE-2B5-Q-REVIEW.md), [Kieran pass 2](Docs/Architecture/GATE-2B5-KIERAN-REVIEW-PASS2.md), [Mel pass 2](Docs/Architecture/GATE-2B5-MEL-REVIEW-PASS2.md)

**All 8 blockers resolved in v2 spec:**
- [x] B1: All sessionKey:nil references removed — upfront key is only pattern
- [x] B2: BeeChatSessionFilter overload added — isBeeChatSession(_:topicRepo:)
- [x] B3: Computed message counts via SQL JOIN — no triggers
- [x] B4: Atomic migration with GRDB transaction + version tracking
- [x] B5: pendingGatewaySync flag + reconciliation on connect
- [x] B6: UNIQUE constraint on openclawSessionKey + upsert
- [x] B7: sessionsSubscribe() added to reconnect path
- [x] B8: Seed data creates Topic, not Session

**v2 also includes:**
- Mel M6-M14 UX specs (sheet, popover, swipe, empty states, offline, VoiceOver, Dynamic Type)
- Q H1-H4 hidden gotchas (sendMessage topic param, saveBridge upsert, TopicRow refactor, ValueObservation)
- Two-model architecture documentation (Session = backend, Topic = frontend)
- 13-step ViewModel implementation plan, 9-step UI plan, 20-item validation checklist

**Next:**
- [ ] Adam approval of v2 spec
- [ ] Q implementation
- [ ] Kieran review of Gate 2B.5 code
- [ ] Bee validation on simulator
- [ ] Adam sign-off

#### Gate 2C: End-to-End Send/Receive
**Goal:** User sends message → gateway processes → reply streams back.
- [ ] Send triggers `chat.send` via SyncBridge
- [ ] Optimistic message appears immediately
- [ ] Bee's reply streams in correctly
- [ ] Message status transitions work
- [ ] Failed sends show error state

#### Gate 2D: Reconnect & Reconciliation
**Goal:** Network interruptions handled gracefully.
- [ ] Automatic reconnection after network recovery
- [ ] Reconciliation fetches latest data, no duplicates
- [ ] Stalled streaming cleaned up
- [ ] Delivery ledger transitions correctly

### Gate 3: Mobile UX Shell
**Goal:** Navigation, sessions list, mobile lifecycle.
**Exit criteria:**
- [ ] NavigationSplitView works on iPad (sidebar + detail)
- [ ] NavigationStack works on iPhone (push/pop)
- [ ] App survives background/foreground cycle (WebSocket reconnects)
- [ ] Session switching works without data loss

### Gate 4: Push Notifications MVP
**Goal:** APNs push from gateway to device.
**Exit criteria:**
- [ ] Apple Developer account set up with push capability
- [ ] Device token registration flow works
- [ ] Gateway can send APNs payload to device
- [ ] Notification tap opens app to correct session
- [ ] Foreground WebSocket + background push model confirmed

### Gate 5: Polish & Distribution
**Goal:** TestFlight-ready build.
**Exit criteria:**
- [ ] Valet keychain storage for auth tokens
- [ ] App icon, launch screen, basic settings
- [ ] TestFlight build uploads
- [ ] Adam can install on iPhone and iPad
- [ ] No crashes in 30-minute daily use test

---

## Team Development Process

See [ADR-002](Docs/Decisions/ADR-002-team-driven-development.md) for full details.

| Role | Agent | Responsibility |
|---|---|---|
| **Coordinator** | Bee | Orchestrates gates, validates deliverables, updates STATUS, manages git |
| **Builder** | Q | All code implementation — Swift, SPM, iOS, UI wiring |
| **Reviewer** | Kieran | Adversarial review of every gate deliverable before it passes |
| **Designer** | Mel | UI/UX design decisions, visual polish, SwiftUI layout guidance |
| **Researcher** | Gav | Prior art, library evaluation, technical evidence gathering |

**Gate workflow:** Bee defines criteria → Q implements → Kieran reviews → Q fixes → Bee validates → Adam approves.
**No gate passes without Kieran sign-off.**
**Bee orchestrates only — never implements code.**

## Active Blockers
- **Gate 2B.5 spec has 8 blockers** — must resolve before Q starts implementation. See consolidated review.
- **Gate 2C blocked by Gate 2B.5** — send/receive needs topic-resolved session keys, not raw session IDs.

## Gate 2B.5 Spec
- **Spec v1:** [GATE-2B5-TOPIC-ARCHITECTURE.md](Docs/Architecture/GATE-2B5-TOPIC-ARCHITECTURE.md)
- **Spec v2 (current):** [GATE-2B5-TOPIC-ARCHITECTURE-v2.md](Docs/Architecture/GATE-2B5-TOPIC-ARCHITECTURE-v2.md)
- **Consolidated review:** [GATE-2B5-CONSOLIDATED-REVIEW.md](Docs/Architecture/GATE-2B5-CONSOLIDATED-REVIEW.md)
- **Reviewer reports:** [Q](Docs/Architecture/GATE-2B5-Q-REVIEW.md), [Kieran pass 2](Docs/Architecture/GATE-2B5-KIERAN-REVIEW-PASS2.md), [Mel pass 2](Docs/Architecture/GATE-2B5-MEL-REVIEW-PASS2.md)
- **Status:** 🟡 v2 spec ready — all 8 blockers resolved, awaiting Adam approval
- **Verdict:** Architecture is sound. All blockers and UX requirements resolved in v2.
- **Key decisions:**
  - D1: Use same Topic model as macOS (no divergence)
  - D2: Sidebar shows only user-created topics
  - D3: Topics created with gateway-format sessionKey upfront — NO nil session keys
  - D4: Store all sessions locally, filter on display
  - D5: Seed data uses Topic model
  - D6: Chronological ordering (lastActivityAt DESC), not alphabetical
  - D7: New Topic: compact sheet (iPhone) / popover (iPad), 80-char limit, auto-navigate
  - D8: Offline creation: pendingGatewaySync flag + reconciliation on connect
  - D9: Two-model architecture: Session (backend) vs Topic (frontend)
  - D10: Computed message counts via SQL, no DB triggers

## Tracked Follow-ups (from Kieran's Gate 2A review, non-blocking)
- MessageMapper in BeeChatUI not MobileKit (Exyte dep reason — spec drift, harmless)
- OfflineBanner text: "You are offline" (spec wanted "Offline. Showing cached messages." + retry)
- ConnectionStatusView: inline VStack not toolbar, not tappable
- Error property: `currentError: Error?` not `connectionError: String?`
- DB name: `beechat.db` not `beechat.sqlite`
- No test files in `BeeChatMobileKitTests/` yet
- No DB init-order assertion (spec S9)
- Default gateway port `:3000` → now `:18789` (fixed in Gate 2B)
- `@State` on ViewModel reference type unnecessary — `let` would suffice

## Git
- **Remote:** https://github.com/beebox196-art/Beechat-Mobile
- **Branch:** main
- **BeeChat-Mobile commit:** 9fa641e — fix(gateway): add deviceFamily to ClientInfo for iOS
- **BeeChat-v5 commit:** 73a5de1 — docs: add Gate 2B rollback plan
- **Previous:** 8feebb4 — fix(project.yml): restore proper 3-target module structure (Q's recovery build)

## Next Steps
1. Adam approval of v2 spec (all 8 blockers resolved)
2. Remove debug logging from v5 GatewayClient
3. Gate 2B.5 implementation (Q) — 13 ViewModel steps + 9 UI steps
4. Kieran review of Gate 2B.5 code
5. Bee validation on simulator (20-item checklist)
6. Gate 2B.5 sign-off → move to Gate 2C

## Context Notes
- **Parent project:** BeeChat v5 (macOS) — shares Core Swift packages via SPM local dependency
- **Architecture principle:** Gateway owns session truth, local DB is cache. Same model as v5.
- **Key constraint:** No contamination of v5. Package reuse via SPM dependency, not shared files.
- **Validation-first:** Adam wants too much checking, not too little. Hard gates between phases.
- **Stack:** Exyte/Chat (primary), SwiftyChat (fallback), Valet (auth), APNs (push), NavigationSplitView (iPad)
- **Terminology:** v5 uses "Sessions" internally. UI layer renamed to "Topics" (Adam's preference, implemented)

---
*Update this file after each meaningful work session. Stale detection flags files not updated in 7 days.*
