import SwiftUI
import ExyteChat
import BeeChatPersistence
import BeeChatMobileKit

/// Shared helper to merge persisted messages with live streaming content.
/// Extracted to avoid duplication between OnlineChatView and OfflineChatView.
@MainActor
struct MergedMessagesHelper {
    static func merge(
        messages: [ExyteChat.Message],
        viewModel: BeeChatMobileViewModel,
        streamingMessageId: String = "streaming-msg"
    ) -> [ExyteChat.Message] {
        guard let topicId = viewModel.selectedTopicId,
              viewModel.isStreaming,
              let key = viewModel.sessionKey(for: topicId),
              let streamingText = viewModel.streamingContent[key],
              !streamingText.isEmpty else {
            return messages
        }

        var merged = messages
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
}
