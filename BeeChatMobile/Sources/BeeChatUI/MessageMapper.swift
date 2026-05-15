import Foundation
import BeeChatPersistence
import ExyteChat

/// Maps v5 Session/Message models to Exyte ChatView types.
public struct MessageMapper {
    public static func exyteUser(for message: BeeChatPersistence.Message, currentUserId: String = "adam") -> ExyteChat.User {
        let isCurrent = message.senderId == currentUserId || message.role == "user"
        let name = message.senderName ?? (isCurrent ? "Adam" : "Bee")
        // F9: empty name may still render an avatar circle with empty initial
        let safeName = name.isEmpty ? " " : name
        return ExyteChat.User(
            id: message.senderId ?? message.id,
            name: safeName,
            avatarURL: nil,
            isCurrentUser: isCurrent
        )
    }

    public static func exyteMessage(from message: BeeChatPersistence.Message, currentUserId: String = "adam") -> ExyteChat.Message {
        let user = exyteUser(for: message, currentUserId: currentUserId)
        let status: ExyteChat.Message.Status = message.isRead ? .read : .sent
        return ExyteChat.Message(
            id: message.id,
            user: user,
            status: status,
            createdAt: message.timestamp,
            text: message.content ?? ""
        )
    }

    public static func exyteMessages(from messages: [BeeChatPersistence.Message], currentUserId: String = "adam") -> [ExyteChat.Message] {
        messages.map { exyteMessage(from: $0, currentUserId: currentUserId) }
    }
}
