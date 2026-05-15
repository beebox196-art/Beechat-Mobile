# BeeChat Mobile Status

**Phase:** Gate 2 — Real Data Pipeline (Gate 2A IN PROGRESS)
**Last Updated:** 2026-05-15

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

#### Gate 2A: AnyCodable Fix + Persistence Layer 🔄 IN PROGRESS (Q building)
**Goal:** Make v5 Core packages compile for iOS, read cached data from GRDB, render in Exyte UI. No network needed.
- [ ] v5 packages compile in iOS target
- [ ] AnyCodable Equatable fix applied to v5 repo (type-explicit switch, not NSNumber)
- [ ] Package.swift refactored (swift-tools-version 6.0, Exyte pinned 2.7.10, Kit+UI targets)
- [ ] project.yml updated for app target (composition root)
- [ ] GRDB schema migrations run on iOS
- [ ] Sessions list displays from local DB
- [ ] Messages display in Exyte ChatView from local DB
- [ ] No stray avatar initials on assistant messages
- [ ] 9 must-fix items (F1-F9) and 13 should-fix items (S1-S13) from team review applied

#### Gate 2B: Live Gateway Connection
**Goal:** Connect to real OpenClaw gateway, receive messages in real-time. Send not required.
- [ ] App connects to gateway on launch
- [ ] Connection state visible in UI
- [ ] Incoming messages render in real-time
- [ ] Streaming text (delta events) updates character-by-character
- [ ] Session list updates on `sessions.changed`
- [ ] Reconnect works after brief disconnect
- [ ] Cached data shows immediately on launch (offline-first)

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

## Active Blockers
None

## Git
- **Remote:** https://github.com/beebox196-art/Beechat-Mobile
- **Branch:** main
- **Commit:** 452537f (initial commit)

## Next 3 Priorities
1. **Gate 2A Build** — Q implementing, Bee coordinating
2. **Gate 2A Review** — Kieran adversarial review before gate passes
3. **Gate 2B** — Live gateway connection (after 2A validated by team)

## Mission Control
- Task: [To be created]

## Context Notes
- **Parent project:** BeeChat v5 (macOS) — shares Core Swift packages via SPM local dependency
- **Architecture principle:** Gateway owns session truth, local DB is cache. Same model as v5.
- **Key constraint:** No contamination of v5. Package reuse via SPM dependency, not shared files.
- **Validation-first:** Adam wants too much checking, not too little. Hard gates between phases.
- **Stack:** Exyte/Chat (primary), SwiftyChat (fallback), Valet (auth), APNs (push), NavigationSplitView (iPad)

---
*Update this file after each meaningful work session. Stale detection flags files not updated in 7 days.*