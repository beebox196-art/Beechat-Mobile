import SwiftUI
import BeeChatGateway

// S2: merged ConnectionStatusView + OfflineBannerView
public struct ConnectionStatusView: View {
    let state: ConnectionState

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
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
    public var body: some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text("You are offline")
                .font(.subheadline)
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.15))
    }
}
