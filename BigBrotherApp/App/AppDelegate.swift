import UIKit
import CloudKit
import BackgroundTasks
import UserNotifications
import BigBrotherCore

/// UIApplicationDelegate for handling push notifications and background tasks.
///
/// SwiftUI apps use @UIApplicationDelegateAdaptor to bridge UIKit lifecycle
/// events. This delegate handles:
/// - Remote notification registration
/// - CloudKit silent push delivery (CKQuerySubscription)
/// - BGTaskScheduler for periodic heartbeat refresh
///
/// The AppState reference is injected via the SwiftUI app entry point.
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Reference to the shared AppState, set by BigBrotherApp on launch.
    var appState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register for remote notifications to receive CloudKit silent pushes.
        BackgroundRefreshHandler.registerForRemoteNotifications()

        // Register BGTask for periodic heartbeat (child devices).
        registerBackgroundTasks()

        // Register unlock request notification category and set delegate.
        UnlockRequestNotificationService.registerCategory()
        UnlockRequestNotificationService.requestPermissionIfNeeded()
        UNUserNotificationCenter.current().delegate = self

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if DEBUG
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[BigBrother] Registered for remote notifications (token: \(tokenString.prefix(16))...)")
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("[BigBrother] Failed to register for remote notifications: \(error.localizedDescription)")
        #endif
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        #if DEBUG
        print("[BigBrother] didReceiveRemoteNotification called")
        #endif

        guard let appState else {
            #if DEBUG
            print("[BigBrother] No appState — ignoring push")
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
            print("[BigBrother] Push handling complete: \(result == .newData ? "newData" : result == .failed ? "failed" : "noData")")
            #endif
            completionHandler(result)
        }
    }

    // MARK: - BGTaskScheduler

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConstants.bgTaskHeartbeat,
            using: nil
        ) { [weak self] task in
            guard let bgTask = task as? BGAppRefreshTask else { return }
            self?.handleHeartbeatRefresh(bgTask)
        }
    }

    /// Schedule the next background heartbeat refresh.
    /// Called after each successful refresh and on app launch.
    func scheduleHeartbeatRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppConstants.bgTaskHeartbeat)
        // Ask iOS to wake us in ~15 minutes. iOS may delay this based on
        // usage patterns and system conditions, but it's the best we can do.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            print("[BGTask] Scheduled heartbeat refresh in ~15 min")
            #endif
        } catch {
            #if DEBUG
            print("[BGTask] Failed to schedule heartbeat refresh: \(error.localizedDescription)")
            #endif
        }
    }

    private func handleHeartbeatRefresh(_ task: BGAppRefreshTask) {
        #if DEBUG
        print("[BGTask] Heartbeat refresh task started")
        #endif

        // Schedule the next one immediately so there's always one pending.
        scheduleHeartbeatRefresh()

        guard let appState else {
            task.setTaskCompleted(success: false)
            return
        }

        let workTask = Task {
            do {
                // Process any pending commands first.
                try? await appState.commandProcessor?.processIncomingCommands()

                // Send a heartbeat.
                try await appState.heartbeatService?.sendNow(force: true)

                // Sync pending events.
                try? await appState.eventLogger?.syncPendingEvents()

                #if DEBUG
                print("[BGTask] Heartbeat refresh complete")
                #endif
                task.setTaskCompleted(success: true)
            } catch {
                #if DEBUG
                print("[BGTask] Heartbeat refresh failed: \(error.localizedDescription)")
                #endif
                task.setTaskCompleted(success: false)
            }
        }

        // If iOS kills the task, cancel our work.
        task.expirationHandler = {
            workTask.cancel()
            #if DEBUG
            print("[BGTask] Heartbeat refresh expired by system")
            #endif
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when app is in foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle notification action button taps.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let appState,
              let result = UnlockRequestNotificationService.handleAction(response) else {
            completionHandler()
            return
        }

        Task {
            switch result.action {
            case .temporaryUnlock(let seconds):
                await sendCommand(
                    .temporaryUnlockApp(requestID: result.requestID, durationSeconds: seconds),
                    target: .device(result.deviceID),
                    appState: appState
                )
                // Navigate to child detail.
                navigateToChild(result.childProfileID, deviceID: result.deviceID, appState: appState)
            case .allowAlways:
                await sendCommand(
                    .allowApp(requestID: result.requestID),
                    target: .device(result.deviceID),
                    appState: appState
                )
                // Track on parent side.
                appState.addApprovedApp(ApprovedApp(
                    id: result.requestID,
                    appName: result.appName,
                    deviceID: result.deviceID
                ))
                // Navigate to child detail.
                navigateToChild(result.childProfileID, deviceID: result.deviceID, appState: appState)
            case .openApp:
                // Just navigate to child detail.
                navigateToChild(result.childProfileID, deviceID: result.deviceID, appState: appState)
            }
            completionHandler()
        }
    }

    /// Set the navigation target to the child who owns the device.
    private func navigateToChild(_ childProfileID: ChildProfileID?, deviceID: DeviceID, appState: AppState) {
        if let childProfileID {
            appState.pendingChildNavigation = childProfileID
        } else {
            // Look up child profile from device ID.
            if let device = appState.childDevices.first(where: { $0.id == deviceID }) {
                appState.pendingChildNavigation = device.childProfileID
            }
        }
    }

    /// Send a command via CloudKit from notification action context.
    private func sendCommand(
        _ action: CommandAction,
        target: CommandTarget,
        appState: AppState
    ) async {
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }

        let command = RemoteCommand(
            familyID: familyID,
            target: target,
            action: action,
            issuedBy: "Parent"
        )

        do {
            try await cloudKit.pushCommand(command)
            #if DEBUG
            print("[BigBrother] Notification action: sent \(action.displayDescription)")
            #endif
        } catch {
            #if DEBUG
            print("[BigBrother] Notification action failed: \(error.localizedDescription)")
            #endif
        }
    }
}
