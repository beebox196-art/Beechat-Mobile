# Gate 2 Specification: Real Data Pipeline

**Date:** 2026-05-15
**Status:** DRAFT — Pending team review
**Author:** Bee (Coordinator)
**Reviewers:** Q (Builder), Kieran (Reviewer), Mel (Designer), Gav (Researcher)

---

## 1. Overview

Gate 2 replaces the hardcoded demo (`BeeChatDemoView.swift`) with a live data pipeline connecting the BeeChat Core packages to the Exyte Chat UI. The goal is a working BeeChat client that can connect to a real OpenClaw gateway, display real messages, and send messages that reach the agent.

This spec breaks Gate 2 into four sub-gates (2A→2B→2C→2D), each independently testable, to avoid compounding risk.

---

## 2. Architecture Principles

### 2.1 Modularity First

Every component must be a **standalone Swift package or module** with a clear public API, not a monolithic file. This is non-negotiable.

**Why:**
- Reuse without rewrites — if we find a better markdown renderer, we swap one module, not refactor a 500-file view
- Test in isolation — each module can have its own test target
- Parallel development — Q can work on the ViewModel while Mel works on themes without merge conflicts
- Swapability — Exyte/Chat is our UI today, but a future SwiftUI-native chat view should be a drop-in replacement for one module, not a rewrite

**Module boundaries:**

| Module | Package | Depends On | Responsibility |
|--------|---------|------------|----------------|
| **BeeChatPersistence** | Already exists (v5) | GRDB | Local DB — sessions, messages, delivery ledger |
| **BeeChatGateway** | Already exists (v5) | Foundation, CryptoKit | WebSocket connection, RPC calls |
| **BeeChatSyncBridge** | Already exists (v5) | Gateway, Persistence | Event routing, reconciliation, streaming state |
| **BeeChatMobileKit** | NEW (local SPM package) | SyncBridge, Persistence | iOS-specific ViewModel layer, connection management, config loading |
| **BeeChatUI** | NEW (local SPM package) | ExyteChat, BeeChatMobileKit | View layer — maps ViewModel state to Exyte ChatView |
| **BeeChatMobile** (app target) | NEW | BeeChatMobileKit, BeeChatUI | App entry point, SwiftUI lifecycle, scene management |

**Package.swift dependency graph:**
```
BeeChatMobile (app)
├── BeeChatUI
│   ├── ExyteChat
│   └── BeeChatMobileKit
│       ├── BeeChatSyncBridge
│       │   ├── BeeChatGateway
│       │   └── BeeChatPersistence
│       │       └── GRDB
│       └── (iOS-specific config, Keychain, etc.)
└── BeeChatMobileKit (re-exported through BeeChatUI)
```

### 2.2 Don't Reinvent the Wheel

The v5 Core packages (Persistence, Gateway, SyncBridge) already implement:
- WebSocket connection with handshake, challenge-response, retry
- RPC calls (`sessions.list`, `sessions.subscribe`, `chat.history`, `chat.send`, `chat.abort`, `sessions.usage`, `sessions.reset`)
- Event routing (`chat`, `agent`, `session.message`, `sessions.changed`, `health`, `tick`)
- Streaming text (delta/final/aborted states, stall detection)
- Local GRDB persistence (sessions, messages, delivery ledger, topics, bookmarks)
- Reconciliation on reconnect
- Session reset with context carry-forward
- Delivery ledger with idempotency keys

**We must reuse all of this.** The mobile app should NOT re-implement any of this logic. The ViewModel layer wraps and adapts — it does not duplicate.

### 2.3 Minimal Bridge Pattern

The only new code is the **bridge** between v5's actor-based Core packages and SwiftUI's `@Observable`/`@MainActor` world. This bridge must be thin:

- **No business logic** in the ViewModel — all logic lives in Core
- **No state duplication** — ViewModel observes Core state and publishes to SwiftUI
- **No direct DB access** from views — all data flows through ViewModel
- **No WebSocket management** in ViewModel — SyncBridge owns the connection lifecycle

---

## 3. Known Issues Carrying In

