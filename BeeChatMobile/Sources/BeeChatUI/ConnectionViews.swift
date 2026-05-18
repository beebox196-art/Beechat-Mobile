import SwiftUI
import BeeChatGateway
import BeeChatMobileKit

public struct ConnectionStatusView: View {
    let state: ConnectionState
    var onRetry: (() -> Void)? = nil

    public var body: some View {
        Button(action: {
            if state == .disconnected || state == .error {
                onRetry?()
            }
        }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state == .disconnected || state == .error {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(onRetry == nil)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting, .handshaking: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var label: String {
        switch state {
        case .connected: return "Online"
        case .connecting: return "Connecting…"
        case .handshaking: return "Handshaking…"
        case .disconnected: return "Offline"
        case .error: return "Error"
        }
    }
}

public struct OfflineBannerView: View {
    var onRetry: (() -> Void)? = nil

    public var body: some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text("Offline. Showing cached messages.")
                .font(.subheadline)
            Spacer()
            if let onRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.15))
    }
}
