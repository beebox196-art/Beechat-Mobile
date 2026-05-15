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
                    // B2 fix: Catch and propagate errors instead of try?
                    do {
                        try await viewModel.start()
                    } catch {
                        viewModel.currentError = error
                    }
                }
        }
    }
}