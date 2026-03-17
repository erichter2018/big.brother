import Foundation

/// How heartbeat monitoring is checked for an active window.
public enum HeartbeatCheckMode: Codable, Sendable, Equatable, Hashable {
    /// Alert if no heartbeat within the specified gap (rolling).
    case gap(TimeInterval)
    /// Alert only if zero heartbeats arrived during today's window.
    case oncePerDay
}

/// A time window on specific days of the week during which heartbeat
/// monitoring is expected. Used by `HeartbeatProfile` to define when
/// a device should be active and reporting.
public struct ActiveWindow: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public var daysOfWeek: Set<DayOfWeek>
    public var startTime: DayTime
    public var endTime: DayTime
    /// Per-window check mode override. When nil, uses `.gap(profile.maxHeartbeatGap)`.
    public var checkMode: HeartbeatCheckMode?

    public init(
        id: UUID = UUID(),
        daysOfWeek: Set<DayOfWeek>,
        startTime: DayTime,
        endTime: DayTime,
        checkMode: HeartbeatCheckMode? = nil
    ) {
        self.id = id
        self.daysOfWeek = daysOfWeek
        self.startTime = startTime
        self.endTime = endTime
        self.checkMode = checkMode
    }

    // Backward-compatible decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        daysOfWeek = try container.decode(Set<DayOfWeek>.self, forKey: .daysOfWeek)
        startTime = try container.decode(DayTime.self, forKey: .startTime)
        endTime = try container.decode(DayTime.self, forKey: .endTime)
        checkMode = try container.decodeIfPresent(HeartbeatCheckMode.self, forKey: .checkMode)
    }

    /// Returns `true` if the given date falls within this window
    /// (matching day-of-week and time range).
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard let day = DayOfWeek(rawValue: weekday),
              daysOfWeek.contains(day) else {
            return false
        }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let now = DayTime(hour: hour, minute: minute)
        return now >= startTime && now < endTime
    }
}

/// A named heartbeat-monitoring profile that defines when a device is
/// expected to be active and the maximum allowed gap between heartbeats.
/// Assigned to a `ChildDevice` via `heartbeatProfileID`.
public struct HeartbeatProfile: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let familyID: FamilyID
    public var name: String
    public var activeWindows: [ActiveWindow]
    /// Maximum allowed time (in seconds) between heartbeats before
    /// the device is considered offline.
    public var maxHeartbeatGap: TimeInterval
    public var isDefault: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        familyID: FamilyID,
        name: String,
        activeWindows: [ActiveWindow],
        maxHeartbeatGap: TimeInterval,
        isDefault: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.familyID = familyID
        self.name = name
        self.activeWindows = activeWindows
        self.maxHeartbeatGap = maxHeartbeatGap
        self.isDefault = isDefault
        self.updatedAt = updatedAt
    }

    /// Returns `true` if any active window contains the given date.
    public func isInActiveWindow(at date: Date, calendar: Calendar = .current) -> Bool {
        activeWindows.contains { $0.contains(date, calendar: calendar) }
    }

    /// Returns the effective check mode for the given time.
    /// Uses the per-window override if the time falls in a window that has one,
    /// otherwise falls back to `.gap(maxHeartbeatGap)`.
    public func effectiveCheckMode(at date: Date, calendar: Calendar = .current) -> HeartbeatCheckMode {
        if let window = activeWindows.first(where: { $0.contains(date, calendar: calendar) }),
           let mode = window.checkMode {
            return mode
        }
        return .gap(maxHeartbeatGap)
    }

    /// Returns the start of today's active window (if one matches), used for oncePerDay checks.
    public func windowStart(at date: Date, calendar: Calendar = .current) -> Date? {
        guard let window = activeWindows.first(where: { $0.contains(date, calendar: calendar) }) else {
            return nil
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = window.startTime.hour
        comps.minute = window.startTime.minute
        return calendar.date(from: comps)
    }

    /// Built-in preset profiles for common device usage patterns.
    public static func presets(familyID: FamilyID) -> [HeartbeatProfile] {
        let weekdays = DayOfWeek.weekdays
        let weekend = DayOfWeek.weekend
        let everyday = Set(DayOfWeek.allCases)

        return [
            HeartbeatProfile(
                familyID: familyID,
                name: "Phone - School Kid",
                activeWindows: [
                    ActiveWindow(
                        daysOfWeek: weekdays,
                        startTime: DayTime(hour: 7, minute: 0),
                        endTime: DayTime(hour: 8, minute: 30)
                    ),
                    ActiveWindow(
                        daysOfWeek: weekdays,
                        startTime: DayTime(hour: 15, minute: 0),
                        endTime: DayTime(hour: 21, minute: 0)
                    ),
                    ActiveWindow(
                        daysOfWeek: weekend,
                        startTime: DayTime(hour: 8, minute: 0),
                        endTime: DayTime(hour: 21, minute: 0)
                    ),
                ],
                maxHeartbeatGap: 7200
            ),
            HeartbeatProfile(
                familyID: familyID,
                name: "iPad - Weekend Only",
                activeWindows: [
                    ActiveWindow(
                        daysOfWeek: weekend,
                        startTime: DayTime(hour: 8, minute: 0),
                        endTime: DayTime(hour: 21, minute: 0),
                        checkMode: .oncePerDay
                    ),
                ],
                maxHeartbeatGap: 14400
            ),
            HeartbeatProfile(
                familyID: familyID,
                name: "Phone - Always Active",
                activeWindows: [
                    ActiveWindow(
                        daysOfWeek: everyday,
                        startTime: DayTime(hour: 7, minute: 0),
                        endTime: DayTime(hour: 22, minute: 0)
                    ),
                ],
                maxHeartbeatGap: 7200
            ),
        ]
    }
}
