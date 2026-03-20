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
///
/// Cross-midnight windows (e.g., 9:30 PM – 7:00 AM) are split into two
/// DeviceActivity registrations: evening (start→23:59) and morning (00:00→end).
/// Both use the same window ID so the Monitor maps them to the same ActiveWindow.
enum ScheduleRegistrar {

    /// Prefix for free-window schedule activities.
    static let activityPrefix = "bigbrother.scheduleprofile."
    /// Prefix for essential-window schedule activities.
    static let essentialPrefix = "bigbrother.essentialwindow."

    /// Suffix for the evening portion of a cross-midnight window.
    private static let eveningSuffix = ".pm"
    /// Suffix for the morning portion of a cross-midnight window.
    private static let morningSuffix = ".am"

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
            registerWindow(window, prefix: activityPrefix, label: "free", center: center)
        }

        // Register one DeviceActivity per essential window.
        for window in profile.essentialWindows {
            registerWindow(window, prefix: essentialPrefix, label: "essential", center: center)
        }
    }

    private static func registerWindow(_ window: ActiveWindow, prefix: String, label: String, center: DeviceActivityCenter) {
        if window.startTime < window.endTime {
            // Same-day window — register directly.
            let activityName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)")
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
                intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
                repeats: true
            )
            register(activityName, schedule: schedule, label: label, center: center)
        } else {
            // Cross-midnight window (e.g., 21:30 → 07:00).
            // Split into evening (21:30→23:59) and morning (00:00→07:00).
            // The Monitor's day-of-week check + ActiveWindow.contains() handle correctness.

            // Evening portion: start → 23:59
            let eveningName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)\(eveningSuffix)")
            let eveningSchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true
            )
            register(eveningName, schedule: eveningSchedule, label: "\(label)-pm", center: center)

            // Morning portion: 00:00 → end
            let morningName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)\(morningSuffix)")
            let morningSchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
                repeats: true
            )
            register(morningName, schedule: morningSchedule, label: "\(label)-am", center: center)
        }
    }

    private static func register(_ name: DeviceActivityName, schedule: DeviceActivitySchedule, label: String, center: DeviceActivityCenter) {
        do {
            try center.startMonitoring(name, during: schedule)
            #if DEBUG
            print("[BigBrother] Registered \(label) activity: \(name.rawValue)")
            #endif
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to register \(label) activity: \(error.localizedDescription)")
            #endif
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
            if activity.rawValue.hasPrefix(activityPrefix) || activity.rawValue.hasPrefix(essentialPrefix) {
                center.stopMonitoring([activity])
            }
        }
    }
}
