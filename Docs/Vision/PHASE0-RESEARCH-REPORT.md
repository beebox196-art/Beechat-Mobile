# BeeChat Mobile Phase 0 Prior Art Survey

**Generated:** 2026-05-12  
**Project:** BeeChat Mobile — native iOS/iPadOS AI chat client  
**Goal:** Find proven, ready-to-use code and patterns so we avoid rebuilding solved pieces.  
**Confidence:** High for package/repo selection; moderate for push effort because final effort depends on existing gateway/APNs capability.

## Executive Summary

The shortest viable route is **not** to fork a full chat app. Mature full apps like Telegram and Element are too large, licence-constrained, and deeply tied to their own protocols. The practical route is:

1. **Reuse BeeChat core packages** for persistence, gateway transport, and sync.
2. **Use a SwiftUI chat UI package** for bubbles, input, media handling, keyboard behaviour, pagination, and message list mechanics.
3. **Use native Apple patterns** for iPad layout, APNs push, app lifecycle, and local auth.
4. **Build only the BeeChat-specific glue**: mapping gateway sessions/messages to UI models, streaming reply updates, agent/session routing, notification routing, and mobile-specific UX.

**Recommended MVP stack:**

| Layer | Recommendation | Why |
|---|---|---|
| Chat UI | **Exyte/Chat** | Most mature SwiftUI-native chat package found; MIT; 1.8k stars; message list, input, markdown, media picker, replies, reactions, pagination. |
| Fallback Chat UI | **SwiftyChat** | Lighter, AI-chat-friendly, Apache-2.0; good fallback if Exyte integration is heavy. |
| Persistence | **Existing BeeChatPersistence** | Already GRDB/SQLite; local DB remains cache. |
| Gateway/WebSocket | **Existing BeeChatGateway**, plus backoff patterns from `wspulse/client-swift` if needed | Avoid replacing working code. Use library patterns, not a rewrite. |
| Sync | **Existing BeeChatSyncBridge** | Already reconciles on reconnect. |
| iPad Layout | **NavigationSplitView** | Native, standard, proven. |
| Push | **Direct APNs from gateway** + iOS Notification Service Extension later | Avoid Firebase/Ably/Pusher unless direct APNs becomes a blocker. |
| Secure Token Storage | **Square Valet** | Active, robust Keychain wrapper, Apache-2.0, 4.2k stars. |
| Markdown | **Exyte built-in / AttributedString(markdown:)**; add Textual only if needed | Do not build markdown renderer. |

Estimated effort reduction versus building from scratch: **55–70% for MVP UI work**, and **35–50% overall** once existing BeeChat core reuse is included. The biggest savings are avoiding a custom chat list/input/keyboard/media stack.

---

## Methodology

Research covered:

- Open-source iOS chat apps and AI chat clients
- SwiftUI chat UI libraries
- APNs and chat push notification architecture
- Multi-platform Swift Package Manager patterns
- WebSocket reconnection on iOS
- iPad split-view layouts
- iOS auth/token/biometric storage patterns

Repo metadata was checked via GitHub API on **2026-05-12** where possible.

---

# 1. Open-source iOS chat apps — full apps we could fork/adapt

## Ranked Findings

### 1. Element X iOS

- **URL:** https://github.com/element-hq/element-x-ios
- **Licence:** AGPL-3.0
- **Stars/maturity:** 845 stars, 309 forks, actively maintained; next-generation Matrix client built with SwiftUI over Matrix Rust SDK.
- **What it provides:** Production-grade chat app architecture, SwiftUI screens, sidebar/detail navigation patterns, state management, login, sync, notification concepts.
- **Adaptation effort:** **Reference only**. Forking would mean removing Matrix protocol, Matrix Rust SDK, crypto, account model, homeserver assumptions, and AGPL constraints.
- **Risks:** AGPL is a major constraint; architecture is bound to Matrix. Too much stripping for BeeChat.
- **Verdict:** **ADAPT AS REFERENCE, DO NOT FORK.**

### 2. Element iOS Classic

