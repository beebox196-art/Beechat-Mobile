# BeeChat Mobile Status

**Phase:** Gate 2 Complete — Core app working on real iPhone. Cross-device topic sync next.
**Last Updated:** 2026-05-22

## Research-First Gate
- [x] Phase 0 Prior Art Survey complete
- [x] Research report approved (Adam: "Great review. Let's make a start")
- [x] Validated repos identified (Exyte/Chat, SwiftyChat, Valet)

**Research Report:** [PHASE0-RESEARCH-REPORT.md](Docs/Vision/PHASE0-RESEARCH-REPORT.md)

---

## Phased Build Plan

### Gate 0: Core Package iOS Audit ✅ PASSED
**Goal:** Verify BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge compile for iOS without modification.
**Exit criteria:**
- [x] All three packages compile in an iOS 17+ target
- [x] No macOS-only imports or API calls
- [x] GRDB works on iOS
- [x] URLSessionWebSocketTask works on iOS
- [x] Audit report + fixes doc written

**Audit report:** `Docs/Architecture/GATE0-AUDIT-REPORT.md`
**Fixes applied:** `Docs/Architecture/GATE0-FIXES.md`

### Gate 1: Exyte/Chat Integration Spike ✅ PASSED
**Goal:** Prove Exyte/Chat renders messages in an iOS app before committing.
- [x] Exyte/Chat added as SPM dependency, compiles for iOS
- [x] Hardcoded messages render in simulator
- [x] Input bar works (type + send)
- [x] Streaming text update works
- [x] No showstoppers

**Spike report:** `Docs/Architecture/GATE1-SPIKE-REPORT.md`

### Gate 2: Real Data Pipeline ✅ COMPLETE (all sub-gates passed)
**Goal:** Connect Exyte UI to real BeeChat data through Core packages.

#### Gate 2A: AnyCodable Fix + Persistence Layer ✅ VALIDATED + TEAM-AUDITED
- [x] v5 packages compile in iOS target
- [x] 3-target module structure (BeeChatMobileKit, BeeChatUI, BeeChatMobile app)
- [x] GRDB schema migrations run on iOS
- [x] Topic list displays from local DB
- [x] Messages display in Exyte ChatView from local DB
- [x] Kieran adversarial review: PASS
- [x] Recovery from protocol breach completed (commit: `8feebb4`)

#### Gate 2B: Live Gateway Connection ✅ FUNCTIONALLY COMPLETE
- [x] App connects to gateway on launch
- [x] Connection state visible in UI
- [x] Device identity sent on handshake (deviceFamily: "mobile")
- [x] Gateway auto-pairing works for local connections
- [x] App shows 🟢 Online status when connected
- [x] Cached data shows immediately on launch (offline-first)

#### Gate 2B.5: Topic Architecture ✅ PHASES 1 & 2 COMPLETE
**Goal:** Replace raw session list with proper Topic layer. Sidebar shows user-created Topics, not gateway sessions.
- [x] Phase 1: Data Layer — Topic model, repository, migration, ViewModel wiring (commit: `bd36900`)
- [x] Phase 2: UI Layer — NewTopicSheet, EmptyTopicsView, ImportSessionsSheet, swipe actions, archive/undo, accessibility (commit: `387e466`)
- [x] Topic CRUD working: create, archive, delete all functional
- [x] Kieran code review fixes applied (commit: `3d589c2`, `9855c6f`)
- [x] Adam verified: topics can be created, deleted, and archived on real device

**Specs (team-approved v3.2):** [GATE-2B5-PHASE1-DATA-LAYER-v3.2.md](Docs/Architecture/GATE-2B5-PHASE1-DATA-LAYER-v3.2.md)
**Architecture parent:** [GATE-2B5-TOPIC-ARCHITECTURE-v2.md](Docs/Architecture/GATE-2B5-TOPIC-ARCHITECTURE-v2.md)

#### Gate 2C: End-to-End Send/Receive ✅ FUNCTIONALLY COMPLETE
- [x] Send triggers `chat.send` via SyncBridge
- [x] Optimistic message appears immediately
- [x] Bee's reply streams in correctly
- [x] Message order correct
- [x] Content-based dedup
- [x] Mic/dictation button works (iOS native dictation confirmed on real device)

#### Gate 2D: Reconnect & Reconciliation 🔄 TODO
**Goal:** Network interruptions handled gracefully.
- [ ] Automatic reconnection after network recovery
- [ ] Reconciliation fetches latest data, no duplicates
- [ ] Stalled streaming cleaned up
- [ ] Delivery ledger transitions correctly

#### Gate 2E: Tailscale + Real Device Baseline ✅ VERIFIED ON REAL DEVICE
- [x] App builds and runs on real iPhone via Xcode USB
- [x] Basic send/receive works on real device over Tailscale
- [x] Field-tested on mobile and WiFi connections
- [x] App icon (bee) on iPhone home screen
- [x] Swap-out architecture: one URL change to switch networking

**Spec:** [GATE-2E-TAILSCALE-REAL-DEVICE.md](Docs/Architecture/GATE-2E-TAILSCALE-REAL-DEVICE.md)

