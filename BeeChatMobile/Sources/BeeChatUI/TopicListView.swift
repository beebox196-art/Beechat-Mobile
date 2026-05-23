import SwiftUI
import BeeChatPersistence
import BeeChatMobileKit
import BeeChatGateway

public struct TopicListView: View {
    @State public var viewModel: BeeChatMobileViewModel

    // Popover state
    @State private var isShowingNewTopicSheet = false

    // Import state
    @State private var isShowingImportSheet = false
    @State private var importCandidates: [Session] = []
    @State private var selectedImportIds: Set<String> = []
    private(set) var isLoadingCandidates = false
    @State private var importCandidateCount: Int = 0

    // Archive undo — Task-based (not DispatchQueue)
    @State private var archivedTopic: Topic? = nil
    @State private var showArchiveToast = false
    @State private var archiveUndoTask: Task<Void, Never>? = nil

    // Delete confirmation
    @State private var topicToDelete: Topic? = nil

    // Loading state for import candidate count
    @State private var isLoadingCandidateCount = false

    // Phase 2: First-run onboarding
    @AppStorage("beechatOnboardingShown") private var onboardingShown = false
    @State private var showOnboarding = false

    // Accessibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(viewModel: BeeChatMobileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Offline banner when disconnected/error (Mel: banner owns disconnected state)
                if viewModel.connectionState == .disconnected || viewModel.connectionState == .error {
                    OfflineBannerView(onRetry: {
                        Task { await viewModel.reconnect() }
                    })
                }