- **URL:** https://github.com/element-hq/element-ios
- **Licence:** AGPL-3.0
- **Stars/maturity:** 1,829 stars, 541 forks; mature but previous-generation client.
- **What it provides:** Large production Matrix chat app, long-lived iOS messaging patterns.
- **Adaptation effort:** **Reference only**. Not SwiftUI-first; legacy architecture; Matrix-specific.
- **Risks:** AGPL, old-generation stack, too much irrelevant code.
- **Verdict:** **REFERENCE ONLY.** Useful for notification/sync concepts, not for BeeChat code reuse.

### 3. Telegram iOS

- **URL:** https://github.com/TelegramMessenger/Telegram-iOS
- **Licence:** No standard SPDX licence exposed via GitHub API; Telegram-specific source terms/branding constraints.
- **Stars/maturity:** 8,512 stars, 2,594 forks; huge production codebase.
- **What it provides:** Best-in-class performance ideas, modular chat UI architecture, media handling patterns.
- **Adaptation effort:** **Do not adapt.** Bazel build, heavy C/C++/Objective-C/Swift mix, hundreds of modules/submodules, Telegram protocol assumptions.
- **Risks:** Massive complexity, unclear reusable licence posture, non-standard build, no short path.
- **Verdict:** **DO NOT USE.** Study only if we need inspiration for extreme performance later.

### 4. Open Relay

- **URL:** https://github.com/Ichigo3766/Open-Relay
- **Licence:** GitHub API reported `NOASSERTION`; confirm manually before reuse.
- **Stars/maturity:** 177 stars, 24 forks; active native iOS client for Open WebUI.
- **What it provides:** Real AI chat app shape: model/server setup, chat screens, self-hosted AI UX, streaming-style interactions.
- **Adaptation effort:** **Reference/adapt snippets only**. It targets Open WebUI, not BeeChat gateway/session model.
- **Risks:** Licence needs manual verification; smaller project; API assumptions differ.
- **Verdict:** **REFERENCE.** Worth cloning for UX patterns, not a base fork.

### 5. CherryHQ Hanlin AI

- **URL:** https://github.com/CherryHQ/hanlin-ai
- **Licence:** MIT
- **Stars/maturity:** 226 stars, 30 forks; active SwiftUI LLM chat app.
- **What it provides:** SwiftUI LLM chat patterns, streaming responses, tool-calling/local model ideas.
- **Adaptation effort:** **Reference/adapt small pieces.** App-specific LLM integration needs replacing.
- **Risks:** Young/smaller codebase; not a generic chat client.
- **Verdict:** **REFERENCE.** Good for AI-specific UI details.

### 6. AssisChat

- **URL:** https://github.com/noobnooc/AssisChat
- **Licence:** MIT
- **Stars/maturity:** 330 stars, 48 forks; AI assistant chat app using user-provided OpenAI/Claude keys.
- **What it provides:** API-key management, AI chat UX, multi-provider concepts.
- **Adaptation effort:** **Reference only**. Provider/API key model differs from BeeChat gateway.
- **Risks:** Smaller app; may duplicate things BeeChat already has.
- **Verdict:** **REFERENCE.** Useful for settings/auth flows, not as app base.

### 7. Barnacle OpenChat

- **URL:** https://github.com/Barnacle-ai/OpenChat
- **Licence:** MIT
- **Stars/maturity:** 35 stars, 8 forks; simple native SwiftUI Mac/iPhone/iPad LLM chat app.
- **What it provides:** Minimal SwiftUI cross-platform chat app.
- **Adaptation effort:** **Reference only**. Too small to carry our UI.
- **Risks:** Low maturity; limited features.
- **Verdict:** **REFERENCE ONLY.**

## Category Verdict

**Do not fork a full app.** Full chat apps are either too protocol-specific, too complex, licence-problematic, or too immature. BeeChat already has the hard backend/local-sync architecture. The fastest route is to **reuse BeeChat core + adopt a chat UI library**.

---

# 2. SwiftUI Chat UI Component Libraries

## Ranked Findings