| Issue | Impact | Resolution |
|-------|--------|------------|
| **AnyCodable.swift** `NSDictionary.isEqual` | iOS compilation fails in `Equatable` conformance | Gate 2A: Replace `NSDictionary` equality with type-explicit comparison |
| **v5 `DatabaseManager.shared`** | Singleton pattern — iOS app needs its own DB path | Gate 2A: `BeeChatMobileKit` provides iOS-specific path via `FileManager` |
| **v5 `AppState`** | macOS-specific (`WindowGroup`, `.windowStyle`, menu commands) | Not reused — mobile has its own `App` entry point |
| **v5 `KeychainTokenStore`** | macOS `SecAccessControl` may need iOS adjustment | Gate 2A: Verify Keychain access works on iOS simulator |
| **`OSAllocatedUnfairLock`** | Used in `PendingRequestMap` — iOS 16+ compatible | No change needed, iOS 17 floor is fine |
| **Exyte "B" avatar** | Stray avatar initial on assistant messages | Gate 2A: Custom `User` with empty name or `avatarURL` override |

---

## 4. Sub-Gate Specifications

### 4.1 Gate 2A: AnyCodable Fix + Persistence Layer

**Goal:** Make v5 Core packages compile into the iOS app target, then read cached sessions and messages from GRDB and render them in Exyte UI. **No network needed.**

**Exit Criteria:**
1. `BeeChatPersistence`, `BeeChatGateway`, and `BeeChatSyncBridge` all compile in the iOS app target
2. AnyCodable `Equatable` works correctly on iOS
3. App launches, opens GRDB database, creates schema (migrations run)
4. App can write a test session + messages to the DB
5. Sessions list view shows DB contents
6. Tapping a session shows its messages in Exyte ChatView
7. No network connection required or attempted

**Module structure:**
```
BeeChatMobile/Sources/BeeChatMobileKit/
├── BeeChatMobileConfig.swift       # iOS-specific config (DB path, gateway URL)
├── BeeChatMobileViewModel.swift    # @Observable, @MainActor, owns SyncBridge lifecycle
├── MessageMapper.swift            # v5 Message/Session → Exyte Message/User
└── KeychainTokenStore+iOS.swift   # iOS keychain adaptation (if needed)

BeeChatMobile/Sources/BeeChatUI/
├── BeeChatView.swift              # Main chat view wrapping Exyte ChatView
├── SessionListView.swift          # Sessions sidebar/list
├── ConnectionStatusView.swift     # Connection indicator
└── Theme/
    └── BeeChatTheme.swift          # ExyteChat theme configuration

BeeChatMobile/Sources/App/
├── BeeChatMobileApp.swift         # @main app entry
└── Info.plist
```

**Package.swift changes:**
- Add `BeeChatMobileKit` library target (depends on BeeChatSyncBridge, BeeChatPersistence)
- Add `BeeChatUI` library target (depends on ExyteChat, BeeChatMobileKit)
- Add `BeeChatMobile` executable target (the app, depends on BeeChatUI)
- Add `BeeChatMobileKitTests` test target

**Key implementation details:**

**BeeChatMobileConfig:**
```swift
public struct BeeChatMobileConfig {
    public let databasePath: String      // iOS: app support dir
    public let gatewayURL: String?       // nil = offline mode
    public let gatewayToken: String?     // nil = offline mode
    public let clientMode: String        // "mobile"
    
    public static let defaultDBName = "beechat.sqlite"
    
    public static func defaultDatabasePath() -> String {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("BeeChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(defaultDBName).path
    }
}
```

**BeeChatMobileViewModel:**
```swift
@MainActor @Observable
final class BeeChatMobileViewModel {
    // Connection
    var connectionState: ConnectionState = .disconnected
    
    // Data
    var sessions: [Session] = []
    var currentSession: Session?
    var messages: [Message] = []          // v5 Message model
    var displayMessages: [ExyteChat.Message] = []  // mapped for UI
    
    // Streaming
    var isStreaming = false
    var streamingText = ""
    
    // Core
    private var syncBridge: SyncBridge?
    private var persistenceStore: BeeChatPersistenceStore?
    
    // Offline-first: can show cached data without gateway
    func loadCachedData() throws { ... }
    
    // Online: connect and sync
    func connect() async throws { ... }
    func disconnect() async { ... }
    
    // Actions
    func sendMessage(_ text: String) async throws { ... }
}
```

