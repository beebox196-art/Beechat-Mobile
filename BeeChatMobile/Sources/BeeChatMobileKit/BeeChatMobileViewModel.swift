import Foundation
import BeeChatPersistence
import BeeChatGateway
import BeeChatSyncBridge

// MARK: - SyncState (Step 13)

public enum SyncState: Equatable, Sendable {
    case synced(lastSync: Date)
    case syncing
    case disconnected
    case syncUnavailable(String)
}

extension SyncState {
    public var symbol: String {
        switch self {
        case .synced: return "checkmark.icloud.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .disconnected: return "exclamationmark.icloud.fill"
        case .syncUnavailable: return "info.circle.fill"
        }
    }
    public var colorAccentName: String {
        switch self {
        case .synced(let lastSync):
            return Date().timeIntervalSince(lastSync) < 300 ? "secondary" : "orange"
        case .syncing: return "blue"
        case .disconnected: return "red"
        case .syncUnavailable: return "secondary"
        }
    }
    public var label: String {
        switch self {
        case .synced(let lastSync):
            let interval = Date().timeIntervalSince(lastSync)
            if interval < 60 { return "Synced just now" }
            let minutes = Int(interval / 60)
            return "Synced \(minutes)m ago"
        case .syncing: return "Syncing..."
        case .disconnected: return "Gateway disconnected"
        case .syncUnavailable(let reason): return reason
        }
    }
    public var isStale: Bool {
        guard case .synced(let lastSync) = self else { return false }
        return Date().timeIntervalSince(lastSync) > 300
    }
}

