import Foundation
import UserNotifications
import BigBrotherCore

/// Sends local notifications on the child device when the enforcement mode changes.
enum ModeChangeNotifier {

    /// Request notification permissions (called once during child setup).
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    /// Notify the child that the device mode has changed.
    static func notify(newMode: LockMode, reason: String? = nil) {
        let content = UNMutableNotificationContent()

        switch newMode {
        case .unlocked:
            content.title = "Device Unlocked"
            content.body = reason ?? "All apps are now accessible."
            content.sound = .default
        case .dailyMode:
            content.title = "Device Locked"
            content.body = reason ?? "Only allowed apps are available."
            content.sound = .default
        case .essentialOnly:
            content.title = "Essential Only Mode"
            content.body = reason ?? "Only essential apps (Phone, Messages) are available."
            content.sound = .default
        }

        content.categoryIdentifier = "MODE_CHANGE"

        let request = UNNotificationRequest(
            identifier: "mode-change-\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately.
        )

        UNUserNotificationCenter.current().add(request) { error in
            #if DEBUG
            if let error {
                print("[BigBrother] Mode notification failed: \(error.localizedDescription)")
            }
            #endif
        }
    }

    /// Notify about a temporary unlock.
    static func notifyTemporaryUnlock(durationSeconds: Int) {
        let content = UNMutableNotificationContent()
        let hours = durationSeconds / 3600
        let mins = (durationSeconds % 3600) / 60
        let durationStr: String
        if hours > 0 && mins > 0 {
            durationStr = "\(hours) hour\(hours == 1 ? "" : "s") \(mins) min"
        } else if hours > 0 {
            durationStr = "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            durationStr = "\(mins) minute\(mins == 1 ? "" : "s")"
        }
        content.title = "Temporary Unlock"
        content.body = "Device unlocked for \(durationStr)."
        content.sound = .default
        content.categoryIdentifier = "MODE_CHANGE"

        let request = UNNotificationRequest(
            identifier: "mode-change-temp-unlock",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Notify that a temporary unlock has expired.
    static func notifyTemporaryUnlockExpired(restoredMode: LockMode) {
        let content = UNMutableNotificationContent()
        content.title = "Temporary Unlock Expired"
        content.body = "Device returned to \(restoredMode.displayName) mode."
        content.sound = .default
        content.categoryIdentifier = "MODE_CHANGE"

        let request = UNNotificationRequest(
            identifier: "mode-change-temp-expired",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Notify about a schedule-triggered mode change.
    static func notifyScheduleChange(newMode: LockMode, windowName: String? = nil) {
        let content = UNMutableNotificationContent()

        switch newMode {
        case .unlocked:
            content.title = "Free Time Started"
            content.body = windowName.map { "\($0): All apps are now accessible." }
                ?? "Scheduled free time — all apps accessible."
        case .dailyMode, .essentialOnly:
            content.title = "Free Time Ended"
            content.body = "Device locked — \(newMode.displayName) mode active."
        }

        content.sound = .default
        content.categoryIdentifier = "SCHEDULE_CHANGE"

        let request = UNNotificationRequest(
            identifier: "schedule-change-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
