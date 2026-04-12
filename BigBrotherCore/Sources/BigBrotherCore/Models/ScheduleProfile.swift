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

    /// Time windows when the device is unlocked.
    /// Outside these windows, `lockedMode` is applied.
    public var unlockedWindows: [ActiveWindow]

    /// Time windows when locked mode is applied (e.g., bedtime).
    /// Takes priority over `lockedMode` but not over `unlockedWindows`.
    public var lockedWindows: [ActiveWindow]

    /// The mode applied outside unlocked and locked windows (typically .restricted).
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
        unlockedWindows: [ActiveWindow],
        lockedWindows: [ActiveWindow] = [],
        lockedMode: LockMode = .restricted,
        exceptionDates: [Date] = [],
        isDefault: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.familyID = familyID
        self.name = name
        self.unlockedWindows = unlockedWindows
        self.lockedWindows = lockedWindows
        self.lockedMode = lockedMode
        self.exceptionDates = exceptionDates
        self.isDefault = isDefault
        self.updatedAt = updatedAt
    }

    // Custom Codable to allow backward-compatible decoding (exceptionDates may be absent in older data).
    enum CodingKeys: String, CodingKey {
        case id, familyID, name, lockedMode, exceptionDates, isDefault, updatedAt
        // Map new property names to old JSON keys for backward compatibility
        case unlockedWindows = "freeWindows"
        case lockedWindows = "essentialWindows"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        familyID = try container.decode(FamilyID.self, forKey: .familyID)
        name = try container.decode(String.self, forKey: .name)
        unlockedWindows = try container.decode([ActiveWindow].self, forKey: .unlockedWindows)
        lockedWindows = try container.decodeIfPresent([ActiveWindow].self, forKey: .lockedWindows) ?? []
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
    public func isInUnlockedWindow(at date: Date, calendar: Calendar = .current) -> Bool {
        unlockedWindows.contains { $0.contains(date, calendar: calendar) }
    }

    /// Returns `true` if any essential window contains the given date.
    public func isInLockedWindow(at date: Date, calendar: Calendar = .current) -> Bool {
        lockedWindows.contains { $0.contains(date, calendar: calendar) }
    }

    /// Returns the mode that should be active at the given date.
    /// Priority: exception date > free window > essential window > lockedMode.
    public func resolvedMode(at date: Date, calendar: Calendar = .current) -> LockMode {
        if isExceptionDate(date, calendar: calendar) { return .unlocked }
        if isInUnlockedWindow(at: date, calendar: calendar) { return .unlocked }
        if isInLockedWindow(at: date, calendar: calendar) { return .locked }
        // Safety net: lockedMode should never be .unlocked — that defeats the
        // purpose of a schedule. Older profiles may have this from a data bug.
        return lockedMode == .unlocked ? .restricted : lockedMode
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
        let activeWindows: [ActiveWindow] = currentMode == .unlocked ? unlockedWindows :
                                             currentMode == .locked ? lockedWindows : []
        if currentMode == .unlocked || (currentMode == .locked && !lockedWindows.isEmpty) {
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
        let allWindows = unlockedWindows + lockedWindows
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
                unlockedWindows: [
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
                unlockedWindows: [
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
                unlockedWindows: [
                    ActiveWindow(
                        daysOfWeek: everyday,
                        startTime: DayTime(hour: 7, minute: 0),
                        endTime: DayTime(hour: 21, minute: 0)
                    ),
                ],
                lockedMode: .restricted
            ),
            ScheduleProfile(
                familyID: familyID,
                name: "Bedtime Only",
                unlockedWindows: [
                    ActiveWindow(
                        daysOfWeek: everyday,
                        startTime: DayTime(hour: 6, minute: 0),
                        endTime: DayTime(hour: 21, minute: 30)
                    ),
                ],
                lockedMode: .locked
            ),
            ScheduleProfile(
                familyID: familyID,
                name: "Test (15-min cycles)",
                unlockedWindows: (0..<24).map { hour in
                    ActiveWindow(
                        daysOfWeek: everyday,
                        startTime: DayTime(hour: hour, minute: 0),
                        endTime: DayTime(hour: hour, minute: 15)
                    )
                },
                lockedWindows: (0..<24).map { hour in
                    ActiveWindow(
                        daysOfWeek: everyday,
                        startTime: DayTime(hour: hour, minute: 30),
                        endTime: DayTime(hour: hour, minute: 45)
                    )
                },
                lockedMode: .restricted
            ),
        ]
    }

    /// Returns the bedtime slot for a given day of the week.
    /// Bedtime = the evening transition to `.locked` mode.
    /// Walks from 6 PM to midnight to find when the mode first becomes `.locked`.
    /// Returns nil if locked mode never kicks in during that window.
    public func bedtimeSlot(for day: DayOfWeek) -> Int? {
        // Scan from 6 PM (slot 72) to midnight (slot 95) in 15-min steps.
        // Bedtime is the first slot where the mode becomes .locked
        // after being non-locked earlier in the evening.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Find a reference date for this day of the week
        var refDate = today
        while cal.component(.weekday, from: refDate) != day.rawValue {
            refDate = cal.date(byAdding: .day, value: 1, to: refDate)!
        }

        var foundNonLocked = false
        for slot in 72...95 { // 6 PM to midnight
            let hour = slot / 4
            let minute = (slot % 4) * 15
            guard let checkTime = cal.date(bySettingHour: hour, minute: minute, second: 0, of: refDate) else { continue }
            let mode = resolvedMode(at: checkTime, calendar: cal)
            if mode != .locked {
                foundNonLocked = true
            } else if foundNonLocked {
                // Transition from non-locked to locked — this is bedtime
                return slot
            }
        }

        // If the whole evening is locked (lockedMode = .locked, no free/essential windows),
        // check if there's a free or essential window ending in the evening
        let allWindows = unlockedWindows + lockedWindows
        let eveningEnds = allWindows
            .filter { $0.daysOfWeek.contains(day) }
            .map { $0.endTime }
            .filter { ($0.hour * 60 + $0.minute) >= 18 * 60 } // after 6 PM
            .sorted { ($0.hour * 60 + $0.minute) < ($1.hour * 60 + $1.minute) }

        if let lastEnd = eveningEnds.last {
            return lastEnd.hour * 4 + lastEnd.minute / 15
        }

        return nil
    }
}