// MARK: - ViewModel

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

    /// Phase 2: Sync state for topic sync indicator
    public var syncState: SyncState = .disconnected

    public let config: BeeChatMobileConfig
    public let persistenceStore: BeeChatPersistenceStore

    // MARK: - Private

    private var syncBridge: SyncBridge?
    private var streamingPollTask: Task<Void, Never>?
    private var connectionWatchTask: Task<Void, Never>?
    private var messageObservationTask: Task<Void, Never>?

    // Phase 2: Debounce for sessions.changed
    private var lastSessionsChangedSync: Date = .distantPast
    private var hasAdminScope: Bool = false

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
        self.topics = try persistenceStore.fetchAllActiveWithCounts()

        // Auto-select first topic
        if selectedTopicId == nil, let first = topics.first {
            selectedTopicId = first.id
        }
    }

    /// Connect to the live gateway. Call after `start()`.
    /// Phase 2: consume gateway metadata via beechatMetadata.
    public func connect() async {
        guard syncBridge == nil else { return }

        NSLog("[BeeChat] connect() called - about to load gateway config")

        guard let gatewayConfig = GatewayConfigLoader.load() else {
            NSLog("[BeeChat] GatewayConfigLoader returned nil - no config found")
            connectionState = .error
            connectionError = "No gateway config found. Check ~/.openclaw/openclaw.json"
            syncState = .disconnected
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

            // Phase 2 Step 7: Fetch raw SessionInfo (preserves pluginExtensions)
            let sessionInfos = try await bridge.fetchSessionInfos()

            // Filter to sessions with BeeChat metadata
            let knownTopics = sessionInfos.compactMap { info -> (GatewaySessionInfo, BeeChatTopicMetadata)? in
                guard let metadata = info.beechatMetadata else { return nil }
                return (info.asGatewaySessionInfo, metadata)
            }

            // Upsert local topics from gateway truth
            try persistenceStore.upsertTopicsFromGateway(knownTopics)

            // Refresh topic list
            self.topics = try persistenceStore.fetchAllActiveWithCounts()

            // Auto-select first topic
            if self.selectedTopicId == nil, let first = topics.first {
                self.selectedTopicId = first.id
            }

            // Check admin scope for sync capability
            self.hasAdminScope = await bridge.hasAdminScope()
            if !self.hasAdminScope {
                self.syncState = .syncUnavailable("Topic sync requires admin scope")
            } else {
                self.syncState = .synced(lastSync: Date())
            }

            // 1. Reconcile pending offline topics
            let pendingTopics = try persistenceStore.topicRepo.fetchPendingSyncTopics()
            for topic in pendingTopics {
                guard let sessionKey = topic.sessionKey else { continue }
                do {
                    _ = try await bridge.sendMessage(sessionKey: sessionKey, text: "Start")
                    try persistenceStore.topicRepo.markSynced(topicId: topic.id)
                } catch {
                    print("[ViewModel] Failed to reconcile topic \(topic.id): \(error)")
                }
            }

            startMessageObservation()
        } catch {
            connectionState = .error
            connectionError = error.localizedDescription
            syncState = .disconnected
        }
    }

    /// Phase 2 Step 12a: Light refresh — fetch session infos, upsert topics, update sync state.
    /// Does NOT reconnect the gateway connection. Use for "Sync Now" button.
    public func refreshTopicsFromGateway() async {
        guard connectionState == .connected, let bridge = syncBridge else { return }
        syncState = .syncing
        do {
            let sessionInfos = try await bridge.fetchSessionInfos()
            let knownTopics = sessionInfos.compactMap { info -> (GatewaySessionInfo, BeeChatTopicMetadata)? in
                guard let metadata = info.beechatMetadata else { return nil }
                return (info.asGatewaySessionInfo, metadata)
            }
            try persistenceStore.upsertTopicsFromGateway(knownTopics)
            self.topics = try persistenceStore.fetchAllActiveWithCounts()
            if hasAdminScope {
                self.syncState = .synced(lastSync: Date())
            }
        } catch {
            // Refresh failed — fall back to full reconnect
            print("[ViewModel] refreshTopicsFromGateway failed: \(error), attempting reconnect")
            await reconnect()
        }
    }

    /// Phase 2 Step 12: Disconnect → update syncState
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
        syncState = .disconnected
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
    public func sessionKey(for topicId: String) -> String? {
        return topics.first(where: { $0.id == topicId })?.sessionKey
    }

    // MARK: - Topic Management

    /// Create a new topic with a user-provided name.
    /// Phase 2: publish to gateway if connected + admin scope.
    public func createTopic(name: String) throws -> Topic {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TopicError.nameRequired
        }
        guard trimmed.count <= 80 else {
            throw TopicError.nameTooLong(count: trimmed.count)
        }

        let isOffline = syncBridge == nil || connectionState != .connected
        let topic = try persistenceStore.topicRepo.create(
            name: trimmed,
            pendingGatewaySync: isOffline
        )

        // Phase 2 Step 9: Publish to gateway if connected + admin scope
        if !isOffline, let bridge = syncBridge, hasAdminScope, let sessionKey = topic.sessionKey {
            let topicForPublish = try persistenceStore.fetchTopicById(topic.id)!
            Task { await bridge.publishTopicState(topic: topicForPublish, sessionKey: sessionKey) }
        }

        // Refresh and auto-select
        self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
        self.selectedTopicId = topic.id
        return topic
    }

    /// Phase 2 Step 10: Delete topic → gateway cleanup
    public func deleteTopic(id: String) async throws {
        guard let topic = try persistenceStore.fetchTopicById(id) else { return }

        // Gateway cleanup if connected with admin scope
        if let bridge = syncBridge, connectionState == .connected, hasAdminScope, let sessionKey = topic.sessionKey {
            let cleared = await bridge.clearTopicStateWithResult(sessionKey: sessionKey)
            if !cleared {
                connectionError = "Topic deleted locally but gateway metadata may persist."
            }
        }

        try persistenceStore.deleteTopicCascading(id)
        self.topics = try persistenceStore.fetchAllActiveWithCounts()
        if selectedTopicId == id {
            selectedTopicId = topics.first?.id
        }
    }

    /// Phase 2 Step 11: Archive topic → gateway sync
    public func archiveTopic(id: String) throws -> Topic? {
        guard let topic = try persistenceStore.fetchTopicById(id) else { return nil }
        guard !topic.isArchived else { return nil }

        try persistenceStore.archiveTopic(topicId: id)
        self.topics = try persistenceStore.fetchAllActiveWithCounts()

        // Publish updated state to gateway
        if let bridge = syncBridge, connectionState == .connected, hasAdminScope, let sessionKey = topic.sessionKey {
            Task { await bridge.publishTopicState(topic: topic, sessionKey: sessionKey) }
        }

        if selectedTopicId == id { selectedTopicId = topics.first?.id }
        return topic
    }

    /// Phase 2 Step 11: Restore archived topic → gateway sync
    public func unarchiveTopic(id: String) throws {
        guard var topic = try persistenceStore.fetchTopicById(id) else { return }
        topic.isArchived = false
        topic.updatedAt = Date()
        try persistenceStore.saveTopic(topic)
        self.topics = try persistenceStore.fetchAllActiveWithCounts()
        self.selectedTopicId = topic.id

        // Publish updated state to gateway
        if let bridge = syncBridge, connectionState == .connected, hasAdminScope, let sessionKey = topic.sessionKey {
            Task { await bridge.publishTopicState(topic: topic, sessionKey: sessionKey) }
        }
    }

    // MARK: - Import Sessions

    public func importCandidates() async throws -> [Session] {
        guard let bridge = syncBridge else {
            throw TopicError.gatewayNotConnected
        }

        let sessions = try await bridge.fetchSessions()
        let existingKeys = try persistenceStore.topicRepo.fetchAllActiveSessionKeys()

        let candidates = sessions.filter { session in
            !existingKeys.contains(session.id)
        }

        let filtered = candidates.filter { session in
            let id = session.id.lowercased()
            let systemPrefixes = ["cron:", "schedule:", "luna-", "gav-", "kieran-", "q-"]
            return !systemPrefixes.contains(where: { id.hasPrefix($0) })
        }

        return filtered
    }

    public func importSelected(_ sessions: [Session]) throws -> Int {
        let existingKeys = try persistenceStore.topicRepo.fetchAllActiveSessionKeys()
        var count = 0

        for session in sessions {
            if existingKeys.contains(session.id) {
                continue
            }

            let topic = Topic(
                id: UUID().uuidString,
                name: session.title ?? session.customName ?? "Conversation",
                lastMessagePreview: session.lastMessagePreview,
                lastActivityAt: session.lastMessageAt ?? session.updatedAt,
                unreadCount: session.unreadCount,
                sessionKey: session.id
            )

            do {
                try persistenceStore.topicRepo.saveAndBridgeInTransaction(topic, sessionKey: session.id)
                count += 1
            } catch {
                print("[ViewModel] Import failed for session \(session.id): \(error)")
            }
        }

        self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
        return count
    }

    public func send(text: String, to topicId: String) async throws {
        guard let topic = topics.first(where: { $0.id == topicId }),
              let sessionKey = topic.sessionKey else {
            throw NSError(domain: "BeeChat", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Topic has no session key"
            ])
        }

        let userMessage = BeeChatPersistence.Message(
            id: UUID().uuidString,
            sessionId: sessionKey,
            role: "user",
            content: text,
            senderName: "Adam",
            senderId: "adam",
            timestamp: Date()
        )
        try persistenceStore.saveMessage(userMessage)

        guard let bridge = syncBridge else {
            return
        }

        _ = try await bridge.sendMessage(sessionKey: sessionKey, text: text)
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
            while !Task.isCancelled {
                self.refreshTopics()
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }
    }

    // MARK: - Seed Data

    private func seedTestData() throws {
        let topicRepo = persistenceStore.topicRepo

        let topic1 = try topicRepo.create(name: "Welcome to BeeChat")
        _ = try topicRepo.create(name: "Solar Dashboard Help")
        _ = try topicRepo.create(name: "Project Planning")

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

public enum TopicError: LocalizedError, Sendable {
    case nameRequired
    case nameTooLong(count: Int)
    case gatewayNotConnected

    public var errorDescription: String? {
        switch self {
        case .nameRequired:
            return "Topic name is required"
        case .nameTooLong(let count):
            return "Topic name must be 80 characters or less (currently \(count))"
        case .gatewayNotConnected:
            return "Gateway is not connected"
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

    // Phase 2 Step 8: Delegate callback with 10-second debounce
    nonisolated public func syncBridgeSessionsChanged(_ bridge: SyncBridge) {
        Task { @MainActor in
            let now = Date()
            guard now.timeIntervalSince(self.lastSessionsChangedSync) >= 10 else { return }
            self.lastSessionsChangedSync = now

            do {
                guard let syncBridge = self.syncBridge else { return }
                let sessionInfos = try await syncBridge.fetchSessionInfos()
                let knownTopics = sessionInfos.compactMap { info -> (GatewaySessionInfo, BeeChatTopicMetadata)? in
                    guard let metadata = info.beechatMetadata else { return nil }
                    return (info.asGatewaySessionInfo, metadata)
                }
                try persistenceStore.upsertTopicsFromGateway(knownTopics)
                self.topics = try persistenceStore.fetchAllActiveWithCounts()
                if self.hasAdminScope {
                    self.syncState = .synced(lastSync: Date())
                }
            } catch {
                print("[ViewModel] sessions.changed sync failed: \(error)")
            }
        }
    }
}
