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
    @State private var isLoadingCandidates = false
    @State private var importCandidateCount: Int = 0

    // Archive undo — Task-based (not DispatchQueue)
    @State private var archivedTopic: Topic? = nil
    @State private var showArchiveUndo = false
    @State private var archiveUndoTask: Task<Void, Never>? = nil

    // Delete confirmation
    @State private var topicToDelete: Topic? = nil

    // Loading state for import candidate count
    @State private var isLoadingCandidateCount = false

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
                // Offline banner when disconnected
                if viewModel.connectionState == .disconnected || viewModel.connectionState == .error {
                    OfflineBannerView(onRetry: {
                        Task { await viewModel.reconnect() }
                    })
                }

                if viewModel.topics.isEmpty {
                    // Empty state (M9)
                    EmptyTopicsView(
                        hasImportableSessions: importCandidateCount > 0,
                        isLoading: isLoadingCandidateCount,
                        onStartConversation: { isShowingNewTopicSheet = true },
                        onImportSessions: importCandidateCount > 0 ? {
                            Task { await loadImportCandidates() }
                            isShowingImportSheet = true
                        } : nil
                    )
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
                    try? viewModel.deleteTopic(id: topic.id)
                    topicToDelete = nil
                }
            }
        } message: {
            Text("This deletes this conversation and all its messages from BeeChat. This cannot be undone.")
        }
        // Archive undo toast — overlay (B3 fix: Task-based, VoiceOver-safe)
        .overlay(alignment: .bottom) {
            if showArchiveUndo, let topic = archivedTopic {
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
        // Cancel any existing undo timer (handles re-archive)
        archiveUndoTask?.cancel()

        do {
            _ = try viewModel.archiveTopic(id: topic.id)
            archivedTopic = topic
            withAnimation(reduceMotion ? .none : .easeInOut) {
                showArchiveUndo = true
            }

            // VoiceOver-safe timeout: if VoiceOver running, don't auto-dismiss
            let timeout: TimeInterval = isVoiceOverEnabled ? 30 : 7

            archiveUndoTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(reduceMotion ? .none : .easeInOut) {
                        showArchiveUndo = false
                    }
                    archivedTopic = nil
                }
            }
        } catch {
            viewModel.connectionError = error.localizedDescription
        }
    }

    private func undoArchive() {
        archiveUndoTask?.cancel()
        guard let topic = archivedTopic else { return }
        do {
            try viewModel.unarchiveTopic(id: topic.id)
            withAnimation(reduceMotion ? .none : .easeInOut) {
                showArchiveUndo = false
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