### 1. Exyte/Chat

- **URL:** https://github.com/exyte/Chat
- **Licence:** MIT
- **Stars/maturity:** 1,767 stars, 312 forks; updated 2026-05-11; mature SwiftUI chat UI framework.
- **What it provides:**
  - SwiftUI `ChatView`
  - Message bubbles/list mechanics
  - Input composer
  - Markdown/AttributedString support
  - Photo/video/audio attachments
  - Media picker
  - Pagination/load-more
  - Replies/reactions/swipe actions
  - Themes/localization
  - Custom message/input builders
- **Adaptation effort:** **ADAPT.** Map BeeChat message/session models to Exyte models. Keep BeeChat persistence/gateway untouched.
- **Risks:** iOS 17+ requirement; model mapping required; streaming text updates need a small adapter; may include features we do not need initially.
- **Verdict:** **USE.** Best default for MVP because it avoids rebuilding message list/input/keyboard/media behaviours.

### 2. SwiftyChat

- **URL:** https://github.com/EnesKaraosman/SwiftyChat
- **Swift Package Index:** https://swiftpackageindex.com/EnesKaraosman/SwiftyChat
- **Licence:** Apache-2.0
- **Stars/maturity:** 342 stars, 56 forks; updated 2026-05-04; active; iOS 17+/macOS 14+.
- **What it provides:**
  - Lightweight SwiftUI chat framework
  - 11 message types
  - 8 themes
  - Markdown/attributed text
  - Link previews
  - Loading messages
  - Quick replies/carousels
  - Cross-platform iOS/macOS support
- **Adaptation effort:** **ADAPT.** Likely faster if BeeChat only needs text-first AI chat and minimal attachments.
- **Risks:** Less mature/community adoption than Exyte; fewer production references.
- **Verdict:** **ADAPT / FALLBACK.** Run a quick spike if Exyte feels too heavy.

### 3. MessageKit

- **URL:** https://github.com/MessageKit/MessageKit
- **Licence:** MIT
- **Stars/maturity:** 6,263 stars, 1,201 forks; very mature UIKit replacement for JSQMessagesViewController.
- **What it provides:** Proven UIKit chat message list and input patterns.
- **Adaptation effort:** **High.** Needs UIKit bridging into SwiftUI, or building app screens around UIKit.
- **Risks:** Adds UIKit integration complexity when project direction is native SwiftUI.
- **Verdict:** **DO NOT USE FOR MVP.** Mature but wrong direction unless SwiftUI libraries fail.

### 4. Stream Chat SwiftUI

- **URL:** https://github.com/GetStream/stream-chat-swiftui
- **Licence:** GitHub API reported `NOASSERTION`; tied to Stream product/licensing.
- **Stars/maturity:** 470 stars, 120 forks; active vendor SDK.
- **What it provides:** Full chat SDK, channel lists, offline support, composer, message lists.
- **Adaptation effort:** **Do not adapt.** It assumes Stream backend.
- **Risks:** Vendor lock-in; duplicates BeeChat gateway/sync; paid/commercial considerations.
- **Verdict:** **DO NOT USE.** Good benchmark only.

### 5. Textual / MarkdownUI for rich message rendering

- **Textual URL:** https://github.com/gonzalezreal/textual
- **MarkdownUI URL:** https://github.com/gonzalezreal/swift-markdown-ui
- **Licence:** MIT
- **Stars/maturity:** Textual 642 stars; MarkdownUI 3,834 stars but maintenance mode.
- **What it provides:** Rich attributed text/Markdown rendering in SwiftUI, including advanced structures.
- **Adaptation effort:** **Use only if needed.** Exyte and SwiftUI `AttributedString(markdown:)` may be enough for MVP.
- **Risks:** Extra dependency; overkill for simple chat messages.
- **Verdict:** **DEFER.** Add Textual only if code blocks/tables/advanced markdown matter in MVP.

## Category Verdict

