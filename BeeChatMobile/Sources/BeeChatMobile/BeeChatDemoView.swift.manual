import SwiftUI
import ExyteChat

struct BeeChatDemoView: View {
    @State var messages: [Message] = [
        Message(
            id: "msg-1",
            user: User(id: "adam", name: "Adam", avatarURL: nil, isCurrentUser: true),
            status: .read,
            createdAt: Date(),
            text: "Hello Bee! How are you today?"
        ),
        Message(
            id: "msg-2",
            user: User(id: "bee", name: "Bee", avatarURL: nil, isCurrentUser: false),
            status: .read,
            createdAt: Date().addingTimeInterval(5),
            text: "Hey Adam! I'm doing great — ready to help with anything you need. 🐝"
        ),
    ]

    @State private var isStreaming = false
    @State private var streamingMessageId = ""
    @State private var streamTimer: Timer? = nil

    var body: some View {
        VStack(spacing: 0) {
            ChatView(messages: messages) { draft in
                let newMessage = Message(
                    id: UUID().uuidString,
                    user: User(id: "adam", name: "Adam", avatarURL: nil, isCurrentUser: true),
                    status: .sending,
                    createdAt: Date(),
                    text: draft.text
                )
                messages.append(newMessage)

                // Simulate a streaming agent reply after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    startStreamingReply()
                }
            }
        }
        .onDisappear {
            streamTimer?.invalidate()
        }
    }

    func startStreamingReply() {
        let replyId = UUID().uuidString
        streamingMessageId = replyId
        let fullReply = "That's a great question! Let me think about the best way to help you with that..."
        var currentIndex = 0

        let replyMessage = Message(
            id: replyId,
            user: User(id: "bee", name: "Bee", avatarURL: nil, isCurrentUser: false),
            status: .sending,
            createdAt: Date(),
            text: ""
        )
        messages.append(replyMessage)
        isStreaming = true

        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { timer in
            guard currentIndex < fullReply.count else {
                timer.invalidate()
                isStreaming = false
                if let idx = messages.firstIndex(where: { $0.id == replyId }) {
                    var msg = messages[idx]
                    msg.status = .sent
                    messages[idx] = msg
                }
                return
            }

            let index = fullReply.index(fullReply.startIndex, offsetBy: currentIndex)
            let nextChar = fullReply[index]

            if let idx = messages.firstIndex(where: { $0.id == replyId }) {
                var msg = messages[idx]
                msg.text += String(nextChar)
                msg.status = .sending
                messages[idx] = msg
            }

            currentIndex += 1
        }
    }
}

@main
struct BeeChatMobileApp: App {
    var body: some Scene {
        WindowGroup {
            BeeChatDemoView()
        }
    }
}
