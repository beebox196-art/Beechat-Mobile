import Foundation
import BeeChatPersistence
import BeeChatGateway
import BeeChatSyncBridge

/// ViewModel owns SyncBridge lifecycle, persists sessions/messages, and maps to Exyte types.
@Observable
@MainActor
public final class BeeChatMobileViewModel {
    // MARK: - Public State

    /// UI-facing property: topics (formerly sessions)
    public var topics: [Topic] = []
    public var selectedTopicId: String? = nil
    public var connectionState: ConnectionState = .disconnected
    public var isStreaming: Bool = false
    public var connectionError: String? = nil

    /// Per-topic streaming content for live UI updates
    public var streamingContent: [String: String] = [:]

    public let config: BeeChatMobileConfig
    public let persistenceStore: BeeChatPersistenceStore

    // MARK: - Private

    private var syncBridge: SyncBridge?
    private var streamingPollTask: Task<Void, Never>?
    private var connectionWatchTask: Task<Void, Never>?
    private var messageObservationTask: Task<Void, Never>?

    public init(config: BeeChatMobileConfig) {
        self.config = config
        self.persistenceStore = BeeChatPersistenceStore()
    }

    // MARK: - Lifecycle

    /// Offline-first startup: load cached data, then optionally connect.
    public func start() async throws {
        NSLog("[BeeChat] start() called - dbPath=%@", config.dbPath)
        try persistenceStore.openDatabase(at: config.dbPath)

        // Seed test data if empty (Gate 2A verification)
        let existing = try persistenceStore.topicRepo.fetchAllActive(limit: 1)
        if existing.isEmpty {
            try seedTestData()
        }

        // Load initial topics from local DB
        self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()

        // Auto-select first topic
        if selectedTopicId == nil, let first = topics.first {
            selectedTopicId = first.id
        }
    }

    /// Connect to the live gateway. Call after `start()`.
    public func connect() async {
        guard syncBridge == nil else { return }

        NSLog("[BeeChat] connect() called - about to load gateway config")

        guard let gatewayConfig = GatewayConfigLoader.load() else {
            NSLog("[BeeChat] GatewayConfigLoader returned nil - no config found")
            connectionState = .error
            connectionError = "No gateway config found. Check ~/.openclaw/openclaw.json"
            return
        }

        NSLog("[BeeChat] Gateway config loaded: url=%@ clientMode=%@", gatewayConfig.url, gatewayConfig.clientMode)

        let clientConfig = GatewayClient.Configuration(
            url: gatewayConfig.url,
            token: gatewayConfig.token,
            clientMode: gatewayConfig.clientMode,
            clientInfo: .init(
                id: "openclaw-ios",
                version: "1.0",
                platform: "ios",
                mode: gatewayConfig.clientMode,
                deviceFamily: "mobile"
            )
        )

        let bridgeConfig = SyncBridgeConfiguration(
            gatewayClient: GatewayClient(config: clientConfig),
            persistenceStore: persistenceStore,
            historyFetchLimit: config.historyFetchLimit,
            reconnectDebounceSeconds: config.reconnectDebounceSeconds
        )

        let bridge = SyncBridge(config: bridgeConfig)
        await bridge.setDelegate(self)
        self.syncBridge = bridge

        // Start connection state monitoring
        connectionWatchTask = Task {
            let stream = await bridge.connectionStateStream()
            for await state in stream {
                await MainActor.run {
                    self.connectionState = state
                }
            }
        }

        do {
            try await bridge.start()

            // 1. Reconcile pending offline topics
            let pendingTopics = try persistenceStore.topicRepo.fetchPendingSyncTopics()
            for topic in pendingTopics {
                guard let sessionKey = topic.sessionKey else { continue }
                do {
                    _ = try await bridge.sendMessage(sessionKey: sessionKey, text: "Start", topic: topic)
                    try persistenceStore.topicRepo.markSynced(topicId: topic.id)
                } catch {
                    print("[ViewModel] Failed to reconcile topic \(topic.id): \(error)")
                }
            }

            // 2. Fetch sessions from gateway
            let sessions = try await bridge.fetchSessions()

            // 3. Filter to only BeeChat sessions (using injected repo)
            let beeChatSessions = sessions.filter { session in
                (try? BeeChatSessionFilter.isBeeChatSession(session.id, topicRepo: persistenceStore.topicRepo)) == true
            }

            // 4. Create topics for new gateway sessions without a topic
            for gatewaySession in beeChatSessions {
                if try persistenceStore.topicRepo.resolveTopicId(for: gatewaySession.id) == nil {
                    let topic = Topic(
                        id: UUID().uuidString,
                        name: gatewaySession.title ?? gatewaySession.customName ?? "Conversation",
                        lastMessagePreview: gatewaySession.lastMessagePreview,
                        lastActivityAt: gatewaySession.lastMessageAt ?? gatewaySession.updatedAt,
                        unreadCount: gatewaySession.unreadCount,
                        sessionKey: gatewaySession.id
                    )
                    try persistenceStore.topicRepo.save(topic)
                    do {
                        try persistenceStore.topicRepo.saveBridge(topicId: topic.id, sessionKey: gatewaySession.id)
                    } catch {
                        print("[ViewModel] Bridge already exists for session \(gatewaySession.id): \(error)")
                    }
                }
            }

            // 5. Sync metadata from BeeChat sessions to local topics
            try persistenceStore.topicRepo.syncMetadataFromSessions(beeChatSessions)

            // 6. Refresh topic list
            self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()

            // 7. Auto-select first topic
            if self.selectedTopicId == nil, let first = topics.first {
                self.selectedTopicId = first.id
            }

            // 8. Session subscription is handled by SyncBridge.start()
            startMessageObservation()
        } catch {
            connectionState = .error
            connectionError = error.localizedDescription
        }
    }

