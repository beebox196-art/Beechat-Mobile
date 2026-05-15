# Gate 2 Specification: Real Data Pipeline

**Date:** 2026-05-15
**Status:** DRAFT — Under team review (Kieran review received, fixes applied)
**Author:** Bee (Coordinator)
**Reviewers:** Q (Builder), Kieran (Reviewer), Mel (Designer), Gav (Researcher)

### Review Log
| Reviewer | Status | Key Findings |
|----------|--------|-------------|
| Kieran | ✅ Complete | 2 blockers (AnyCodable, error handling), 4 warnings (threading, temporal coupling, dependency graph, in-flight sends), 2 nits |
| Mel | 🔄 In progress | — |
| Gav | 🔄 In progress | — |
| Q | ⏳ Pending | — |

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

**Package.swift dependency graph:** *(Updated after Kieran review — removed duplicate dependency)*
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
```

> **Kieran's finding:** The original graph listed `BeeChatMobileKit` twice — once as a direct app dependency and once transitively through `BeeChatUI`. Removed the direct dependency; the app accesses BeeChatMobileKit through BeeChatUI.

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

**BeeChatMobileViewModel:** *(Updated after Kieran review — threading fix)*
```swift
@MainActor @Observable
final class BeeChatMobileViewModel {
    // Connection
    var connectionState: ConnectionState = .disconnected
    var connectionError: String?              // NEW: error message for UI
    
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
    
    // ⚠️ INIT ORDER INVARIANT: DatabaseManager.shared MUST be opened
    // (via openDatabase(at:)) BEFORE SyncBridge is created or any
    // SyncBridge/Persistence method is called. This is a temporal coupling
    // inherited from v5 — the shared singleton must be initialized first.
    
    // Offline-first: can show cached data without gateway
    func loadCachedData() throws { ... }
    
    // Online: connect and sync
    func connect() async throws {
        do {
            try await syncBridge?.start()
            connectionState = .connected
            connectionError = nil
        } catch {
            connectionState = .error          // FIX: set error state
            connectionError = error.localizedDescription  // FIX: propagate message
        }
    }
    func disconnect() async { ... }
    
    // Actions
    func sendMessage(_ text: String) async throws { ... }
}
```

> **Kieran's finding:** The original spec only set `.connected` on success and never set `.error` on failure. The v5 macOS app correctly sets `.error` + `offlineStatus`. The mobile ViewModel must do the same.

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

**AnyCodable fix:** *(Updated after Kieran review — original spec had bugs)*
The current `Equatable` implementation uses `NSDictionary.isEqual(to:)` which doesn't work correctly on iOS. The original spec proposed type-explicit `switch` comparison, but Kieran identified two critical bugs:

1. **Numeric types**: `Int64`, `UInt`, `UInt64` values created programmatically won't match `as Int`. NSNumber bridging handles this correctly.
2. **Array types**: After JSON decode, arrays are stored as `[Any]`, not `[AnyCodable]`. The `case let (a as [AnyCodable], b as [AnyCodable])` pattern would **never match** — array equality would silently always return `false`.

**Corrected fix** using `NSNumber` for numerics and a recursive helper for arrays:
```swift
extension AnyCodable: Equatable {
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (a as Bool, b as Bool): return a == b
        case let (a as NSNumber, b as NSNumber):
            // Covers Int, Int64, UInt, Float, Double — but NOT Bool (matched above)
            // NSNumber comparison uses value semantics, matching NSDictionary behavior
            let objCType = String(cString: NSNumber(value: a).objCType)
            if objCType == "c" || objCType == "B" { return false }  // Skip Bool masquerading as NSNumber
            return a == b
        case let (a as String, b as String): return a == b
        case let (a as [Any], b as [Any]): return compareAnyArrays(a, b)
        case let (a as [String: Any], b as [String: Any]):
            guard a.count == b.count else { return false }
            for (key, val) in a {
                guard let bVal = b[key] else { return false }
                if !AnyCodable(val).isEqual(to: AnyCodable(bVal)) { return false }
            }
            return true
        case (is NSNull, is NSNull): return true
        default: return false
        }
    }
    
    private static func compareAnyArrays(_ lhs: [Any], _ rhs: [Any]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if !AnyCodable(a).isEqual(to: AnyCodable(b)) { return false }
        }
        return true
    }
}
```

> **Kieran's verdict:** This is a real correctness bug. The original fix would pass for scalar values and dictionaries but **silently fail for arrays**. The `NSNumber` approach is what `NSDictionary.isEqual` was doing implicitly, but without the dictionary wrapper. This must be correct before Gate 2A.

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

> **Kieran's addition:** The spec must also handle what happens when `connect()` fails (auth failure, unreachable gateway). The original spec only set `.connected` on success — it never set `.error` or propagated an error message. This has been fixed in the ViewModel example above. The UI must show a clear error state, not just silently stay at `.disconnected`.

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

**SyncBridgeDelegate conformance:** *(Updated after Kieran review — CRITICAL threading fix)*
```swift
extension BeeChatMobileViewModel: SyncBridgeDelegate {
    // ⚠️ CRITICAL: SyncBridge is an actor. Delegate callbacks fire on the
    // actor's executor, NOT on @MainActor. All delegate methods MUST be
    // marked `nonisolated` and dispatch to @MainActor via Task.
    // Direct property writes from these callbacks WILL CRASH under strict
    // concurrency checking. This is the #1 most likely Gate 2 build failure.
    
