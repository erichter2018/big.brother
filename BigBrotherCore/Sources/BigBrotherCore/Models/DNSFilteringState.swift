import Foundation

/// Atomic App Group state for the DNS kill switch.
/// Single JSON blob consumed by the tunnel's DNSProxy gate.
/// Writes are race-free because UserDefaults replaces the whole value atomically.
public struct DNSFilteringState: Codable, Equatable, Sendable {

    public var enabled: Bool
    public var disabledAt: Date?
    public var disabledDurationSeconds: Int

    public init(enabled: Bool, disabledAt: Date? = nil, disabledDurationSeconds: Int = 0) {
        self.enabled = enabled
        self.disabledAt = disabledAt
        self.disabledDurationSeconds = disabledDurationSeconds
    }

    /// Default state: filtering ON, no disable timestamp.
    public static let defaultEnabled = DNSFilteringState(enabled: true)

    /// Returns the effective state at the given time.
    /// If filtering was disabled with a duration, returns `defaultEnabled`
    /// once the duration has elapsed. Includes 60s tolerance for clock rewind.
    public func effective(now: Date = Date()) -> DNSFilteringState {
        guard !enabled, let disabledAt else { return self }
        let elapsed = now.timeIntervalSince(disabledAt)
        if elapsed < -60 { return .defaultEnabled }
        if elapsed >= Double(disabledDurationSeconds) && disabledDurationSeconds > 0 {
            return .defaultEnabled
        }
        return self
    }

    /// Clamp duration to a reasonable range (1 minute to 24 hours).
    /// Zero means indefinite (no auto-reenable).
    public static func clampDurationSeconds(_ seconds: Int) -> Int {
        if seconds <= 0 { return 0 }
        return min(max(seconds, 60), 86400)
    }

    // MARK: - App Group Persistence

    public static func read(from defaults: UserDefaults?) -> DNSFilteringState {
        guard let defaults,
              let data = defaults.data(forKey: AppGroupKeys.dnsFilteringStateJSON),
              let state = try? JSONDecoder().decode(DNSFilteringState.self, from: data)
        else {
            return .defaultEnabled
        }
        return state
    }

    public static func write(_ state: DNSFilteringState, to defaults: UserDefaults?) {
        guard let defaults,
              let data = try? JSONEncoder().encode(state)
        else { return }
        defaults.set(data, forKey: AppGroupKeys.dnsFilteringStateJSON)
    }
}
