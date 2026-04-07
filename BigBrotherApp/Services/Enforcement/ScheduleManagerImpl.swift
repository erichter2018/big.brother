import Foundation
import DeviceActivity
import BigBrotherCore

/// Concrete schedule manager that registers DeviceActivity schedules with the system.
///
/// The system guarantees that the DeviceActivityMonitor extension fires
/// when registered schedule intervals start and end, even if the main app
/// is not running.
final class ScheduleManagerImpl: ScheduleManagerProtocol {

    private let center = DeviceActivityCenter()

    // MARK: - ScheduleManagerProtocol

    func registerSchedules(_ schedules: [Schedule]) throws {
        // Clear previous schedules.
        clearAllSchedules()

        for schedule in schedules where schedule.isActive {
            let activityName = DeviceActivityName(rawValue: schedule.id.uuidString)

            let startComponents = DateComponents(
                hour: schedule.startTime.hour,
                minute: schedule.startTime.minute
            )
            let endComponents = DateComponents(
                hour: schedule.endTime.hour,
                minute: schedule.endTime.minute
            )

            let daSchedule = DeviceActivitySchedule(
                intervalStart: startComponents,
                intervalEnd: endComponents,
                repeats: true
            )

            try center.startMonitoring(activityName, during: daSchedule)
        }
    }

    func clearAllSchedules() {
        // Selectively stop schedule-profile activities only.
        // Do NOT use center.stopMonitoring() (no args) — that nukes reconciliation + usage tracking too.
        for activity in center.activities {
            let raw = activity.rawValue
            if raw.hasPrefix("bigbrother.scheduleprofile.")
                || raw.hasPrefix("bigbrother.essentialwindow.") {
                center.stopMonitoring([activity])
            }
        }
    }

    /// Register 4 quarter-day reconciliation windows (6 hours each).
    ///
    /// DeviceActivity constraints:
    /// - Hard limit: 20 activities total across app + all extensions
    /// - Minimum interval: 15 minutes
    /// - DateComponents must include `hour` (minute-only = invalidDateComponents)
    ///
    /// 4 windows × (intervalDidStart + warningTime + intervalDidEnd) = 12 callbacks/day.
    /// Usage tracking milestones provide additional reconciliation every ~5 min of screen time.
    func registerReconciliationSchedule() throws {
        let quarters: [(name: String, startHour: Int, endHour: Int)] = [
            ("bigbrother.reconciliation.q0", 0, 5),
            ("bigbrother.reconciliation.q1", 6, 11),
            ("bigbrother.reconciliation.q2", 12, 17),
            ("bigbrother.reconciliation.q3", 18, 23),
        ]

        for q in quarters {
            let activityName = DeviceActivityName(rawValue: q.name)
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: q.startHour, minute: 0),
                intervalEnd: DateComponents(hour: q.endHour, minute: 59),
                repeats: true,
                warningTime: DateComponents(hour: 3)
            )
            do {
                try center.startMonitoring(activityName, during: schedule)
            } catch {
                NSLog("[ScheduleManager] FAILED to register \(q.name): \(error)")
                throw error
            }
        }

        let count = center.activities.filter { $0.rawValue.hasPrefix("bigbrother.reconciliation") }.count
        NSLog("[ScheduleManager] Registered \(count) reconciliation quarters (of 4)")
    }
}
