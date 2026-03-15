import Foundation

/// A named schedule profile that defines when a device is unlocked (free)
/// and what lock mode to apply outside those free windows.
///
/// Assigned to a `ChildDevice` via `scheduleProfileID`. One profile can
/// be shared across multiple devices and children.
///
/// The DeviceActivityMonitor extension uses this to automatically
/// unlock/lock devices on schedule without network access.
public struct ScheduleProfile: Codable, Sendable, Identifiable, Equatable {
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
