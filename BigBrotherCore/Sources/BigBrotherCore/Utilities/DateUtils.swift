import Foundation

public extension Date {
    /// Seconds from now until the next midnight, clamped to a minimum of 60.
    static var secondsUntilMidnight: Int {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        return max(60, Int(midnight.timeIntervalSince(now)))
    }
}
