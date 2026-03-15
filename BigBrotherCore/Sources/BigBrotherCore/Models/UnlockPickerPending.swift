import Foundation

/// Flag written by ShieldAction when child taps "Ask for More Time".
/// The main app reads this to auto-present the app picker.
public struct UnlockPickerPending: Codable, Sendable {
    public let requestedAt: Date

    public init(requestedAt: Date = Date()) {
        self.requestedAt = requestedAt
    }

    /// Whether this request is recent enough to act on (within 5 minutes).
    public var isRecent: Bool {
        -requestedAt.timeIntervalSinceNow < 300
    }
}
