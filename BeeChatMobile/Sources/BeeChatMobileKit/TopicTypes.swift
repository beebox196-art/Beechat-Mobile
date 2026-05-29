import Foundation

// MARK: - Topic Type Definitions

/// Topic sync payload format — served by the Mac's REST topic server.
/// The iPhone fetches this JSON and reconciles from it.
struct TopicSyncPayload: Codable {
    let v: Int
    let timestamp: String  // ISO 8601 with Z suffix (UTC)
    let topics: [TopicPayloadItem]

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