**USE Exyte/Chat first.** It is the highest-leverage UI reuse. Keep SwiftyChat as the lightweight fallback. Do **not** build chat bubbles, keyboard handling, message grouping, attachment UI, or scroll mechanics from scratch.

---

# 3. Push Notification Patterns for Chat Apps

## Ranked Findings

### 1. Direct APNs from BeeChat/OpenClaw gateway

- **URL:** https://developer.apple.com/documentation/usernotifications
- **Licence:** Apple platform APIs.
- **Maturity:** Standard iOS push path.
- **What it provides:** Reliable native iOS push notifications when app is backgrounded/terminated.
- **Adaptation effort:** **BUILD SMALL GATEWAY RELAY + USE native iOS APIs.** Register device token in iOS app; gateway sends APNs payloads for relevant events.
- **Risks:** Requires Apple Developer account, APNs auth key/cert, device-token registration, gateway-side push sender, production/sandbox split.
- **Verdict:** **USE.** This is the cleanest long-term path and avoids vendor lock-in.

### 2. Notification Service Extension

- **URL:** https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications
- **Licence:** Apple platform APIs.
- **Maturity:** Standard for rich notifications.
- **What it provides:** Modify notification content before display; fetch/decrypt previews; attach images; customize title/body.
- **Adaptation effort:** **DEFER/ADAPT.** Not required for MVP if gateway sends simple notification title/body and app syncs on open.
- **Risks:** About 30 seconds execution time; tight memory budget; should not do heavy sync.
- **Verdict:** **BUILD LATER.** MVP can use plain APNs alert + session ID.

### 3. Silent push / background refresh

- **URL:** https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app
- **Licence:** Apple platform APIs.
- **Maturity:** Standard but opportunistic.
- **What it provides:** Background sync hints, not guaranteed real-time delivery.
- **Adaptation effort:** **ADAPT cautiously.** Use push as a wake/sync hint, not as the source of truth.
- **Risks:** iOS throttles background execution; silent pushes are not guaranteed.
- **Verdict:** **SUPPORT, BUT DO NOT DEPEND ON IT.** Foreground WebSocket + APNs alert + foreground sync is the reliable model.

### 4. Firebase Cloud Messaging / OneSignal / Pusher / Ably

- **URLs:**
  - https://firebase.google.com/docs/cloud-messaging
  - https://onesignal.com
  - https://pusher.com
  - https://ably.com
- **Licence/maturity:** Mature hosted services; commercial/vendor terms.
- **What it provides:** Push infrastructure, dashboards, analytics, cross-platform abstractions.
- **Adaptation effort:** **ADAPT if direct APNs blocks.**
- **Risks:** Vendor lock-in, extra infrastructure, privacy/ownership tradeoffs, redundant for a personal BeeChat client.
- **Verdict:** **DO NOT USE FOR MVP unless direct APNs becomes a blocker.**

### 5. ntfy.sh self-hosted notification relay

- **URL:** https://ntfy.sh/docs/config
- **Licence:** Open source service.
- **Maturity:** Useful self-hosted notification system.
- **What it provides:** Simple HTTP pub/sub notifications; can self-host server.
- **Adaptation effort:** **Reference/avoid.** iOS instant notifications still need APNs via upstream ntfy infrastructure.
- **Risks:** Not a clean fit for a custom native BeeChat app; adds another notification path.
- **Verdict:** **DO NOT USE.** Interesting fallback for homelab alerts, not BeeChat Mobile.

## Recommended Push Architecture

MVP:

1. iOS app requests push permission.
2. iOS app registers with APNs and sends device token to BeeChat gateway.
3. Gateway stores token per user/device.
4. When a new relevant message/session event occurs and device is backgrounded, gateway sends APNs payload:
   - `aps.alert.title`
   - `aps.alert.body`
   - `session_id`
   - `message_id`
   - `event_sequence`
5. App opens from notification, sync bridge fetches/reconciles full state from gateway.

Do **not** treat notification payload as canonical message content. Gateway remains truth; local DB remains cache.

## Category Verdict

**USE native APNs.** Build the smallest possible gateway APNs bridge. Defer Notification Service Extension/rich notifications until after MVP.

