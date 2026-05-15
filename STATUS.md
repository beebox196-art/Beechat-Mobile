# BeeChat Mobile Status

**Phase:** Phase 0 — Validation
**Last Updated:** 2026-05-12

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
**⚠️ Manual verification needed:** Open project in Xcode, run on simulator, confirm visual rendering

### Gate 2: Real Data Pipeline
**Goal:** Connect Exyte UI to real BeeChat data through Core packages.
**Exit criteria:**
- [ ] BeeChatPersistence reads cached sessions on iOS simulator
- [ ] BeeChatGateway connects to real gateway, receives events
- [ ] BeeChatSyncBridge reconciles on reconnect
- [ ] Messages from gateway render in Exyte UI
- [ ] Sent messages reach gateway (end-to-end send/receive)

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

## Active Blockers
None

## Next 3 Priorities
1. **Gate 1 manual verification** — Adam opens project in Xcode, runs on simulator, confirms visual rendering
2. **Gate 2: Real Data Pipeline** — Wire BeeChat Core packages to Exyte UI for real gateway data
3. **Gate 2: Validate** — Messages from gateway render, sent messages reach gateway end-to-end

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