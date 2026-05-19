import SwiftUI
import ExyteChat
import BeeChatMobileKit
import BeeChatPersistence

/// Offline chat view with disabled input and reconnect button.
/// Generic type: ChatView<EmptyView, OfflineInputBar, DefaultMessageMenuAction>
struct OfflineChatView: View {
    let viewModel: BeeChatMobileViewModel
    let messages: [ExyteChat.Message]
    /// Read-only preserved draft from OnlineChatView — shown in placeholder text
    /// so the user has visual context of what they were typing before going offline.
    let preservedDraft: String
    /// Hotfix 1: Callback to trigger message reload after send.
    /// Currently unused (offline input is disabled) but wired for consistency.
    var onMessageSent: () -> Void
    private static let streamingMessageId = "streaming-msg"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ChatView(
            messages: mergedMessages,
            didSendMessage: { _ in
                // Callback won't fire — input is disabled
            },
            inputViewBuilder: { text, _, _, _, _, _ in
                HStack {
                    TextField(preservedDraft.isEmpty
                              ? "Reconnect to send messages"
                              : "Draft: \"\(preservedDraft)\" — reconnect to send",
                              text: text)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                        .accessibilityLabel("Message input, currently offline")
                    Button {
                        Task { await viewModel.reconnect() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reconnect")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        )
        .showNetworkConnectionProblem(true)
        .overlay {
            if viewModel.isStreaming {
                VStack {
                    StreamingIndicatorView()
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
    }

    private var mergedMessages: [ExyteChat.Message] {
        MergedMessagesHelper.merge(
            messages: messages,
            viewModel: viewModel,
            streamingMessageId: Self.streamingMessageId
        )
    }
}
