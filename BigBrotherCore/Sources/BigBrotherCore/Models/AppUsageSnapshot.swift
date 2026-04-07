import Foundation

/// Precise per-app foreground usage from DeviceActivityEvent milestones.
/// Written by the Monitor extension, read by heartbeat and parent dashboard.
/// Keyed by app fingerprint. Resets daily.
public struct AppUsageSnapshot: Codable, Sendable, Equatable {
    /// Date string "yyyy-MM-dd" for daily reset.
    public var dateString: String
    /// Minutes of foreground usage per app fingerprint.
    public var usageByFingerprint: [String: Int]

    public init(dateString: String, usageByFingerprint: [String: Int] = [:]) {
        self.dateString = dateString
        self.usageByFingerprint = usageByFingerprint
    }
}
