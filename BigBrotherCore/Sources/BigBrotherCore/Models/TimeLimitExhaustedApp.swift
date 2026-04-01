import Foundation

/// Tracks an app that exhausted its daily time budget.
/// Written by the Monitor extension when a DeviceActivityEvent threshold fires.
/// Read by enforcement to exclude the app from the allowed set and add to shield.applications.
/// Cleared at midnight when the daily schedule interval restarts.
public struct TimeLimitExhaustedApp: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// References the AppTimeLimit this belongs to.
    public let timeLimitID: UUID
    public let appName: String
    /// Encoded ApplicationToken for enforcement.
    public let tokenData: Data
    public let fingerprint: String
    public let exhaustedAt: Date
    /// "yyyy-MM-dd" — used for daily reset (only enforce for today's date).
    public let dateString: String

    public init(
        id: UUID = UUID(),
        timeLimitID: UUID,
        appName: String,
        tokenData: Data,
        fingerprint: String,
        exhaustedAt: Date = Date(),
        dateString: String? = nil
    ) {
        self.id = id
        self.timeLimitID = timeLimitID
        self.appName = appName
        self.tokenData = tokenData
        self.fingerprint = fingerprint
        self.exhaustedAt = exhaustedAt
        if let ds = dateString {
            self.dateString = ds
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            self.dateString = fmt.string(from: exhaustedAt)
        }
    }
}
