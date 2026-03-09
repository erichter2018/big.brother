import Foundation
import UIKit
import CloudKit
import BigBrotherCore

/// Handles background refresh and silent push notification wakeups.
///
/// Integration points:
/// - CloudKit CKQuerySubscription silent pushes wake the app
/// - UIApplication background fetch can trigger periodic sync
/// - BGTaskScheduler can schedule deferred work (future enhancement)
///
/// Flow when a silent push arrives:
/// 1. AppDelegate.didReceiveRemoteNotification is called
/// 2. BackgroundRefreshHandler.handleRemoteNotification runs
/// 3. SyncCoordinator performs a quick sync (commands + heartbeat)
/// 4. If command changes mode, enforcement is applied immediately
/// 5. Completion handler is called with the appropriate result
enum BackgroundRefreshHandler {

    /// Handle a CloudKit silent push notification.
    ///
    /// Called from `UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    /// Performs a quick sync cycle: fetch pending commands, process them,
    /// send heartbeat. The policy pipeline runs if a command changes mode.
    ///
    /// - Parameters:
    ///   - userInfo: The notification payload from CloudKit
    ///   - appState: The app's root state object
    /// - Returns: The fetch result to pass to the completion handler
    static func handleRemoteNotification(
        userInfo: [AnyHashable: Any],
        appState: AppState
    ) async -> UIBackgroundFetchResult {
        #if DEBUG
        print("[BigBrother] Received remote notification")
        #endif

        // Verify this is a CloudKit notification.
        guard let notification = CKNotificationFromUserInfo(userInfo) else {
            #if DEBUG
            print("[BigBrother] Not a CloudKit notification, ignoring")
            #endif
            return .noData
        }

        // Only process query notifications (from our CKQuerySubscription).
        guard notification is CKQueryNotification else {
            #if DEBUG
            print("[BigBrother] Not a query notification, ignoring")
            #endif
            return .noData
        }

        #if DEBUG
        print("[BigBrother] CloudKit push received — waiting for index consistency...")
        #endif

        // CloudKit fires the push immediately on record creation, but the query
        // index may not reflect the new record yet. Wait briefly so the fetch
        // actually returns the new command.
        try? await Task.sleep(for: .seconds(1.5))

        // Perform a quick sync: commands + heartbeat.
        do {
            try await appState.syncCoordinator?.performQuickSync()
            await MainActor.run { appState.refreshLocalState() }
            // Ensure heartbeat reflects new mode immediately.
            try? await appState.heartbeatService?.sendNow(force: true)
            #if DEBUG
            print("[BigBrother] Quick sync complete after push")
            #endif
            return .newData
        } catch {
            #if DEBUG
            print("[BigBrother] Quick sync failed: \(error.localizedDescription)")
            #endif
            return .failed
        }
    }

    /// Register for remote notifications.
    ///
    /// Must be called after app launch. The system requires explicit registration
    /// before silent pushes from CKQuerySubscription will be delivered.
    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

// MARK: - CloudKit Notification Helper

/// Parse a CKNotification from the raw push userInfo dictionary.
/// Returns nil if the payload is not a CloudKit notification.
private func CKNotificationFromUserInfo(_ userInfo: [AnyHashable: Any]) -> CKNotification? {
    CKNotification(fromRemoteNotificationDictionary: userInfo)
}
