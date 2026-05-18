import Foundation

/// Loads gateway configuration for BeeChat Mobile.
///
/// Resolution order:
/// 1. Environment variables (BEECHAT_GATEWAY_URL + BEECHAT_GATEWAY_TOKEN) — for Xcode scheme injection
/// 2. Config file in app group container (for production)
/// 3. Fallback: returns nil (offline mode)
///
/// Note: iOS apps cannot access ~/.openclaw/openclaw.json due to sandboxing.
/// For simulator development, inject via Xcode scheme environment variables.
public struct GatewayConfigLoader: Sendable {
    public struct Config: Sendable {
        public let url: String
        public let token: String
        public let clientMode: String

        public init(url: String, token: String, clientMode: String = "webchat") {
            self.url = url
            self.token = token
            self.clientMode = clientMode
        }
    }

    public static func load() -> Config? {
        // 1. Environment variables (Xcode scheme injection for development)
        if let url = ProcessInfo.processInfo.environment["BEECHAT_GATEWAY_URL"],
           let token = ProcessInfo.processInfo.environment["BEECHAT_GATEWAY_TOKEN"] {
            print("[GatewayConfigLoader] Using environment variable config")
            return Config(url: url, token: token)
        }

        // 2. Config file in app container (for bundled/production config)
        //    Looks for gateway-config.json in the app's Application Support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport {
            let configPath = dir.appendingPathComponent("BeeChat/gateway-config.json")
            if FileManager.default.fileExists(atPath: configPath.path) {
                do {
                    let data = try Data(contentsOf: configPath)
                    let config = try JSONDecoder().decode(GatewayFileConfig.self, from: data)
                    print("[GatewayConfigLoader] Using file config from \(configPath.path)")
                    return Config(url: config.url, token: config.token, clientMode: config.clientMode ?? "webchat")
                } catch {
                    print("[GatewayConfigLoader] Failed to parse gateway-config.json: \(error)")
                }
            }
        }

        // 3. No config found — offline mode
        print("[GatewayConfigLoader] No gateway config found. Running in offline mode.")
        print("[GatewayConfigLoader] Set BEECHAT_GATEWAY_URL and BEECHAT_GATEWAY_TOKEN environment variables in Xcode scheme for development.")
        return nil
    }
}

// MARK: - File Config Model

private struct GatewayFileConfig: Codable {
    let url: String
    let token: String
    let clientMode: String?
}