### Gate 2F: Cross-Device Topic Sync 🔄 PHASE 0 COMPLETE, PHASE 1 NEXT
**Goal:** Mac is the master topic source. iPhone sees the same topics as Mac (like Telegram). No bidirectional sync needed — iPhone is conversations on the go.
**Spec (v2, team-approved):** [GATE-2F-CROSS-DEVICE-TOPIC-SYNC-v2.md](Docs/Architecture/GATE-2F-CROSS-DEVICE-TOPIC-SYNC-v2.md)
**ADR:** [ADR-003-cross-device-topic-sync.md](Docs/Decisions/ADR-003-cross-device-topic-sync.md)
**Reviews:** [Q](Docs/Architecture/GATE-2F-V1-Q-REVIEW.md), [Kieran](Docs/Architecture/GATE-2F-V1-KIERAN-REVIEW.md), [Mel](Docs/Architecture/GATE-2F-V1-MEL-REVIEW.md), [Consolidated](Docs/Architecture/GATE-2F-V1-CONSOLIDATED-REVIEW.md)

**Design constraints (Adam, May 22):**
- Mac is master — topic definitions flow Mac → iPhone only
- iPhone is conversations on the go — no need for iPhone topics to sync back
- One device at a time typically — no relentless real-time pinging
- Duplicate topic names only a concern at initial sync
- Simple, stable, unbreakable
- Standard patterns — minimal invention, reuse existing

**Architecture:** Gateway is truth, iPhone is cache. `sessions.pluginPatch` for metadata, `sessions.patch` for labels, `sessions.list` for reads, `sessions.changed` for push. No new gateway endpoints.

#### Phase 0: Shared Package Prerequisite ✅ COMPLETE
- [x] `SessionInfo` decodes `pluginExtensions` from `sessions.list` response (backwards compatible)
- [x] `BeeChatTopicMetadata` typed struct with direct extraction (no AnyCodable round-trip)
- [x] 17 unit tests (including malformed-data tests)
- [x] Kieran adversarial review: PASS (2 blockers fixed)
- [x] Merged to main, tagged `gate-2f-phase0`

#### Phase 1: Mac-Side Publishing 📋 NEXT
- [ ] `sessionsPatch` + `sessionsPluginPatch` RPC wrappers
- [ ] `publishTopicState` + `clearTopicState` on SyncBridge
- [ ] `reconcileAllTopicState()` on reconnect
- [ ] CRUD hooks: create, archive, save, delete
- [ ] Verify `operator.admin` scope on Mac client

#### Phase 2: iPhone Topic Derivation 📋 TODO
#### Phase 3: Cleanup & Validation 📋 TODO

### Gate 3: Mobile UX Shell 📋 TODO
**Goal:** Navigation, mobile lifecycle, backgrounding.
**Exit criteria:**
- [ ] NavigationSplitView works on iPad (sidebar + detail)
- [ ] NavigationStack works on iPhone (push/pop)
- [ ] App survives background/foreground cycle (WebSocket reconnects)
- [ ] Topic switching works without data loss

### Gate 4: Push Notifications MVP 📋 TODO
**Goal:** APNs push from gateway to device.
**Exit criteria:**
- [ ] Apple Developer account set up with push capability
- [ ] Device token registration flow works
- [ ] Gateway can send APNs payload to device
- [ ] Notification tap opens app to correct topic
- [ ] Foreground WebSocket + background push model confirmed

### Gate 5: Polish & Distribution 📋 TODO
**Goal:** TestFlight-ready build.
**Exit criteria:**
- [ ] Valet keychain storage for auth tokens
- [ ] App icon, launch screen, basic settings
- [ ] TestFlight build uploads
- [ ] Adam can install on iPhone and iPad
- [ ] No crashes in 30-minute daily use test

---

## Voice Roadmap (tracked, not urgent)
- **Phase 1 (✅ working):** Dictation to message entry — iOS native dictation, on-device
- **Phase 2 (TODO):** TTS read-back — speaker button on Bee's responses. Start with AVSpeechSynthesizer, upgrade to ElevenLabs Flash v2.5 for personality.
- **Phase 3 (Future):** Live real-time voice — full duplex WebSocket (OpenAI Realtime API / ElevenLabs Agents)

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
- None currently

## Terminology (important)
- **Topic** = user-facing concept. What appears in the sidebar. What users create, archive, delete.
- **Session** = gateway internal. Backend implementation detail only.
- All user-facing UI, specs, and documentation use **Topics** language exclusively.
- "Session switching" does not exist — it's "topic switching" or "navigating between topics."
- This distinction is critical to avoid the confusion that plagued BeeChat macOS development.

## Git
- **Remote:** https://github.com/beebox196-art/Beechat-Mobile
- **Branch:** main
- **Latest commit:** `54ffc0a` — Gate 2E verified on real iPhone

## Next Steps
1. **Gate 2F:** Cross-device topic sync spec (Gav research → spec → team review → implement)
2. **Gate 2D:** Reconnect & reconciliation (more meaningful on real device)
3. **Gate 3:** Mobile UX Shell (backgrounding, navigation)
4. **Voice Phase 2:** TTS read-back on Bee's responses

## Context Notes
- **Parent project:** BeeChat v5 (macOS) — shares Core Swift packages via SPM local dependency
- **Architecture principle:** Gateway owns session truth, local DB is cache. Same model as v5.
- **Key constraint:** No contamination of v5. Package reuse via SPM dependency, not shared files.
- **Validation-first:** Adam wants too much checking, not too little. Hard gates between phases.
- **Stack:** Exyte/Chat (primary), SwiftyChat (fallback), Valet (auth), APNs (push), NavigationSplitView (iPad)
- **Tailscale:** Dev convenience, not dependency. Swap-out is one URL change.

---
*Update this file after each meaningful work session. Stale detection flags files not updated in 7 days.*