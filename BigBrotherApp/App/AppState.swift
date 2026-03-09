import Foundation
import Observation
import BigBrotherCore

/// Root application state, observable by SwiftUI views.
///
/// Holds the current device role, enrollment state, and references
/// to all core services. Initialized on app launch by reading from Keychain.
/// Services are created after role detection because some depend on enrollment state.
@Observable
final class AppState {

    // MARK: - Role & Identity

    /// This device's role, read from Keychain on init.
    private(set) var deviceRole: DeviceRole = .unconfigured

    /// Enrollment state (child devices only).
    private(set) var enrollmentState: ChildEnrollmentState?

    /// Parent state (parent devices only).
    private(set) var parentState: ParentState?

    // MARK: - Runtime State

    /// Whether the parent has authenticated in this session.
    var isParentAuthenticated: Bool = false

    /// Child profiles (parent mode — fetched from CloudKit).
    var childProfiles: [ChildProfile] = []

    /// All enrolled devices (parent mode — fetched from CloudKit).
    var childDevices: [ChildDevice] = []

    /// Latest heartbeats for all devices (parent mode).
    var latestHeartbeats: [DeviceHeartbeat] = []

    /// Current effective policy (child mode — from local snapshot).
    var currentEffectivePolicy: EffectivePolicy?

    /// Active capability warnings.
    var activeWarnings: [CapabilityWarning] = []

    /// Whether initial restoration has completed.
    private(set) var isRestored: Bool = false

    /// CloudKit account status message (nil when available).
    var cloudKitStatusMessage: String?

    // MARK: - Services

    private(set) var cloudKit: (any CloudKitServiceProtocol)?
    private(set) var enforcement: (any EnforcementServiceProtocol)?
    private(set) var auth: (any AuthServiceProtocol)?
    private(set) var enrollment: (any EnrollmentServiceProtocol)?
    private(set) var commandProcessor: (any CommandProcessorProtocol)?
    private(set) var heartbeatService: (any HeartbeatServiceProtocol)?
    private(set) var eventLogger: (any EventLoggerProtocol)?
    private(set) var syncCoordinator: (any SyncCoordinatorProtocol)?

    /// The authoritative store for policy snapshots.
    private(set) var snapshotStore: PolicySnapshotStore?

    // MARK: - Dependencies

    let keychain: any KeychainProtocol
    let storage: any SharedStorageProtocol

    // MARK: - Initialization

    init(
        keychain: any KeychainProtocol = KeychainManager(),
        storage: any SharedStorageProtocol = AppGroupStorage()
    ) {
        self.keychain = keychain
        self.storage = storage
        loadRole()
    }

    /// Read role and enrollment state from Keychain.
    private func loadRole() {
        deviceRole = (try? keychain.get(DeviceRole.self, forKey: StorageKeys.deviceRole))
            ?? .unconfigured

        switch deviceRole {
        case .child:
            enrollmentState = try? keychain.get(
                ChildEnrollmentState.self,
                forKey: StorageKeys.enrollmentState
            )
        case .parent:
            parentState = try? keychain.get(
                ParentState.self,
                forKey: StorageKeys.parentState
            )
        case .unconfigured:
            break
        }
    }

    /// Whether FamilyControls/ManagedSettings are available.
    /// These frameworks crash without the FamilyControls entitlement approved by Apple.
    private(set) var familyControlsAvailable: Bool = false