**MessageMapper:**
```swift
struct MessageMapper {
    static let adamUser = ExyteChat.User(id: "adam", name: "Adam", avatarURL: nil, isCurrentUser: true)
    static let beeUser = ExyteChat.User(id: "bee", name: "", avatarURL: nil, isCurrentUser: false)  // empty name = no avatar initial
    
    static func toExyteMessage(_ v5Message: BeeChatPersistence.Message) -> ExyteChat.Message { ... }
    static func toExyteMessages(_ v5Messages: [BeeChatPersistence.Message]) -> [ExyteChat.Message] { ... }
    static func toExyteUser(role: String, senderName: String?) -> ExyteChat.User { ... }
}
```

**AnyCodable fix:**
The current `Equatable` implementation uses `NSDictionary.isEqual(to:)` which doesn't work correctly on iOS. Replace with type-explicit comparison:
```swift
extension AnyCodable: Equatable {
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (a as Bool, b as Bool): return a == b
        case let (a as Int, b as Int): return a == b
        case let (a as Double, b as Double): return a == b
        case let (a as String, b as String): return a == b
        case let (a as [AnyCodable], b as [AnyCodable]): return a == b
        case let (a as [String: AnyCodable], b as [String: AnyCodable]): return a == b
        case (is NSNull, is NSNull): return true
        default: return false
        }
    }
}
```

**Note:** This fix should be applied to the **v5 repo** (`BeeChat-v5/Sources/BeeChatGateway/AnyCodable.swift`) since both macOS and iOS benefit from a correct implementation. It should NOT be forked into the mobile project.

**Review checklist for Gate 2A:**
- [ ] All three Core packages compile for iOS
- [ ] AnyCodable Equatable passes unit tests on both macOS and iOS
- [ ] GRDB migrations run successfully on iOS
- [ ] Sessions can be read from DB and displayed in list
- [ ] Messages can be read from DB and displayed in Exyte ChatView
- [ ] No retain cycles in ViewModel → Core → ViewModel callback chain
- [ ] No network calls made (offline-first verified)
- [ ] Exyte ChatView renders with correct User mapping (no stray avatar initials)
- [ ] KeychainTokenStore works on iOS simulator

---

### 4.2 Gate 2B: Live Gateway Connection

**Goal:** Connect to a real OpenClaw gateway via WebSocket and receive messages. **Sending not required yet.**

**Exit Criteria:**
1. App connects to running OpenClaw gateway on local network
2. Connection state changes are visible in the UI (disconnected → connecting → connected)
3. Incoming messages from the gateway render in real-time in Exyte ChatView
4. Streaming text (delta events) updates character-by-character in the UI
5. Session list updates when `sessions.changed` event fires
6. App reconnects automatically after brief network interruption
7. Cached data shows immediately on launch (offline-first UX)

**Key implementation details:**

**Gateway config loading:**
The macOS v5 reads `~/.openclaw/openclaw.json`. On iOS, the app needs a different approach:
- **Option A (MVP):** Hardcoded gateway URL + token in `BeeChatMobileConfig` for development
- **Option B (future):** Settings screen with QR code pairing or manual entry
- **For Gate 2B:** Use Option A — a simple config struct with the local gateway URL and token

```swift
extension BeeChatMobileConfig {
    // Development config — points to local gateway
    public static let development = BeeChatMobileConfig(
        databasePath: defaultDatabasePath(),
        gatewayURL: "ws://127.0.0.1:18789",
        gatewayToken: "<read from environment or config file>",
        clientMode: "mobile"
    )
}
```

**Note:** The token MUST NOT be committed to the repo. It should be read from a `.env` file or Xcode scheme environment variable at build time. The `.gitignore` must exclude config files containing tokens.

**Connection lifecycle:**
```swift
// In BeeChatMobileViewModel
func connect() async throws {
    guard let config = BeeChatMobileConfig.development.gatewayURL,
          let token = BeeChatMobileConfig.development.gatewayToken else {
        connectionState = .disconnected
        return
    }
    
    let gwConfig = GatewayClient.Configuration(
        url: config,
        token: token,
        clientMode: "mobile",
        clientInfo: .init(id: "openclaw-ios", version: "1.0", platform: "ios", mode: "mobile")
    )
    
    let persistenceStore = BeeChatPersistenceStore()
    try persistenceStore.openDatabase(at: BeeChatMobileConfig.defaultDatabasePath())
    
    let gatewayClient = GatewayClient(config: gwConfig)
    let syncBridgeConfig = SyncBridgeConfiguration(
        gatewayClient: gatewayClient,
        persistenceStore: persistenceStore
    )
    
    self.syncBridge = SyncBridge(config: syncBridgeConfig)
    self.syncBridge?.delegate = self
    
    try await syncBridge?.start()
    connectionState = .connected
}
```

