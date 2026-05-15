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
        VStack(spacing: 0) {
            // B4: Wire connection status into view hierarchy
            ConnectionStatusView(state: viewModel.connectionState)

            ChatView(messages: messages) { draft in
                guard let sessionId = viewModel.selectedSessionId else { return }
                Task {
                    do {
                        try await viewModel.send(text: draft.text, to: sessionId)
                        // W5: Surface errors instead of silent try?
                        loadMessages()
                    } catch {
                        viewModel.currentError = error
                    }
                }
            }
            .overlay {
                // W4: Display streaming indicator when active
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
        .onChange(of: viewModel.selectedSessionId) { _, _ in
            loadMessages()
        }
    }

    // B1 fix: Use Task (non-detached, inherits MainActor) instead of Task.detached
    // S10 from spec: DB reads are synchronous and blocking, but Task on MainActor
    // is acceptable for Gate 2A data sizes. Post-Gate-2: use ValueObservation.
    private func loadMessages() {
        guard let sessionId = viewModel.selectedSessionId else { messages = []; return }
        Task {
            let msgs = (try? viewModel.messages(for: sessionId)) ?? []
            let mapped = MessageMapper.exyteMessages(from: msgs)
            if viewModel.selectedSessionId == sessionId {
                self.messages = mapped
            }
        }
    }
}