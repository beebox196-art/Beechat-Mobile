import Foundation

/// Loads gateway configuration for BeeChat Mobile.
///
/// Resolution order:
/// 1. Environment variables (BEECHAT_GATEWAY_URL + BEECHAT_GATEWAY_TOKEN) — for Xcode scheme injection
/// 2. Config file in app container (Application Support/BeeChat/gateway-config.json)
/// 3. Fallback: returns nil (offline mode)
///
/// For simulator development: seed gateway-config.json via `xcrun simctl` or Xcode scheme env vars.
/// For real device development: use Tailscale Serve URL (wss://...) over tailnet.
/// For production: bundle it or download from a provisioning server.
///
/// ## Swap-out Architecture
///
/// The app never imports Tailscale or uses the Tailscale SDK. It just connects to a URL.
/// Tailscale makes that URL reachable. Swapping to any alternative is one config change,
/// zero code changes.
///
/// | Scenario | Swap to | URL pattern |
/// |---|---|---|
/// | Tailscale adds costs we don't want | LAN IP (same network) | ws://192.168.x.x:18789 |
/// | Going public with the app | Public server with DNS + SSL | wss://beechat.example.com/ws |
/// | Remote dev without Tailscale | Cloudflare Tunnel or WireGuard | wss://tunnel.example.com/ws |
/// | Corporate network blocks Tailscale | WireGuard or direct VPN | ws://10.x.x.x:18789 |
///
/// To switch: change `BEECHAT_GATEWAY_URL` env var in Xcode scheme, or update gateway-config.json.
public struct GatewayConfigLoader: Sendable {
    public struct Config: Sendable {
        public let url: String
        public let token: String
        public let clientMode: String

        public init(url: String, token: String, clientMode: String = "ui") {
            self.url = url
            self.token = token
            self.clientMode = clientMode
        }
    }

    public static func load() -> Config? {
        // 1. Environment variables (Xcode scheme injection for development)
        if let url = ProcessInfo.processInfo.environment["BEECHAT_GATEWAY_URL"],
           let token = ProcessInfo.processInfo.environment["BEECHAT_GATEWAY_TOKEN"] {
            NSLog("[GatewayConfigLoader] Using env var config: %@", url)
            return Config(url: url, token: token)
        }

        // 2. Config file in app container
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = appSupport else {
            print("[GatewayConfigLoader] No Application Support directory. Running in offline mode.")
            return nil
        }
        let configPath = dir.appendingPathComponent("BeeChat/gateway-config.json")

        if FileManager.default.fileExists(atPath: configPath.path) {
            NSLog("[GatewayConfigLoader] Found config at %@", configPath.path)
            do {
                let data = try Data(contentsOf: configPath)
                // Try the bundled gateway-config.json format (url + token + clientMode)
                if let config = try? JSONDecoder().decode(GatewayFileConfig.self, from: data) {
                    NSLog("[GatewayConfigLoader] Parsed gateway-config.json: url=%@, clientMode=%@", config.url, config.clientMode ?? "ui")
                    return Config(url: config.url, token: config.token, clientMode: config.clientMode ?? "ui")
                }
                // Fall back to OpenClaw config JSON (gateway.auth.token + gateway.mode)
                let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let gw = raw?["gateway"] as? [String: Any],
                   let auth = gw["auth"] as? [String: Any],
                   let token = auth["token"] as? String {
                    let mode = gw["mode"] as? String ?? "local"
                    let url = "wss://openclaws-mac-mini-1.tail3f2df8.ts.net/ws"
                    print("[GatewayConfigLoader] Using OpenClaw config from \(configPath.path), mode=\(mode), url=\(url)")
                    return Config(url: url, token: token, clientMode: "ui")
                }
                // Try flat gatewayUrl + token format
                if let url = raw?["gatewayUrl"] as? String,
                   let token = raw?["token"] as? String {
                    print("[GatewayConfigLoader] Using flat config from \(configPath.path)")
                    return Config(url: url, token: token, clientMode: "ui")
                }
            } catch {
                print("[GatewayConfigLoader] Failed to parse config at \(configPath.path): \(error)")
            }
        }

        // 3. No config found - offline mode
        NSLog("[GatewayConfigLoader] No gateway config found at %@ - offline mode", configPath.path)
        return nil
    }
}

// MARK: - File Config Model

private struct GatewayFileConfig: Codable {
    let url: String
    let token: String
    let clientMode: String?
}