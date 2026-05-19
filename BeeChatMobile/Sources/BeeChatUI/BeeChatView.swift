import SwiftUI
import ExyteChat
import BeeChatMobileKit
import BeeChatPersistence

public struct BeeChatView: View {
    @State public var viewModel: BeeChatMobileViewModel
    @State private var messages: [ExyteChat.Message] = []
    @State private var streamingMessageId: String = "streaming-msg"

    // Draft preservation across online/offline transitions (B3 fix)
    @State private var preservedDraft: String = ""
    // Hotfix 1: Trigger message reload after send
    @State private var messageVersion: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: BeeChatMobileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            ConnectionStatusView(
                state: viewModel.connectionState,
                onRetry: {
                    Task { await viewModel.reconnect() }
                }
            )

            // B1 fix: Switch between two separate View structs.
            // Each has its own concrete ChatView generic type — valid Swift conditional.
            if viewModel.connectionState == .connected {
                OnlineChatView(
                    viewModel: viewModel,
                    messages: messages,
                    preservedDraft: $preservedDraft,
                    onMessageSent: { messageVersion += 1 }
                )
            } else {
                OfflineChatView(
                    viewModel: viewModel,
                    messages: messages,
                    preservedDraft: preservedDraft,
                    onMessageSent: { messageVersion += 1 }
                )
            }
        }
        .onAppear { loadMessages() }
        .onChange(of: viewModel.selectedTopicId) { _, _ in loadMessages() }
        .onChange(of: viewModel.isStreaming) { _, newValue in
            if !newValue { loadMessages() }
        }
        .onChange(of: messageVersion) { _, _ in loadMessages() }
    }

    private func loadMessages() {
        guard let topicId = viewModel.selectedTopicId,
              let key = viewModel.sessionKey(for: topicId) else { messages = []; return }
        Task {
            let msgs = (try? viewModel.messages(for: key)) ?? []
            let mapped = MessageMapper.exyteMessages(from: msgs)
            if viewModel.selectedTopicId == topicId {
                self.messages = mapped
            }
        }
    }
}
