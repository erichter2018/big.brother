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
        // Register repeating schedules that fire every 5 minutes to reconcile enforcement state.
        // Tightened from 15-minute to reduce the window when Monitor is killed mid-operation
        // and shields are inconsistent with the policy snapshot.
        let intervals: [(name: String, minute: Int)] = [
            ("bigbrother.reconciliation", 0),
            ("bigbrother.reconciliation.q2", 5),
            ("bigbrother.reconciliation.q3", 10),
            ("bigbrother.reconciliation.q4", 15),
            ("bigbrother.reconciliation.q5", 20),
            ("bigbrother.reconciliation.q6", 25),
            ("bigbrother.reconciliation.q7", 30),
            ("bigbrother.reconciliation.q8", 35),
            ("bigbrother.reconciliation.q9", 40),
            ("bigbrother.reconciliation.q10", 45),
            ("bigbrother.reconciliation.q11", 50),
            ("bigbrother.reconciliation.q12", 55),
        ]

        for q in intervals {
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