    /// Create and wire all services. Called after init because some services
    /// depend on knowing the device role and enrollment state.
    func configureServices() {
        let ck = CloudKitServiceImpl()
        self.cloudKit = ck

        // Create the snapshot store.
        let snapStore = PolicySnapshotStore(storage: storage)
        self.snapshotStore = snapStore

        let authImpl = AuthServiceImpl(keychain: keychain, storage: storage)
        self.auth = authImpl

        let enrollmentImpl = EnrollmentServiceImpl(cloudKit: ck, keychain: keychain, storage: storage)
        self.enrollment = enrollmentImpl

        let loggerImpl = EventLoggerImpl(cloudKit: ck, storage: storage, keychain: keychain)
        self.eventLogger = loggerImpl

        // FamilyControls/ManagedSettings crash without Apple-approved entitlement.
        // Guard their creation so the app remains usable for UI testing and parent setup.
        let enforcementImpl: EnforcementServiceImpl?
        if Self.isFamilyControlsSafe() {
            let fcManager = FamilyControlsManagerImpl(storage: storage)
            let impl = EnforcementServiceImpl(storage: storage, fcManager: fcManager)
            self.enforcement = impl
            enforcementImpl = impl
            familyControlsAvailable = true

            fcManager.observeAuthorizationChanges { [weak self] newStatus in
                guard let self else { return }
                self.handleAuthorizationChange(newStatus)
            }
        } else {
            enforcementImpl = nil
            #if DEBUG
            print("[BigBrother] ⚠️ FamilyControls unavailable — enforcement disabled")
            #endif
        }

        // Command processing, heartbeat, and sync work regardless of enforcement.
        // When enforcement is nil, commands are processed but not applied to device restrictions.
        let cmdProcessor = CommandProcessorImpl(
            cloudKit: ck,
            storage: storage,
            keychain: keychain,
            enforcement: enforcementImpl,
            eventLogger: loggerImpl,
            snapshotStore: snapStore
        )
        self.commandProcessor = cmdProcessor

        let hbService = HeartbeatServiceImpl(
            cloudKit: ck,
            keychain: keychain,
            storage: storage,
            enforcement: enforcementImpl
        )
        self.heartbeatService = hbService

        let syncImpl = SyncCoordinatorImpl(
            cloudKit: ck,
            commandProcessor: cmdProcessor,
            heartbeat: hbService,
            eventLogger: loggerImpl,
            storage: storage,
            keychain: keychain,
            enforcement: enforcementImpl,
            snapshotStore: snapStore
        )
        self.syncCoordinator = syncImpl
    }

