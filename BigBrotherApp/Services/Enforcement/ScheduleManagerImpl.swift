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
        // Register a schedule that fires every hour to reconcile enforcement state.
        // Uses a fixed activity name so it can be updated without duplication.
        let activityName = DeviceActivityName(rawValue: "bigbrother.reconciliation")

        // Reconciliation schedule: fires at the start of every hour.
        // The DeviceActivityMonitor extension will re-read the policy snapshot
        // and verify enforcement state matches.
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let startMinute = (now.minute ?? 0) + 1  // next minute
        let endMinute = startMinute + 1

        let start = DateComponents(hour: now.hour, minute: startMinute % 60)
        let end = DateComponents(hour: now.hour, minute: endMinute % 60)

        let schedule = DeviceActivitySchedule(
            intervalStart: start,
            intervalEnd: end,
            repeats: true
        )

        try center.startMonitoring(activityName, during: schedule)
    }
}
