import SwiftUI
import ExyteChat
import BeeChatMobileKit
import BeeChatPersistence

/// Online chat view using the default Exyte input (no inputViewBuilder).
/// Generic type: ChatView<EmptyView, EmptyView, DefaultMessageMenuAction>
struct OnlineChatView: View {
    let viewModel: BeeChatMobileViewModel
    let messages: [ExyteChat.Message]
    /// Binding to preserved draft — we can clear it on successful send
    /// because the online view has access to Exyte's draft state.
    @Binding var preservedDraft: String
    private static let streamingMessageId = "streaming-msg"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ChatView(messages: mergedMessages) { draft in
            guard let topicId = viewModel.selectedTopicId else { return }
            Task {
                do {
                    try await viewModel.send(text: draft.text, to: topicId)
                    preservedDraft = ""  // Clear on successful send
                } catch {
                    viewModel.connectionError = error.localizedDescription
                }
            }
        }
        .showNetworkConnectionProblem(false)
        .overlay {
            // Empty messages prompt
            if messages.isEmpty && !viewModel.isStreaming {
                VStack {
                    Text("Ask Bee anything to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
