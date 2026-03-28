import Foundation
import UserNotifications
import BigBrotherCore

/// Posts local notifications when children request app unlocks.
///
/// Registers actionable notification categories so the parent can approve
/// directly from the notification (long-press). Actions:
/// - 15 minutes, 1 hour, 2 hours, For today, Allow always
///
/// The notification identifier encodes the device ID and request ID so
/// the action handler can route the command correctly.
enum UnlockRequestNotificationService {

    // MARK: - Category & Action IDs

    static let categoryID = "UNLOCK_REQUEST"

    enum ActionID: String {
        case unlock15min = "UNLOCK_15MIN"
        case unlock1hour = "UNLOCK_1HOUR"
        case unlock2hours = "UNLOCK_2HOURS"
        case unlockForToday = "UNLOCK_TODAY"
        case allowAlways = "ALLOW_ALWAYS"
    }

    // MARK: - Setup

    /// Register the notification category with action buttons.
    /// Call once at app launch (before any notifications are posted).
    static func registerCategory() {
        let actions: [UNNotificationAction] = [
            UNNotificationAction(identifier: ActionID.unlock15min.rawValue, title: "15 minutes"),
            UNNotificationAction(identifier: ActionID.unlock1hour.rawValue, title: "1 hour"),
            UNNotificationAction(identifier: ActionID.unlock2hours.rawValue, title: "2 hours"),
            UNNotificationAction(identifier: ActionID.unlockForToday.rawValue, title: "For today"),
            UNNotificationAction(identifier: ActionID.allowAlways.rawValue, title: "Allow always"),
        ]

        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Request notification permission if not already granted.
    static func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    // MARK: - Posting Notifications

    /// Check for new unlock requests in event logs and post notifications.
    ///
    /// Call this after refreshing events. Tracks which request IDs have already
    /// been notified via UserDefaults to avoid duplicates.
    static func checkAndNotify(
        events: [EventLogEntry],
        childDeviceIDs: Set<DeviceID>,
        childName: String,
        childProfileID: ChildProfileID? = nil
    ) {
        let unlockRequests = events.filter { event in
            event.eventType == .unlockRequested &&
            childDeviceIDs.contains(event.deviceID)
        }

        guard !unlockRequests.isEmpty else { return }

        let notifiedKey = "fr.bigbrother.notifiedUnlockRequests"
        let defaults = UserDefaults.standard
        var notifiedIDs = Set(defaults.stringArray(forKey: notifiedKey) ?? [])

        // Prune old entries (keep last 200).
        if notifiedIDs.count > 200 {
            notifiedIDs = Set(Array(notifiedIDs).suffix(200))
        }

        for request in unlockRequests {
            let idString = request.id.uuidString
            guard !notifiedIDs.contains(idString) else { continue }

            // 1. Precise deduplication by Request ID (standard).
            // (Handled by the guard above)

            // 2. High-signal deduplication by App Name + Device ID + Time.
            // If the same app is requested multiple times within 30 seconds,
            // ignore the duplicates (covers the case where child device logs twice).
            let appName = extractAppName(from: request.details)
            let dedupeKey = "notified-\(request.deviceID.rawValue)-\(appName)"
            let lastNotifiedTime = defaults.double(forKey: dedupeKey)
            let now = Date().timeIntervalSince1970
            
            if now - lastNotifiedTime < 30 {
                notifiedIDs.insert(idString) // Mark as "notified" so we don't check it again
                continue
            }

            // Only notify for requests from the last 30 minutes.
            guard request.timestamp.timeIntervalSinceNow > -1800 else {
                notifiedIDs.insert(idString)
                continue
            }

            postNotification(
                requestID: request.id,
                deviceID: request.deviceID,
                childName: childName,
                appName: appName,
                childProfileID: childProfileID
            )
            notifiedIDs.insert(idString)
            defaults.set(now, forKey: dedupeKey)
        }

        defaults.set(Array(notifiedIDs), forKey: notifiedKey)
    }

    private static func postNotification(
        requestID: UUID,
        deviceID: DeviceID,
        childName: String,
        appName: String,
        childProfileID: ChildProfileID?
    ) {
        let content = UNMutableNotificationContent()
        content.title = "\(childName) is requesting access"
        content.body = "Wants to use \(appName)"
        content.sound = .default
        content.categoryIdentifier = categoryID

        // Encode request context in userInfo for action handling.
        var userInfo: [String: Any] = [
            "requestID": requestID.uuidString,
            "deviceID": deviceID.rawValue,
            "appName": appName,
            "childName": childName
        ]
        if let childProfileID {
            userInfo["childProfileID"] = childProfileID.rawValue
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "unlock-\(requestID.uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Action Handling

    /// Handle a notification action response. Returns the command to send, or nil.
    static func handleAction(
        _ response: UNNotificationResponse
    ) -> (action: UnlockAction, requestID: UUID, deviceID: DeviceID, appName: String, childProfileID: ChildProfileID?)? {
        guard response.notification.request.content.categoryIdentifier == categoryID else {
            return nil
        }

        let userInfo = response.notification.request.content.userInfo
        guard let requestIDString = userInfo["requestID"] as? String,
              let requestID = UUID(uuidString: requestIDString),
              let deviceIDString = userInfo["deviceID"] as? String,
              let appName = userInfo["appName"] as? String else {
            return nil
        }
        let deviceID = DeviceID(rawValue: deviceIDString)
        let childProfileID = (userInfo["childProfileID"] as? String).map { ChildProfileID(rawValue: $0) }

        let action: UnlockAction
        switch response.actionIdentifier {
        case ActionID.unlock15min.rawValue:
            action = .temporaryUnlock(seconds: 900)
        case ActionID.unlock1hour.rawValue:
            action = .temporaryUnlock(seconds: 3600)
        case ActionID.unlock2hours.rawValue:
            action = .temporaryUnlock(seconds: 7200)
        case ActionID.unlockForToday.rawValue:
            action = .temporaryUnlock(seconds: secondsUntilMidnight())
        case ActionID.allowAlways.rawValue:
            action = .allowAlways
        case UNNotificationDefaultActionIdentifier:
            // Tapped the notification itself — open the app and navigate to child.
            action = .openApp
        default:
            return nil
        }

        return (action, requestID, deviceID, appName, childProfileID)
    }

    enum UnlockAction {
        case temporaryUnlock(seconds: Int)
        case allowAlways
        case openApp
    }

    // MARK: - Helpers

    private static func extractAppName(from details: String?) -> String {
        guard var details, details.hasPrefix("Requesting access to ") else {
            return "an app"
        }
        // Strip TOKEN payload if present.
        if let tokenRange = details.range(of: "\nTOKEN:") {
            details = String(details[..<tokenRange.lowerBound])
        }
        return String(details.dropFirst("Requesting access to ".count))
    }

    private static func secondsUntilMidnight() -> Int { Date.secondsUntilMidnight }
}
