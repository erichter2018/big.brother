import Foundation

/// Tracks daily self-unlock usage on a child device.
///
/// Persisted to App Group storage so the child can check availability
/// even when offline. The `date` field enables automatic midnight reset
/// without requiring a timer — when the local date changes, `usedCount`
/// is treated as 0.
///
/// Time zone manipulation is prevented by `requireAutomaticDateAndTime`
/// (enforced via ManagedSettings on the default store, persists during unlocks).
public struct SelfUnlockState: Codable, Sendable, Equatable {
    /// Calendar date string ("yyyy-MM-dd") this state applies to.
    /// When the current local date differs, the counter resets.
    public let date: String

    /// Number of self-unlocks consumed today.
    public let usedCount: Int

    /// Daily budget cached from ChildDevice.selfUnlocksPerDay.
    /// Cached locally so the child can check availability offline.
    public let budget: Int

    /// How many self-unlocks remain today.
    public var remaining: Int { max(0, budget - usedCount) }

    /// Whether a self-unlock can be used right now.
    public var isAvailable: Bool { remaining > 0 }

    public init(date: String, usedCount: Int, budget: Int) {
        self.date = date
        self.usedCount = usedCount
        self.budget = budget
    }

    /// Return a new state with one self-unlock consumed.
    /// Auto-resets if the date has changed since last use.
    public func consuming(one currentDate: String) -> SelfUnlockState {
        if date == currentDate {
            return SelfUnlockState(date: currentDate, usedCount: usedCount + 1, budget: budget)
        } else {
            // New day — reset counter, consume one.
            return SelfUnlockState(date: currentDate, usedCount: 1, budget: budget)
        }
    }

    /// Return a state with the counter reset if the date has changed.
    /// Preserves the budget. If the date matches, returns self unchanged.
    public func resettingIfNeeded(currentDate: String) -> SelfUnlockState {
        if date == currentDate {
            return self
        }
        return SelfUnlockState(date: currentDate, usedCount: 0, budget: budget)
    }

    /// Format today's date as "yyyy-MM-dd" in the device's local calendar.
    /// Uses local time so the budget resets at local midnight.
    /// Time zone manipulation is blocked by requireAutomaticDateAndTime.
    public static func todayDateString() -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