                if viewModel.topics.isEmpty {
                    // Phase 2 Step 14: Empty state variants
                    emptyStateView()
                        .transition(.opacity)
                } else {
                    // Topic list with swipe actions
                    List(viewModel.topics, id: \.id, selection: Binding(
                        get: { viewModel.selectedTopicId },
                        set: { viewModel.selectedTopicId = $0 }
                    )) { topic in
                        NavigationLink(value: topic.id) {
                            TopicRow(topic: topic)
                                .accessibilityLabel("Topic: \(topic.name)")
                                .accessibilityHint("Tap to open conversation")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            // Archive (default full-swipe action) — neutral tint
                            Button {
                                archiveTopic(topic)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.secondary)
                            .accessibilityLabel("Archive")
                            .accessibilityHint("Archives this topic")

                            // Delete (destructive)
                            Button(role: .destructive) {
                                topicToDelete = topic
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityLabel("Delete")
                            .accessibilityHint("Permanently deletes this topic and messages")
                        }
                    }
                }
            }
            .navigationTitle("Topics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingNewTopicSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Topic")
                    .accessibilityHint("Creates a conversation topic")
                }
            }
            // Single presentation: .popover with compact adaptation
            .popover(isPresented: $isShowingNewTopicSheet) {
                NewTopicSheet(onCreate: { name in
                    do {
                        try viewModel.createTopic(name: name)
                    } catch {
                        viewModel.connectionError = error.localizedDescription
                    }
                })
                .presentationDetents(
                    dynamicTypeSize > .xLarge
                        ? [.medium]
                        : [.height(220)]
                )
            }
        } detail: {
            if let topicId = viewModel.selectedTopicId {
                BeeChatView(viewModel: viewModel)
                    .id(topicId)
                    .navigationTitle(viewModel.topics.first(where: { $0.id == topicId })?.name ?? "Chat")
            } else {
                Text("Select a topic")
                    .foregroundStyle(.secondary)
            }
        }
        // Error alert
        .alert("Error", isPresented: Binding(
            get: { viewModel.connectionError != nil },
            set: { if !$0 { viewModel.connectionError = nil } }
        )) {
            Button("OK") { viewModel.connectionError = nil }
            Button("Retry") {
                viewModel.connectionError = nil
                Task { await viewModel.reconnect() }
            }
        } message: {
            Text(viewModel.connectionError ?? "Unknown error")
        }
        // Delete confirmation — rephrased (W8)
        .alert("Delete Topic?", isPresented: Binding(
            get: { topicToDelete != nil },
            set: { if !$0 { topicToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { topicToDelete = nil }
            Button("Delete", role: .destructive) {
                if let topic = topicToDelete {
                    Task {
                        try? await viewModel.deleteTopic(id: topic.id)
                    }
                    topicToDelete = nil
                }
            }
        } message: {
            Text("This deletes this conversation and all its messages from BeeChat. This cannot be undone.")
        }
        // Phase 2 Step 13: Sync footer — hidden during toast + offline banner (Mel UX notes)
        .safeAreaInset(edge: .bottom) {
            syncFooterView()
        }
        // Archive undo toast — overlay (Mel: toast wins, footer hidden)
        .overlay(alignment: .bottom) {
            if showArchiveToast, let topic = archivedTopic {
                archiveUndoToast(topic: topic)
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Load import candidate count when connection state changes (B4)
        .onChange(of: viewModel.connectionState) { _, newState in
            if newState == .connected {
                Task { await refreshImportCandidateCount() }
            } else {
                importCandidateCount = 0
            }
        }
        // Phase 2 Step 14: Show first-run onboarding once
        .onAppear {
            if !onboardingShown && viewModel.topics.isEmpty {
                showOnboarding = true
            }
        }
        // Import sheet
        .sheet(isPresented: $isShowingImportSheet) {
            ImportSessionsSheet(
                candidates: importCandidates,
                onImport: { sessions in
                    do {
                        let count = try viewModel.importSelected(sessions)
                        print("[TopicListView] Imported \(count) sessions")
                    } catch {
                        viewModel.connectionError = error.localizedDescription
                    }
                }
            )
        }
        // Cancel archive undo task on disappear
        .onDisappear {
            archiveUndoTask?.cancel()
        }
        // First-run onboarding sheet
        .alert("Welcome to BeeChat", isPresented: $showOnboarding) {
            Button("Got it") {
                onboardingShown = true
            }
        } message: {
            Text("Topics from your Mac appear here automatically. Create topics on either device — they'll stay in sync.")
        }
    }

    // MARK: - Empty State Variants (Step 14)

    @ViewBuilder
    private func emptyStateView() -> some View {
        if !onboardingShown {
            // First run, no cache
            EmptyTopicsView(
                state: .firstRunNoCache,
                onStartConversation: { isShowingNewTopicSheet = true },
                onImportSessions: importCandidateCount > 0 ? {
                    Task {
                        await loadImportCandidates()
                        isShowingImportSheet = true
                    }
                } : nil,
                onReconnect: { Task { await viewModel.reconnect() } },
                hasImportableSessions: importCandidateCount > 0,
                isLoadingCandidates: isLoadingCandidateCount
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Welcome to BeeChat. Topics from your Mac will appear here automatically.")
        } else if viewModel.connectionState == .disconnected || viewModel.connectionState == .error {
            // Disconnected, no cache
            EmptyTopicsView(
                state: .disconnectedNoCache,
                onStartConversation: { isShowingNewTopicSheet = true },
                onImportSessions: nil,
                onReconnect: { Task { await viewModel.reconnect() } },
                hasImportableSessions: false,
                isLoadingCandidates: false
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Cannot reach gateway. Connect to the gateway to load topics.")
        } else {
            // Syncing, no cache or connected, no topics
            EmptyTopicsView(
                state: .syncingNoCache,
                onStartConversation: { isShowingNewTopicSheet = true },
                onImportSessions: nil,
                onReconnect: { Task { await viewModel.reconnect() } },
                hasImportableSessions: importCandidateCount > 0,
                isLoadingCandidates: isLoadingCandidateCount
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Loading topics. Connecting to your Mac.")
        }
    }

    // MARK: - Sync Footer (Step 13 — Mel UX notes)

    @ViewBuilder
    private func syncFooterView() -> some View {
        // Mel: Footer hidden during toast + offline banner
        if showArchiveToast { return AnyView(EmptyView()) }
        if viewModel.connectionState == .disconnected || viewModel.connectionState == .error {
            return AnyView(EmptyView())
        }
        // Show footer for actionable states: syncing, stale, sync unavailable
        guard viewModel.syncState.isStale ||
              case .syncing = viewModel.syncState ||
              case .syncUnavailable = viewModel.syncState else {
            return AnyView(EmptyView())
        }

        return AnyView(
            VStack(spacing: 4) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: viewModel.syncState.symbol)
                        .font(.caption)
                        .foregroundStyle(Color(viewModel.syncState.colorAccentName))
                        .accessibilityHidden(true)
                    Text(viewModel.syncState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if viewModel.syncState.isStale {
                        Button("Sync Now") {
                            Task { await viewModel.refreshTopicsFromGateway() }
                        }
                        .font(.caption)
                        .accessibilityLabel("Sync topics now")
                        .accessibilityHint("Refreshes topics from the gateway.")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        )
    }

    // MARK: - Archive Undo Toast (Task-based, VoiceOver-safe)

    @ViewBuilder
    private func archiveUndoToast(topic: Topic) -> some View {
        HStack {
            Text("Archived '\(topic.name)'")
                .font(.subheadline)
            Spacer()
            Button("Undo") {
                undoArchive()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Topic archived. Undo available.")
    }

    // MARK: - Actions

    private func archiveTopic(_ topic: Topic) {
        archiveUndoTask?.cancel()

        if let archived = try? viewModel.archiveTopic(id: topic.id) {
            archivedTopic = archived
            withAnimation(reduceMotion ? .none : .easeInOut) {
                showArchiveToast = true
            }

            let timeout: TimeInterval = isVoiceOverEnabled ? 30 : 7

            archiveUndoTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(reduceMotion ? .none : .easeInOut) {
                        showArchiveToast = false
                    }
                    archivedTopic = nil
                }
            }
        }
    }

    private func undoArchive() {
        archiveUndoTask?.cancel()
        guard let topic = archivedTopic else { return }
        do {
            try viewModel.unarchiveTopic(id: topic.id)
            withAnimation(reduceMotion ? .none : .easeInOut) {
                showArchiveToast = false
            }
            archivedTopic = nil
        } catch {
            viewModel.connectionError = error.localizedDescription
        }
    }

    // MARK: - Import

    private func refreshImportCandidateCount() async {
        guard viewModel.connectionState == .connected else { return }
        isLoadingCandidateCount = true
        defer { isLoadingCandidateCount = false }
        do {
            let candidates = try await viewModel.importCandidates()
            importCandidateCount = candidates.count
        } catch {
            importCandidateCount = 0
        }
    }

    private func loadImportCandidates() async {
        isLoadingCandidates = true
        do {
            importCandidates = try await viewModel.importCandidates()
            selectedImportIds = []
        } catch {
            viewModel.connectionError = error.localizedDescription
        }
        isLoadingCandidates = false
    }
}

struct TopicRow: View {
    let topic: Topic

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.name)
                .font(.headline)
            if let preview = topic.lastMessagePreview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Text(topic.lastActivityAt?.formatted(.relative(presentation: .named)) ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if topic.unreadCount > 0 {
                    Text("\(topic.unreadCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .accessibilityLabel("\(topic.unreadCount) unread messages")
                }
            }
        }
        .padding(.vertical, 4)
    }
}
