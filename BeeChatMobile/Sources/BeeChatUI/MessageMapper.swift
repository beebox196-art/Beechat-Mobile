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
        var result: [ExyteChat.Message] = []
        var lastUserContent: [String: Date] = [:]  // content -> timestamp, for dedup

        for message in messages {
            // Dedup: skip if a message with same role+content was already added within 2 seconds
            if message.role == "user", let content = message.content, let existingTime = lastUserContent[content] {
                if abs(message.timestamp.timeIntervalSince(existingTime)) < 2.0 {
                    continue  // Skip duplicate
                }
            }

            let exyteMsg = exyteMessage(from: message, currentUserId: currentUserId)
            result.append(exyteMsg)

            if message.role == "user", let content = message.content {
                lastUserContent[content] = message.timestamp
            }
        }

        return result
    }
}
