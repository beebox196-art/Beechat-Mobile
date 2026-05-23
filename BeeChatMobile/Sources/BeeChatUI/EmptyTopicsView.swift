import SwiftUI

// MARK: - Empty State Variants (Step 14)

enum EmptyTopicState {
    case firstRunNoCache
    case syncingNoCache
    case disconnectedNoCache
    case allArchived
    case connectedNoTopics
}

struct EmptyTopicsView: View {
    let state: EmptyTopicState
    let onStartConversation: () -> Void
    let onImportSessions: (() -> Void)?
    let onReconnect: (() -> Void)?
    let hasImportableSessions: Bool
    let isLoadingCandidates: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: state.icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .modifier(state.iconAnimation())

            VStack(spacing: 8) {
                Text(state.headline)
                    .font(.title2.bold())

                Text(state.subtext(hasImportableSessions))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 12) {
                if state.showNewTopicButton {
                    Button(action: onStartConversation) {
                        Label("+ Start a Topic", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if state.showReconnectButton, let onReconnect = onReconnect {
                    Button(action: onReconnect) {
                        Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

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

            if isLoadingCandidates {
                ProgressView()
                    .padding(.top, 4)
            }

            Spacer()
        }
    }
}

extension EmptyTopicState {
    var icon: String {
        switch self {
        case .firstRunNoCache: return "sparkles"
        case .syncingNoCache: return "arrow.triangle.2.circlepath"
        case .disconnectedNoCache: return "wifi.slash"
        case .allArchived: return "archivebox"
        case .connectedNoTopics: return "bubble.left.and.bubble.right"
        }
    }

    var headline: String {
        switch self {
        case .firstRunNoCache: return "Welcome to BeeChat"
        case .syncingNoCache: return "Loading topics..."
        case .disconnectedNoCache: return "No connection"
        case .allArchived: return "All topics archived"
        case .connectedNoTopics: return "No topics yet"
        }
    }

    func subtext(_ hasImportable: Bool) -> String {
        switch self {
        case .firstRunNoCache:
            return "Topics from your Mac will appear here automatically."
        case .syncingNoCache:
            return "Connecting to your Mac."
        case .disconnectedNoCache:
            return "Connect to the gateway to load topics."
        case .allArchived:
            return "No active conversations."
        case .connectedNoTopics:
            return hasImportable
                ? "Import your recent sessions to get started."
                : "Create a topic to start chatting."
        }
    }

    var showNewTopicButton: Bool {
        switch self {
        case .firstRunNoCache, .allArchived, .connectedNoTopics: return true
        case .syncingNoCache, .disconnectedNoCache: return false
        }
    }

    var showReconnectButton: Bool {
        switch self {
        case .disconnectedNoCache: return true
        default: return false
        }
    }

    func iconAnimation() -> some ViewModifier {
        switch self {
        case .syncingNoCache: return IconAnimationModifier(isAnimating: true)
        default: return IconAnimationModifier(isAnimating: false)
        }
    }
}

struct IconAnimationModifier: ViewModifier {
    let isAnimating: Bool

    func body(content: Content) -> some View {
        if isAnimating {
            content
                .rotationEffect(.degrees(360), anchor: .center)
                .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isAnimating)
        } else {
            content
        }
    }
}

// MARK: - Legacy initializer for backward compatibility

extension EmptyTopicsView {
    init(
        hasImportableSessions: Bool,
        isLoading: Bool,
        showArchiveToast: Bool,
        onStartConversation: @escaping () -> Void,
        onImportSessions: (() -> Void)?
    ) {
        self.state = hasImportableSessions ? .connectedNoTopics : .firstRunNoCache
        self.onStartConversation = onStartConversation
        self.onImportSessions = onImportSessions
        self.onReconnect = nil
        self.hasImportableSessions = hasImportableSessions
        self.isLoadingCandidates = isLoading
    }
}
