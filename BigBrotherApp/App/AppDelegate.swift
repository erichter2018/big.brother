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
        // FIRST THING: detect "needs guided setup" state synchronously and set the
        // suppression flag BEFORE any service can fire a permission prompt.
        // Without this, motion/location prompts triggered later by service
        // configuration fire at once on a fresh reinstall, flooding the user
        // with simultaneous system dialogs.
        Self.setGuidedSetupFlagIfNeeded()

        // Register for remote notifications to receive CloudKit silent pushes.
        BackgroundRefreshHandler.registerForRemoteNotifications()

        // Register BGTask for periodic heartbeat (child devices).
        registerBackgroundTasks()

        // Register unlock request notification category so `UNNotificationResponse`
        // actions (15m / 1h / Allow always) are available whenever the app
        // delivers a notification. Note: we do NOT ask for notification
        // permission here. That request is deferred to PermissionFixerView
        // so the kid sees an explanatory screen before the system prompt
        // fires, and the request happens from an explicit tap. Auto-firing
        // on every launch was the behavior the user flagged as noisy.
        UnlockRequestNotificationService.registerCategory()
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
        UserDefaults.appGroup?
            .set(Date().timeIntervalSince1970, forKey: AppGroupKeys.apnsTokenRegisteredAt)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("[BigBrother] APNs registration FAILED: \(error.localizedDescription)")
        UserDefaults.appGroup?
            .set("failed: \(error.localizedDescription)", forKey: AppGroupKeys.apnsTokenError)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NSLog("[BigBrother] PUSH RECEIVED: didReceiveRemoteNotification")
        UserDefaults.appGroup?
            .set(Date().timeIntervalSince1970, forKey: AppGroupKeys.lastPushReceivedAt)

        // Poke the VPN tunnel to poll for commands NOW, rather than waiting
        // for its 1-second cadence. Darwin notifications are delivered
        // synchronously across processes, so this shaves 0–1s off the apply
        // latency whenever iOS delivers our CKSubscription push promptly.
        // No-op if the tunnel is already polling or not running.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppConstants.darwinNotifTunnelPokeCommands as CFString),
            nil, nil, true
        )

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

    // MARK: - Background URLSession Wake (tunnel enforcement bridge)

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier.hasPrefix("bb.enforcement.wake") else {
            completionHandler()
            return
        }
        NSLog("[BigBrother] Background URLSession wake from tunnel — applying enforcement")

        let defaults = UserDefaults.appGroup
        let flagEpoch = defaults?.double(forKey: AppGroupKeys.needsEnforcementRefresh) ?? 0
        if flagEpoch > 0 {
            let store = ManagedSettingsStore(named: .init(rawValue: AppConstants.managedSettingsStoreEnforcement))
            let storage = AppGroupStorage()
            let resolution = ModeStackResolver.resolve(storage: storage)

            if resolution.mode == .unlocked {
                store.clearAllSettings()
            } else {
                if let tokenData = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                   let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: tokenData),
                   !tokens.isEmpty, resolution.mode == .restricted {
                    store.shield.applicationCategories = .all(except: tokens)
                } else {
                    store.shield.applicationCategories = .all()
                }
            }
            defaults?.removeObject(forKey: AppGroupKeys.needsEnforcementRefresh)
            defaults?.set(Date().timeIntervalSince1970, forKey: "bgURLSessionEnforcedAt")
            NSLog("[BigBrother] Background URLSession enforcement applied: \(resolution.mode.rawValue)")
        }
        completionHandler()
    }

    // MARK: - Guided Setup Detection

    /// Synchronously detect "needs guided setup" and set the suppression flag
    /// BEFORE any other code runs that might trigger system permission prompts.
    ///
    /// On a fresh reinstall, FC auth is reset to .notDetermined while the App Group
    /// UserDefaults and Keychain (enrollment) survive. We detect that state here and
    /// flip the flag so notifications/location/motion/FC/VPN prompts all suppress
    /// themselves until PermissionFixerView walks the user through them one at a time.
    static func setGuidedSetupFlagIfNeeded() {
        let keychain = KeychainManager()
        guard let role = try? keychain.get(DeviceRole.self, forKey: StorageKeys.deviceRole),
              role == .child else { return }
        let defaults = UserDefaults.appGroup

        // b439 (reinstall detection): Check if this is a fresh install or reinstall.
        // The App Group UserDefaults survive reinstall (where permissionFixerCompletedOnce
        // lives), but UserDefaults.standard is scoped to the app sandbox and IS wiped on
        // reinstall. We use a token in .standard as the authoritative "this install"
        // marker. On a reinstall, ALL permissions (VPN, Location, Motion, Notifications)
        // need to be re-granted since they're tied to the app sandbox, AND the
        // `permissionFixerCompletedOnce` flag in the App Group would otherwise falsely
        // claim the fixer already ran. Force the fixer to run on any fresh install or
        // reinstall regardless of FC status — we CAN'T trust FC auth as a reinstall
        // signal because iCloud Screen Time sync can preserve it across reinstalls.
        let installTokenKey = "fr.bigbrother.installToken"
        if UserDefaults.standard.string(forKey: installTokenKey) == nil {
            defaults?.removeObject(forKey: AppGroupKeys.permissionFixerCompletedOnce)
            defaults?.set(true, forKey: AppGroupKeys.showPermissionFixerOnNextLaunch)
            UserDefaults.standard.set(UUID().uuidString, forKey: installTokenKey)
            NSLog("[BigBrother] AppDelegate: fresh install/reinstall detected — forced showPermissionFixerOnNextLaunch, cleared permissionFixerCompletedOnce")
            return
        }

        // Not a fresh install. Respect the user's previous fixer completion — cold-start
        // FC daemon can briefly report .notDetermined even when auth is actually approved,
        // and we don't want to keep re-showing the "All Set" sheet on every foreground.
        if defaults?.bool(forKey: AppGroupKeys.permissionFixerCompletedOnce) == true { return }
        let fcStatus = AuthorizationCenter.shared.authorizationStatus
        if fcStatus != .approved {
            defaults?.set(true, forKey: AppGroupKeys.showPermissionFixerOnNextLaunch)
            NSLog("[BigBrother] AppDelegate: FC auth=\(fcStatus.rawValue) — setting guided setup flag to suppress prompts")
        }
    }

    // MARK: - Background Enforcement Restoration

    /// Lightweight enforcement restoration that runs directly from didFinishLaunching.
    /// Does NOT depend on AppState or the SwiftUI view hierarchy.
    ///
    /// b431: This used to duplicate ~150 lines of EnforcementServiceImpl.apply()
    /// logic, which created two separate writers to the same ManagedSettingsStore
    /// within the same process. Any divergence between AppDelegate's copy and
    /// EnforcementServiceImpl was a self-race waiting to happen. We now funnel
    /// through the canonical EnforcementServiceImpl.apply() path so there is a
    /// single writer in the main app process. The Monitor extension is a
    /// separate process and still has its own writer (which we can't unify
    /// without cross-process coordination).
    ///
    /// IMPORTANT: Do NOT perform nuclear resets or ManagedSettingsStore writes from
    /// background launches (push, BGTask, geofence). ManagedSettings writes are
    /// unreliable when backgrounded, and the existing shields from the previous
    /// session persist across launches — not writing is safer than writing wrong
    /// values that silently fail. Only the foreground path + Monitor should write.
    private func restoreEnforcementIfNeeded() {
        let keychain = KeychainManager()
        guard let role = try? keychain.get(DeviceRole.self, forKey: StorageKeys.deviceRole),
              role == .child else { return }

        // b439: If the guided setup fixer is about to run (fresh install /
        // reinstall), skip restoration entirely. The fixer will re-run
        // enforcement after the user has granted FC auth. Applying here would
        // trigger the deep-rescue recovery path which fires Screen Time
        // prompts ahead of the stepwise fixer flow.
        let defaults = UserDefaults.appGroup
        if defaults?.bool(forKey: AppGroupKeys.showPermissionFixerOnNextLaunch) == true {
            NSLog("[BigBrother] restoreEnforcementIfNeeded: guided setup active — deferring to PermissionFixerView")
            return
        }

        // ManagedSettingsStores persist across launches. Only write to them if
        // we're confident FC auth is ready — otherwise the existing shields from
        // the previous session are still active and correct.
        let authCenter = AuthorizationCenter.shared
        guard authCenter.authorizationStatus == .approved else {
            NSLog("[BigBrother] restoreEnforcementIfNeeded: FC auth not ready (status=\(authCenter.authorizationStatus.rawValue)) — previous shields still active, skipping write")
            return
        }

        let storage = AppGroupStorage()

        // Use ModeStackResolver as the single source of truth — it handles
        // temp unlocks, timed unlocks, lockUntil, schedule, and cleanup.
        let resolution = ModeStackResolver.resolve(storage: storage)

        // Force essential mode if permissions are missing.
        let effectiveMode: LockMode
        let permDefaults = UserDefaults.appGroup
        if permDefaults?.bool(forKey: AppGroupKeys.allPermissionsGranted) == false && resolution.mode != .locked {
            effectiveMode = .locked
        } else {
            effectiveMode = resolution.mode
        }

        // Check if we're actually in the foreground. ManagedSettings writes from
        // background launches (push, BGTask, geofence) are unreliable and can race
        // with the Monitor extension. Existing shields persist across launches, so
        // skipping the write is safer than writing wrong values that silently fail.
        //
        // b432: Use UIApplication.applicationState as the authoritative signal.
        // The previous version used `mainAppLastForegroundAt < 5s` which fails on
        // every cold launch (the timestamp is from the PREVIOUS session and is
        // always > 5s old), so cold-launch repair was never running. Apple sets
        // applicationState to .background only for background-launched apps;
        // user-initiated launches start in .inactive transitioning to .active.
        let uiAppState = UIApplication.shared.applicationState
        let isLikelyForeground = uiAppState != .background

        if !isLikelyForeground {
            // Background launch — don't touch ManagedSettingsStore. Schedule a
            // near-future one-shot DeviceActivity so the Monitor can apply
            // enforcement from its privileged context. The old stopMonitoring
            // trick didn't reliably wake the Monitor on iOS 17+.
            NSLog("[BigBrother] restoreEnforcementIfNeeded: background launch (state=\(uiAppState.rawValue)) — scheduling Monitor refresh")
            scheduleEnforcementRefreshActivity(source: "appDelegate.bgLaunch")
        } else {
            // Foreground — apply via canonical EnforcementServiceImpl path.
            // SINGLE WRITER within main app process. EnforcementServiceImpl
            // handles legacy store migration, mode dispatch, applyShield,
            // applyWebBlocking, applyRestrictions, post-write verification,
            // and ghost shield detection — everything we used to duplicate here.
            //
            // b432 (audit fix): Set mainAppLastForegroundAt BEFORE calling
            // apply(). EnforcementServiceImpl's internal verification-recovery
            // path uses this timestamp to decide whether it can safely do a
            // nuclear reset (foreground-only, since background writes silently
            // fail). On cold launch the timestamp is from a previous session,
            // so apply() would misclassify us as "background" exactly when we
            // most need the recovery. We already verified via
            // UIApplication.applicationState that this is a foreground launch,
            // so setting the timestamp is accurate.
            UserDefaults.appGroup?
                .set(Date().timeIntervalSince1970, forKey: AppGroupKeys.mainAppLastForegroundAt)

            let fcManager = FamilyControlsManagerImpl(storage: storage)
            let enforcement = EnforcementServiceImpl(storage: storage, fcManager: fcManager)

            // Build EffectivePolicy from current resolved state. Pull
            // allowedAppTokensData and policyVersion from the snapshot when
            // available so the apply path has the same context as a foreground
            // sync would.
            let snapshot = storage.readPolicySnapshot()
            let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            let isTempUnlock = resolution.isTemporary && effectiveMode == .unlocked
            let policy = EffectivePolicy(
                resolvedMode: effectiveMode,
                controlAuthority: resolution.controlAuthority,
                isTemporaryUnlock: isTempUnlock,
                temporaryUnlockExpiresAt: resolution.expiresAt,
                allowedAppTokensData: snapshot?.effectivePolicy.allowedAppTokensData,
                deviceRestrictions: restrictions,
                policyVersion: snapshot?.effectivePolicy.policyVersion ?? 0
            )

            // b439: Dispatch the apply() to a background queue. didFinishLaunching
            // runs on the main thread; a direct call here freezes the UI for 6+
            // seconds if apply() falls into the deep daemon rescue. Mark the
            // restoration timestamp BEFORE dispatching so AppLaunchRestorer's
            // 2-second skip window still covers the race against a later
            // performRestoration() call. The apply happens asynchronously; the
            // UI comes up immediately.
            UserDefaults.appGroup?
                .set(Date().timeIntervalSince1970, forKey: AppGroupKeys.appDelegateRestorationAt)
            let capturedEnforcement = enforcement
            let capturedPolicy = policy
            let capturedMode = effectiveMode
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try capturedEnforcement.apply(capturedPolicy)
                    NSLog("[BigBrother] restoreEnforcementIfNeeded: applied via EnforcementServiceImpl (background), mode=\(capturedMode.rawValue) reason=\(resolution.reason)")
                } catch {
                    NSLog("[BigBrother] restoreEnforcementIfNeeded: enforcement.apply failed: \(error.localizedDescription)")
                    try? AppGroupStorage().appendDiagnosticEntry(DiagnosticEntry(
                        category: .enforcement,
                        message: "AppDelegate restore enforcement.apply failed",
                        details: "mode=\(capturedMode.rawValue) error=\(error.localizedDescription)"
                    ))
                }
            }

            UserDefaults.appGroup?
                .set("backgroundRestore", forKey: AppGroupKeys.lastShieldChangeReason)
        } // end isLikelyForeground

        // Re-register reconciliation schedules so the Monitor extension keeps firing
        // even if DeviceActivity registrations were lost during an Xcode deploy or update.
        reregisterReconciliationSchedule()

        // If we were dead and the tunnel flagged us, grab location immediately.
        if let diedAt = defaults?.double(forKey: AppGroupKeys.appDiedNeedLocationAt), diedAt > 0 {
            defaults?.removeObject(forKey: AppGroupKeys.appDiedNeedLocationAt)
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
                warningTime: nil
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

        if let tap = AppReviewNotificationService.handleTap(response) {
            appState?.pendingChildNavigation = tap.childProfileID
            appState?.pendingReviewNeedsRefresh = true
            appState?.highlightedReviewID = tap.reviewID
            Task { try? await appState?.refreshDashboard() }
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
        let defaults = UserDefaults.appGroup ?? .standard
        let timestamp = defaults.double(forKey: AppGroupKeys.lastCommandProcessedAt)
        guard timestamp > 0 else { return false }
        return Date(timeIntervalSince1970: timestamp) >= date
    }
}