    public func disconnect() async {
        streamingPollTask?.cancel()
        connectionWatchTask?.cancel()
        messageObservationTask?.cancel()
        streamingPollTask = nil
        connectionWatchTask = nil
        messageObservationTask = nil
        streamingContent.removeAll()

        if let bridge = syncBridge {
            await bridge.stop()
        }
        syncBridge = nil
        connectionState = .disconnected
    }

    public func reconnect() async {
        await disconnect()
        await connect()
    }

    // MARK: - Data Access

    public func messages(for sessionId: String) throws -> [BeeChatPersistence.Message] {
        try persistenceStore.fetchMessages(sessionId: sessionId, limit: 200, before: nil)
    }

    /// Resolve a Topic ID to the session key used for message lookups.
    private func sessionKey(for topicId: String) -> String? {
        return topics.first(where: { $0.id == topicId })?.sessionKey
    }

    public func send(text: String, to topicId: String) async throws {
        guard let topic = topics.first(where: { $0.id == topicId }),
              let sessionKey = topic.sessionKey else {
            throw NSError(domain: "BeeChat", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Topic has no session key"
            ])
        }

        guard let bridge = syncBridge else {
            // Offline-only: write to local DB
            let idempotencyKey = UUID().uuidString
            let msg = BeeChatPersistence.Message(
                id: idempotencyKey,
                sessionId: sessionKey,
                role: "user",
                content: text,
                senderName: "Adam",
                senderId: "adam",
                timestamp: Date()
            )
            try persistenceStore.saveMessage(msg)
            return
        }

        _ = try await bridge.sendMessage(sessionKey: sessionKey, text: text, topic: topic)
    }

    // MARK: - Streaming

    private func startStreamingPoll(for sessionKey: String) {
        streamingPollTask?.cancel()
        streamingPollTask = Task {
            var lastContent = ""
            var updateCounter = 0
            while !Task.isCancelled {
                guard let bridge = self.syncBridge else { break }
                let content = await bridge.streamingContent(for: sessionKey)
                if content != lastContent {
                    lastContent = content
                    updateCounter += 1
                    // Coalesce: update every 2-3 tokens to reduce UI churn
                    if updateCounter >= 2 || content.count - (self.streamingContent[sessionKey]?.count ?? 0) > 10 {
                        updateCounter = 0
                        self.streamingContent[sessionKey] = content
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }
    }

    private func stopStreamingPoll() {
        streamingPollTask?.cancel()
        streamingPollTask = nil
    }

    // MARK: - Message Observation

    private func startMessageObservation() {
        messageObservationTask?.cancel()
        messageObservationTask = Task {
            // Simple polling-based observation for MVP
            // Post-Gate-2: use GRDB ValueObservation
            while !Task.isCancelled {
                self.refreshTopics()
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }
    }

    // MARK: - Seed Data

    private func seedTestData() throws {
        let topicRepo = persistenceStore.topicRepo

        // Create 3 seed topics with gateway-format keys
        let topic1 = try topicRepo.create(name: "Welcome to BeeChat")
        let topic2 = try topicRepo.create(name: "Solar Dashboard Help")
        let topic3 = try topicRepo.create(name: "Project Planning")

        // Save test messages linked to topic1's session key
        guard let sessionKey = topic1.sessionKey else { return }
        let msgs: [BeeChatPersistence.Message] = [
            BeeChatPersistence.Message(
                id: "m1", sessionId: sessionKey, role: "user",
                content: "Hello Bee! How are you today?",
                senderName: "Adam", senderId: "adam",
                timestamp: Date().addingTimeInterval(-10)
            ),
            BeeChatPersistence.Message(
                id: "m2", sessionId: sessionKey, role: "assistant",
                content: "Hey Adam! I'm doing great - ready to help with anything you need. 🐝",
                senderName: "Bee", senderId: "bee",
                timestamp: Date().addingTimeInterval(-5)
            ),
            BeeChatPersistence.Message(
                id: "m3", sessionId: sessionKey, role: "user",
                content: "Can you show me my sessions list?",
                senderName: "Adam", senderId: "adam",
                timestamp: Date()
            ),
        ]
        for m in msgs { try persistenceStore.saveMessage(m) }
    }

    // MARK: - Refresh

    private func refreshTopics() {
        do {
            self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
        } catch {
            print("[ViewModel] Failed to refresh topics: \(error)")
        }
    }
}

// MARK: - SyncBridgeDelegate

extension BeeChatMobileViewModel: SyncBridgeDelegate {
    nonisolated public func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState) {
        Task { @MainActor in
            self.connectionState = state
            if state == .connected {
                self.connectionError = nil
            }
        }
    }

    nonisolated public func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error) {
        Task { @MainActor in
            self.connectionError = error.localizedDescription
            if self.connectionState != .connected {
                self.connectionState = .error
            }
        }
    }

    nonisolated public func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String) {
        Task { @MainActor in
            self.isStreaming = true
            self.startStreamingPoll(for: sessionKey)
        }
    }

    nonisolated public func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
        Task { @MainActor in
            self.isStreaming = false
            self.streamingContent.removeValue(forKey: sessionKey)
            self.stopStreamingPoll()
            self.refreshTopics()
        }
    }

    nonisolated public func syncBridge(_ bridge: SyncBridge, didStartAutoReset sessionKey: String) {}
    nonisolated public func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String) {}
    nonisolated public func syncBridge(_ bridge: SyncBridge, didStartManualReset sessionKey: String) {}
    nonisolated public func syncBridge(_ bridge: SyncBridge, didStopManualReset sessionKey: String) {}
}
