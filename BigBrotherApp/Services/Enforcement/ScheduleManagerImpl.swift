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
        center.stopMonitoring()
    }

    func registerReconciliationSchedule() throws {
        // Register repeating schedules that fire every 15 minutes to reconcile enforcement state.
        // More frequent reconciliation ensures force-close detection within ~35 minutes
        // (15 min cycle + 20 min flag threshold) instead of up to 2 hours with hourly checks.
        // Uses 4 fixed activity names (one per quarter-hour) so they can be updated without duplication.
        let quarters: [(name: String, minute: Int)] = [
            ("bigbrother.reconciliation", 0),
            ("bigbrother.reconciliation.q2", 15),
            ("bigbrother.reconciliation.q3", 30),
            ("bigbrother.reconciliation.q4", 45),
        ]

        for q in quarters {
            let activityName = DeviceActivityName(rawValue: q.name)
            let start = DateComponents(minute: q.minute)
            let end = DateComponents(minute: q.minute + 1)

            let schedule = DeviceActivitySchedule(
                intervalStart: start,
                intervalEnd: end,
                repeats: true
            )

            try center.startMonitoring(activityName, during: schedule)
        }
    }
}
