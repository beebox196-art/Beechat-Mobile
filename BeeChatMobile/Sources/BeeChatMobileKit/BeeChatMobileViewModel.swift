import Foundation
import BeeChatPersistence
import BeeChatGateway
import BeeChatSyncBridge

/// ViewModel owns SyncBridge lifecycle, persists sessions/messages, and maps to Exyte types.
/// Gate 2A: offline-first. No network connection attempted. Gateway connection deferred to Gate 2B.
@Observable
@MainActor
public final class BeeChatMobileViewModel {
    public var sessions: [Session] = []
    public var selectedSessionId: String? = nil
    public var connectionState: ConnectionState = .disconnected
    public var isStreaming: Bool = false
    public var currentError: Error? = nil

    public let config: BeeChatMobileConfig
    public let persistenceStore: BeeChatPersistenceStore
    private var syncBridge: SyncBridge?

    public init(config: BeeChatMobileConfig) {
        self.config = config
        self.persistenceStore = BeeChatPersistenceStore()
    }

    public func start() async throws {
        try persistenceStore.openDatabase(at: config.dbPath)

        // Seed test data if empty (Gate 2A verification)
        let existing = try persistenceStore.fetchSessions(limit: 1, offset: 0)
        if existing.isEmpty {
            try seedTestData()
        }

        // Load initial sessions from local DB
        self.sessions = try persistenceStore.fetchSessions(limit: 100, offset: 0)
    }

    public func messages(for sessionId: String) throws -> [BeeChatPersistence.Message] {
        try persistenceStore.fetchMessages(sessionId: sessionId, limit: 200, before: nil)
    }

    public func send(text: String, to sessionId: String) async throws {
        // Gate 2A: write outgoing message to local DB immediately
        let idempotencyKey = UUID().uuidString
        let msg = BeeChatPersistence.Message(
            id: idempotencyKey,
            sessionId: sessionId,
            role: "user",
            content: text,
            senderName: "Adam",
            senderId: "adam",
            timestamp: Date()
        )
        try persistenceStore.saveMessage(msg)
        // Refresh messages for the current session
        // Gateway send deferred to Gate 2C
    }

    /// Gate 2B: Setup SyncBridge with a live gateway connection
    public func setupSyncBridge(gatewayConfig: GatewayClient.Configuration) async throws {
        let bridgeConfig = SyncBridgeConfiguration(
            gatewayClient: GatewayClient(config: gatewayConfig),
            persistenceStore: persistenceStore
        )
        let bridge = SyncBridge(config: bridgeConfig)
        await bridge.setDelegate(self)
        self.syncBridge = bridge
    }

    private func seedTestData() throws {
        let sessionId = "seed-session-1"
        let session = Session(
            id: sessionId,
            agentId: "bee",
            title: "Welcome to BeeChat",
            lastMessageAt: Date(),
            updatedAt: Date(),
            createdAt: Date(),
            messageCount: 3
        )
        try persistenceStore.saveSession(session)

        let msgs: [BeeChatPersistence.Message] = [
            BeeChatPersistence.Message(id: "m1", sessionId: sessionId, role: "user", content: "Hello Bee! How are you today?", senderName: "Adam", senderId: "adam", timestamp: Date().addingTimeInterval(-10)),
            BeeChatPersistence.Message(id: "m2", sessionId: sessionId, role: "assistant", content: "Hey Adam! I'm doing great — ready to help with anything you need. 🐝", senderName: "Bee", senderId: "bee", timestamp: Date().addingTimeInterval(-5)),
            BeeChatPersistence.Message(id: "m3", sessionId: sessionId, role: "user", content: "Can you show me my sessions list?", senderName: "Adam", senderId: "adam", timestamp: Date()),
        ]
        for m in msgs { try persistenceStore.saveMessage(m) }
    }
}

// MARK: - SyncBridgeDelegate
// S1: merged into ViewModel extension (follows v5's SyncBridgeObserver pattern)
extension BeeChatMobileViewModel: SyncBridgeDelegate {
    nonisolated public func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState) {
        Task { @MainActor in
            self.connectionState = state
        }
    }
    nonisolated public func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error) {
        Task { @MainActor in
            self.currentError = error
        }
    }
    nonisolated public func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String) {
        Task { @MainActor in
            self.isStreaming = true
        }
    }
    nonisolated public func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
        Task { @MainActor in
            self.isStreaming = false
        }
    }
    nonisolated public func syncBridge(_ bridge: SyncBridge, didStartAutoReset sessionKey: String) {}
    nonisolated public func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String) {}
    nonisolated public func syncBridge(_ bridge: SyncBridge, didStartManualReset sessionKey: String) {}
    nonisolated public func syncBridge(_ bridge: SyncBridge, didStopManualReset sessionKey: String) {}
}