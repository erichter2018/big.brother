import UIKit
import CloudKit
import BigBrotherCore

/// UIApplicationDelegate for handling push notifications and background fetch.
///
/// SwiftUI apps use @UIApplicationDelegateAdaptor to bridge UIKit lifecycle
/// events. This delegate handles:
/// - Remote notification registration
/// - CloudKit silent push delivery (CKQuerySubscription)
/// - Background fetch scheduling (future)
///
/// The AppState reference is injected via the SwiftUI app entry point.
class AppDelegate: NSObject, UIApplicationDelegate {

    /// Reference to the shared AppState, set by BigBrotherApp on launch.
    var appState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register for remote notifications to receive CloudKit silent pushes.
        BackgroundRefreshHandler.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if DEBUG
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[BigBrother] ✅ Registered for remote notifications (token: \(tokenString.prefix(16))...)")
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("[BigBrother] ❌ Failed to register for remote notifications: \(error.localizedDescription)")
        #endif
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        #if DEBUG
        print("[BigBrother] 📩 didReceiveRemoteNotification called")
        #endif

        guard let appState else {
            #if DEBUG
            print("[BigBrother] ❌ No appState — ignoring push")
            #endif
            completionHandler(.noData)
            return
        }

        Task {
            let result = await BackgroundRefreshHandler.handleRemoteNotification(
                userInfo: userInfo,
                appState: appState
            )
            #if DEBUG
            print("[BigBrother] 📩 Push handling complete: \(result == .newData ? "newData" : result == .failed ? "failed" : "noData")")
            #endif
            completionHandler(result)
        }
    }
}
