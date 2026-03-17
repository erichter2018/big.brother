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

    /// The lock mode applied outside free windows.
    public var lockedMode: LockMode

    public var isDefault: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        familyID: FamilyID,
        name: String,
        freeWindows: [ActiveWindow],
        lockedMode: LockMode = .dailyMode,
        isDefault: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.familyID = familyID
        self.name = name
        self.freeWindows = freeWindows
        self.lockedMode = lockedMode
        self.isDefault = isDefault
        self.updatedAt = updatedAt
    }

    /// Returns `true` if any free window contains the given date.
    public func isInFreeWindow(at date: Date, calendar: Calendar = .current) -> Bool {
        freeWindows.contains { $0.contains(date, calendar: calendar) }
    }

    /// Returns the mode that should be active at the given date.
    public func resolvedMode(at date: Date, calendar: Calendar = .current) -> LockMode {
        isInFreeWindow(at: date, calendar: calendar) ? .unlocked : lockedMode
    }

    /// Returns the next time the mode will change (end of current free window,
    /// or start of the next free window). Used for schedule labels like
    /// "Free until 8 PM" / "Locked until 3 PM".
    public func nextTransitionTime(from date: Date, calendar: Calendar = .current) -> Date? {
        let weekday = calendar.component(.weekday, from: date)
        guard let today = DayOfWeek(rawValue: weekday) else { return nil }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let now = DayTime(hour: hour, minute: minute)

        let inFree = isInFreeWindow(at: date, calendar: calendar)

        if inFree {
            // Find the end of the current free window.
            for window in freeWindows where window.daysOfWeek.contains(today) {
                if now >= window.startTime && now < window.endTime {
                    var comps = calendar.dateComponents([.year, .month, .day], from: date)
                    comps.hour = window.endTime.hour
                    comps.minute = window.endTime.minute
                    comps.second = 0
                    return calendar.date(from: comps)
                }
            }
        } else {
            // Find the start of the next free window (today or upcoming days).
            // Check remaining windows today first.
            let todayStarts = freeWindows
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
                let dayStarts = freeWindows
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