    nonisolated func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState) {
        Task { @MainActor in
            self.connectionState = state
        }
    }
    
    nonisolated func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String) {
        Task { @MainActor in
            self.isStreaming = true
        }
    }
    
    nonisolated func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
        Task { @MainActor in
            self.isStreaming = false
            Task { await self.refreshMessages() }
        }
    }
    
    nonisolated func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error) {
        Task { @MainActor in
            self.connectionError = error.localizedDescription
        }
    }
    
    nonisolated func syncBridge(_ bridge: SyncBridge, didStartAutoReset sessionKey: String) { /* UI notification */ }
    nonisolated func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String) { /* UI notification */ }
    nonisolated func syncBridge(_ bridge: SyncBridge, didStartManualReset sessionKey: String) { /* UI notification */ }
    nonisolated func syncBridge(_ bridge: SyncBridge, didStopManualReset sessionKey: String) { /* UI notification */ }
}
```

> **Kieran's verdict:** The original spec's delegate example would crash at runtime under strict concurrency. This is the single most likely cause of a Gate 2 build failure. The `nonisolated` + `Task { @MainActor in }` pattern is already proven in v5's `SyncBridgeObserver`.

**Streaming text binding:**
SyncBridge already manages a `streamingBuffer` and `streamingSessionKeys`. The ViewModel polls `syncBridge.streamingContent(for:)` during streaming and maps it to the Exyte `Message` text.

**Review checklist for Gate 2B:**
- [ ] Gateway connects on launch (auto-connect)
- [ ] Connection state indicator updates in real-time
- [ ] `.error` state set on auth failure, unreachable gateway, etc.
- [ ] Error message propagated to UI (not just `.disconnected`)
- [ ] Incoming messages appear in chat without manual refresh
- [ ] Streaming text updates character-by-character
- [ ] Session list refreshes when `sessions.changed` fires
- [ ] Reconnection works after brief disconnect (5-10 seconds)
- [ ] Cached data shows immediately on launch before connection
- [ ] Gateway token NOT committed to repo
- [ ] No force-unwraps on optional network responses
- [ ] All SyncBridgeDelegate callbacks are `nonisolated` with `Task { @MainActor in }` dispatch
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
- [ ] Bee's reply streams in correctly
- [ ] Message status transitions: sending → sent → read
- [ ] Failed sends show error state
- [ ] In-flight sends during disconnect: delivery ledger tracks `.pending` → `.failed` if gateway unreachable
- [ ] Optimistic messages marked `.error` when send fails, with retry UI
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
- [ ] In-flight sends during disconnect: `.pending` entries reconciled after reconnect
- [ ] UI shows connection state accurately at all times
- [ ] `.error` state shown with descriptive message (not just `.disconnected`)
- [ ] Stall timer fires correctly (30 seconds of no delta → stream cleared)
- [ ] No crashes or data corruption during rapid connect/disconnect cycles
- [ ] DatabaseManager.shared init order invariant maintained after reconnect

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
| `DatabaseManager.shared` singleton temporal coupling | Medium | Low | Document init-order invariant: DB must be opened before SyncBridge creation. No code change needed, but failure to observe this invariant will cause `DatabaseManagerError.notOpen` |
| **SyncBridgeDelegate callbacks fire on actor executor, not MainActor** | **High** | **High (will crash)** | **All delegate methods MUST be `nonisolated` with `Task { @MainActor in }` dispatch. This is the #1 build failure risk.** |
| Keychain access differs on iOS vs macOS | Medium | Low | `KeychainTokenStore` uses standard Security framework APIs; verify on simulator |
| Exyte/Chat `Message` struct is value type — frequent mutations for streaming | Medium | High | Use `@State` array + element replacement (same pattern as demo); SwiftUI's diffing handles it. If performance issues, switch to `@Observable` object wrapper |
| WebSocket connection drops on iOS background | High | High | Gate 4 (Push Notifications) addresses this. For Gate 2, app is foreground-only. Document as known limitation |
| GRDB WAL mode on iOS | Low | Low | WAL mode works on iOS. Already configured in `DatabaseManager` |
| **AnyCodable `Equatable` fails for arrays and some numeric types on iOS** | **High** | **High (silent data corruption)** | **Use `NSNumber` comparison for numerics + recursive `[Any]` comparison for arrays. Apply to v5 repo, not fork.** |
| Gateway auth/connection failure silently leaves app in `.disconnected` state | Medium | Medium | Set `.error` state + `connectionError` message. Show in UI as offline banner with error detail |
| In-flight send lost during disconnect | Medium | Medium | Delivery ledger tracks `.pending` → `.failed` if gateway unreachable. Mark optimistic message as error, offer retry |

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

### Kieran's Answers (received):
1. ✅ Boundary is correct — `BeeChatMobileKit` owns logic, `BeeChatUI` owns views. Separation worth the overhead.
2. ✅ `DatabaseManager.shared` works but is temporal coupling — must document init-order invariant.
3. ✅ No retain cycle (`weak` delegate), but delegate callbacks spawn Tasks without `[weak self]`. Acceptable for app-lifecycle ViewModel.
4. ✅ AnyCodable fix should be PR to v5 repo — confirmed.
5. **NEW:** `SyncBridgeDelegate` callbacks MUST be `nonisolated` with `Task { @MainActor in }`. This is the #1 crash risk.
6. **NEW:** Package graph has duplicate `BeeChatMobileKit` dependency — removed direct app dependency, kept transitive.

### Q to Mel (Designer) — 🔄 Awaiting response:
1. Session list: sidebar vs push/pop vs adaptive?
2. Connection status indicator placement?
3. Offline state UX?
4. Streaming text UX?

### Q to Gav (Researcher) — 🔄 Awaiting response:
1. WebSocket libraries comparison for iOS?
2. Exyte/Chat latest version and breaking changes?
3. Keychain: raw Security framework vs Valet library?
4. Swift Concurrency actor + @MainActor bridging gotchas?
5. GRDB on iOS known issues?
6. SPM modular structure assessment?

### Q to Q (Builder) — ⏳ Pending:
1. MessageMapper: direct mapping vs intermediate display model?
2. @Observable + @MainActor streaming performance?
3. Swift tools version: 5.9 vs 6.0?

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