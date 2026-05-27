import Foundation

// MARK: - Topic Sync Payload

/// Payload format for topic sync via the `agent:main:beechat-sync` session.
/// The Mac publishes this JSON; the iPhone reads and reconciles from it.
struct TopicSyncPayload: Codable {
    let v: Int
    let timestamp: String  // ISO 8601 with Z suffix (UTC)
    let topics: [TopicPayloadItem]

    /// Maximum payload size in bytes (sanity guard)
    static let maxPayloadSize = 50_000  // 50KB

    /// Extract and validate a TopicSyncPayload from a raw message content string.
    /// Handles both pure JSON and content wrapped in chat message envelopes.
    static func extract(from content: String?) -> TopicSyncPayload? {
        guard let content = content else { return nil }

        // Size guard
        guard content.utf8.count <= maxPayloadSize else {
            print("[TopicSync] Payload exceeds \(maxPayloadSize) bytes, rejecting")
            return nil
        }

        // Try to parse as JSON directly
        if let data = content.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let payload = try? JSONDecoder().decode(TopicSyncPayload.self, from: data) {
            return validate(payload)
        }

        // Try to extract JSON from markdown code block wrapper (```json ... ```)
        if let range = content.range(of: "{", options: .literal),
           let endRange = content.range(of: "}", options: .backwards) {
            let jsonString = String(content[range.lowerBound...endRange.lowerBound])
            if let data = jsonString.data(using: .utf8),
               let payload = try? JSONDecoder().decode(TopicSyncPayload.self, from: data) {
                return validate(payload)
            }
        }

        print("[TopicSync] Could not parse payload from content")
        return nil
    }

    /// Validate payload structure and version
    private static func validate(_ payload: TopicSyncPayload) -> TopicSyncPayload? {
        // Version check
        guard payload.v == 1 else {
            print("[TopicSync] Unsupported payload version: \(payload.v)")
            return nil
        }

        // Empty topics guard — don't archive everything on empty payload
        guard !payload.topics.isEmpty else {
            print("[TopicSync] Payload has 0 topics, skipping (safety guard)")
            return nil
        }

        return payload
    }

    /// Parse the timestamp string as a Date
    /// Handles both fractional-seconds ("2026-05-27T20:00:00.000Z")
    /// and non-fractional ("2026-05-27T20:00:00Z") formats.
    var timestampDate: Date? {
        parseISO8601(from: timestamp)
    }
}

struct TopicPayloadItem: Codable {
    let id: String
    let name: String
    let sessionKey: String
    let isArchived: Bool?
    let lastActivityAt: String?  // ISO 8601
    let lastMessagePreview: String?

    var lastActivityDate: Date? {
        guard let lastActivityAt = lastActivityAt else { return nil }
        return parseISO8601(from: lastActivityAt)
    }
}

/// Parse an ISO 8601 date string, trying fractional seconds first then falling back.
/// This handles both "2026-05-27T20:00:00.000Z" and "2026-05-27T20:00:00Z".
private func parseISO8601(from string: String) -> Date? {
    // Try with fractional seconds first
    let fmt1 = ISO8601DateFormatter()
    fmt1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fmt1.date(from: string) { return date }

    // Fallback without fractional seconds
    let fmt2 = ISO8601DateFormatter()
    fmt2.formatOptions = [.withInternetDateTime]
    return fmt2.date(from: string)
}