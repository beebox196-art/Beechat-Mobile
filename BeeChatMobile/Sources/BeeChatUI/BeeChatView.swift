import SwiftUI
import ExyteChat
import BeeChatMobileKit
import BeeChatPersistence

public struct BeeChatView: View {
    @State public var viewModel: BeeChatMobileViewModel
    @State private var messages: [ExyteChat.Message] = []
    @State private var draft: String = ""
    @State private var streamingMessageId: String = "streaming-msg"

    public init(viewModel: BeeChatMobileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Wire connection status into view hierarchy with retry action
            ConnectionStatusView(
                state: viewModel.connectionState,
                onRetry: {
                    Task {
                        await viewModel.reconnect()
                    }
                }
            )

            ChatView(messages: mergedMessages) { draft in
                guard let topicId = viewModel.selectedTopicId else { return }
                Task {
                    do {
                        try await viewModel.send(text: draft.text, to: topicId)
                        loadMessages()
                    } catch {
                        viewModel.connectionError = error.localizedDescription
                    }
                }
            }
            .overlay {
                // Display streaming indicator when active
                if viewModel.isStreaming {
                    VStack {
                        StreamingIndicatorView()
                        Spacer()
                    }
                    .padding(.top, 8)
                }
            }
        }
        .onAppear {
            loadMessages()
        }
        .onChange(of: viewModel.selectedTopicId) { _, _ in
            loadMessages()
        }
        .onChange(of: viewModel.streamingContent) { _, _ in
            updateStreamingMessage()
        }
        .onChange(of: viewModel.isStreaming) { _, newValue in
            if !newValue {
                // Streaming ended, refresh messages
                loadMessages()
            }
        }
    }

    /// Merge persisted messages with live streaming content
    private var mergedMessages: [ExyteChat.Message] {
        guard let topicId = viewModel.selectedTopicId,
              viewModel.isStreaming,
              let key = viewModel.sessionKey(for: topicId),
              let streamingText = viewModel.streamingContent[key],
              !streamingText.isEmpty else {
            return messages
        }

        var merged = messages
        // Remove any existing streaming message
        merged.removeAll { $0.id == streamingMessageId }

        let streamingMsg = ExyteChat.Message(
            id: streamingMessageId,
            user: ExyteChat.User(
                id: "bee",
                name: "Bee",
                avatarURL: nil,
                isCurrentUser: false
            ),
            status: .sent,
            createdAt: Date(),
            text: streamingText
        )
        merged.append(streamingMsg)
        return merged
    }

    private func updateStreamingMessage() {
        // onChange handles the refresh automatically via mergedMessages
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
