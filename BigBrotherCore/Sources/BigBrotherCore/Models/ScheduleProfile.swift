import Foundation

/// A named schedule profile that defines when a device is unlocked (free)
/// and what lock mode to apply outside those free windows.
///
/// Assigned to a `ChildDevice` via `scheduleProfileID`. One profile can
/// be shared across multiple devices and children.
///
/// The DeviceActivityMonitor extension uses this to automatically
/// unlock/lock devices on schedule without network access.
public struct ScheduleProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let familyID: FamilyID
    public var name: String

    /// Time windows when the device is FREE (unlocked).
    /// Outside these windows, `lockedMode` is applied.
    public var freeWindows: [ActiveWindow]

    /// Time windows when essential-only mode is applied (e.g., overnight).
    /// Takes priority over `lockedMode` but not over `freeWindows`.
    /// Old child builds ignore this field — device stays in `lockedMode` (safer, stricter).
    public var essentialWindows: [ActiveWindow]

    /// The lock mode applied outside free windows and essential windows.
    public var lockedMode: LockMode

    public var isDefault: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        familyID: FamilyID,
        name: String,
        freeWindows: [ActiveWindow],
        essentialWindows: [ActiveWindow] = [],
        lockedMode: LockMode = .dailyMode,
        isDefault: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.familyID = familyID
        self.name = name
        self.freeWindows = freeWindows
        self.essentialWindows = essentialWindows
        self.lockedMode = lockedMode
        self.isDefault = isDefault
        self.updatedAt = updatedAt
    }

    /// Returns `true` if any free window contains the given date.
    public func isInFreeWindow(at date: Date, calendar: Calendar = .current) -> Bool {
        freeWindows.contains { $0.contains(date, calendar: calendar) }
    }

    /// Returns `true` if any essential window contains the given date.
    public func isInEssentialWindow(at date: Date, calendar: Calendar = .current) -> Bool {
        essentialWindows.contains { $0.contains(date, calendar: calendar) }
    }

    /// Returns the mode that should be active at the given date.
    /// Priority: free window > essential window > lockedMode.
    public func resolvedMode(at date: Date, calendar: Calendar = .current) -> LockMode {
        if isInFreeWindow(at: date, calendar: calendar) { return .unlocked }
        if isInEssentialWindow(at: date, calendar: calendar) { return .essentialOnly }
        return lockedMode
    }

    /// Returns the next time the mode will change. Considers free windows,
    /// essential windows, and their boundaries. Used for schedule labels like
    /// "Free until 8 PM" / "Locked until 3 PM" / "Essential until 7 AM".
    public func nextTransitionTime(from date: Date, calendar: Calendar = .current) -> Date? {
        let weekday = calendar.component(.weekday, from: date)
        guard let today = DayOfWeek(rawValue: weekday) else { return nil }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let now = DayTime(hour: hour, minute: minute)

        let currentMode = resolvedMode(at: date, calendar: calendar)

        // If in a free or essential window, find its end time.
        let activeWindows: [ActiveWindow] = currentMode == .unlocked ? freeWindows :
                                             currentMode == .essentialOnly ? essentialWindows : []
        if currentMode == .unlocked || (currentMode == .essentialOnly && !essentialWindows.isEmpty) {
            for window in activeWindows where window.contains(date, calendar: calendar) {
                if window.startTime < window.endTime {
                    // Same-day window — end is today
                    var comps = calendar.dateComponents([.year, .month, .day], from: date)
                    comps.hour = window.endTime.hour
                    comps.minute = window.endTime.minute
                    comps.second = 0
                    return calendar.date(from: comps)
                } else {
                    // Cross-midnight window — end is tomorrow if we're in evening portion
                    let baseDate = now >= window.startTime
                        ? calendar.date(byAdding: .day, value: 1, to: date)!
                        : date
                    var comps = calendar.dateComponents([.year, .month, .day], from: baseDate)
                    comps.hour = window.endTime.hour
                    comps.minute = window.endTime.minute
                    comps.second = 0
                    return calendar.date(from: comps)
                }
            }
        }

        // Outside active windows — find the next transition (free or essential, whichever is sooner).
        let allWindows = freeWindows + essentialWindows
        let todayStarts = allWindows
            .filter { $0.daysOfWeek.contains(today) && $0.startTime > now }
            .sorted { $0.startTime < $1.startTime }
        if let next = todayStarts.first {
            var comps = calendar.dateComponents([.year, .month, .day], from: date)
            comps.hour = next.startTime.hour
            comps.minute = next.startTime.minute
            comps.second = 0
            return calendar.date(from: comps)
        }

        // Check future days (up to 7 days ahead).
        for dayOffset in 1...7 {
            guard let futureDate = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let futureWeekday = calendar.component(.weekday, from: futureDate)
            guard let futureDay = DayOfWeek(rawValue: futureWeekday) else { continue }
            let dayStarts = allWindows
                .filter { $0.daysOfWeek.contains(futureDay) }
                .sorted { $0.startTime < $1.startTime }
            if let next = dayStarts.first {
                var comps = calendar.dateComponents([.year, .month, .day], from: futureDate)
                comps.hour = next.startTime.hour
                comps.minute = next.startTime.minute
                comps.second = 0
                return calendar.date(from: comps)
            }
        }

        return nil
    }

    /// Built-in preset profiles for common device usage patterns.
    public static func presets(familyID: FamilyID) -> [ScheduleProfile] {
        let weekdays = DayOfWeek.weekdays
        let weekend = DayOfWeek.weekend
        let everyday = Set(DayOfWeek.allCases)

        return [
            ScheduleProfile(
                familyID: familyID,
                name: "School Day",
                freeWindows: [
                    ActiveWindow(
                        daysOfWeek: weekdays,
                        startTime: DayTime(hour: 7, minute: 0),
                        endTime: DayTime(hour: 8, minute: 0)
                    ),
                    ActiveWindow(
                        daysOfWeek: weekdays,
                        startTime: DayTime(hour: 15, minute: 0),
                        endTime: DayTime(hour: 20, minute: 0)
                    ),
                    ActiveWindow(
                        daysOfWeek: weekend,
                        startTime: DayTime(hour: 9, minute: 0),
                        endTime: DayTime(hour: 20, minute: 0)
                    ),
                ],
                lockedMode: .dailyMode
            ),
            ScheduleProfile(
                familyID: familyID,
                name: "Weekend Only",
                freeWindows: [
                    ActiveWindow(
                        daysOfWeek: weekend,
                        startTime: DayTime(hour: 9, minute: 0),
                        endTime: DayTime(hour: 20, minute: 0)
                    ),
                ],
                lockedMode: .dailyMode
            ),
            ScheduleProfile(
                familyID: familyID,
                name: "Lenient",
                freeWindows: [
                    ActiveWindow(
                        daysOfWeek: everyday,
                        startTime: DayTime(hour: 7, minute: 0),
                        endTime: DayTime(hour: 21, minute: 0)
                    ),
                ],
                lockedMode: .dailyMode
            ),
        ]
    }
}
