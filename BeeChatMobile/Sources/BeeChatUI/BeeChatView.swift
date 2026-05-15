import SwiftUI
import ExyteChat
import BeeChatMobileKit
import BeeChatPersistence

public struct BeeChatView: View {
    @State public var viewModel: BeeChatMobileViewModel
    @State private var messages: [ExyteChat.Message] = []
    @State private var draft: String = ""

    public init(viewModel: BeeChatMobileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ChatView(messages: messages) { draft in
            guard let sessionId = viewModel.selectedSessionId else { return }
            Task {
                try? await viewModel.send(text: draft.text, to: sessionId)
                // Refresh messages
                loadMessages()
            }
        }
        .onAppear {
            loadMessages()
        }
        .onChange(of: viewModel.selectedSessionId) { _, _ in
            loadMessages()
        }
    }

    private func loadMessages() {
        guard let sessionId = viewModel.selectedSessionId else { messages = []; return }
        Task.detached {
            guard let msgs = try? viewModel.messages(for: sessionId) else { return }
            let mapped = MessageMapper.exyteMessages(from: msgs)
            await MainActor.run {
                if viewModel.selectedSessionId == sessionId {
                    self.messages = mapped
                }
            }
        }
    }
}