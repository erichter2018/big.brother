import Foundation
import UserNotifications
import BigBrotherCore

enum ModeChangeNotifier {

    private static let dedupKey = "lastNotifiedMode"

    private static var lastNotifiedMode: LockMode? {
        get {
            guard let raw = UserDefaults.appGroup?.string(forKey: dedupKey) else { return nil }
            return LockMode(rawValue: raw)
        }
        set {
            UserDefaults.appGroup?.set(newValue?.rawValue, forKey: dedupKey)
        }
    }

    static func requestPermission() {
        let defaults = UserDefaults.appGroup
        if defaults?.bool(forKey: "showPermissionFixerOnNextLaunch") == true { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    static func notify(newMode: LockMode, reason: String? = nil) {
        guard newMode != lastNotifiedMode else { return }
        lastNotifiedMode = newMode

        let content = UNMutableNotificationContent()
        switch newMode {
        case .unlocked:
            content.title = "Device Unlocked"
            content.body = reason ?? "All apps are now accessible."
        case .restricted:
            content.title = "Restricted"
            content.body = reason ?? "Only allowed apps are available."
        case .locked:
            content.title = "Locked"
            content.body = reason ?? "Only essential apps are available."
        case .lockedDown:
            content.title = "Locked Down"
            content.body = reason ?? "Essential apps only, no internet."
        }
        content.sound = .default
        content.categoryIdentifier = "MODE_CHANGE"
        post("mode-change", content: content)
    }

    static func formatDuration(_ seconds: Int) -> String {
        let totalMinutes = (seconds + 59) / 60
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

    static func notifyTemporaryUnlock(durationSeconds: Int, isExtension: Bool = false) {
        lastNotifiedMode = .unlocked
        let content = UNMutableNotificationContent()
        let dur = formatDuration(durationSeconds)
        if isExtension {
            content.title = "Unlock Extended"
            content.body = "\(dur) total remaining."
        } else {
            content.title = "Unlocked for \(dur)"
            content.body = "All apps are accessible."
        }
        content.sound = .default
        content.categoryIdentifier = "MODE_CHANGE"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["mode-change"])
        post("mode-change", content: content)
    }

    static func notifyTemporaryUnlockExpired(restoredMode: LockMode) {
        lastNotifiedMode = restoredMode
        let content = UNMutableNotificationContent()
        content.title = "Unlock Expired"
        content.body = "Back to \(restoredMode.displayName) mode."
        content.sound = .default
        content.categoryIdentifier = "MODE_CHANGE"
        post("mode-change", content: content)
    }

    static func notifyPenaltyStarted(penaltySeconds: Int, unlockSeconds: Int) {
        let content = UNMutableNotificationContent()
        let penaltyStr = formatDuration(penaltySeconds)
        let unlockStr = formatDuration(unlockSeconds)
        content.title = "Penalty Time"
        content.body = "Locked for \(penaltyStr), then unlocked for \(unlockStr)."
        content.sound = .default
        content.categoryIdentifier = "MODE_CHANGE"
        post("mode-change", content: content)
    }

    static func notifyParentMessage(text: String, from sender: String) {
        let content = UNMutableNotificationContent()
        content.title = "Message from \(sender)"
        content.body = text
        content.sound = .default
        content.categoryIdentifier = "PARENT_MESSAGE"
        post("parent-msg-\(UUID().uuidString)", content: content)
    }

    static func notifyScheduleChange(newMode: LockMode, windowName: String? = nil) {
        guard newMode != lastNotifiedMode else { return }
        lastNotifiedMode = newMode

        let content = UNMutableNotificationContent()
        switch newMode {
        case .unlocked:
            content.title = "Free Time Started"
            content.body = windowName.map { "\($0): All apps accessible." }
                ?? "All apps accessible."
        case .restricted, .locked, .lockedDown:
            content.title = "Free Time Ended"
            content.body = "\(newMode.displayName) mode active."
        }
        content.sound = .default
        content.categoryIdentifier = "SCHEDULE_CHANGE"
        post("mode-change", content: content)
    }

    private static func post(_ identifier: String, content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            #if DEBUG
            if let error { print("[Notif] \(identifier) failed: \(error.localizedDescription)") }
            #endif
        }
    }
}
