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

    /// Dates on which the schedule is suspended — device stays unlocked all day.
    /// Stored as start-of-day dates. Old child builds ignore this field (safe default: no exceptions).
    public var exceptionDates: [Date]

    public var isDefault: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        familyID: FamilyID,
        name: String,
        freeWindows: [ActiveWindow],
        essentialWindows: [ActiveWindow] = [],
        lockedMode: LockMode = .restricted,
        exceptionDates: [Date] = [],
        isDefault: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.familyID = familyID
        self.name = name
        self.freeWindows = freeWindows
        self.essentialWindows = essentialWindows
        self.lockedMode = lockedMode
        self.exceptionDates = exceptionDates
        self.isDefault = isDefault
        self.updatedAt = updatedAt
    }

    // Custom Codable to allow backward-compatible decoding (exceptionDates may be absent in older data).
    enum CodingKeys: String, CodingKey {
        case id, familyID, name, freeWindows, essentialWindows, lockedMode, exceptionDates, isDefault, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        familyID = try container.decode(FamilyID.self, forKey: .familyID)
        name = try container.decode(String.self, forKey: .name)
        freeWindows = try container.decode([ActiveWindow].self, forKey: .freeWindows)
        essentialWindows = try container.decodeIfPresent([ActiveWindow].self, forKey: .essentialWindows) ?? []
        lockedMode = try container.decode(LockMode.self, forKey: .lockedMode)
        exceptionDates = try container.decodeIfPresent([Date].self, forKey: .exceptionDates) ?? []
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Returns `true` if the given date falls on a schedule exception date (unlocked all day).
    public func isExceptionDate(_ date: Date, calendar: Calendar = .current) -> Bool {
        let dateOnly = calendar.startOfDay(for: date)
        return exceptionDates.contains { calendar.isDate($0, inSameDayAs: dateOnly) }
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
    /// Priority: exception date > free window > essential window > lockedMode.
    public func resolvedMode(at date: Date, calendar: Calendar = .current) -> LockMode {
        if isExceptionDate(date, calendar: calendar) { return .unlocked }
        if isInFreeWindow(at: date, calendar: calendar) { return .unlocked }
        if isInEssentialWindow(at: date, calendar: calendar) { return .locked }
        return lockedMode
    }

    /// Returns the next time the mode will change. Considers free windows,
    /// essential windows, and their boundaries. Used for schedule labels like
    /// "Free until 8 PM" / "Locked until 3 PM" / "Essential until 7 AM".
    public func nextTransitionTime(from date: Date, calendar: Calendar = .current) -> Date? {
        // Exception dates unlock all day — next transition is midnight (start of next day).
        if isExceptionDate(date, calendar: calendar) {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
            return calendar.startOfDay(for: tomorrow)
        }

        let weekday = calendar.component(.weekday, from: date)
        guard let today = DayOfWeek(rawValue: weekday) else { return nil }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let now = DayTime(hour: hour, minute: minute)

        let currentMode = resolvedMode(at: date, calendar: calendar)

        // If in a free or essential window, find its end time.
        let activeWindows: [ActiveWindow] = currentMode == .unlocked ? freeWindows :
                                             currentMode == .locked ? essentialWindows : []
        if currentMode == .unlocked || (currentMode == .locked && !essentialWindows.isEmpty) {
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
                    let baseDate: Date
                    if now >= window.startTime {
                        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
                        baseDate = tomorrow
                    } else {
                        baseDate = date
                    }
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

        // Check future days (up to 7 days ahead), skipping exception dates.
        for dayOffset in 1...7 {
            guard let futureDate = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            if isExceptionDate(futureDate, calendar: calendar) { continue }
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
                lockedMode: .restricted
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
                lockedMode: .restricted
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
                lockedMode: .restricted
            ),
        ]
    }
}
