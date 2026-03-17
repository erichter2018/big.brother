import Foundation

/// A recurring schedule that overrides the base policy mode during
/// specific time windows on specific days.
///
/// Example: "School Hours" — apply dailyMode from 08:00–15:00 on weekdays.
public struct Schedule: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let childProfileID: ChildProfileID
    public let familyID: FamilyID
    /// Human-readable name, e.g. "School Hours", "Bedtime"
    public var name: String
    /// The lock mode to apply during this schedule window.
    public var mode: LockMode
    public var daysOfWeek: Set<DayOfWeek>
    public var startTime: DayTime
    public var endTime: DayTime
    public var isActive: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        childProfileID: ChildProfileID,
        familyID: FamilyID,
        name: String,
        mode: LockMode,
        daysOfWeek: Set<DayOfWeek>,
        startTime: DayTime,
        endTime: DayTime,
        isActive: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.childProfileID = childProfileID
        self.familyID = familyID
        self.name = name
        self.mode = mode
        self.daysOfWeek = daysOfWeek
        self.startTime = startTime
        self.endTime = endTime
        self.isActive = isActive
        self.updatedAt = updatedAt
    }
}

/// Time of day without a date component.
public struct DayTime: Codable, Sendable, Equatable, Hashable, Comparable {
    public let hour: Int   // 0–23
    public let minute: Int // 0–59

    public init(hour: Int, minute: Int) {
        precondition((0...23).contains(hour), "Hour must be 0–23")
        precondition((0...59).contains(minute), "Minute must be 0–59")
        self.hour = hour
        self.minute = minute
    }

    /// Total minutes since midnight, used for comparison.
    public var minutesSinceMidnight: Int {
        hour * 60 + minute
    }

    public static func < (lhs: DayTime, rhs: DayTime) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

public enum DayOfWeek: Int, Codable, Sendable, CaseIterable, Comparable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    public static func < (lhs: DayOfWeek, rhs: DayOfWeek) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }

    public var shortName: String {
        switch self {
        case .sunday: "Sun"
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        }
    }

    public var initial: String {
        String(displayName.prefix(1))
    }

    /// Weekdays (Mon–Fri).
    public static let weekdays: Set<DayOfWeek> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    /// Weekend days (Sat–Sun).
    public static let weekend: Set<DayOfWeek> = [.saturday, .sunday]
}
