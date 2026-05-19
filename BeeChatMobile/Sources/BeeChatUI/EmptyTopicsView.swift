import SwiftUI

struct EmptyTopicsView: View {
    let hasImportableSessions: Bool
    let isLoading: Bool
    let onStartConversation: () -> Void
    let onImportSessions: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("No topics yet")
                    .font(.title2.bold())

                Text(hasImportableSessions
                     ? "Import your recent sessions to get started."
                     : "Start a topic when you're ready to chat with Bee.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 12) {
                Button(action: onStartConversation) {
                    Label("Start a Topic", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if hasImportableSessions, let onImport = onImportSessions {
                    Button(action: onImport) {
                        Label("Import Recent Sessions", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 32)

            if isLoading {
                ProgressView()
                    .padding(.top, 4)
            }

            Spacer()
        }
    }
}
