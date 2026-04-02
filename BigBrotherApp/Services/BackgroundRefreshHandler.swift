import Foundation
import UIKit
import CloudKit
import os
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

    /// Minimum interval between push-triggered syncs (seconds).
    /// Pushes arriving faster than this are coalesced.
    private static let pushDebounceInterval: TimeInterval = 10

    /// Timestamp of last push-triggered sync (child path only).
    private static let _lastPushSyncLock = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private static var lastPushSync: Date {
        get { _lastPushSyncLock.withLock { $0 } }
        set { _lastPushSyncLock.withLock { $0 = newValue } }
    }

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

        let isParent = await MainActor.run { appState.parentState != nil }
        if isParent {
            #if DEBUG
            print("[BigBrother] CloudKit push received (parent) — refreshing dashboard...")
            #endif
            // Short delay for CloudKit index consistency.
            try? await Task.sleep(for: .seconds(0.5))
            do {
                try await appState.refreshDashboard()
                #if DEBUG
                print("[BigBrother] Parent dashboard refreshed after push")
                #endif
                return .newData
            } catch {
                #if DEBUG
                print("[BigBrother] Parent push refresh failed: \(error.localizedDescription)")
                #endif
                return .failed
            }
        } else {
            // Brief debounce — but schedule a delayed reprocess instead of dropping.
            // The delayed task goes through processIncomingCommands() which uses
            // ProcessingGate, preventing uncoordinated concurrent syncs.
            let elapsed = Date().timeIntervalSince(lastPushSync)
            if elapsed < 2 {
                #if DEBUG
                print("[BigBrother] Push debounced (\(Int(elapsed * 1000))ms) — scheduling delayed command processing")
                #endif
                // Schedule a delayed sync through the proper command processing gate.
                Task {
                    try? await Task.sleep(for: .seconds(2 - elapsed + 0.5))
                    try? await appState.commandProcessor?.processIncomingCommands()
                }
                return .newData
            }
            lastPushSync = Date()

            #if DEBUG
            print("[BigBrother] CloudKit push received (child) — waiting for index consistency...")
            #endif
            try? await Task.sleep(for: .seconds(0.5))

            do {
                await MainActor.run {
                    appState.handleMainAppResponsive(reapplyEnforcement: true)
                }
                // performQuickSync already includes commands + heartbeat + events.
                // No need for a separate forced heartbeat — it just doubles CloudKit writes.
                try await appState.syncCoordinator?.performQuickSync()
                await MainActor.run { appState.refreshLocalState() }
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
