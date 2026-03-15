import Foundation
import DeviceActivity
import BigBrotherCore

/// Registers DeviceActivity schedules on the child device based on the
/// assigned ScheduleProfile. Each free window becomes a monitored
/// DeviceActivity interval.
///
/// When an interval starts, the DeviceActivityMonitor extension unlocks the device.
/// When it ends, the extension re-applies the locked mode.
///
/// DeviceActivity schedules persist across app launches and reboots (after first unlock).
enum ScheduleRegistrar {

    /// Prefix for all schedule profile activities.
    static let activityPrefix = "bigbrother.scheduleprofile."

    /// Register DeviceActivity schedules for the given profile.
    /// Clears any previously registered schedule profile activities first.
    static func register(_ profile: ScheduleProfile, storage: any SharedStorageProtocol) {
        let center = DeviceActivityCenter()

        // Clear existing schedule profile activities.
        clearAll(center: center)

        // Write the profile to App Group so the extension can read it.
        try? storage.writeActiveScheduleProfile(profile)

        // Register one DeviceActivity per free window.
        for window in profile.freeWindows {
            let activityName = DeviceActivityName(rawValue: "\(activityPrefix)\(window.id.uuidString)")

            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
                intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
                repeats: true
            )

            do {
                try center.startMonitoring(activityName, during: schedule)
                #if DEBUG
                print("[BigBrother] Registered schedule activity: \(activityName.rawValue) (\(window.startTime.hour):\(String(format: "%02d", window.startTime.minute))-\(window.endTime.hour):\(String(format: "%02d", window.endTime.minute)))")
                #endif
            } catch {
                #if DEBUG
                print("[BigBrother] Failed to register schedule activity: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Clear all schedule profile activities and remove stored profile.
    static func clearAll(storage: any SharedStorageProtocol) {
        clearAll(center: DeviceActivityCenter())
        try? storage.writeActiveScheduleProfile(nil)
    }

    /// Clear all schedule profile activities from DeviceActivityCenter.
    private static func clearAll(center: DeviceActivityCenter) {
        for activity in center.activities {
            if activity.rawValue.hasPrefix(activityPrefix) {
                center.stopMonitoring([activity])
            }
        }
    }
}
