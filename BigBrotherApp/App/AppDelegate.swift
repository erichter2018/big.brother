import UIKit
import CloudKit
import BackgroundTasks
import UserNotifications
import ManagedSettings
import FamilyControls
import DeviceActivity
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

        // Detect location-based relaunch. iOS kills the app and relaunches it
        // for significant location changes, geofence transitions, and visits.
        if launchOptions?[.location] != nil {
            #if DEBUG
            print("[BigBrother] App relaunched by location services")
            #endif
        }

        // Immediately restore enforcement for child devices. This is critical
        // for background launches (geofence, push, BGTask) where the SwiftUI
        // view hierarchy may not appear and the normal .task-based restoration
        // in BigBrotherApp.setupOnLaunch() won't run.
        restoreEnforcementIfNeeded()

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        NSLog("[BigBrother] APNs token registered: \(tokenString.prefix(16))...")
        // Write to App Group so diagnostic can report push status
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "apnsTokenRegisteredAt")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("[BigBrother] APNs registration FAILED: \(error.localizedDescription)")
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("failed: \(error.localizedDescription)", forKey: "apnsTokenError")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NSLog("[BigBrother] PUSH RECEIVED: didReceiveRemoteNotification")
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "lastPushReceivedAt")

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

    // MARK: - Background Enforcement Restoration

    /// Lightweight enforcement restoration that runs directly from didFinishLaunching.
    /// Does NOT depend on AppState or the SwiftUI view hierarchy.
    ///
    /// This mirrors the Monitor extension's applyShieldingToAllStores() logic:
    /// reads policy state from App Group storage and applies shields directly
    /// to ManagedSettingsStore. Idempotent — safe to run even when the foreground
    /// .task-based restoration will also run.
    private func restoreEnforcementIfNeeded() {
        let keychain = KeychainManager()
        guard let role = try? keychain.get(DeviceRole.self, forKey: StorageKeys.deviceRole),
              role == .child else { return }

        let storage = AppGroupStorage()

        // Use ModeStackResolver as the single source of truth — it handles
        // temp unlocks, timed unlocks, lockUntil, schedule, and cleanup.
        let resolution = ModeStackResolver.resolve(storage: storage)

        // If device should be unlocked (temp unlock, free window, etc.), clear shields.
        // ModeStackResolver already checked expiry and cleaned up stale state.

        // Force essential mode if permissions are missing.
        let effectiveMode: LockMode
        let permDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if permDefaults?.bool(forKey: "allPermissionsGranted") == false && resolution.mode != .locked {
            effectiveMode = .locked
        } else {
            effectiveMode = resolution.mode
        }

        // Apply shields to ManagedSettingsStore.
        let baseStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreBase))
        let scheduleStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreSchedule))
        let tempUnlockStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreTempUnlock))

        // Clear temp unlock store (no active temp unlock at this point).
        tempUnlockStore.shield.applications = nil
        tempUnlockStore.shield.applicationCategories = nil
        tempUnlockStore.shield.webDomainCategories = nil
        tempUnlockStore.shield.webDomains = nil

        switch effectiveMode {
        case .unlocked:
            // Free window or unlocked — set wide-open shields instead of clearing.
            // Avoids .child auth re-validation race on re-apply.
            let decoder = JSONDecoder()
            var allTokens = Set<ApplicationToken>()
            if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
               let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
                allTokens.formUnion(allowed)
            }
            if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
               let selection = try? decoder.decode(FamilyActivitySelection.self, from: data) {
                allTokens.formUnion(selection.applicationTokens)
            }
            for limit in storage.readAppTimeLimits() {
                if let token = try? decoder.decode(ApplicationToken.self, from: limit.tokenData) {
                    allTokens.insert(token)
                }
            }
            for s in [baseStore, scheduleStore] {
                s.shield.applications = nil
                s.shield.applicationCategories = allTokens.isEmpty ? nil : .all(except: allTokens)
                s.shield.webDomainCategories = nil
                s.shield.webDomains = nil
            }
            tempUnlockStore.shield.applications = nil
            tempUnlockStore.shield.applicationCategories = nil
            tempUnlockStore.shield.webDomainCategories = nil
            tempUnlockStore.shield.webDomains = nil

        case .restricted, .locked, .lockedDown:
            let allowExemptions = effectiveMode == .restricted
            let decoder = JSONDecoder()

            // Collect allowed tokens (parent-approved apps).
            var allowedTokens = Set<ApplicationToken>()
            if allowExemptions {
                if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                   let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
                    allowedTokens.formUnion(allowed)
                }
                let tempEntries = storage.readTemporaryAllowedApps()
                for entry in tempEntries where entry.isValid {
                    if let token = try? decoder.decode(ApplicationToken.self, from: entry.tokenData) {
                        allowedTokens.insert(token)
                    }
                }
            }

            // Load picker tokens (FamilyActivitySelection).
            var pickerTokens = Set<ApplicationToken>()
            if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
               let selection = try? decoder.decode(FamilyActivitySelection.self, from: data) {
                pickerTokens = selection.applicationTokens
            }

            // Web blocking: locked/lockedDown ALWAYS block web, restricted respects flag.
            let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            let shouldBlockWeb = !allowExemptions || restrictions.denyWebWhenLocked

            // Apply hybrid blocking (mirrors Monitor extension logic).
            if !pickerTokens.isEmpty && allowExemptions {
                let tokensToBlock = pickerTokens.subtracting(allowedTokens)
                let perAppTokens: Set<ApplicationToken>
                if tokensToBlock.count <= 50 {
                    perAppTokens = tokensToBlock
                } else {
                    let sorted = tokensToBlock.sorted { $0.hashValue < $1.hashValue }
                    perAppTokens = Set(sorted.prefix(50))
                }
                for s in [baseStore, scheduleStore] {
                    s.shield.applications = perAppTokens
                    s.shield.applicationCategories = .all(except: allowedTokens)
                    if shouldBlockWeb {
                        s.shield.webDomainCategories = .all()
                        // Domain allowlist enforced at VPN/DNS layer, not ManagedSettings.
                    } else {
                        s.shield.webDomainCategories = nil
                    }
                }
            } else {
                let apps: Set<ApplicationToken>? = allowExemptions ? nil : (pickerTokens.isEmpty ? nil : pickerTokens)
                for s in [baseStore, scheduleStore] {
                    s.shield.applications = apps
                    if allowedTokens.isEmpty {
                        s.shield.applicationCategories = .all()
                    } else {
                        s.shield.applicationCategories = .all(except: allowedTokens)
                    }
                    if shouldBlockWeb {
                        s.shield.webDomainCategories = .all()
                        // Domain allowlist enforced at VPN/DNS layer, not ManagedSettings.
                    } else {
                        s.shield.webDomainCategories = nil
                    }
                }
            }

            // Write DNS blocklist for the tunnel — previously missing from background restore.
            // Without this, shields are restored but DNS blocking stays empty until foreground.
            let encoder = JSONEncoder()
            let cache = storage.readAllCachedAppNames()
            let shieldedTokens = pickerTokens.subtracting(allowedTokens)
            var shieldedNames = Set<String>()
            for token in shieldedTokens {
                if let data = try? encoder.encode(token) {
                    let key = data.base64EncodedString()
                    if let name = cache[key], !name.hasPrefix("App ") {
                        shieldedNames.insert(name)
                    }
                }
            }
            var blockedDomains = Set<String>()
            for name in shieldedNames {
                blockedDomains.formUnion(DomainCategorizer.domainsForApp(name))
            }
            blockedDomains.formUnion(DomainCategorizer.dohResolverDomains)
            if restrictions.denyWebGamesWhenRestricted {
                blockedDomains.formUnion(DomainCategorizer.webGamingDomains)
            }
            // Only write if we computed something, or if the existing list is empty.
            // Preserves existing blocklist if our name cache is empty (cold start).
            if !blockedDomains.isEmpty || storage.readEnforcementBlockedDomains().isEmpty {
                try? storage.writeEnforcementBlockedDomains(blockedDomains)
            }
        }

        // Apply device restrictions on the default store.
        let r = storage.readDeviceRestrictions() ?? DeviceRestrictions()
        let defaultStore = ManagedSettingsStore()
        defaultStore.application.denyAppRemoval = r.denyAppRemoval ? true : nil
        defaultStore.media.denyExplicitContent = r.denyExplicitContent ? true : nil
        defaultStore.account.lockAccounts = r.lockAccounts ? true : nil
        defaultStore.dateAndTime.requireAutomaticDateAndTime = r.requireAutomaticDateAndTime ? true : nil

        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("backgroundRestore", forKey: "lastShieldChangeReason")

        // Re-register reconciliation schedules so the Monitor extension keeps firing
        // even if DeviceActivity registrations were lost during an Xcode deploy or update.
        reregisterReconciliationSchedule()

        // If we were dead and the tunnel flagged us, grab location immediately.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if let diedAt = defaults?.double(forKey: "appDiedNeedLocationAt"), diedAt > 0 {
            defaults?.removeObject(forKey: "appDiedNeedLocationAt")
            // CLLocationManager is already running from startContinuousTracking.
            // Just request an immediate fix + heartbeat.
            CLLocationManager().requestLocation()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .restoration,
                message: "Relaunch after death — requested immediate location fix"
            ))
        }

        #if DEBUG
        print("[BigBrother][BgRestore] Enforcement restored: mode=\(effectiveMode.rawValue) (\(resolution.reason))")
        #endif
    }

    /// Re-register the reconciliation schedule (4 quarter-day windows).
    /// Mirrors ScheduleManagerImpl.registerReconciliationSchedule() but
    /// runs from AppDelegate without needing AppState.
    private func reregisterReconciliationSchedule() {
        let center = DeviceActivityCenter()
        let quarters: [(name: String, startHour: Int, endHour: Int)] = [
            ("bigbrother.reconciliation.q0", 0, 5),
            ("bigbrother.reconciliation.q1", 6, 11),
            ("bigbrother.reconciliation.q2", 12, 17),
            ("bigbrother.reconciliation.q3", 18, 23),
        ]
        for q in quarters {
            let activityName = DeviceActivityName(rawValue: q.name)
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: q.startHour, minute: 0),
                intervalEnd: DateComponents(hour: q.endHour, minute: 59),
                repeats: true,
                warningTime: DateComponents(hour: 3)
            )
            do {
                try center.startMonitoring(activityName, during: schedule)
            } catch {
                NSLog("[AppDelegate] Failed to register \(q.name): \(error)")
            }
        }
        let count = center.activities.filter { $0.rawValue.hasPrefix("bigbrother.reconciliation") }.count
        NSLog("[AppDelegate] Reconciliation: \(count) quarters registered")
    }

    // MARK: - BGTaskScheduler

    private func registerBackgroundTasks() {
        // BGTaskScheduler.register() returns Void but can fail silently if
        // the identifier is not declared in Info.plist or if called too late.
        // We wrap in a do/catch and verify by attempting an immediate submit.

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConstants.bgTaskHeartbeat,
            using: nil
        ) { [weak self] task in
            guard let bgTask = task as? BGAppRefreshTask else { return }
            self?.handleHeartbeatRefresh(bgTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConstants.bgTaskRelock,
            using: nil
        ) { [weak self] task in
            guard let bgTask = task as? BGProcessingTask else { return }
            self?.handleRelockTask(bgTask)
        }

        // Verify registration succeeded by scheduling — submit() throws if
        // the identifier was never registered (e.g., missing from Info.plist).
        verifyBGTaskRegistration()
    }

    /// Attempt a test submit to confirm BGTask identifiers are properly registered.
    /// Logs a diagnostic on failure so we can catch Info.plist mismatches early.
    private func verifyBGTaskRegistration() {
        let testRequest = BGAppRefreshTaskRequest(identifier: AppConstants.bgTaskHeartbeat)
        testRequest.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        do {
            try BGTaskScheduler.shared.submit(testRequest)
            #if DEBUG
            print("[BGTask] Heartbeat task registered and scheduled successfully")
            #endif
        } catch {
            let storage = AppGroupStorage()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "BGTask heartbeat registration/submit FAILED",
                details: "\(error.localizedDescription) — check Info.plist BGTaskSchedulerPermittedIdentifiers"
            ))
            #if DEBUG
            print("[BGTask] WARNING: Heartbeat task submit failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Schedule the next background heartbeat refresh.
    /// Called after each successful refresh and on app launch.
    func scheduleHeartbeatRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppConstants.bgTaskHeartbeat)
        // Ask iOS to wake us in ~5 minutes. iOS may delay this based on
        // usage patterns and system conditions. Shorter interval improves
        // command delivery latency when the app is backgrounded.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            print("[BGTask] Scheduled heartbeat refresh in ~5 min")
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

        let workStartedAt = Date()
        let workTask = Task {
            do {
                // Check for expired unlocks and re-lock if needed (safety net).
                await MainActor.run {
                    appState.handleMainAppResponsive(reapplyEnforcement: true)
                    self.checkAndRelockExpiredUnlocks(appState: appState)
                }

                // Process any pending commands first.
                try? await appState.commandProcessor?.processIncomingCommands()

                // Send a normal heartbeat if command processing did not already
                // request an immediate confirmation heartbeat.
                if !Self.didProcessCommands(since: workStartedAt) {
                    try await appState.heartbeatService?.sendNow(force: false)
                }

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
            task.setTaskCompleted(success: false)
            #if DEBUG
            print("[BGTask] Heartbeat refresh expired by system")
            #endif
        }
    }

    // MARK: - Enforcement Safety Net

    /// Check for expired temporary/timed unlocks and schedule transitions, then re-lock/unlock as needed.
    /// Called from both the heartbeat BGTask and the re-lock BGProcessingTask.
    @MainActor
    private func checkAndRelockExpiredUnlocks(appState: AppState) {
        let now = Date()

        // Check expired temporary unlock.
        if let unlockState = appState.storage.readTemporaryUnlockState(),
           unlockState.expiresAt <= now {
            appState.applyTimedUnlockEnd()
            #if DEBUG
            print("[BGTask] Safety net: cleared expired temporary unlock")
            #endif
        }

        // Re-read timed info (applyTimedUnlockEnd may have cleared it above).
        if let timedInfo = appState.storage.readTimedUnlockInfo() {
            if now < timedInfo.unlockAt {
                // Still in penalty phase — ensure device is locked.
                appState.enforcePenaltyPhaseLock()
            } else if now >= timedInfo.unlockAt && now < timedInfo.lockAt {
                // Should be in free phase — ensure device is unlocked.
                appState.applyTimedUnlockStart()
            } else if now >= timedInfo.lockAt {
                // Past lock time — re-lock.
                appState.applyTimedUnlockEnd()
            }
        }

        // Check schedule transitions (free window start/end).
        appState.enforceScheduleTransition()
        // Schedule the next BGTask for the upcoming schedule transition.
        appState.scheduleNextScheduleBGTask()
    }

    // MARK: - Re-lock BGProcessingTask

    /// Schedule a BGProcessingTask to fire at the given date.
    /// Called when a temporary or timed unlock is created.
    /// Static so it can be called from CommandProcessor/AppState without a reference to AppDelegate.
    static func scheduleRelockTask(at date: Date) {
        let request = BGProcessingTaskRequest(identifier: AppConstants.bgTaskRelock)
        request.earliestBeginDate = date
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Log in all builds — failed BGTask = reduced safety net for re-lock.
            let storage = AppGroupStorage()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "BGTask re-lock schedule FAILED — DeviceActivity schedule is primary safety net",
                details: "Target: \(date) — \(error.localizedDescription)"
            ))
            // Schedule a local notification at expiry as a last-resort wakeup.
            // When the user taps it, the app launches and the 60s enforcement loop catches it.
            let content = UNMutableNotificationContent()
            content.title = "Big Brother"
            content.body = "Checking enforcement status..."
            content.sound = nil
            let interval = max(1, date.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: "relock-fallback", content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    private func handleRelockTask(_ task: BGProcessingTask) {
        #if DEBUG
        print("[BGTask] Re-lock task started")
        #endif

        guard let appState else {
            task.setTaskCompleted(success: false)
            return
        }

        let workStartedAt = Date()
        let workTask = Task { @MainActor in
            appState.handleMainAppResponsive(reapplyEnforcement: true)
            self.checkAndRelockExpiredUnlocks(appState: appState)

            // Also process commands, send heartbeat, and sync events
            // since we're awake anyway.
            try? await appState.commandProcessor?.processIncomingCommands()
            if !Self.didProcessCommands(since: workStartedAt) {
                try? await appState.heartbeatService?.sendNow(force: false)
            }
            try? await appState.eventLogger?.syncPendingEvents()

            #if DEBUG
            print("[BGTask] Re-lock task complete")
            #endif
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            workTask.cancel()
            task.setTaskCompleted(success: false)
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
        // Child-side: "Extra Time Granted" notification from tunnel.
        if response.notification.request.identifier.hasPrefix("extra-time-") {
            let body = response.notification.request.content.body
            // e.g. "Tap to start using Doodle Buddy"
            let appName = body.replacingOccurrences(of: "Tap to start using ", with: "")
            appState?.childConfirmationMessage = "\(appName) — extra time granted!"
            // Auto-dismiss after 5 seconds.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self.appState?.childConfirmationMessage = nil
            }
            completionHandler()
            return
        }

        guard let appState,
              let result = UnlockRequestNotificationService.handleAction(response) else {
            completionHandler()
            return
        }

        Task {
            // Delete the request event from CloudKit immediately so it doesn't reappear.
            try? await appState.cloudKit?.deleteEventLog(result.requestID)
            // Clear blue dot for this child.
            if let childProfileID = result.childProfileID {
                appState.childrenWithPendingRequests.remove(childProfileID)
            }

            switch result.action {
            case .temporaryUnlock(let seconds):
                if result.isMoreTimeRequest, let fp = result.fingerprint {
                    let minutes = max(1, seconds / 60)
                    await sendCommand(
                        .grantExtraTime(appFingerprint: fp, extraMinutes: minutes),
                        target: .device(result.deviceID),
                        appState: appState
                    )
                } else if result.isMoreTimeRequest {
                    let minutes = max(1, seconds / 60)
                    let vm = appState.childDetailViewModel(forDeviceID: result.deviceID)
                    if let config = vm?.timeLimitConfigs.first(where: { $0.appName == result.appName }) {
                        await sendCommand(
                            .grantExtraTime(appFingerprint: config.appFingerprint, extraMinutes: minutes),
                            target: .device(result.deviceID),
                            appState: appState
                        )
                    } else {
                        await sendCommand(
                            .temporaryUnlockApp(requestID: result.requestID, durationSeconds: seconds),
                            target: .device(result.deviceID),
                            appState: appState
                        )
                    }
                } else {
                    await sendCommand(
                        .temporaryUnlockApp(requestID: result.requestID, durationSeconds: seconds),
                        target: .device(result.deviceID),
                        appState: appState
                    )
                }
                navigateToChild(result.childProfileID, deviceID: result.deviceID, appState: appState)
            case .allowAlways:
                let success = await sendCommand(
                    .allowApp(requestID: result.requestID),
                    target: .device(result.deviceID),
                    appState: appState
                )
                // Only track on parent side if command was delivered successfully.
                if success {
                    appState.addApprovedApp(ApprovedApp(
                        id: result.requestID,
                        appName: result.appName,
                        deviceID: result.deviceID
                    ))
                }
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

    /// Send a command via CloudKit from notification action context. Returns true on success.
    @discardableResult
    private func sendCommand(
        _ action: CommandAction,
        target: CommandTarget,
        appState: AppState
    ) async -> Bool {
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return false }

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
            return true
        } catch {
            #if DEBUG
            print("[BigBrother] Notification action failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    private static func didProcessCommands(since date: Date) -> Bool {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
        let timestamp = defaults.double(forKey: "fr.bigbrother.lastCommandProcessedAt")
        guard timestamp > 0 else { return false }
        return Date(timeIntervalSince1970: timestamp) >= date
    }
}
