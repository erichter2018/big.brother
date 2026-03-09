import Foundation
import BigBrotherCore

/// Shared formatting helpers for schedule display across list, detail, and editor views.
enum ScheduleFormatting {
    static func daysText(_ days: Set<DayOfWeek>) -> String {
        if days == Set(DayOfWeek.allCases) { return "Every day" }
        if days == DayOfWeek.weekdays { return "Weekdays" }
        if days == DayOfWeek.weekend { return "Weekend" }
        return days.sorted().map(\.shortName).joined(separator: ", ")
    }

    static func timeText(_ time: DayTime) -> String {
        let h = time.hour % 12 == 0 ? 12 : time.hour % 12
        let ampm = time.hour < 12 ? "AM" : "PM"
        if time.minute == 0 { return "\(h) \(ampm)" }
        return String(format: "%d:%02d %@", h, time.minute, ampm)
    }

    static func timeRange(_ start: DayTime, _ end: DayTime) -> String {
        "\(timeText(start)) – \(timeText(end))"
    }
}
