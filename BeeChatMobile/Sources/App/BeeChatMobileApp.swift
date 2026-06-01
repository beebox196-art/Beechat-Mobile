import SwiftUI
import BeeChatUI
import BeeChatMobileKit

@main
struct BeeChatMobileApp: App {
    @State private var viewModel = BeeChatMobileViewModel(config: BeeChatMobileConfig())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TopicListView(viewModel: viewModel)
                .task {
                    NSLog("[BeeChat] App .task firing")
                    do {
                        // Offline-first: load cached data
                        try await viewModel.start()
                        // Then connect to live gateway
                        await viewModel.connect()
                    } catch {
                        viewModel.connectionError = error.localizedDescription
                        viewModel.connectionState = .error
                    }
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    viewModel.onScenePhaseChange(newPhase)
                }
        }
    }
}
