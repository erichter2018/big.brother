import SwiftUI
import CloudKit
import UserNotifications
import BigBrotherCore
import FirebaseCore

// MARK: - Launch Diagnostics (inline to avoid cross-file resolution issues)

/// Writes breadcrumb messages to Documents/launch_log.txt.
/// Used to diagnose launch crashes that only occur without the debugger attached.
private enum _LaunchLog {
    static let url: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("launch_log.txt")

    static func start() {
        guard let url else { return }
        try? "=== Launch \(Date()) ===\n".write(to: url, atomically: true, encoding: .utf8)
    }

    static func log(_ msg: String) {
        guard let url else { return }
        let line = "[\(Date())] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        }
    }
}

// MARK: - App Entry Point

/// Main app entry point.
///
/// On launch:
/// 1. Creates AppState (reads role from Keychain)
/// 2. Connects AppDelegate for push notification handling
/// 3. Configures all services
/// 4. Validates CloudKit environment
/// 5. Performs restoration (child devices: reconciles enforcement state)
/// 6. Sets up CloudKit subscriptions for near-real-time command delivery
/// 7. Starts heartbeat for child devices
/// 8. Routes to the appropriate root view
@main
struct BigBrotherApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        _LaunchLog.start()
        _LaunchLog.log("App struct init")
        // Configure Firebase only if GoogleService-Info.plist is present.
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            _LaunchLog.log("Firebase configured")
        } else {
            _LaunchLog.log("Firebase: GoogleService-Info.plist not found, skipping")
        }
        self._appState = State(initialValue: MainActor.assumeIsolated { AppState() })
        _LaunchLog.log("AppState created, role=\(self._appState.wrappedValue.deviceRole)")
    }

    var body: some Scene {
        WindowGroup {
            RootRouter(appState: appState)
                .task {
                    await setupOnLaunch()
                }
        }
    }

    private func setupOnLaunch() async {
        _LaunchLog.log("setupOnLaunch started")

        // Clear badge and stale launch-needed notifications on launch.
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["app-launch-needed"])

        // Wire AppState into the AppDelegate for push notification handling.
        appDelegate.appState = appState

        // Skip heavy setup for unconfigured devices — services aren't needed during onboarding.
        guard appState.deviceRole != .unconfigured else {
            _LaunchLog.log("Unconfigured device — skipping setup")
            return
        }

        #if DEBUG
        // Install Darwin notification observers used by test_shield_cycle.sh
        // to inject mode-change commands without going through CloudKit.
        // Debug builds only — observer code is compiled out of release.
        TestCommandReceiver.install(appState: appState)
        // Parent-side receiver: harness posts a Darwin notification to the
        // parent phone, this calls AppState.sendCommand through the real
        // CK pipeline. Only installs when running as parent role.
        if appState.deviceRole == .parent {
            ParentTestCommandReceiver.install(appState: appState)
        }
        #endif

        // Record that the main app launched with this build number.
        // The Monitor extension checks this to prompt re-launch after updates.
        let launchDefaults = UserDefaults.appGroup
        launchDefaults?.set(AppConstants.appBuildNumber, forKey: AppGroupKeys.mainAppLastLaunchedBuild)

        // Clear build-mismatch DNS block if the Monitor set it (update is now complete).
        if launchDefaults?.bool(forKey: AppGroupKeys.buildMismatchDNSBlock) == true {
            launchDefaults?.removeObject(forKey: AppGroupKeys.buildMismatchDNSBlock)
            launchDefaults?.removeObject(forKey: AppGroupKeys.internetBlockedUntil)
        }

        // Configure all services (creates ManagedSettingsStore, CloudKit, etc.).
        _LaunchLog.log("Calling configureServices (role=\(appState.deviceRole))")
        appState.configureServices()
        _LaunchLog.log("configureServices complete")

        // Restore enforcement state (child devices). This is synchronous and fast.
        _LaunchLog.log("performRestoration starting")
        appState.performRestoration()
        _LaunchLog.log("performRestoration complete")
        appState.handleMainAppResponsive(reapplyEnforcement: false)

        // Safety net: re-apply enforcement after a short delay.
        // On Xcode reinstall, the OS may clear ManagedSettingsStore slightly after
        // the app launches, undoing the restoration above.
        if appState.deviceRole == .child {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                appState.performRestoration()
                _LaunchLog.log("Delayed re-restoration complete")
            }
        }

        // --- UI-presenting requests ---
        // DO NOT auto-fire multiple system prompts here — that floods the user with
        // simultaneous "Allow X" dialogs that are confusing and easy to mis-tap.
        // Instead, the PermissionFixerView walks through them one at a time.
        //
        // Detect "needs guided setup" by checking if FamilyControls auth is missing
        // or notDetermined. This works correctly even after app delete + reinstall
        // (App Group UserDefaults persist, but FC auth is reset on reinstall).
        if appState.deviceRole == .child {
            let permDefaults = UserDefaults.appGroup
            // b437 (parity fix): Respect `permissionFixerCompletedOnce` the same
            // way AppDelegate.setGuidedSetupFlagIfNeeded does. Without this,
            // a cold-start FC daemon briefly reporting .notDetermined would
            // re-arm the guided setup flag even though the user already
            // completed the fixer — pop the sheet up unnecessarily.
            let alreadyCompletedOnce = permDefaults?.bool(forKey: AppGroupKeys.permissionFixerCompletedOnce) == true
            let fcAuthStatus = appState.enforcement?.authorizationStatus
            let needsGuidedSetup = fcAuthStatus != .authorized

            if needsGuidedSetup && !alreadyCompletedOnce {
                // Set a flag the ChildHomeView reads to auto-show the fixer.
                // ALL other auto-prompts (notifications, location, FC auth) check
                // this flag and suppress themselves until the fixer takes over.
                permDefaults?.set(true, forKey: AppGroupKeys.showPermissionFixerOnNextLaunch)
                _LaunchLog.log("Child: needs guided setup (FC auth=\(fcAuthStatus?.rawValue ?? "nil")) — will auto-show PermissionFixerView")
            } else if needsGuidedSetup && alreadyCompletedOnce {
                _LaunchLog.log("Child: FC auth=\(fcAuthStatus?.rawValue ?? "nil") but permissionFixerCompletedOnce — not re-arming (user can open fixer manually if needed)")
            } else {
                _LaunchLog.log("Child: FC auth OK — no guided setup needed")
            }
        }

        // --- Background work (CloudKit, sync) — no UI presentation ---
        Task.detached {
            _LaunchLog.log("Task.detached started")

            // Bootstrap CloudKit schema (creates record types in Development environment).
            let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase
            _LaunchLog.log("CloudKit schema bootstrap starting")
            await CloudKitSchemaBootstrap.bootstrapIfNeeded(database: db)
            _LaunchLog.log("CloudKit schema bootstrap done")

            // Give CloudKit a moment to propagate newly created record types.
            try? await Task.sleep(for: .seconds(2))

            // Validate CloudKit environment.
            _LaunchLog.log("Checking CloudKit account status")
            let cloudKitStatus = await CloudKitEnvironment.checkAccountStatus()
            _LaunchLog.log("CloudKit status: \(cloudKitStatus)")
            if cloudKitStatus != .available {
                await MainActor.run {
                    appState.cloudKitStatusMessage = CloudKitEnvironment.statusDescription(cloudKitStatus)
                }
            }

            // Set up CloudKit subscriptions and sync.
            let role = await MainActor.run { appState.deviceRole }
            _LaunchLog.log("Setting up for role: \(role)")
            switch role {
            case .child:
                let (enrollment, childCloudKit) = await MainActor.run {
                    (appState.enrollmentState, appState.cloudKit)
                }
                if let enrollment {
                    await Self.setupSubscriptionsWithRetry(
                        cloudKit: childCloudKit,
                        familyID: enrollment.familyID,
                        deviceID: enrollment.deviceID
                    )
                }
                await MainActor.run { appState.startChildSync() }
                await appState.recoverModeIfNeeded()
                let syncCoordinator = await MainActor.run { appState.syncCoordinator }
                try? await syncCoordinator?.performFullSync()

                // Schedule BGTask for periodic heartbeat when app is suspended.
                await MainActor.run { appDelegate.scheduleHeartbeatRefresh() }

            case .parent:
                _LaunchLog.log("Parent: setting up subscriptions")
                let (familyID, parentCloudKit) = await MainActor.run {
                    (appState.parentState?.familyID, appState.cloudKit)
                }
                if let familyID {
                    _LaunchLog.log("Parent: familyID=\(familyID)")
                    await Self.setupSubscriptionsWithRetry(
                        cloudKit: parentCloudKit,
                        familyID: familyID,
                        deviceID: nil
                    )
                    _LaunchLog.log("Parent: subscriptions done")
                }
                _LaunchLog.log("Parent: refreshing dashboard")
                try? await appState.refreshDashboard()
                _LaunchLog.log("Parent: dashboard refreshed")

                // Start monitoring child device heartbeats for offline alerts.
                await MainActor.run {
                    let monitor = DeviceMonitor(appState: appState)
                    appState.deviceMonitor = monitor
                    monitor.startMonitoring()
                    appState.startUnlockRequestPolling()
                    _LaunchLog.log("Parent: DeviceMonitor + unlock request polling started")

                    // Initialize AllowanceTracker timer integration if enabled.
                    appState.initializeTimerServiceIfNeeded()
                }

                // Run CloudKit cleanup to prune old records.
                let ck = await MainActor.run { appState.cloudKit }
                if let familyID, let ck {
                    await CloudKitCleanupService.performCleanup(
                        cloudKit: ck,
                        familyID: familyID
                    )
                    _LaunchLog.log("Parent: CloudKit cleanup done")
                }

            case .unconfigured:
                break
            }
            _LaunchLog.log("Background setup complete")
        }
    }

    /// Retries CloudKit subscription setup up to 3 times with backoff.
    /// Critical for command delivery — silent failure means no push notifications.
    private static func setupSubscriptionsWithRetry(
        cloudKit: (any CloudKitServiceProtocol)?,
        familyID: FamilyID,
        deviceID: DeviceID?,
        maxAttempts: Int = 3
    ) async {
        for attempt in 1...maxAttempts {
            do {
                try await cloudKit?.setupSubscriptions(familyID: familyID, deviceID: deviceID)
                NSLog("[BigBrother] CK subscriptions setup OK (attempt \(attempt))")
                _LaunchLog.log("Subscriptions setup succeeded (attempt \(attempt))")
                return
            } catch {
                NSLog("[BigBrother] CK subscriptions setup FAILED (attempt \(attempt)/\(maxAttempts)): \(error)")
                _LaunchLog.log("Subscriptions setup failed (attempt \(attempt)/\(maxAttempts)): \(error)")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                }
            }
        }
    }
}
