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
    /// Derives the topics URL by appending `/topics/v1/topics` to the gateway domain.
    init(gatewayURL: URL) {
        // Append /topics/v1/topics to the gateway URL
        var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false)!
        // Preserve existing path and append the topic server path
        let existingPath = components.path
        if existingPath.isEmpty || existingPath == "/" {
            components.path = "/topics/v1/topics"
        } else {
            // Remove trailing slash and append
            let cleanPath = existingPath.hasSuffix("/") ? String(existingPath.dropLast()) : existingPath
            components.path = cleanPath + "/topics/v1/topics"
        }

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