**SyncBridgeDelegate conformance:**
```swift
extension BeeChatMobileViewModel: SyncBridgeDelegate {
    func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState) {
        self.connectionState = state
    }
    
    func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String) {
        self.isStreaming = true
    }
    
    func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
        self.isStreaming = false
        Task { await refreshMessages() }
    }
    
    // ... error handling, auto-reset notifications
}
```

**Streaming text binding:**
SyncBridge already manages a `streamingBuffer` and `streamingSessionKeys`. The ViewModel polls `syncBridge.streamingContent(for:)` during streaming and maps it to the Exyte `Message` text.

**Review checklist for Gate 2B:**
- [ ] Gateway connects on launch (auto-connect)
- [ ] Connection state indicator updates in real-time
- [ ] Incoming messages appear in chat without manual refresh
- [ ] Streaming text updates character-by-character
- [ ] Session list refreshes when `sessions.changed` fires
- [ ] Reconnection works after brief disconnect (5-10 seconds)
- [ ] Cached data shows immediately on launch before connection
- [ ] Gateway token NOT committed to repo
- [ ] No force-unwraps on optional network responses
- [ ] Error states handled gracefully (connection refused, auth failure)

---

### 4.3 Gate 2C: End-to-End Send/Receive

**Goal:** User types a message, it reaches the gateway, Bee processes it, and the reply appears in the chat.

**Exit Criteria:**
1. User types in Exyte input bar and taps send
2. Message is optimistically added to local DB with `.sending` status
3. Message reaches OpenClaw gateway via `chat.send` RPC
4. Optimistic status updates to `.sent` on gateway acknowledgment
5. Bee's reply streams in via `chat` delta events
6. Reply finalizes and is persisted to local DB
7. Message ordering is correct (user message → streaming reply → final reply)
8. Failed sends show `.error` status and can be retried

**Key implementation details:**

**Send flow:**
```swift
func sendMessage(_ text: String) async throws {
    // 1. Optimistic local write
    let optimisticMessage = BeeChatPersistence.Message(
        id: UUID().uuidString,
        sessionId: currentSessionKey,
        role: "user",
        content: text,
        timestamp: Date()
    )
    try persistenceStore.saveMessage(optimisticMessage)
    updateDisplayMessages()
    
    // 2. Send via SyncBridge (handles idempotency, auto-reset, context injection)
    do {
        _ = try await syncBridge.sendMessage(
            sessionKey: currentSessionKey,
            text: text
        )
        // Status update handled by SyncBridge + event stream
    } catch {
        // Mark as failed, offer retry
        optimisticMessage.status = .error
        try persistenceStore.saveMessage(optimisticMessage)
        updateDisplayMessages()
    }
}
```

**Message status mapping:**
```swift
// v5 doesn't have explicit delivery status on messages
// We infer from position in flow:
// - Just sent, no gateway response → .sending
// - Gateway acknowledged (runId received) → .sent
// - Delivery confirmed (appears in history) → .delivered
// - Read (future feature) → .read

static func toExyteStatus(_ v5Message: BeeChatPersistence.Message) -> ExyteChat.Message.Status {
    // For now, messages loaded from DB are always .read
    // Optimistic sends use .sending → .sent → .read progression
    return .read
}
```

