import Testing
@testable import BigBrotherCore
import Foundation

@Suite("Schedule Model")
struct ScheduleModelTests {

    let familyID = FamilyID.generate()
    let childProfileID = ChildProfileID.generate()

    @Test("Schedule initializes with correct defaults")
    func scheduleDefaults() {
        let schedule = Schedule(
            childProfileID: childProfileID,
            familyID: familyID,
            name: "Test",
            mode: .dailyMode,
            daysOfWeek: DayOfWeek.weekdays,
            startTime: DayTime(hour: 8, minute: 0),
            endTime: DayTime(hour: 15, minute: 0)
        )
        #expect(schedule.isActive)
        #expect(schedule.name == "Test")
        #expect(schedule.daysOfWeek.count == 5)
    }

    @Test("DayTime minutesSinceMidnight")
    func dayTimeMinutes() {
        let midnight = DayTime(hour: 0, minute: 0)
        #expect(midnight.minutesSinceMidnight == 0)

        let noon = DayTime(hour: 12, minute: 0)
        #expect(noon.minutesSinceMidnight == 720)

        let endOfDay = DayTime(hour: 23, minute: 59)
        #expect(endOfDay.minutesSinceMidnight == 1439)
    }

    @Test("DayOfWeek all cases ordered Sun through Sat")
    func dayOfWeekOrdering() {
        let sorted = DayOfWeek.allCases.sorted()
        #expect(sorted.first == .sunday)
        #expect(sorted.last == .saturday)
    }

    @Test("DayOfWeek short names")
    func shortNames() {
        #expect(DayOfWeek.sunday.shortName == "Sun")
        #expect(DayOfWeek.wednesday.shortName == "Wed")
        #expect(DayOfWeek.friday.shortName == "Fri")
    }

    @Test("DayOfWeek initials")
    func initials() {
        #expect(DayOfWeek.sunday.initial == "S")
        #expect(DayOfWeek.monday.initial == "M")
        #expect(DayOfWeek.tuesday.initial == "T")
    }

    @Test("Schedule Codable preserves all fields")
    func scheduleCodable() throws {
        let schedule = Schedule(
            childProfileID: childProfileID,
            familyID: familyID,
            name: "School",
            mode: .essentialOnly,
            daysOfWeek: [.monday, .wednesday, .friday],
            startTime: DayTime(hour: 9, minute: 30),
            endTime: DayTime(hour: 14, minute: 45),
            isActive: false
        )

        let data = try JSONEncoder().encode(schedule)
        let decoded = try JSONDecoder().decode(Schedule.self, from: data)

        #expect(decoded.id == schedule.id)
        #expect(decoded.name == "School")
        #expect(decoded.mode == .essentialOnly)
        #expect(decoded.daysOfWeek == [.monday, .wednesday, .friday])
        #expect(decoded.startTime.hour == 9)
        #expect(decoded.startTime.minute == 30)
        #expect(decoded.endTime.hour == 14)
        #expect(decoded.endTime.minute == 45)
        #expect(!decoded.isActive)
    }

    @Test("Schedule Equatable")
    func scheduleEquatable() {
        let id = UUID()
        let s1 = Schedule(
            id: id,
            childProfileID: childProfileID,
            familyID: familyID,
            name: "Test",
            mode: .dailyMode,
            daysOfWeek: DayOfWeek.weekdays,
            startTime: DayTime(hour: 8, minute: 0),
            endTime: DayTime(hour: 15, minute: 0)
        )
        let s2 = Schedule(
            id: id,
            childProfileID: childProfileID,
            familyID: familyID,
            name: "Test",
            mode: .dailyMode,
            daysOfWeek: DayOfWeek.weekdays,
            startTime: DayTime(hour: 8, minute: 0),
            endTime: DayTime(hour: 15, minute: 0),
            updatedAt: s1.updatedAt
        )
        #expect(s1 == s2)
    }

    @Test("DayTime equality")
    func dayTimeEquality() {
        let a = DayTime(hour: 10, minute: 30)
        let b = DayTime(hour: 10, minute: 30)
        let c = DayTime(hour: 10, minute: 31)
        #expect(a == b)
        #expect(a != c)
    }
}
