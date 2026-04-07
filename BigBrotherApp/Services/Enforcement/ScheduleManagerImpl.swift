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
        // Register repeating schedules that fire every 2 minutes to reconcile enforcement state.
        // Register 60 reconciliation slots (every minute) for maximum responsiveness.
        // Each slot has a 2-minute duration so intervals overlap — at any given moment,
        // at least one slot is active. This ensures stopMonitoring() triggers intervalDidEnd.
        var intervals: [(name: String, minute: Int)] = []
        for m in 0..<60 {
            let name = m == 0 ? "bigbrother.reconciliation" : "bigbrother.reconciliation.m\(m)"
            intervals.append((name: name, minute: m))
        }

        for q in intervals {
            let activityName = DeviceActivityName(rawValue: q.name)
            let start = DateComponents(minute: q.minute)
            let endMinute = (q.minute + 2) % 60
            // Skip slots where end wraps past the hour (DeviceActivity doesn't handle cross-hour)
            guard endMinute > q.minute else { continue }
            let end = DateComponents(minute: endMinute)

            let schedule = DeviceActivitySchedule(
                intervalStart: start,
                intervalEnd: end,
                repeats: true
            )

            try center.startMonitoring(activityName, during: schedule)
        }
    }
}