**Review checklist for Gate 2C:**
- [ ] Send button triggers `sendMessage()`
- [ ] Optimistic message appears immediately
- [ ] Gateway receives the message (verify in OpenClaw logs)
- [ | Bee's reply streams in correctly
- [ ] Message status transitions: sending → sent → read
- [ ] Failed sends show error state
- [ ] Idempotency key prevents duplicate sends
- [ ] Auto-reset fires correctly when context window fills
- [ ] No message duplication after reconnect
- [ ] Message ordering is correct (timestamps respected)

---

### 4.4 Gate 2D: Reconnect & Reconciliation

**Goal:** SyncBridge handles disconnects gracefully, and the app recovers cleanly.

**Exit Criteria:**
1. Network interruption (WiFi off → on) results in automatic reconnection
2. After reconnect, `Reconciler` fetches latest sessions and messages from gateway
3. No duplicate messages appear after reconciliation
4. No messages lost during disconnect (optimistic sends are retried or marked failed)
5. App remains usable during offline period (cached data visible, send queued)
6. Streaming messages that were interrupted are cleaned up (stall detection)

**Key implementation details:**

SyncBridge already implements:
- `Reconciler.reconcile()` — fetches latest history, upserts to DB, reconciles delivery ledger
- `SyncBridge.clearAllStalledStreams()` — cleans up interrupted streaming on disconnect
- `GatewayClient` exponential backoff with configurable retry (max 10 retries)
- `DeliveryLedgerEntry` tracking with `.pending` → `.sent` → `.delivered`/`.failed` states

The ViewModel needs to:
- Observe connection state changes and show appropriate UI (offline banner, reconnecting spinner)
- NOT queue sends while offline (reject with clear error message instead)
- On reconnect, refresh session list and current chat history
- Clear stale streaming state

**Review checklist for Gate 2D:**
- [ ] Airplane mode toggled → app reconnects automatically
- [ ] Reconciled data matches what's on the gateway
- [ ] No duplicate messages after reconciliation
- [ ] Delivery ledger entries transition correctly
- [ ] Streaming state cleaned up on disconnect
- [ ] UI shows connection state accurately at all times
- [ ] Stall timer fires correctly (30 seconds of no delta → stream cleared)
- [ ] No crashes or data corruption during rapid connect/disconnect cycles

---

## 5. Testing Strategy

### 5.1 Unit Tests

Each module gets its own test target:

| Test Target | Tests |
|-------------|-------|
| `BeeChatMobileKitTests` | Config defaults, ViewModel state transitions, MessageMapper mapping, offline data loading |
| `BeeChatUITests` | View rendering (SwiftUI Preview), theme application |

### 5.2 Integration Tests

- **Gate 2A:** Launch app → verify DB created → verify schema → insert test data → verify display
- **Gate 2B:** Launch app with gateway running → verify connection → send message from gateway CLI → verify it appears
- **Gate 2C:** Launch app → type message → verify it appears in gateway logs → verify reply streams back
- **Gate 2D:** Launch app → connect → toggle network → verify reconnect → verify reconciliation

### 5.3 Manual Verification

Each sub-gate requires a **manual verification step** on the iOS simulator (or physical device):
1. Build and run on iPhone 17 simulator
2. Verify visual rendering matches expectations
3. Verify interactive flows (typing, sending, receiving)
4. Verify error states (connection failure, send failure)

---

## 6. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Exyte/Chat API doesn't support some v5 features (streaming, status updates) | Medium | Low | Already verified streaming works in Gate 1; fallback to custom `ChatView` wrapper |
| `DatabaseManager.shared` singleton conflicts on iOS (different app sandbox) | Low | Medium | `BeeChatMobileConfig` provides iOS-specific path; singleton pattern is fine per-app |
| Keychain access differs on iOS vs macOS | Medium | Low | `KeychainTokenStore` uses standard Security framework APIs; verify on simulator |
| Exyte/Chat `Message` struct is value type — frequent mutations for streaming | Medium | High | Use `@State` array + element replacement (same pattern as demo); SwiftUI's diffing handles it. If performance issues, switch to `@Observable` object wrapper |
| WebSocket connection drops on iOS background | High | High | Gate 4 (Push Notifications) addresses this. For Gate 2, app is foreground-only. Document as known limitation |
| GRDB WAL mode on iOS | Low | Low | WAL mode works on iOS. Already configured in `DatabaseManager` |

---

## 7. File Inventory

### New Files (to be created by Q)

```
BeeChatMobile/Sources/BeeChatMobileKit/
├── BeeChatMobileConfig.swift
├── BeeChatMobileViewModel.swift
├── MessageMapper.swift
└── SyncBridgeDelegateHandler.swift

BeeChatMobile/Sources/BeeChatUI/
├── BeeChatView.swift
├── SessionListView.swift
├── ConnectionStatusView.swift
└── Theme/BeeChatTheme.swift

BeeChatMobile/Sources/App/
├── BeeChatMobileApp.swift
└── Info.plist

BeeChatMobile/Tests/BeeChatMobileKitTests/
├── MessageMapperTests.swift
├── BeeChatMobileConfigTests.swift
└── ViewModelStateTests.swift
```

### Modified Files (in v5 repo, PR back)

```
BeeChat-v5/Sources/BeeChatGateway/AnyCodable.swift      # Fix Equatable for iOS
```

### Deleted Files (from mobile repo)

```
BeeChatMobile/Sources/BeeChatMobile/BeeChatDemoView.swift  # Replaced by BeeChatView + ViewModel
```

---

## 8. Dependencies

### External (SPM)
| Dependency | Version | Purpose |
|------------|---------|---------|
| Exyte/Chat | 2.7.10+ | Chat UI framework (bubbles, input bar, streaming) |
| GRDB | 7.0.0+ | Local SQLite persistence (via BeeChatPersistence) |
| Kingfisher | 8.x | Image loading/caching (transitive via Exyte) |

### Internal (local SPM)
| Dependency | Path | Purpose |
|------------|------|---------|
| BeeChatPersistence | `../../BeeChat-v5` | GRDB-based local DB |
| BeeChatGateway | `../../BeeChat-v5` | WebSocket client |
| BeeChatSyncBridge | `../../BeeChat-v5` | Event routing, reconciliation |

### Platform
| Requirement | Value |
|-------------|-------|
| iOS minimum | 17.0 |
| Xcode | 26.x (current) |
| Swift | 5.9+ (SPM tools-version) |
| Simulator | iPhone 17 Pro, iOS 26.2 |

---

## 9. Questions for Team Review

### Q to Kieran (Reviewer):
1. Is the `BeeChatMobileKit` → `BeeChatUI` boundary correct? Should the ViewModel be in the same package as the views, or is the separation worth the overhead?
2. The `DatabaseManager.shared` singleton pattern — is this safe on iOS where the app sandbox is different, or should we inject a `DatabaseManager` instance?
3. The `SyncBridgeDelegate` pattern uses `weak var delegate` — in the `@Observable` ViewModel, are there any retain cycle risks we need to guard against beyond the `weak` reference?
4. Should the AnyCodable fix be a separate PR to v5, or bundled with the mobile work?

### Q to Mel (Designer):
1. The session list — should it be a sidebar (iPad) or a push/pop navigation (iPhone)? Or both (adaptive NavigationSplitView)?
2. Connection status indicator — where should it live? Top bar? Overlay? Inline with chat?
3. Offline state — what should the user see when disconnected? Full-screen error? Banner? Cached data with warning?
4. Streaming text — should we show a typing indicator before the first delta, or jump straight into streaming text?

### Q to Gav (Researcher):
1. Are there better iOS WebSocket libraries than `URLSessionWebSocketTask`? (Current v5 uses it directly via `WebSocketTransport`.) Any gotchas on iOS backgrounding?
2. Exyte/Chat v2.7.10 — any newer versions or breaking changes we should know about?
3. Keychain on iOS — is `SecAccessControl` with `kSecAccessControlBiometryAny` the right approach for storing the gateway token, or should we use the `Valet` library from our Phase 0 research?

### Q to Q (Builder — self-review):
1. The `MessageMapper` maps v5 `Message` → Exyte `Message`. Is this the right abstraction, or should we map to an intermediate "display model" first?
2. `@Observable` + `@MainActor` ViewModel — any concerns with SwiftUI re-rendering performance for streaming text?
3. Package.swift currently uses `swift-tools-version:5.9`. Should we bump to 6.0 since v5 is already on 6.0?

---

## 10. Success Metrics

| Metric | Target |
|--------|--------|
| Gate 2A completion | App shows cached data from local DB, no network needed |
| Gate 2B completion | Live gateway messages appear in real-time |
| Gate 2C completion | End-to-end send/receive works |
| Gate 2D completion | Disconnect/reconnect works cleanly |
| Total new Swift files | ~15 (excluding tests) |
| Total modified v5 files | 1 (AnyCodable.swift) |
| Build time (cold) | < 60 seconds |
| Build time (incremental) | < 15 seconds |
| Memory on simulator | < 100MB baseline |

---

*This spec is a DRAFT. All team members should review and comment before implementation begins.*