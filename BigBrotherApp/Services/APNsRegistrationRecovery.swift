import Foundation
import UIKit
import UserNotifications
import BigBrotherCore

/// Defensive re-registration for Apple Push Notification service.
///
/// Why this exists: `UIApplication.shared.registerForRemoteNotifications()`
/// is called unconditionally in `AppDelegate.didFinishLaunchingWithOptions`.
/// If the user hasn't granted notification authorization yet at that moment
/// (first launch, pre-PermissionFixer flow), **iOS silently no-ops the call**
/// — no token, no error, no callback. The user later grants permission via
/// `PermissionFixerView` and nothing re-kicks APNs registration, so the
/// device permanently runs without a push token and every parent command
/// has to wait out the REST-polling fallback.
///
/// This helper runs on every scene-becomes-active transition and re-calls
/// `registerForRemoteNotifications()` if:
///   * notifications are currently `.authorized`, AND
///   * we have never recorded an `apnsTokenRegisteredAt` timestamp in the
///     App Group.
///
/// The re-register is a cheap no-op when the token was already issued; iOS
/// deduplicates the call via the already-cached device token.
enum APNsRegistrationRecovery {

    /// Call from the scenePhase=.active hook and from PermissionFixerView
    /// after the user grants notifications. Idempotent.
    @MainActor
    static func reRegisterIfNeeded() {
        let defaults = UserDefaults.appGroup
        let registeredAt = defaults?.double(forKey: AppGroupKeys.apnsTokenRegisteredAt) ?? 0
        guard registeredAt == 0 else { return }

        // Check auth status. If denied, there's no point re-registering —
        // iOS will silently no-op until the user changes their mind in
        // Settings, at which point the next scenePhase=.active tick will
        // catch it.
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional || status == .ephemeral else {
                return
            }
            // Check again inside the Task — another tick may have already
            // triggered registration while we awaited.
            let latest = UserDefaults.appGroup?.double(forKey: AppGroupKeys.apnsTokenRegisteredAt) ?? 0
            guard latest == 0 else { return }

            await MainActor.run {
                BBLog("[APNsRecovery] No APNs token registered yet — re-calling registerForRemoteNotifications (auth=\(status.rawValue))")
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
}