---

# 4. Multi-platform Swift Package Patterns

## Ranked Findings

### 1. Local Swift Package reuse between macOS and iOS

- **URL:** https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages
- **Licence:** Apple platform tooling.
- **Maturity:** Standard Xcode/SPM workflow.
- **What it provides:** Shared packages compiled into multiple app targets without copying files.
- **Adaptation effort:** **USE.** BeeChat Mobile should depend on BeeChatPersistence, BeeChatGateway, and BeeChatSyncBridge as local SPM packages.
- **Risks:** Platform-specific imports in core packages may fail iOS builds; deployment target mismatch.
- **Verdict:** **USE.** This directly matches the project principle: package reuse, no contamination of macOS v5.

### 2. Platform conditional compilation

- **Pattern:**
  ```swift
  #if os(iOS)
  import UIKit
  #elseif os(macOS)
  import AppKit
  #endif
  ```
- **What it provides:** Keep shared packages clean while isolating platform-specific edge cases.
- **Adaptation effort:** **ADAPT ONLY WHERE NEEDED.** Ideally shared core imports Foundation/GRDB only.
- **Risks:** Too much conditional compilation can make packages messy.
- **Verdict:** **USE SPARINGLY.** If a package needs lots of conditionals, that is a design smell.

### 3. Separate app target, shared package products

- **Pattern:**
  - `BeeChatApp` macOS UI remains separate.
  - `BeeChatMobile` iOS UI target depends on shared packages.
  - Core packages expose stable products.
- **What it provides:** Prevents v5 contamination and keeps UI layers independent.
- **Adaptation effort:** **USE.**
- **Risks:** Shared package changes can still break macOS if APIs are changed carelessly.
- **Verdict:** **USE WITH API DISCIPLINE.** Add tests/build checks for both macOS package build and iOS app build.

## Category Verdict

**USE local SPM packages exactly as planned.** First technical task should be a core package audit/build for iOS. Do not copy shared source files into the mobile app.

---

# 5. WebSocket + Reconnection on iOS

## Ranked Findings

### 1. Existing BeeChatGateway using URLSessionWebSocketTask

- **URL:** Apple native API: https://developer.apple.com/documentation/foundation/urlsessionwebsockettask
- **Licence:** Apple platform API.
- **Maturity:** Native, stable.
- **What it provides:** Existing gateway transport already aligned with iOS/macOS Foundation networking.
- **Adaptation effort:** **USE EXISTING.** Audit for iOS lifecycle handling rather than replacing.
- **Risks:** Native `URLSessionWebSocketTask` is bare-bones; reconnect/backoff/heartbeat must be implemented above it. iOS backgrounding will terminate/suspend foreground sockets.
- **Verdict:** **USE.** Do not replace working gateway code until a concrete failure appears.

### 2. wspulse/client-swift

- **URL:** https://github.com/wspulse/client-swift
- **Licence:** MIT
- **Stars/maturity:** 0 stars at time of check; new/small but active; updated 2026-05-02.
- **What it provides:** Actor-based Swift WebSocket client, auto-reconnect, exponential backoff, URLSessionWebSocketTask-based, iOS 16+.
- **Adaptation effort:** **REFERENCE / POSSIBLE ADAPT.** Good source of proven-ish reconnection/backoff shape, but too young to blindly adopt.
- **Risks:** Very low adoption.
- **Verdict:** **REFERENCE PATTERN, NOT CORE DEPENDENCY YET.**

### 3. Starscream

- **URL:** https://github.com/daltoniam/Starscream
- **Licence:** Apache-2.0
- **Stars/maturity:** 8,637 stars, 1,262 forks; very mature Swift WebSocket library.
- **What it provides:** Popular cross-platform WebSocket implementation.
- **Adaptation effort:** **REPLACE/ADAPT only if needed.**
- **Risks:** Adds dependency; still need app-level reconnect semantics; replacing native code adds churn.
- **Verdict:** **DO NOT USE INITIALLY.** Keep as fallback if `URLSessionWebSocketTask` proves insufficient.

