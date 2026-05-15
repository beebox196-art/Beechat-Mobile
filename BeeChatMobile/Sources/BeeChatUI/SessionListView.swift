import SwiftUI
import BeeChatPersistence
import BeeChatMobileKit
import BeeChatGateway

public struct SessionListView: View {
    @State public var viewModel: BeeChatMobileViewModel

    public init(viewModel: BeeChatMobileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            List(viewModel.sessions, id: \.id, selection: Binding(
                get: { viewModel.selectedSessionId },
                set: { viewModel.selectedSessionId = $0 }
            )) { session in
                NavigationLink(value: session.id) {
                    SessionRow(session: session)
                }
            }
            .navigationTitle("Sessions")
            // B4: Show offline banner when disconnected
            .overlay(alignment: .top) {
                if viewModel.connectionState == .disconnected {
                    OfflineBannerView()
                }
            }
        } detail: {
            if let sessionId = viewModel.selectedSessionId {
                BeeChatView(viewModel: viewModel)
                    .id(sessionId)
                    .navigationTitle(viewModel.sessions.first(where: { $0.id == sessionId })?.title ?? "Chat")
            } else {
                Text("Select a session")
                    .foregroundStyle(.secondary)
            }
        }
        // B3: Display errors to the user
        .alert("Error", isPresented: Binding(
            get: { viewModel.currentError != nil },
            set: { if !$0 { viewModel.currentError = nil } }
        )) {
            Button("OK") { viewModel.currentError = nil }
        } message: {
            Text(viewModel.currentError?.localizedDescription ?? "Unknown error")
        }
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title ?? session.customName ?? "Untitled")
                .font(.headline)
            if let preview = session.lastMessagePreview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Text(session.lastMessageAt?.formatted(.relative(presentation: .named)) ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if session.unreadCount > 0 {
                    Text("\(session.unreadCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }
}