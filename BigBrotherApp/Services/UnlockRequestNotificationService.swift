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

    // MARK: - Posting Notifications

    /// Shared dedup store. 10-minute content window catches the kid tapping
    /// the same blocked app repeatedly. The `(deviceID, normalizedName)` and
    /// `(deviceID, fingerprint)` axes each get their own content key so
    /// either can suppress a duplicate.
    private static let dedupStore = NotificationDedupStore(
        configuration: .init(
            notifiedIDsKey: "fr.bigbrother.notifiedUnlockRequests",
            contentKeysKey: "fr.bigbrother.unlockRequestContentKeys",
            maxNotifiedIDs: 200,
            maxContentKeys: 200
        )
    )

    private static let contentWindow: TimeInterval = 600

    /// Check for new unlock requests in event logs and post notifications.
    ///
    /// Call this after refreshing events. Tracks which request IDs have already
    /// been notified via UserDefaults to avoid duplicates.
    static func checkAndNotify(
        events: [EventLogEntry],
        childDeviceIDs: Set<DeviceID>,
        childName: String,
        childProfileID: ChildProfileID? = nil,
        timeLimitConfigs: [TimeLimitConfig] = []
    ) {
        let unlockRequests = events.filter { event in
            event.eventType == .unlockRequested &&
            childDeviceIDs.contains(event.deviceID)
        }

        guard !unlockRequests.isEmpty else { return }

        struct ToPost {
            let requestID: UUID
            let deviceID: DeviceID
            let appName: String
            let fingerprint: String?
            let isMoreTimeRequest: Bool
        }

        let toPost: [ToPost] = dedupStore.withLock { state in
            var items: [ToPost] = []

            for request in unlockRequests {
                let idString = request.id.uuidString
                guard !state.hasNotified(idString) else { continue }

                var appName = extractAppName(from: request.details)
                let fingerprint = extractFingerprint(from: request.details)
                let isTimeRequest = Self.isMoreTimeRequest(details: request.details)

                if (appName == "an app" || appName == "App" || appName.isEmpty), let fp = fingerprint,
                   let config = timeLimitConfigs.first(where: { $0.appFingerprint == fp }) {
                    appName = config.appName
                }

                let normalizedName = appName
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let nameKey = "unlock:name:\(request.deviceID.rawValue):\(normalizedName)"
                let fpKey = "unlock:fp:\(request.deviceID.rawValue):\(fingerprint ?? "none")"

                if state.isRecentContentKey(nameKey, within: contentWindow) ||
                   state.isRecentContentKey(fpKey, within: contentWindow) {
                    state.markNotified(idString)
                    continue
                }

                guard request.timestamp.timeIntervalSinceNow > -1800 else {
                    state.markNotified(idString)
                    continue
                }

                state.recordContentKey(nameKey)
                state.recordContentKey(fpKey)
                state.markNotified(idString)
                items.append(ToPost(
                    requestID: request.id,
                    deviceID: request.deviceID,
                    appName: appName,
                    fingerprint: fingerprint,
                    isMoreTimeRequest: isTimeRequest
                ))
            }
            return items
        }

        for item in toPost {
            postNotification(
                requestID: item.requestID,
                deviceID: item.deviceID,
                childName: childName,
                appName: item.appName,
                fingerprint: item.fingerprint,
                childProfileID: childProfileID,
                isMoreTimeRequest: item.isMoreTimeRequest
            )
        }
    }

    private static func postNotification(
        requestID: UUID,
        deviceID: DeviceID,
        childName: String,
        appName: String,
        fingerprint: String?,
        childProfileID: ChildProfileID?,
        isMoreTimeRequest: Bool = false
    ) {
        let content = UNMutableNotificationContent()
        if isMoreTimeRequest {
            content.title = "\(childName) needs more time"
            content.body = "\(appName)'s daily limit reached. Grant extra time?"
        } else {
            content.title = "\(childName) is requesting access"
            content.body = "Wants to use \(appName)"
        }
        content.sound = .default
        content.categoryIdentifier = categoryID

        // Encode request context in userInfo for action handling.
        var userInfo: [String: Any] = [
            "requestID": requestID.uuidString,
            "deviceID": deviceID.rawValue,
            "appName": appName,
            "childName": childName,
            "isMoreTimeRequest": isMoreTimeRequest
        ]
        if let fingerprint { userInfo["fingerprint"] = fingerprint }
        if let childProfileID { userInfo["childProfileID"] = childProfileID.rawValue }
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
    ) -> (action: UnlockAction, requestID: UUID, deviceID: DeviceID, appName: String, childProfileID: ChildProfileID?, isMoreTimeRequest: Bool, fingerprint: String?)? {
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
        let isMoreTimeRequest = userInfo["isMoreTimeRequest"] as? Bool ?? false
        let fingerprint = userInfo["fingerprint"] as? String

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

        return (action, requestID, deviceID, appName, childProfileID, isMoreTimeRequest, fingerprint)
    }

    enum UnlockAction {
        case temporaryUnlock(seconds: Int)
        case allowAlways
        case openApp
    }

    // MARK: - Helpers

    private static func extractAppName(from details: String?) -> String {
        guard var details else { return "an app" }
        // Strip metadata lines.
        for prefix in ["\nFINGERPRINT:", "\nTOKEN:", "\nBUNDLE:"] {
            if let range = details.range(of: prefix) {
                details = String(details[..<range.lowerBound])
            }
        }
        if details.hasPrefix("Requesting more time for ") {
            return String(details.dropFirst("Requesting more time for ".count))
        }
        if details.hasPrefix("Requesting access to ") {
            return String(details.dropFirst("Requesting access to ".count))
        }
        return "an app"
    }

    /// Extract the token fingerprint from event details, if present.
    static func extractFingerprint(from details: String?) -> String? {
        guard let details, let range = details.range(of: "FINGERPRINT:") else { return nil }
        let afterPrefix = details[range.upperBound...]
        let fingerprint = afterPrefix.prefix(while: { $0 != "\n" })
        return fingerprint.isEmpty ? nil : String(fingerprint)
    }

    /// Whether the event details indicate a time-limit "more time" request (vs general unlock).
    static func isMoreTimeRequest(details: String?) -> Bool {
        details?.contains("Requesting more time for ") == true
    }

    private static func secondsUntilMidnight() -> Int { Date.secondsUntilMidnight }
}