### 4. Pusher WebSocket Swift / Socket.IO Swift

- **URLs:**
  - https://github.com/pusher/pusher-websocket-swift
  - https://github.com/socketio/socket.io-client-swift
- **Licence/maturity:** Mature, but protocol/vendor-specific.
- **What it provides:** Reconnection, heartbeat, event abstractions.
- **Adaptation effort:** **High / wrong protocol.**
- **Risks:** Vendor/protocol mismatch.
- **Verdict:** **DO NOT USE.** BeeChat gateway is plain WebSocket/RPC, not Pusher or Socket.IO.

## Recommended iOS WebSocket Pattern

- Foreground: maintain WebSocket connection.
- Background: expect socket suspension/closure; rely on APNs.
- Foreground/resume: reconnect with exponential backoff and jitter.
- On reconnect: sync bridge reconciles from gateway using sequence/session state.
- Heartbeat: app-level ping or WebSocket ping while foregrounded.
- No persistent background socket assumption.

## Category Verdict

**USE existing BeeChatGateway.** Add only the missing iOS lifecycle/backoff pieces if audit reveals gaps. Do not bring Starscream in unless native Foundation transport fails in practice.

---

# 6. iPad Split-view Layouts

## Ranked Findings

### 1. NavigationSplitView

- **URL:** https://developer.apple.com/documentation/swiftui/navigationsplitview
- **Licence:** Apple SwiftUI API.
- **Maturity:** Standard since iOS 16/macOS 13; current best practice.
- **What it provides:** Two- or three-column layouts for sidebar/detail experiences. Perfect for session list + chat detail on iPad.
- **Adaptation effort:** **USE VERBATIM.**
- **Risks:** Need careful state selection binding for compact/regular size classes.
- **Verdict:** **USE.** Do not build custom split-view navigation.

### 2. Size-class adaptive layout

- **Pattern:** iPhone = stack navigation; iPad = sidebar + detail.
- **What it provides:** Native iPhone/iPad behaviour from same SwiftUI structure.
- **Adaptation effort:** **ADAPT.**
- **Risks:** Need test on iPad landscape/portrait and iPhone compact.
- **Verdict:** **USE.**

### 3. Three-column layout later

- **Pattern:** Sidebar = sessions; content = thread/message list; detail = agent/session metadata/BeeBoard.
- **What it provides:** Future full iPad workspace.
- **Adaptation effort:** **DEFER.**
- **Risks:** Overbuilding MVP.
- **Verdict:** **BUILD LATER.** MVP should be two-column.

## Category Verdict

**USE NavigationSplitView.** MVP: session sidebar + chat detail. Do not create custom tablet navigation.

---

# 7. Auth Patterns for iOS Chat Apps

## Ranked Findings

### 1. Square Valet

- **URL:** https://github.com/square/Valet
- **Swift Package Index:** https://swiftpackageindex.com/square/Valet
- **Licence:** Apache-2.0
- **Stars/maturity:** 4,158 stars, 224 forks; updated 2026-05-10; actively maintained.
- **What it provides:** Friendly Keychain wrapper; token storage; access control; app group support; biometric/Secure Enclave options.
- **Adaptation effort:** **USE.** Store gateway token/session credentials in Keychain via Valet.
- **Risks:** Adds dependency, but small and well-maintained.
- **Verdict:** **USE.** Best balance of active maintenance and capability.

### 2. KeychainAccess

- **URL:** https://github.com/kishikawakatsumi/KeychainAccess
- **Licence:** MIT
- **Stars/maturity:** 8,247 stars, 838 forks; popular and stable.
- **What it provides:** Simple Swift Keychain API, broad platform support.
- **Adaptation effort:** **USE if simplicity preferred.**
- **Risks:** Historically less active than Valet; fewer advanced guardrails.
- **Verdict:** **FALLBACK.** Good option, but Valet is better for a new project.

### 3. Native Security + LocalAuthentication frameworks

- **URLs:**
  - https://developer.apple.com/documentation/security
  - https://developer.apple.com/documentation/localauthentication
