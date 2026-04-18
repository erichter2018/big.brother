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
    /// Each window fires intervalDidStart + intervalDidEnd = 8 callbacks/day.
    /// Usage tracking milestones provide additional reconciliation every ~5 min of screen time.
    func registerReconciliationSchedule() throws {
        let storage = AppGroupStorage()

        // Log existing activities before registration for diagnosis.
        let existingActivities = center.activities
        let existingNames = existingActivities.map(\.rawValue)
        BBLog("[ScheduleManager] Before registration: \(existingActivities.count) activities: \(existingNames)")
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "Reconciliation registration starting",
            details: "\(existingActivities.count) existing activities"
        ))

        let quarters: [(name: String, startHour: Int, endHour: Int)] = [
            ("bigbrother.reconciliation.q0", 0, 5),
            ("bigbrother.reconciliation.q1", 6, 11),
            ("bigbrother.reconciliation.q2", 12, 17),
            ("bigbrother.reconciliation.q3", 18, 23),
        ]

        var registered = 0
        var errors: [String] = []

        for q in quarters {
            let activityName = DeviceActivityName(rawValue: q.name)
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: q.startHour, minute: 0),
                intervalEnd: DateComponents(hour: q.endHour, minute: 59),
                repeats: true
            )

            // Stop before re-registering — on iOS 18+, re-registering without
            // stopping first can cause intervalDidStart to never fire.
            center.stopMonitoring([activityName])

            // Retry up to 3 times with 1s delay on "helper application" error.
            // This is the recommended workaround for the deviceactivityd XPC flake.
            for attempt in 1...3 {
                do {
                    try center.startMonitoring(activityName, during: schedule)
                    registered += 1
                    BBLog("[ScheduleManager] ✓ Registered \(q.name)\(attempt > 1 ? " (attempt \(attempt))" : "")")
                    break
                } catch {
                    if attempt < 3 {
                        BBLog("[ScheduleManager] ✗ \(q.name) attempt \(attempt) failed: \(error.localizedDescription) — retrying in 0.5s")
                        usleep(500_000) // 0.5s — shorter than 1s to reduce UI freeze
                    } else {
                        let msg = "\(q.name): \(error.localizedDescription)"
                        errors.append(msg)
                        BBLog("[ScheduleManager] ✗ FAILED \(msg) (all 3 attempts)")
                    }
                }
            }
        }

        let afterCount = center.activities.filter { $0.rawValue.hasPrefix("bigbrother.reconciliation") }.count
        let result = "Registered \(registered)/4 quarters (\(afterCount) visible in .activities)"
        BBLog("[ScheduleManager] \(result)")
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: errors.isEmpty ? "Reconciliation registered OK" : "Reconciliation registration PARTIAL",
            details: "\(result)\(errors.isEmpty ? "" : " ERRORS: \(errors.joined(separator: "; "))")"
        ))

        if registered == 0 { throw NSError(domain: "ScheduleManager", code: 1, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "; ")]) }
    }
}
