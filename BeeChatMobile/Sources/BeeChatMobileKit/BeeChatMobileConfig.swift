import Foundation
import BeeChatPersistence

/// iOS-specific configuration for BeeChat Mobile.
/// No clientMode — GatewayClient.Configuration derives platform from #if os(iOS).
public struct BeeChatMobileConfig: Sendable {
    public let dbPath: String
    public let gatewayURL: String
    public let historyFetchLimit: Int
    public let reconnectDebounceSeconds: Double

    public init(
        dbPath: String? = nil,
        gatewayURL: String = "wss://openclaws-mac-mini-1.tail3f2df8.ts.net/ws",
        historyFetchLimit: Int = 200,
        reconnectDebounceSeconds: Double = 1.0
    ) {
        // W7 fix: guard let instead of force-unwrap
        if let dbPath {
            self.dbPath = dbPath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let dir = appSupport?.appendingPathComponent("BeeChat", isDirectory: true)
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                self.dbPath = dir.appendingPathComponent("beechat.db").path
            } else {
                // Fallback: documents directory (should never happen on iOS)
                self.dbPath = "beechat.db"
            }
        }
        self.gatewayURL = gatewayURL
        self.historyFetchLimit = historyFetchLimit
        self.reconnectDebounceSeconds = reconnectDebounceSeconds
    }
}