- **Licence:** Apple platform APIs.
- **Maturity:** Canonical APIs.
- **What it provides:** Direct Keychain and Face ID/Touch ID.
- **Adaptation effort:** **Build wrapper manually.**
- **Risks:** Verbose, easy to make small mistakes, unnecessary when Valet exists.
- **Verdict:** **DO NOT BUILD FROM SCRATCH.** Use Valet unless dependency policy forbids it.

## Recommended Auth Pattern

MVP:

- Store gateway auth token in Valet using device-local Keychain accessibility.
- Optional app lock with Face ID/Touch ID using LocalAuthentication.
- Do not store secrets in UserDefaults.
- Do not put full chat content in notification payloads.
- Support logout by clearing token + local cache if requested.

## Category Verdict

**USE Valet.** Defer biometric app lock unless Adam explicitly wants it in MVP.

---

# Recommended Stack

## MVP Stack

| Area | Use | Notes |
|---|---|---|
| App framework | SwiftUI | Native iOS/iPadOS target. |
| Chat UI | Exyte/Chat | Primary package for message list, bubbles, input, attachments. |
| Chat UI fallback | SwiftyChat | Spike if Exyte mapping is too heavy. |
| Persistence | BeeChatPersistence | Existing GRDB/SQLite package. |
| Gateway | BeeChatGateway | Existing URLSessionWebSocketTask-based gateway client. |
| Sync | BeeChatSyncBridge | Existing reconnect/reconcile model. |
| Layout | NavigationSplitView | iPad sidebar/detail. |
| iPhone navigation | NavigationStack | Native compact layout. |
| Push | APNs direct from gateway | Plain alert payload initially. |
| Auth token storage | Valet | Keychain wrapper. |
| Markdown | Exyte/AttributedString | Add Textual only for advanced markdown/code blocks. |

## First Build Spike

A practical 2–3 day technical spike should answer all real integration risks:

1. Create iOS app target.
2. Add local SPM dependencies to BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge.
3. Add Exyte/Chat.
4. Render hardcoded BeeChat-style messages in Exyte.
5. Map real cached messages from BeeChatPersistence into Exyte models.
6. Send a message through BeeChatGateway in foreground.
7. Reconnect and verify BeeChatSyncBridge reconciliation.
8. Run on iPhone simulator + iPad simulator.

If Exyte integration fights us for more than one day, switch to SwiftyChat before sunk cost builds up.

---

# What We DON'T Build

Do **not** build these from scratch:

- Chat bubbles
- Message grouping
- Scroll-to-bottom behaviour
- Keyboard avoidance
- Input composer basics
- Markdown inline rendering
- Attachment picker basics
- iPad split-view navigation
- Keychain wrapper
- WebSocket protocol client from zero
- Custom push notification infrastructure beyond the gateway APNs sender
- Full local-first sync model — BeeChat already has gateway truth + local cache + reconciliation

This is the main lesson from v5: avoid heroic custom infrastructure where a proven package exists.

---

# What We DO Build

Build only BeeChat-specific pieces:

1. **BeeChat iOS shell**
   - SwiftUI app target
   - App lifecycle
   - Dependency injection / app state

2. **Model adapters**
   - BeeChat session/message models → chat UI package models
   - Draft/send flow → gateway RPC/event flow
   - Streaming assistant reply updates → update visible message row

3. **Mobile session UX**
   - Session sidebar/list
   - Search/filter if needed
   - Agent/session metadata surfaces

4. **Gateway integration**
   - Auth bootstrap
   - Foreground WebSocket connection lifecycle
   - Reconnect/resync hooks on app foreground

5. **Push registration**
   - Device token registration
   - Gateway token registration endpoint/client call
   - Notification tap routing to session/message

6. **BeeChat-specific future features**
   - Voice input/output
   - BeeBoard integration
   - Agent routing controls
   - Notification preferences per session
   - Widgets/quick actions

---

# Estimated Effort Reduction

## Versus building from scratch

