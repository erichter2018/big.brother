import SwiftUI
import CloudKit
import BigBrotherCore

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
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootRouter(appState: appState)
                .task {
                    await setupOnLaunch()
                }
        }
    }

    private func setupOnLaunch() async {
        // Wire AppState into the AppDelegate for push notification handling.
        appDelegate.appState = appState

        // Skip heavy setup for unconfigured devices — services aren't needed during onboarding.
        guard appState.deviceRole != .unconfigured else { return }

        // Configure all services (creates ManagedSettingsStore, CloudKit, etc.).
        appState.configureServices()

        // Restore enforcement state (child devices). This is synchronous and fast.
        appState.performRestoration()

        // Run CloudKit and sync work in the background so it doesn't block UI.
        Task.detached {
            // Bootstrap CloudKit schema (creates record types in Development environment).
            let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase
            await CloudKitSchemaBootstrap.bootstrapIfNeeded(database: db)

            // Give CloudKit a moment to propagate newly created record types.
            try? await Task.sleep(for: .seconds(2))

            // Validate CloudKit environment.
            let cloudKitStatus = await CloudKitEnvironment.checkAccountStatus()
            if cloudKitStatus != .available {
                await MainActor.run {
                    appState.cloudKitStatusMessage = CloudKitEnvironment.statusDescription(cloudKitStatus)
                }
            }

            // Set up CloudKit subscriptions and sync.
            let role = await MainActor.run { appState.deviceRole }
            switch role {
            case .child:
                let enrollment = await MainActor.run { appState.enrollmentState }
                if let enrollment {
                    try? await appState.cloudKit?.setupSubscriptions(
                        familyID: enrollment.familyID,
                        deviceID: enrollment.deviceID
                    )
                }
                await MainActor.run { appState.startChildSync() }
                try? await appState.syncCoordinator?.performFullSync()

            case .parent:
                let familyID = await MainActor.run { appState.parentState?.familyID }
                if let familyID {
                    try? await appState.cloudKit?.setupSubscriptions(
                        familyID: familyID,
                        deviceID: nil
                    )
                }
                try? await appState.refreshDashboard()

            case .unconfigured:
                break
            }
        }
    }
}
