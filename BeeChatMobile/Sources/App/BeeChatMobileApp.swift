import SwiftUI
import BeeChatUI
import BeeChatMobileKit

@main
struct BeeChatMobileApp: App {
    @State private var viewModel = BeeChatMobileViewModel(config: BeeChatMobileConfig())

    var body: some Scene {
        WindowGroup {
            SessionListView(viewModel: viewModel)
                .task {
                    try? await viewModel.start()
                    // Auto-select first session for Gate 2A verification
                    if viewModel.selectedSessionId == nil, let first = viewModel.sessions.first {
                        viewModel.selectedSessionId = first.id
                    }
                }
        }
    }
}