    /// Check if FamilyControls APIs can be used without crashing.
    /// ManagedSettingsStore and AuthorizationCenter crash at runtime if the
    /// com.apple.developer.family-controls entitlement is not in the provisioning profile.
    private static func isFamilyControlsSafe() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        // Test if FamilyControls is usable by accessing AuthorizationCenter.
        // If the entitlement is missing, this will crash — but we wrap it
        // so the rest of the app keeps working.
        // On devices with the entitlement provisioned, this succeeds.
        return _checkFamilyControlsAccess()
        #endif
    }

    /// Separate function so a crash here doesn't take down the caller's stack frame.
    private static func _checkFamilyControlsAccess() -> Bool {
        // If FamilyControls entitlement is missing, accessing AuthorizationCenter.shared
        // triggers EXC_BREAKPOINT. There's no safe way to catch that. Instead, check
        // the provisioning profile for the entitlement string.
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profileData = try? Data(contentsOf: profileURL),
              let profileString = String(data: profileData, encoding: .ascii) else {
            // No provisioning profile — likely dev-signed without profile.
            // Optimistically try if running on device with automatic signing.
            #if DEBUG
            print("[BigBrother] No embedded.mobileprovision found — trying FamilyControls optimistically")
            #endif
            return true
        }
        let hasFamilyControls = profileString.contains("com.apple.developer.family-controls")
        #if DEBUG
        print("[BigBrother] FamilyControls entitlement in profile: \(hasFamilyControls)")
        #endif
        return hasFamilyControls
    }

    /// Perform app launch restoration (child devices only).
    func performRestoration() {
        guard deviceRole == .child else {
            isRestored = true
            return
        }

        guard let enforcement, let eventLogger, let snapshotStore else {
            isRestored = true
            return
        }

        let restorer = AppLaunchRestorer(
            keychain: keychain,
            storage: storage,
            enforcement: enforcement,
            eventLogger: eventLogger,
            snapshotStore: snapshotStore
        )
        restorer.restore()

        // Update runtime state from restored snapshot.
        if let snapshot = snapshotStore.loadCurrentSnapshot() {
            currentEffectivePolicy = snapshot.effectivePolicy
            activeWarnings = snapshot.effectivePolicy.warnings
        }

        isRestored = true
    }

    // MARK: - Authorization Change Handling

    /// Handle FamilyControls authorization state changes.
    /// Generates a new snapshot through the pipeline when authorization changes,
    /// ensuring enforcement matches the new reality.
    private func handleAuthorizationChange(_ newStatus: FCAuthorizationStatus) {
        guard deviceRole == .child else { return }
        guard let enforcement, let eventLogger, let snapshotStore else { return }

        let authHealth = storage.readAuthorizationHealth()
        let currentSnapshot = snapshotStore.loadCurrentSnapshot()

        if newStatus == .denied || newStatus == .notDetermined {
            eventLogger.log(.familyControlsAuthChanged, details: "Authorization revoked")

            // Generate a degraded snapshot if we have a current policy.
            if let snapshot = currentSnapshot {
                let policy = Policy(
                    targetDeviceID: snapshot.deviceID ?? DeviceID(rawValue: "unknown"),
                    mode: snapshot.effectivePolicy.resolvedMode,
                    version: snapshot.effectivePolicy.policyVersion
                )
                let capabilities = DeviceCapabilities(
                    familyControlsAuthorized: false,
                    isOnline: true
                )
                let inputs = PolicyPipelineCoordinator.Inputs(
                    basePolicy: policy,
                    capabilities: capabilities,
                    temporaryUnlockState: storage.readTemporaryUnlockState(),
                    authorizationHealth: authHealth,
                    deviceID: snapshot.deviceID,
                    source: .authorizationChange,
                    trigger: "FamilyControls authorization revoked"
                )
                let output = PolicyPipelineCoordinator.generateSnapshot(
                    from: inputs, previousSnapshot: currentSnapshot
                )
                do {
                    let result = try snapshotStore.commit(output.snapshot)
                    if case .committed(let committed) = result {
                        try? enforcement.apply(committed.effectivePolicy)
                        try? snapshotStore.markApplied()
                        currentEffectivePolicy = committed.effectivePolicy
                        activeWarnings = committed.effectivePolicy.warnings
                    }
                } catch {
                    // Log but don't crash.
                }
            }
        } else if newStatus == .authorized {
            eventLogger.log(.authorizationRestored, details: "Authorization restored")

            // Re-apply enforcement now that authorization is available.
            if let snapshot = currentSnapshot {
                let policy = Policy(
                    targetDeviceID: snapshot.deviceID ?? DeviceID(rawValue: "unknown"),
                    mode: snapshot.intendedMode ?? snapshot.effectivePolicy.resolvedMode,
                    version: snapshot.effectivePolicy.policyVersion
                )
                let capabilities = DeviceCapabilities(
                    familyControlsAuthorized: true,
                    isOnline: true
                )
                let inputs = PolicyPipelineCoordinator.Inputs(
                    basePolicy: policy,
                    capabilities: capabilities,
                    temporaryUnlockState: storage.readTemporaryUnlockState(),
                    authorizationHealth: authHealth,
                    deviceID: snapshot.deviceID,
                    source: .authorizationChange,
                    trigger: "FamilyControls authorization restored"
                )
                let output = PolicyPipelineCoordinator.generateSnapshot(
                    from: inputs, previousSnapshot: currentSnapshot
                )
                do {
                    let result = try snapshotStore.commit(output.snapshot)
                    if case .committed(let committed) = result {
                        try? enforcement.apply(committed.effectivePolicy)
                        try? snapshotStore.markApplied()
                        currentEffectivePolicy = committed.effectivePolicy
                        activeWarnings = committed.effectivePolicy.warnings
                    }
                } catch {
                    // Log but don't crash.
                }
            }
        }
    }

    // MARK: - Role Management

    /// Set the device role (called during onboarding).
    func setRole(_ role: DeviceRole) throws {
        try keychain.set(role, forKey: StorageKeys.deviceRole)
        deviceRole = role
    }

    /// Store child enrollment state (called during enrollment).
    func setEnrollmentState(_ state: ChildEnrollmentState) throws {
        try keychain.set(state, forKey: StorageKeys.enrollmentState)
        enrollmentState = state
    }

    /// Store parent state (called during parent setup).
    func setParentState(_ state: ParentState) throws {
        try keychain.set(state, forKey: StorageKeys.parentState)
        parentState = state
    }

    // MARK: - Parent Actions

    /// Fetch all child profiles and devices from CloudKit (parent mode).
    /// Individual query failures are logged but don't block the rest.
    func refreshDashboard() async throws {
        guard let familyID = parentState?.familyID,
              let cloudKit else { return }

        // Profiles are the critical query — let this one throw.
        childProfiles = try await cloudKit.fetchChildProfiles(familyID: familyID)

        // Devices and heartbeats are secondary — don't let them block the dashboard.
        do {
            childDevices = try await cloudKit.fetchDevices(familyID: familyID)
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to fetch devices: \(error.localizedDescription)")
            #endif
        }

        do {
            latestHeartbeats = try await cloudKit.fetchLatestHeartbeats(familyID: familyID)
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to fetch heartbeats: \(error.localizedDescription)")
            #endif
        }

        // Merge heartbeat data into device records.
        for heartbeat in latestHeartbeats {
            if let idx = childDevices.firstIndex(where: { $0.id == heartbeat.deviceID }) {
                childDevices[idx].lastHeartbeat = heartbeat.timestamp
                childDevices[idx].confirmedMode = heartbeat.currentMode
                childDevices[idx].confirmedPolicyVersion = heartbeat.policyVersion
                childDevices[idx].familyControlsAuthorized = heartbeat.familyControlsAuthorized
            }
        }
    }

    /// Send a command to a specific target (parent mode).
    func sendCommand(target: CommandTarget, action: CommandAction) async throws {
        guard let familyID = parentState?.familyID,
              let cloudKit else { return }

        let command = RemoteCommand(
            familyID: familyID,
            target: target,
            action: action,
            issuedBy: "Parent"
        )
        try await cloudKit.pushCommand(command)
    }

    // MARK: - Child Actions

    private var commandPollTimer: Timer?

    /// Start periodic sync for child devices.
    func startChildSync() {
        heartbeatService?.startHeartbeat()
        startCommandPolling()
    }

    /// Stop periodic sync.
    func stopChildSync() {
        heartbeatService?.stopHeartbeat()
        commandPollTimer?.invalidate()
        commandPollTimer = nil
    }

    /// Poll for commands every 5 seconds for fast response to parent actions.
    private func startCommandPolling() {
        commandPollTimer?.invalidate()
        commandPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                try? await self.commandProcessor?.processIncomingCommands()
                await MainActor.run { self.refreshLocalState() }
                // Send heartbeat immediately so parent sees updated mode.
                try? await self.heartbeatService?.sendNow(force: true)
            }
        }
        // Fire immediately.
        Task {
            #if DEBUG
            print("[BigBrother] Command polling started (every 5s)")
            #endif
            try? await commandProcessor?.processIncomingCommands()
            refreshLocalState()
        }
    }

    /// Re-read the current snapshot and update observable state so the UI refreshes.
    func refreshLocalState() {
        if let snapshot = snapshotStore?.loadCurrentSnapshot() {
            currentEffectivePolicy = snapshot.effectivePolicy
            activeWarnings = snapshot.effectivePolicy.warnings
            #if DEBUG
            print("[BigBrother] UI state refreshed: mode=\(snapshot.effectivePolicy.resolvedMode.displayName)")
            #endif
        }
    }
}
