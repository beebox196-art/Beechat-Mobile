import SwiftUI
import BeeChatPersistence
import BeeChatMobileKit
import BeeChatGateway

public struct TopicListView: View {
    @State public var viewModel: BeeChatMobileViewModel

    public init(viewModel: BeeChatMobileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Show offline banner when disconnected
                if viewModel.connectionState == .disconnected || viewModel.connectionState == .error {
                    OfflineBannerView(onRetry: {
                        Task {
                            await viewModel.reconnect()
                        }
                    })
                }
                List(viewModel.topics, id: \.id, selection: Binding(
                    get: { viewModel.selectedTopicId },
                    set: { viewModel.selectedTopicId = $0 }
                )) { topic in
                    NavigationLink(value: topic.id) {
                        TopicRow(topic: topic)
                    }
                }
            }
            .navigationTitle("Topics")
        } detail: {
            if let topicId = viewModel.selectedTopicId {
                BeeChatView(viewModel: viewModel)
                    .id(topicId)
                    .navigationTitle(viewModel.topics.first(where: { $0.id == topicId })?.title ?? "Chat")
            } else {
                Text("Select a topic")
                    .foregroundStyle(.secondary)
            }
        }
        // Display errors to the user
        .alert("Error", isPresented: Binding(
            get: { viewModel.connectionError != nil },
            set: { if !$0 { viewModel.connectionError = nil } }
        )) {
            Button("OK") { viewModel.connectionError = nil }
            Button("Retry") {
                viewModel.connectionError = nil
                Task {
                    await viewModel.reconnect()
                }
            }
        } message: {
            Text(viewModel.connectionError ?? "Unknown error")
        }
    }
}

struct TopicRow: View {
    let topic: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.title ?? topic.customName ?? "Untitled")
                .font(.headline)
            if let preview = topic.lastMessagePreview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Text(topic.lastMessageAt?.formatted(.relative(presentation: .named)) ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if topic.unreadCount > 0 {
                    Text("\(topic.unreadCount)")
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
