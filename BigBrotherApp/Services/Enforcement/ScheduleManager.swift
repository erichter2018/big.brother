import Foundation
import BigBrotherCore

/// Manages DeviceActivitySchedule registration with the system.
///
/// Translates BigBrotherCore.Schedule models into DeviceActivity framework
/// schedule registrations. The system guarantees that the DeviceActivityMonitor
/// extension will be called when registered schedules start and end,
/// even if the main app is not running.
///
/// Also registers a "reconciliation" schedule that fires periodically
/// to ensure enforcement state matches the policy snapshot, acting as
/// a reliability backstop.
protocol ScheduleManagerProtocol {
    /// Register all active schedules for a child with the system.
    /// Replaces any previously registered schedules.
    func registerSchedules(_ schedules: [Schedule]) throws

    /// Unregister all schedules (e.g., on unenrollment).
    func clearAllSchedules()

    /// Register a recurring reconciliation schedule.
    /// Fires the DeviceActivityMonitor extension periodically to verify
    /// enforcement state, even if no user-defined schedules exist.
    func registerReconciliationSchedule() throws
}