| Area | Scratch Estimate | With recommended reuse | Reduction |
|---|---:|---:|---:|
| Chat UI list/bubbles/input/keyboard | 7–12 days | 1–3 days integration | 65–80% |
| Local persistence | 4–7 days | Existing package audit | 80–90% |
| WebSocket transport | 3–5 days | Existing gateway audit | 60–80% |
| Sync/reconcile | 5–10 days | Existing sync bridge audit | 70–90% |
| iPad layout | 2–4 days custom | 0.5–1 day NavigationSplitView | 60–75% |
| Auth storage | 1–2 days raw Keychain | 0.25–0.5 day Valet | 60–75% |
| Push MVP | 3–6 days | 2–4 days direct APNs setup | 20–40% |

**Overall MVP reduction:** approximately **35–50%**.  
**UI-specific reduction:** approximately **55–70%**.  
**Risk reduction:** high, because the trickiest UI behaviours are delegated to maintained packages.

---

# Final Recommendation

Proceed with this approach:

1. **Do not fork Telegram, Element, or an AI chat clone.** Too much stripping; wrong architecture/licence/protocol.
2. **Start with Exyte/Chat.** It is the best ready-made SwiftUI chat surface.
3. **Keep SwiftyChat as fallback.** If Exyte model mapping slows the spike, switch quickly.
4. **Reuse BeeChat core packages.** Audit them for iOS compatibility before UI build-out.
5. **Use native APNs, NavigationSplitView, and Valet.** These are solved problems.
6. **Build only adapters and BeeChat-specific UX.** That is where effort actually belongs.

**Practical next action:** run a 2–3 day integration spike: iOS target + local core packages + Exyte/Chat + real gateway send/receive in foreground. That will validate the stack before any deeper build commitment.

---

# Source Index

## Repos / Libraries

- Exyte/Chat — https://github.com/exyte/Chat
- SwiftyChat — https://github.com/EnesKaraosman/SwiftyChat
- Swift Package Index: SwiftyChat — https://swiftpackageindex.com/EnesKaraosman/SwiftyChat
- MessageKit — https://github.com/MessageKit/MessageKit
- Stream Chat SwiftUI — https://github.com/GetStream/stream-chat-swiftui
- Element X iOS — https://github.com/element-hq/element-x-ios
- Element iOS Classic — https://github.com/element-hq/element-ios
- Telegram iOS — https://github.com/TelegramMessenger/Telegram-iOS
- Open Relay — https://github.com/Ichigo3766/Open-Relay
- Hanlin AI — https://github.com/CherryHQ/hanlin-ai
- AssisChat — https://github.com/noobnooc/AssisChat
- Barnacle OpenChat — https://github.com/Barnacle-ai/OpenChat
- Valet — https://github.com/square/Valet
- Swift Package Index: Valet — https://swiftpackageindex.com/square/Valet
- KeychainAccess — https://github.com/kishikawakatsumi/KeychainAccess
- Starscream — https://github.com/daltoniam/Starscream
- wspulse/client-swift — https://github.com/wspulse/client-swift
- Textual — https://github.com/gonzalezreal/textual
- MarkdownUI — https://github.com/gonzalezreal/swift-markdown-ui

## Apple Docs

- NavigationSplitView — https://developer.apple.com/documentation/swiftui/navigationsplitview
- UserNotifications — https://developer.apple.com/documentation/usernotifications
- Notification Service Extension — https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications
- Background Tasks Strategy — https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app
- URLSessionWebSocketTask — https://developer.apple.com/documentation/foundation/urlsessionwebsockettask
- Organizing code with local packages — https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages
- Keychain/Security — https://developer.apple.com/documentation/security
- LocalAuthentication — https://developer.apple.com/documentation/localauthentication

## Push / Notification Services

- ntfy self-hosting docs — https://ntfy.sh/docs/config
- Firebase Cloud Messaging — https://firebase.google.com/docs/cloud-messaging
- OneSignal — https://onesignal.com
- Pusher — https://pusher.com
- Ably — https://ably.com
