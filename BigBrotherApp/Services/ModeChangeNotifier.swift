import Foundation
import UserNotifications
import BigBrotherCore

/// Sends local notifications on the child device when the enforcement mode changes.
/// Deduplicates: only fires when the mode actually changes from the last notification.
enum ModeChangeNotifier {

    /// Last mode we notified about — prevents duplicate notifications when
    /// enforcement refreshes or reconciliation re-applies the same mode.
    private static var lastNotifiedMode: LockMode?

    /// Request notification permissions (called once during child setup).
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    /// Notify the child that the device mode has changed.
    /// Deduplicates: skips if mode matches the last notification sent.
    static func notify(newMode: LockMode, reason: String? = nil) {
        // Skip if we already notified about this mode.
        guard newMode != lastNotifiedMode else { return }
        lastNotifiedMode = newMode

        let content = UNMutableNotificationContent()

        switch newMode {
        case .unlocked:
            content.title = "Device Unlocked"
            content.body = reason ?? "All apps are now accessible."
            content.sound = .default
        case .restricted:
            content.title = "Device Restricted"
            content.body = reason ?? "Only allowed apps are available."
            content.sound = .default
        case .locked:
            content.title = "Device Locked"
            content.body = reason ?? "Only essential apps (Phone, Messages) are available."
            content.sound = .default
        case .lockedDown:
            content.title = "Device Locked Down"
            content.body = reason ?? "Only essential apps, no internet."
            content.sound = .default
        }

        content.categoryIdentifier = "MODE_CHANGE"

        // Fixed identifier — replaces the previous mode notification instead of stacking.
        let request = UNNotificationRequest(
            identifier: "mode-change",
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

    /// Format seconds as a human-readable duration, rounding up to the nearest minute.
    static func formatDuration(_ seconds: Int) -> String {
        let totalMinutes = (seconds + 59) / 60  // round up
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if hours > 0 && mins > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s") \(mins) min"
        } else if hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            return "\(mins) minute\(mins == 1 ? "" : "s")"
        }
    }

    /// Notify about a temporary unlock or extension.
    static func notifyTemporaryUnlock(durationSeconds: Int, isExtension: Bool = false) {
        let content = UNMutableNotificationContent()
        let durationStr = formatDuration(durationSeconds)
        if isExtension {
            content.title = "Unlock Extended"
            content.body = "Time extended — \(durationStr) total remaining."
        } else {
            content.title = "Temporary Unlock"
            content.body = "Device unlocked for \(durationStr)."
        }
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

    /// Notify that a penalty-offset unlock has started (device locked during penalty).
    static func notifyPenaltyStarted(penaltySeconds: Int, unlockSeconds: Int) {
        let content = UNMutableNotificationContent()
        let penaltyStr = formatDuration(penaltySeconds)
        let unlockStr = formatDuration(unlockSeconds)
        content.title = "Penalty Time"
        content.body = "Device locked for \(penaltyStr), then unlocked for \(unlockStr)."
        content.sound = .default
        content.categoryIdentifier = "MODE_CHANGE"

        let request = UNNotificationRequest(
            identifier: "mode-change-penalty-start",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Notify the child about a parent message.
    static func notifyParentMessage(text: String, from sender: String) {
        let content = UNMutableNotificationContent()
        content.title = "Message from \(sender)"
        content.body = text
        content.sound = .default
        content.categoryIdentifier = "PARENT_MESSAGE"
        let request = UNNotificationRequest(
            identifier: "parent-msg-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Notify about a schedule-triggered mode change.
    /// Deduplicates via lastNotifiedMode — same guard as notify().
    static func notifyScheduleChange(newMode: LockMode, windowName: String? = nil) {
        guard newMode != lastNotifiedMode else { return }
        lastNotifiedMode = newMode

        let content = UNMutableNotificationContent()

        switch newMode {
        case .unlocked:
            content.title = "Free Time Started"
            content.body = windowName.map { "\($0): All apps are now accessible." }
                ?? "Scheduled free time — all apps accessible."
        case .restricted, .locked, .lockedDown:
            content.title = "Free Time Ended"
            content.body = "Device locked — \(newMode.displayName) mode active."
        }

        content.sound = .default
        content.categoryIdentifier = "SCHEDULE_CHANGE"

        // Fixed identifier — replaces previous schedule notification.
        let request = UNNotificationRequest(
            identifier: "schedule-change",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
