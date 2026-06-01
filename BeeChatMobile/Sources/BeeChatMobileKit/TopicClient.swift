import Foundation

/// REST client for fetching topic data from the Mac's TopicServer.
/// Proxied via Tailscale Serve at the same domain as the gateway URL.
///
/// URL derivation: gateway URL `https://openclaws-mac-mini-1.tail3f2df8.ts.net` →
/// topic URL `https://openclaws-mac-mini-1.tail3f2df8.ts.net/topics/v1/topics`
struct TopicClient {
    /// URLSession for HTTP GET requests.
    /// Uses the shared URLSession configuration (ATS-compliant by default).
    private let session: URLSession

    /// Full URL of the topics endpoint.
    let topicsURL: URL

    /// Create a TopicClient from the gateway configuration.
    /// Derives the topics URL by replacing the gateway path with `/topics/v1/topics`
    /// and switching scheme from `wss` to `https` (URLSession requires HTTP for plain GET).
    ///
    /// gatewayURL = "wss://openclaws-mac-mini-1.tail3f2df8.ts.net/ws"
    /// topicsURL  = "https://openclaws-mac-mini-1.tail3f2df8.ts.net/topics/v1/topics"
    init(gatewayURL: URL) {
        var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false)!
        // URLSession rejects wss/ws for plain HTTP GET — switch to https
        components.scheme = "https"
        // Strip the /ws suffix and use the topic server path
        components.path = "/topics/v1/topics"
        components.query = nil  // strip any query params from gateway URL

        self.topicsURL = components.url!

        // 10-second timeout for topic fetches
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    /// Fetch topic data from the Mac's TopicServer.
    /// Returns nil if the server is unreachable (standalone mode).
    /// - Returns: `TopicSyncPayload?` — nil means server unavailable, app continues in standalone mode.
    func fetchTopics() async -> TopicSyncPayload? {
        var request = URLRequest(url: topicsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[TopicClient] Invalid response type — standalone mode")
                return nil
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                print("[TopicClient] HTTP \(httpResponse.statusCode) — standalone mode")
                return nil
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(TopicSyncPayload.self, from: data)
            return payload
        } catch {
            print("[TopicClient] Fetch failed: \(error) — standalone mode")
            return nil
        }
    }
}