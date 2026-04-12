import Foundation

/// Flag written by ShieldAction when child taps "Ask for access" on a
/// category-shielded app where iOS doesn't pass an ApplicationToken.
/// The main app reads this on next foreground and auto-presents the picker
/// so the kid can re-select the app, capturing a fresh token that the
/// parent's reviewApp commands can resolve. The optional appName/bundleID
/// come from the ShieldConfiguration extension's Darwin notification bridge,
/// so we can hint the kid which app to tap.
public struct UnlockPickerPending: Codable, Sendable {
    public let requestedAt: Date
    public let appName: String?
    public let bundleID: String?

    public init(
        requestedAt: Date = Date(),
        appName: String? = nil,
        bundleID: String? = nil
    ) {
        self.requestedAt = requestedAt
        self.appName = appName
        self.bundleID = bundleID
    }

    /// Whether this request is recent enough to act on (within 5 minutes).
    public var isRecent: Bool {
        -requestedAt.timeIntervalSinceNow < 300
    }
}
