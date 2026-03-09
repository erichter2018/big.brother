import ManagedSettings
import BigBrotherCore

/// ShieldAction extension.
///
/// Handles button taps on the shield (blocked app) screen.
/// Called by the system when the user taps a button on the shield UI.
///
/// Responsibilities:
/// - Handle "OK" (primary) button → dismiss shield
/// - Handle "Request Unlock" (secondary) button → log request event
///   (future: could trigger a notification to the parent)
///
/// Constraints:
/// - Cannot make network calls
/// - Cannot present UI
/// - Must be fast — limited execution time
class BigBrotherShieldActionExtension: ShieldActionDelegate {

    private let storage = AppGroupStorage()

    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)

        case .secondaryButtonPressed:
            // Check if a temporary unlock is active — if so, defer to the base store.
            if let extState = storage.readExtensionSharedState(),
               extState.isTemporaryUnlock {
                completionHandler(.defer)
                return
            }
            logEvent(.appLaunchBlocked, details: "Unlock requested via shield button")
            completionHandler(.close)

        @unknown default:
            completionHandler(.close)
        }
    }

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        // Same handling for web domains.
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            logEvent(.appLaunchBlocked, details: "Web unlock requested via shield button")
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }

    override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            logEvent(.appLaunchBlocked, details: "Category unlock requested via shield button")
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }

    private func logEvent(_ type: EventType, details: String?) {
        let keychain = KeychainManager()
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        let entry = EventLogEntry(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            eventType: type,
            details: details
        )
        try? storage.appendEventLog(entry)
    }
}
