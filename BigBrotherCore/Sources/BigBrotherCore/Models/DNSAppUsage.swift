import Foundation

/// Tracks per-app DNS activity minutes for time limit enforcement.
/// The VPN tunnel accumulates active minutes (60-second windows with DNS queries)
/// and compares against configured AppTimeLimit budgets.
public struct DNSAppUsage: Codable, Sendable {
    /// Date string "yyyy-MM-dd" for daily reset.
    public var dateString: String
    /// Per-app accumulated active minutes. Key = app name from DomainCategorizer.
    public var apps: [String: Int]

    public init(dateString: String = "", apps: [String: Int] = [:]) {
        self.dateString = dateString
        self.apps = apps
    }
}
