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
    private var isReconciling: Bool = false

    /// Well-known session key for topic sync payload (Mac → iPhone)
    private static let syncSessionKey = "agent:main:beechat-sync"
    /// UserDefaults key for last sync payload timestamp (staleness guard)
    private static let lastSyncTimestampKey = "beechat_lastSyncTimestamp"

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

            // 2. Read topic sync payload from gateway (with staleness guard)
            isReconciling = true
            do {
                if let payload = try await readSyncPayload() {
                    try reconcileFromPayload(payload)
                } else {
                    print("[ViewModel] No sync payload available — standalone mode (local topics only)")
                }
            } catch {
                print("[ViewModel] Sync payload read failed: \(error) — standalone mode (local topics only)")
            }
            isReconciling = false

            // 3. Refresh topic list
            self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()

            // 4. Auto-select first topic (or re-select if archived)
            if self.selectedTopicId == nil, let first = topics.first {
                self.selectedTopicId = first.id
            } else if let selectedId = self.selectedTopicId,
                      self.topics.first(where: { $0.id == selectedId }) == nil {
                self.selectedTopicId = self.topics.first?.id
            }

            // 5. Session subscription is handled by SyncBridge.start()
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
    public func sessionKey(for topicId: String) -> String? {
        return topics.first(where: { $0.id == topicId })?.sessionKey
    }

    // MARK: - Topic Management

    /// Create a new topic with a user-provided name.
    /// Generates an upfront gateway-format session key and bridge entry.
    /// If the gateway is connected, sends a bootstrap message immediately.
    /// If offline, sets pendingGatewaySync = true for later reconciliation.
    ///
    /// - Parameter name: Display name (1-80 chars, trimmed)
    /// - Returns: The created Topic
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

        // If connected, send bootstrap immediately
        if !isOffline, let bridge = syncBridge, let sessionKey = topic.sessionKey {
            Task {
                do {
                    _ = try await bridge.sendMessage(sessionKey: sessionKey, text: "Start", topic: topic)
                    try persistenceStore.topicRepo.markSynced(topicId: topic.id)
                } catch {
                    print("[ViewModel] Bootstrap send failed for \(topic.id): \(error)")
                    // Topic stays pending — will reconcile on next connect
                }
            }
        }

        // Refresh and auto-select
        self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
        self.selectedTopicId = topic.id
        return topic
    }

    /// Archive a topic. Removes it from the active list.
    /// Uses the existing TopicRepository.archive(topicId:) method which
    /// performs a surgical SQL UPDATE (no stale in-memory data risk).
    /// Returns the archived topic for undo support.
    public func archiveTopic(id: String) throws -> Topic? {
        // Fetch the topic before archiving (for undo)
        guard let topic = try persistenceStore.topicRepo.fetchById(id) else { return nil }
        guard !topic.isArchived else { return nil }

        // Use the existing repo method — direct SQL UPDATE
        try persistenceStore.topicRepo.archive(topicId: id)

        // Refresh list
        self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()

        // If archived topic was selected, select the first remaining
        if selectedTopicId == id {
            selectedTopicId = topics.first?.id
        }

        return topic
    }

    /// Restore an archived topic. Used for undo support.
    /// Re-selects the restored topic so the user sees it immediately.
    public func unarchiveTopic(id: String) throws {
        guard var topic = try persistenceStore.topicRepo.fetchById(id) else { return }
        topic.isArchived = false
        topic.updatedAt = Date()
        try persistenceStore.topicRepo.save(topic)
        self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()

        // Re-select the restored topic
        self.selectedTopicId = topic.id
    }

    /// Delete a topic and all associated data (messages, bridge entry).
    /// This is permanent and cannot be undone.
    /// The caller must show a confirmation dialog before calling this.
    public func deleteTopic(id: String) throws {
        try persistenceStore.topicRepo.deleteCascading(id)

        // Refresh list
        self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()

        // If deleted topic was selected, select the first remaining
        if selectedTopicId == id {
            selectedTopicId = topics.first?.id
        }
    }

    // MARK: - Import Sessions

    /// Fetch candidate sessions that could be imported as topics.
    /// These are gateway sessions that don't already have a local topic bridge.
    /// Filters out known system/cron session patterns.
    public func importCandidates() async throws -> [Session] {
        guard let bridge = syncBridge else {
            throw TopicError.gatewayNotConnected
        }

        let sessions = try await bridge.fetchSessions()
        let existingKeys = try persistenceStore.topicRepo.fetchAllActiveSessionKeys()

        // Filter to sessions that don't already have a bridge entry
        let candidates = sessions.filter { session in
            !existingKeys.contains(session.id)
        }

        // Filter out known system/cron/agent session patterns
        let filtered = candidates.filter { session in
            let id = session.id.lowercased()
            let systemPrefixes = ["cron:", "schedule:", "luna-", "gav-", "kieran-", "q-"]
            return !systemPrefixes.contains(where: { id.hasPrefix($0) })
        }

        return filtered
    }

    /// Create topics from selected gateway sessions.
    /// Uses the existing gateway session key to preserve message history.
    /// Each import is wrapped in a GRDB write transaction for atomicity.
    /// On bridge failure (UNIQUE constraint), the transaction rolls back —
    /// no orphaned topic, no deleted messages.
    ///
    /// - Returns: The number of topics successfully created.
    public func importSelected(_ sessions: [Session]) throws -> Int {
        let existingKeys = try persistenceStore.topicRepo.fetchAllActiveSessionKeys()
        var count = 0

        for session in sessions {
            // Pre-check: skip if session already has a bridge.
            // This reduces violations but doesn't guarantee prevention (TOCTOU race).
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

            // Atomic transaction: topic + bridge saved together, or neither.
            do {
                try persistenceStore.topicRepo.saveAndBridgeInTransaction(topic, sessionKey: session.id)
                count += 1
            } catch {
                // Transaction rolled back — topic was never persisted.
                // No cleanup needed. No messages deleted.
                print("[ViewModel] Import failed for session \(session.id): \(error)")
            }
        }

        // Refresh
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

        // Persist user message locally for immediate display (both online and offline paths)
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
            // Offline-only: message already persisted above
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

// MARK: - Topic Sync

extension BeeChatMobileViewModel {
    /// Read the topic sync payload from the gateway's beechat-sync session.
    /// Returns nil if no payload exists (standalone mode) or if the payload is invalid/stale.
    private func readSyncPayload() async throws -> TopicSyncPayload? {
        guard let bridge = syncBridge else { return nil }
        guard let content = try await bridge.fetchSyncPayload(sessionKey: "agent:main:beechat-sync") else {
            return nil
        }
        guard let payload = TopicSyncPayload.extract(from: content) else {
            return nil
        }
        // Staleness guard: reject payloads older than the last sync
        let defaults = UserDefaults.standard
        let lastSync = defaults.double(forKey: "beechat_lastSyncTimestamp")
        if let payloadDate = payload.timestampDate {
            let payloadTimestamp = payloadDate.timeIntervalSince1970
            if payloadTimestamp <= lastSync {
                print("[ViewModel] Sync payload is stale (payload=\(payloadTimestamp), last=\(lastSync)), skipping")
                return nil
            }
            defaults.set(payloadTimestamp, forKey: "beechat_lastSyncTimestamp")
        }
        return payload
    }

    /// Reconcile local topics from a sync payload.
    /// Creates/updates topics from the Mac's list, archives Mac-origin topics not in the payload,
    /// and never archives local-origin topics.
    private func reconcileFromPayload(_ payload: TopicSyncPayload) throws {
        let topicRepo = persistenceStore.topicRepo

        // Collect all session keys from the payload for matching
        let payloadKeys = Set(payload.topics.map(\.sessionKey))

        // 1. Match by sessionKey first, then by id
        for item in payload.topics {
            // Try sessionKey match first (handles migration from nil-origin topics)
            let existingById = try topicRepo.fetchById(item.id)
            let existingBySessionKey = item.sessionKey.isEmpty ? nil : try topicRepo.resolveTopicId(for: item.sessionKey).flatMap { try topicRepo.fetchById($0) }

            if let existing = existingBySessionKey ?? existingById {
                // Update existing topic
                var updated = existing
                updated.name = item.name
                updated.isArchived = item.isArchived ?? false
                updated.lastActivityAt = item.lastActivityDate
                updated.lastMessagePreview = item.lastMessagePreview
                updated.origin = "mac"
                updated.sessionKey = item.sessionKey
                updated.updatedAt = Date()
                try topicRepo.save(updated)
            } else {
                // Create new topic from payload
                let topic = Topic(
                    id: item.id,
                    name: item.name,
                    lastMessagePreview: item.lastMessagePreview,
                    lastActivityAt: item.lastActivityDate,
                    sessionKey: item.sessionKey,
                    isArchived: item.isArchived ?? false,
                    origin: "mac"
                )
                try topicRepo.save(topic)
                // Create bridge entry
                do {
                    try topicRepo.saveBridge(topicId: topic.id, sessionKey: item.sessionKey)
                } catch {
                    print("[ViewModel] Bridge save failed for \(item.id): \(error)")
                }
            }
        }

        // 2. Archive Mac-origin topics not in the payload
        // Use Int.max limit to ensure ALL topics are checked for archival
        let allTopics = try topicRepo.fetchAllActive(limit: Int.max)
        for topic in allTopics where topic.origin == "mac" && !payloadKeys.contains(topic.sessionKey ?? "") {
            try topicRepo.archive(topicId: topic.id)
        }

        // 3. Refresh topic list
        self.topics = try topicRepo.fetchAllActiveWithCounts()
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

    nonisolated public func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
        Task { @MainActor in
            guard !self.isReconciling else { return }
            self.isReconciling = true
            defer { self.isReconciling = false }

            // Only re-read sync payload when the beechat-sync session changes
            guard sessionKeys.contains(where: { $0.contains("beechat-sync") }) else { return }

            do {
                if let payload = try await self.readSyncPayload() {
                    try self.reconcileFromPayload(payload)
                }
            } catch {
                print("[ViewModel] Failed to reconcile sync payload: \(error)")
            }
        }
    }
}
