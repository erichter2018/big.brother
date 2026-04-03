import Foundation
import CloudKit
import CoreLocation
import UIKit
import Observation
import UserNotifications
import BigBrotherCore

/// Root application state, observable by SwiftUI views.
///
/// Holds the current device role, enrollment state, and references
/// to all core services. Initialized on app launch by reading from Keychain.
/// Services are created after role detection because some depend on enrollment state.
@Observable
@MainActor
final class AppState {

    // MARK: - Role & Identity

    /// This device's role, read from Keychain on init.
    private(set) var deviceRole: DeviceRole = .unconfigured

    /// Enrollment state (child devices only).
    private(set) var enrollmentState: ChildEnrollmentState?

    /// Parent state (parent devices only).
    private(set) var parentState: ParentState?

    /// Stored NotificationCenter observer tokens for cleanup.
    private var notificationObservers: [Any] = []

    nonisolated deinit {
        // Timer cleanup is handled by invalidation; observers are weak references.
        // Cannot call @MainActor methods from deinit, but NotificationCenter
        // removeObserver is thread-safe.
    }

    // MARK: - Runtime State

    /// Whether the parent has authenticated in this session.
    var isParentAuthenticated: Bool = false

    /// Child profiles (parent mode — fetched from CloudKit).
    var childProfiles: [ChildProfile] = []

    /// User-defined display order for children. IDs not in this list appear at the end.
    var childOrder: [ChildProfileID] = [] {
        didSet { persistChildOrder() }
    }

    /// All enrolled devices (parent mode — fetched from CloudKit).
    var childDevices: [ChildDevice] = []

    /// Latest heartbeats for all devices (parent mode).
    var latestHeartbeats: [DeviceHeartbeat] = []

    /// Heartbeats for a specific child's devices.
    func latestHeartbeats(for childID: ChildProfileID) -> [DeviceHeartbeat] {
        let deviceIDs = Set(childDevices.filter { $0.childProfileID == childID }.map(\.id))
        return latestHeartbeats.filter { deviceIDs.contains($0.deviceID) }
    }

    /// Cached child detail view models — prevents re-creation on every dashboard refresh.
    @ObservationIgnored private var childDetailViewModels: [ChildProfileID: ChildDetailViewModel] = [:]

    func childDetailViewModel(forID childID: ChildProfileID) -> ChildDetailViewModel {
        if let existing = childDetailViewModels[childID] {
            existing.ensureDataLoaded()
            return existing
        }
        let child = childProfiles.first(where: { $0.id == childID })
            ?? ChildProfile(id: childID, familyID: FamilyID(rawValue: ""), name: "Unknown")
        let vm = ChildDetailViewModel(appState: self, child: child)
        vm.ensureDataLoaded()
        childDetailViewModels[childID] = vm
        return vm
    }

    /// Heartbeat monitoring profiles (parent mode).
    var heartbeatProfiles: [HeartbeatProfile] = []

    /// Schedule profiles (parent mode).
    var scheduleProfiles: [ScheduleProfile] = []

    /// Apps permanently approved by parent, per device (parent mode).
    var approvedApps: [ApprovedApp] = [] {
        didSet { persistApprovedApps() }
    }

    /// Current effective policy (child mode — from local snapshot).
    var currentEffectivePolicy: EffectivePolicy?

    /// Penalty timer data relayed from parent via CloudKit (child mode).
    var childPenaltySeconds: Int?
    var childPenaltyTimerEndTime: Date?

    /// Active capability warnings.
    var activeWarnings: [CapabilityWarning] = []

    /// Whether initial restoration has completed.
    private(set) var isRestored: Bool = false

    /// CloudKit account status message (nil when available).
    var cloudKitStatusMessage: String?

    /// Set to true when a requestAppConfiguration command is received,
    /// triggering the FamilyActivityPicker sheet on the child device.
    var showAppConfigurationRequest: Bool = false

    /// Set to true when a requestAlwaysAllowedSetup command is received,
    /// triggering the always-allowed apps picker on the child device.
    var showAlwaysAllowedSetup: Bool = false

    /// Set to true when a requestTimeLimitSetup command is received.
    var showTimeLimitSetup: Bool = false

    /// Expected mode per child, set when any view model sends a mode command.
    /// Used by the dashboard to show the correct mode before heartbeat confirms.
    /// Cleared when a heartbeat confirms the mode.
    var expectedModes: [ChildProfileID: (mode: LockMode, sentAt: Date)] = [:]

    /// Children whose enforcement is driven by their schedule (no manual override).
    /// Shared across all view models so both dashboard and child detail views can modify it.
    /// Persisted in UserDefaults so it survives app relaunch.
    var scheduleActiveChildren: Set<ChildProfileID> = {
        if let raw = UserDefaults.standard.array(forKey: "scheduleActiveChildIDs_v2") as? [String] {
            return Set(raw.map { ChildProfileID(rawValue: $0) })
        }
        return []
    }() {
        didSet {
            let raw = scheduleActiveChildren.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: "scheduleActiveChildIDs_v2")
        }
    }

    /// Set by notification tap to deep-link into a specific child's detail view.
    var pendingChildNavigation: ChildProfileID?

    // MARK: - Debug Mode

    /// Developer mode — shows build numbers, Insights tab, diagnostics.
    /// Persists across app restarts via UserDefaults.
    /// Always false in release/App Store builds.
    #if DEBUG
    var debugMode: Bool = UserDefaults.standard.bool(forKey: "fr.bigbrother.debugMode") {
        didSet { UserDefaults.standard.set(debugMode, forKey: "fr.bigbrother.debugMode") }
    }
    #else
    let debugMode: Bool = false
    #endif

    // MARK: - Network

    let networkMonitor = NetworkMonitor()

    // MARK: - Subscription

    let subscriptionManager = SubscriptionManager()

    // MARK: - Services

    private(set) var cloudKit: (any CloudKitServiceProtocol)?
    private(set) var enforcement: (any EnforcementServiceProtocol)?
    private(set) var auth: (any AuthServiceProtocol)?
    private(set) var enrollment: (any EnrollmentServiceProtocol)?
    private(set) var commandProcessor: (any CommandProcessorProtocol)?
    private(set) var heartbeatService: (any HeartbeatServiceProtocol)?
    private(set) var eventLogger: (any EventLoggerProtocol)?
    private(set) var syncCoordinator: (any SyncCoordinatorProtocol)?

    /// Location tracking service (child mode only).
    private(set) var locationService: LocationService?

    /// VPN tunnel manager (child mode only).
    private(set) var vpnManager: VPNManagerService?

    /// Driving safety monitor (child mode only).
    private(set) var drivingMonitor: DrivingMonitor?

    /// AllowanceTracker timer integration (parent mode only).
    private(set) var timerService: TimerIntegrationService?

    /// Monitors child device heartbeats and sends local notifications (parent mode only).
    internal var deviceMonitor: DeviceMonitor?

    /// Periodic timer that checks for new unlock requests (parent mode only).
    private var unlockRequestPollTimer: Timer?

    /// Last extension diagnostic timestamp printed to the debug console.
    private var lastPrintedExtensionDiagnosticAt: Date?

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
        storage.ensureSharedFilesExist()
        loadRole()
        loadApprovedApps()
        loadChildOrder()
        loadCachedDashboard()
    }

    /// Read role and enrollment state from Keychain.
    ///
    /// If the role is `.child` but enrollment state is missing (e.g. after
    /// app reinstall where Keychain migrated or access group changed),
    /// reset to `.unconfigured` so the user sees the onboarding flow.
    private func loadRole() {
        let storedRole = (try? keychain.get(DeviceRole.self, forKey: StorageKeys.deviceRole))
            ?? .unconfigured

        switch storedRole {
        case .child:
            let enrollment = try? keychain.get(
                ChildEnrollmentState.self,
                forKey: StorageKeys.enrollmentState
            )
            if let enrollment {
                deviceRole = .child
                enrollmentState = enrollment
                // Ensure enrollment IDs are cached in App Group for extensions.
                let cached = CachedEnrollmentIDs(deviceID: enrollment.deviceID, familyID: enrollment.familyID)
                if let data = try? JSONEncoder().encode(cached) {
                    try? storage.writeRawData(data, forKey: StorageKeys.cachedEnrollmentIDs)
                }
            } else {
                // Stale role without enrollment — reset to onboarding.
                #if DEBUG
                print("[BigBrother] Child role found but no enrollment state — resetting to unconfigured")
                #endif
                try? keychain.delete(forKey: StorageKeys.deviceRole)
                deviceRole = .unconfigured
            }
        case .parent:
            let parent = try? keychain.get(
                ParentState.self,
                forKey: StorageKeys.parentState
            )
            if let parent {
                deviceRole = .parent
                parentState = parent
            } else {
                #if DEBUG
                print("[BigBrother] Parent role found but no parent state — resetting to unconfigured")
                #endif
                try? keychain.delete(forKey: StorageKeys.deviceRole)
                deviceRole = .unconfigured
            }
        case .unconfigured:
            deviceRole = .unconfigured
        }
    }

    // MARK: - Approved Apps Persistence

    private static let approvedAppsKey = "fr.bigbrother.approvedApps"

    private func loadApprovedApps() {
        guard let data = UserDefaults.standard.data(forKey: Self.approvedAppsKey) else { return }
        approvedApps = (try? JSONDecoder().decode([ApprovedApp].self, from: data)) ?? []
    }

    private func persistApprovedApps() {
        guard let data = try? JSONEncoder().encode(approvedApps) else { return }
        UserDefaults.standard.set(data, forKey: Self.approvedAppsKey)
    }

    // MARK: - Child Order

    private static let childOrderKey = "fr.bigbrother.childOrder"

    func loadChildOrder() {
        guard let data = UserDefaults.standard.data(forKey: Self.childOrderKey) else { return }
        childOrder = (try? JSONDecoder().decode([ChildProfileID].self, from: data)) ?? []
    }

    private func persistChildOrder() {
        guard let data = try? JSONEncoder().encode(childOrder) else { return }
        UserDefaults.standard.set(data, forKey: Self.childOrderKey)
    }

    // MARK: - Dashboard Cache

    private static let cachedChildProfilesKey = "fr.bigbrother.cachedChildProfiles"
    private static let cachedChildDevicesKey = "fr.bigbrother.cachedChildDevices"

    func loadCachedDashboard() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: Self.cachedChildProfilesKey),
           let profiles = try? decoder.decode([ChildProfile].self, from: data) {
            childProfiles = profiles
        }
        if let data = UserDefaults.standard.data(forKey: Self.cachedChildDevicesKey),
           let devices = try? decoder.decode([ChildDevice].self, from: data) {
            childDevices = devices
        }
    }

    func persistDashboardCache() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(childProfiles) {
            UserDefaults.standard.set(data, forKey: Self.cachedChildProfilesKey)
        }
        if let data = try? encoder.encode(childDevices) {
            UserDefaults.standard.set(data, forKey: Self.cachedChildDevicesKey)
        }
    }

    /// Returns child profiles sorted by user-defined order.
    /// Children not in the order list appear at the end.
    var orderedChildProfiles: [ChildProfile] {
        let orderMap = Dictionary(uniqueKeysWithValues: childOrder.enumerated().map { ($1, $0) })
        return childProfiles.sorted { a, b in
            let ia = orderMap[a.id] ?? Int.max
            let ib = orderMap[b.id] ?? Int.max
            return ia < ib
        }
    }

    func addApprovedApp(_ app: ApprovedApp) {
        guard !approvedApps.contains(where: {
            $0.deviceID == app.deviceID &&
            Self.normalizeAppName($0.appName) == Self.normalizeAppName(app.appName)
        }) else { return }
        approvedApps.append(app)
    }

    func removeApprovedApp(requestID: UUID) {
        approvedApps.removeAll { $0.id == requestID }
    }

    func removeApprovedApp(appName: String, deviceID: DeviceID) {
        let normalizedName = Self.normalizeAppName(appName)
        approvedApps.removeAll {
            $0.deviceID == deviceID &&
            Self.normalizeAppName($0.appName) == normalizedName
        }
    }

    func approvedApps(for deviceID: DeviceID) -> [ApprovedApp] {
        approvedApps.filter { $0.deviceID == deviceID }
    }

    private static func normalizeAppName(_ appName: String) -> String {
        appName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Update approved app names when heartbeat provides better resolved names.
    /// Called during dashboard refresh after heartbeats are fetched.
    func enrichApprovedAppNames(from heartbeats: [DeviceHeartbeat]) {
        var changed = false
        for heartbeat in heartbeats {
            guard let allowedNames = heartbeat.allowedAppNames, !allowedNames.isEmpty else { continue }
            for i in approvedApps.indices where approvedApps[i].deviceID == heartbeat.deviceID {
                let currentName = approvedApps[i].appName
                // Skip if already has a good name.
                if Self.isPlaceholderAppName(currentName) {
                    // Try to find a matching name from the heartbeat's allowed list.
                    // The heartbeat resolves names via DeviceActivityReport — use the first unmatched name
                    // or any name that's better than the placeholder.
                    if let betterName = allowedNames.first(where: { !Self.isPlaceholderAppName($0) }) {
                        approvedApps[i] = ApprovedApp(
                            id: approvedApps[i].id,
                            appName: betterName,
                            deviceID: approvedApps[i].deviceID,
                            approvedAt: approvedApps[i].approvedAt
                        )
                        changed = true
                    }
                }
            }
        }
        if changed {
            persistApprovedApps()
        }
    }

    private static func isPlaceholderAppName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n.isEmpty || n == "unknown" || n == "an app" || n == "app"
            || n.hasPrefix("blocked app ") || n.contains("token(")
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

        // FamilyControls/ManagedSettings are only needed on child devices.
        // Creating ManagedSettingsStore or accessing AuthorizationCenter on a parent
        // device (where authorization was never requested) can trigger EXC_BREAKPOINT.
        // The debugger catches this silently, but standalone launches crash immediately.
        let enforcementImpl: EnforcementServiceImpl?
        if deviceRole == .child && Self.isFamilyControlsSafe() {
            let fcManager = FamilyControlsManagerImpl(storage: storage)
            let impl = EnforcementServiceImpl(storage: storage, fcManager: fcManager)
            self.enforcement = impl
            enforcementImpl = impl
            familyControlsAvailable = true

            // Write FC auth status to App Group so the tunnel diagnostic can report it.
            let authStatus = impl.authorizationStatus
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(authStatus.rawValue, forKey: "familyControlsAuthStatus")

            fcManager.observeAuthorizationChanges { [weak self] newStatus in
                UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                    .set(newStatus.rawValue, forKey: "familyControlsAuthStatus")
                Task { @MainActor [weak self] in
                    self?.handleAuthorizationChange(newStatus)
                }
            }
        } else {
            enforcementImpl = nil
            #if DEBUG
            if deviceRole == .parent {
                print("[BigBrother] Parent device — FamilyControls enforcement skipped")
            } else {
                print("[BigBrother] ⚠️ FamilyControls unavailable — enforcement disabled")
            }
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
        cmdProcessor.onRequestAppConfiguration = { [weak self] in
            self?.showAppConfigurationRequest = true
        }
        cmdProcessor.onRequestAlwaysAllowedSetup = { [weak self] in
            self?.showAlwaysAllowedSetup = true
        }
        cmdProcessor.onRequestTimeLimitSetup = { [weak self] in
            self?.showTimeLimitSetup = true
        }
        self.commandProcessor = cmdProcessor

        let hbService = HeartbeatServiceImpl(
            cloudKit: ck,
            keychain: keychain,
            storage: storage,
            enforcement: enforcementImpl
        )
        self.heartbeatService = hbService

        // Set up location service on child devices.
        if deviceRole == .child {
            let locService = LocationService(cloudKit: ck, keychain: keychain)
            // Ensure child devices always run in continuous mode.
            // The persisted mode may be stale (e.g., onDemand from an old command).
            if locService.mode != .continuous {
                locService.setMode(.continuous)
            }
            self.locationService = locService
            hbService.locationService = locService
            hbService.eventLogger = eventLogger
            locService.onRequestImmediateHeartbeat = { [weak hbService] in
                Task { try? await hbService?.sendNow(force: true) }
            }
            locService.eventLogger = eventLogger

            // Set up driving safety monitor.
            guard let evLogger = eventLogger else {
                #if DEBUG
                print("[BigBrother] WARNING: EventLogger not configured before DrivingMonitor — skipping driving monitor setup")
                #endif
                return
            }
            let driveMon = DrivingMonitor(
                eventLogger: evLogger,
                cloudKit: ck,
                storage: storage,
                keychain: keychain
            )
            locService.drivingMonitor = driveMon
            self.drivingMonitor = driveMon
            DeviceLockMonitor.shared.onLockStateChanged = { [weak driveMon] isLocked in
                driveMon?.onScreenLockStateChanged(isLocked: isLocked)
            }

            // Set up VPN tunnel for persistent background execution.
            let vpn = VPNManagerService()
            hbService.vpnManager = vpn
            self.vpnManager = vpn
            ensureVPNInstalled(vpn)

            cmdProcessor.onLocationModeChanged = { [weak locService] mode in
                locService?.setMode(mode)
            }
            cmdProcessor.onRequestLocation = { [weak locService] in
                Task { let _ = await locService?.requestCurrentLocation() }
            }
            cmdProcessor.onSyncNamedPlaces = { [weak self, weak locService] in
                Task {
                    guard let self, let familyID = (try? self.keychain.get(
                        ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
                    ))?.familyID else { return }
                    if let places = try? await ck.fetchNamedPlaces(familyID: familyID) {
                        await MainActor.run { locService?.registerNamedPlaces(places) }
                    }
                }
            }
            cmdProcessor.onRestartVPNTunnel = { [weak vpn] in
                Task {
                    try? await vpn?.installAndStart()
                }
            }
            cmdProcessor.onScheduleSyncNeeded = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    await self.syncScheduleProfile()
                    // Re-apply enforcement with the (potentially updated) schedule.
                    // The returnToSchedule already applied with whatever was local;
                    // if the sync changed the schedule, re-apply now.
                    if let snapshot = self.snapshotStore?.loadCurrentSnapshot() {
                        try? self.enforcement?.apply(snapshot.effectivePolicy)
                    }
                }
            }
            cmdProcessor.onRequestDiagnostics = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    let report = await DiagnosticCollector.collect(appState: self)
                    Task {
                        try? await ck.saveDiagnosticReport(report)
                        #if DEBUG
                        print("[BigBrother] Diagnostic report uploaded (\(report.recentLogs.count) log entries)")
                        #endif
                    }
                }
            }
            cmdProcessor.onRequestPermissions = { [weak self, weak locService] in
                Task { @MainActor in
                    // Re-request FamilyControls authorization
                    try? await self?.enforcement?.requestAuthorization()

                    // Ensure location service is at least onDemand so it's ready
                    if locService?.mode == .off {
                        locService?.setMode(.onDemand)
                    }

                    // Always open Settings — the parent is holding the device and
                    // needs to verify/set location to "Always". No guessing.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        await UIApplication.shared.open(url)
                    }
                }
            }
        }

        // Debug mode: run driving detection on the parent device for testing.
        // Logs CoreMotion transitions, speed, braking, phone-while-driving to console + diagnostics.
        #if DEBUG
        if deviceRole == .parent {
            // Write a temporary enrollment so LocationService can save breadcrumbs
            let debugDeviceID = DeviceID(rawValue: "PARENT-DEBUG-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "0")")
            let debugFamilyID = parentState?.familyID ?? FamilyID(rawValue: "debug")
            let debugEnrollment = ChildEnrollmentState(deviceID: debugDeviceID, childProfileID: ChildProfileID(rawValue: "parent-debug"), familyID: debugFamilyID)
            try? keychain.set(debugEnrollment, forKey: StorageKeys.enrollmentState)

            // Copy home coordinates to App Group so LocationService can register geofence.
            // Parent stores per-device, but LocationService reads from App Group (child convention).
            let debugDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
            for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
                if key.hasPrefix("homeLatitude."), let lat = value as? Double {
                    let suffix = String(key.dropFirst("homeLatitude.".count))
                    if let lon = UserDefaults.standard.object(forKey: "homeLongitude.\(suffix)") as? Double {
                        debugDefaults?.set(lat, forKey: "homeLatitude")
                        debugDefaults?.set(lon, forKey: "homeLongitude")
                        break // Use first found
                    }
                }
            }

            let locService = LocationService(cloudKit: ck, keychain: keychain)
            self.locationService = locService
            locService.setMode(.continuous)

            let driveMon = DrivingMonitor(
                eventLogger: eventLogger ?? EventLoggerImpl(cloudKit: ck, storage: storage, keychain: keychain),
                cloudKit: ck,
                storage: storage,
                keychain: keychain
            )
            locService.drivingMonitor = driveMon
            self.drivingMonitor = driveMon
            locService.eventLogger = eventLogger
            DeviceLockMonitor.shared.onLockStateChanged = { [weak driveMon] isLocked in
                driveMon?.onScreenLockStateChanged(isLocked: isLocked)
            }
            // Save breadcrumbs with a debug device ID so the map can show them
            locService.onRequestImmediateHeartbeat = { [weak hbService] in
                Task { try? await hbService?.sendNow(force: true) }
            }
            print("[BigBrother] DEBUG: Driving detection active on parent device for testing")
        }
        #endif

        // Wire up heartbeat request: when the parent pings, send a heartbeat immediately.
        cmdProcessor.onRequestHeartbeat = { [weak hbService] in
            Task { try? await hbService?.sendNow(force: true) }
        }

        // Wire up command processing on heartbeat success — if the device is online
        // enough to send a heartbeat, it should also process pending commands.
        hbService.onHeartbeatSent = { [weak cmdProcessor] in
            Task { try? await cmdProcessor?.processIncomingCommands() }
        }
        hbService.onLivenessConfirmed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleMainAppResponsive(reapplyEnforcement: true)
            }
        }

        // Listen for iCloud account changes on child devices.
        // CKAccountChanged fires spuriously (app launch, network reconnect, etc.)
        // so we only log/notify when the account status actually changes.
        if deviceRole == .child {
            let observer = NotificationCenter.default.addObserver(
                forName: Notification.Name.CKAccountChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
                    let status = try? await container.accountStatus()
                    let statusKey = "lastCKAccountStatus"
                    let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
                    let previous = defaults?.integer(forKey: statusKey) ?? -1
                    let current = status?.rawValue ?? -1
                    defaults?.set(current, forKey: statusKey)

                    guard previous != -1, current != previous else {
                        #if DEBUG
                        print("[BigBrother] CKAccountChanged — status unchanged (\(current)), ignoring")
                        #endif
                        return
                    }
                    self.eventLogger?.log(.familyControlsAuthChanged, details: "iCloud account status changed: \(previous) → \(current)")
                    #if DEBUG
                    print("[BigBrother] CKAccountChanged — real change: \(previous) → \(current)")
                    #endif

                    // Re-register CloudKit subscriptions — the old push token may be
                    // invalid after an iCloud account change (MDM removal, sign-out, etc.)
                    // Without this, silent pushes for commands stop being delivered.
                    if let enrollment = try? self.keychain.get(ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState) {
                        Task {
                            try? await self.cloudKit?.setupSubscriptions(
                                familyID: enrollment.familyID,
                                deviceID: enrollment.deviceID
                            )
                            // Also re-register for remote notifications (APNs token)
                            await MainActor.run {
                                UIApplication.shared.registerForRemoteNotifications()
                            }
                            self.eventLogger?.log(.policyReconciled, details: "Re-registered CK subscriptions + push after iCloud account change")
                        }
                    }
                }
            }
            notificationObservers.append(observer)
        }

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
        // Wire unenroll callbacks (command processor + sync coordinator).
        let unenrollHandler: () -> Void = { [weak self] in
            self?.performLocalUnenroll()
        }
        cmdProcessor.onUnenroll = unenrollHandler
        syncImpl.onUnenroll = unenrollHandler

        self.syncCoordinator = syncImpl
    }

    /// Clear local enrollment state and reset to unconfigured.
    /// Called when the parent deletes this device or sends an unenroll command.
    func performLocalUnenroll() {
        #if DEBUG
        print("[BigBrother] Performing local unenroll — clearing enrollment and resetting role")
        #endif
        // Clear Keychain (enrollment, role, PIN, familyID, signing keys).
        try? keychain.delete(forKey: StorageKeys.enrollmentState)
        try? keychain.delete(forKey: StorageKeys.deviceRole)
        try? keychain.delete(forKey: StorageKeys.familyID)
        try? keychain.delete(forKey: StorageKeys.parentPINHash)
        try? keychain.delete(forKey: StorageKeys.commandSigningPublicKey)

        // Clear cached enrollment IDs from App Group.
        try? storage.writeRawData(nil, forKey: StorageKeys.cachedEnrollmentIDs)

        // Clear App Group state files.
        try? storage.clearTemporaryUnlockState()
        try? storage.writeRawData(nil, forKey: StorageKeys.pendingUnlockRequests)
        try? storage.clearUnlockPickerPending()

        // Stop background services.
        heartbeatService?.stopHeartbeat()

        deviceRole = .unconfigured
        enrollmentState = nil
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
        // multiple sources for the entitlement.

        let entitlementKey = "com.apple.developer.family-controls"

        // Method 1: Check embedded provisioning profile.
        // The file is binary CMS/PKCS7 data wrapping a plist — String(data:encoding:.ascii)
        // can return nil if any byte > 127. Search the raw bytes instead.
        let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            ?? URL(fileURLWithPath: Bundle.main.bundlePath + "/embedded.mobileprovision")

        if let profileData = try? Data(contentsOf: profileURL) {
            let needle = Data(entitlementKey.utf8)
            let found = profileData.range(of: needle) != nil
            #if DEBUG
            print("[BigBrother] embedded.mobileprovision found (\(profileData.count) bytes), FamilyControls entitlement: \(found)")
            #endif
            if found { return true }
        } else {
            #if DEBUG
            print("[BigBrother] embedded.mobileprovision not found in bundle")
            #endif
        }

        // Method 2: Check the app's code signing entitlements file.
        // If the entitlements file declares FamilyControls, the provisioning profile
        // should include it — the profile check above may have failed due to file format issues.
        if let entURL = Bundle.main.url(forResource: "BigBrother", withExtension: "entitlements"),
           let entData = try? Data(contentsOf: entURL),
           let entString = String(data: entData, encoding: .utf8),
           entString.contains(entitlementKey) {
            #if DEBUG
            print("[BigBrother] FamilyControls entitlement found in bundled .entitlements file")
            #endif
            return true
        }

        // Method 3: Check the built-in entitlements from the code signature.
        // On iOS, the codesign entitlements are embedded in the binary itself.
        // Look for the entitlement key in our own Mach-O binary.
        if let executableURL = Bundle.main.executableURL,
           let execData = try? Data(contentsOf: executableURL) {
            let needle = Data(entitlementKey.utf8)
            let found = execData.range(of: needle) != nil
            #if DEBUG
            print("[BigBrother] Executable binary FamilyControls entitlement: \(found)")
            #endif
            if found { return true }
        }

        // Method 4: Environment variable override.
        if ProcessInfo.processInfo.environment["BIGBROTHER_FORCE_FC"] == "1" {
            #if DEBUG
            print("[BigBrother] FamilyControls force-enabled via BIGBROTHER_FORCE_FC")
            #endif
            return true
        }

        #if DEBUG
        print("[BigBrother] FamilyControls entitlement not found — enforcement disabled")
        print("[BigBrother] Try: Delete app → Clean Build Folder (Cmd+Shift+K) → Rebuild")
        #endif
        return false
    }

    /// Perform app launch restoration (child devices only).
    func performRestoration() {
        guard deviceRole == .child else {
            isRestored = true
            return
        }

        // One-time migration: denyWebWhenLocked used to default to true, which was wrong.
        // Reset it to false on all existing devices so web isn't blocked unless the parent
        // explicitly enables it. Future setRestrictions commands will set the correct value.
        let migrationKey = "migration_denyWebWhenLocked_default_fixed"
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if defaults?.bool(forKey: migrationKey) != true {
            var r = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            if r.denyWebWhenLocked {
                r.denyWebWhenLocked = false
                try? storage.writeDeviceRestrictions(r)
            }
            defaults?.set(true, forKey: migrationKey)
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

        // Register the hourly reconciliation schedule so the monitor extension
        // periodically verifies enforcement state, even if the app isn't running.
        if familyControlsAvailable {
            let scheduleManager = ScheduleManagerImpl()
            try? scheduleManager.registerReconciliationSchedule()

            // Register usage tracking milestones for screen time reporting.
            ScheduleRegistrar.registerUsageTracking()
        }

        // Update runtime state from restored snapshot.
        if let snapshot = snapshotStore.loadCurrentSnapshot() {
            currentEffectivePolicy = snapshot.effectivePolicy
            activeWarnings = snapshot.effectivePolicy.warnings
        }

        isRestored = true
    }

    /// Immediate full sync when the child app comes to foreground.
    /// Pulls latest schedule, restrictions, and pending commands from CloudKit,
    /// applies enforcement, and sends a heartbeat so the parent sees current state.
    /// This ensures that when a kid opens BB, everything is instantly up to date.
    private var isForegroundSyncing = false

    /// Timer that polls for commands while the app is in foreground.
    /// Push notifications are unreliable (iOS throttles silent pushes, iCloud
    /// account changes break CK subscriptions). This 5-second poll ensures
    /// commands are processed promptly when the parent sends them.
    private var foregroundCommandPollTimer: Timer?

    /// Start polling for commands while the app is in foreground.
    func startForegroundCommandPoll() {
        guard deviceRole == .child else { return }
        stopForegroundCommandPoll()
        foregroundCommandPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { [weak self] in
                try? await self?.commandProcessor?.processIncomingCommands()
            }
        }
    }

    /// Stop polling when the app goes to background.
    func stopForegroundCommandPoll() {
        foregroundCommandPollTimer?.invalidate()
        foregroundCommandPollTimer = nil
    }

    func performForegroundSync() {
        guard deviceRole == .child else { return }
        guard !isForegroundSyncing else { return }
        isForegroundSyncing = true

        // Detect stale binary: if the tunnel has a newer build than our in-memory
        // constant, we're running old code after a devicectl install (the tunnel
        // restarts with new code but the app process may be resumed stale).
        // Force exit so iOS relaunches with the new binary.
        let tunnelBuild = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .integer(forKey: "tunnelBuildNumber") ?? 0
        if tunnelBuild > AppConstants.appBuildNumber {
            exit(0)
        }

        Task {
            defer {
                Task { @MainActor in
                    self.isForegroundSyncing = false
                }
            }

            // 1. FIRST: process commands immediately — this is what the parent is waiting for.
            // Don't make them wait for schedule sync or enforcement verification.
            try? await commandProcessor?.processIncomingCommands()

            // 2. Sync schedule + restrictions from CloudKit
            await syncScheduleProfile()

            // 4. Re-apply enforcement — use ModeStackResolver as ground truth.
            let resolution = ModeStackResolver.resolve(storage: storage)
            if let snapshot = snapshotStore?.loadCurrentSnapshot() {
                if snapshot.effectivePolicy.resolvedMode != resolution.mode {
                    let corrected = EffectivePolicy(
                        resolvedMode: resolution.mode,
                        isTemporaryUnlock: resolution.isTemporary,
                        temporaryUnlockExpiresAt: resolution.expiresAt,
                        shieldedCategoriesData: snapshot.effectivePolicy.shieldedCategoriesData,
                        allowedAppTokensData: snapshot.effectivePolicy.allowedAppTokensData,
                        warnings: snapshot.effectivePolicy.warnings,
                        policyVersion: snapshot.effectivePolicy.policyVersion + 1
                    )
                    let correctedSnapshot = PolicySnapshot(
                        source: .restoration,
                        trigger: "Foreground sync: corrected \(snapshot.effectivePolicy.resolvedMode.rawValue) → \(resolution.mode.rawValue)",
                        effectivePolicy: corrected
                    )
                    try? storage.commitCorrectedSnapshot(correctedSnapshot)
                    try? enforcement?.apply(corrected)
                } else {
                    try? enforcement?.apply(snapshot.effectivePolicy)
                }
            }

            // 5. Ensure VPN is installed
            if let vpn = vpnManager {
                if !(await vpn.isConfigured()) {
                    try? await vpn.installAndStart()
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .enforcement,
                        message: "VPN was missing — reinstalled during foreground sync"
                    ))
                }
            }

            // 6. Verify enforcement matches ModeStackResolver
            verifyAndFixEnforcement()

            // 7. Send heartbeat so parent sees updated state immediately
            try? await heartbeatService?.sendNow(force: true)

            // 8. Ping the VPN tunnel to clear any stale blackholes
            vpnManager?.sendPing()

            await MainActor.run {
                self.refreshLocalState()
            }
        }
    }

    /// Called when the child app proves it is running again after fail-safe mode.
    /// Clears the latched force-close flag and, when needed, restores the
    /// parent-chosen enforcement immediately instead of waiting for the next
    /// reconciliation cycle.
    func handleMainAppResponsive(reapplyEnforcement: Bool) {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if let requestToken = defaults?.string(forKey: "extensionHeartbeatRequestToken"),
           !requestToken.isEmpty {
            defaults?.set(requestToken, forKey: "extensionHeartbeatAcknowledgedToken")
            defaults?.set(Date().timeIntervalSince1970, forKey: "extensionHeartbeatAcknowledgedAt")
        }
        let hadFailSafe = defaults?.bool(forKey: "forceCloseWebBlocked") == true
        if hadFailSafe {
            defaults?.removeObject(forKey: "forceCloseWebBlocked")
            defaults?.removeObject(forKey: "forceCloseLastNagAt")
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["force-close-nag"])

        guard reapplyEnforcement, hadFailSafe, deviceRole == .child else { return }
        performRestoration()
        refreshLocalState()
    }

    // MARK: - VPN Tunnel Management

    /// Install the VPN tunnel, retrying on failure.
    /// If the user denies the VPN permission dialog, retries every 60 seconds
    /// until the VPN is configured. Also retries on each app launch.
    private func ensureVPNInstalled(_ vpn: VPNManagerService) {
        Task {
            // Check if already configured — no prompt needed
            if await vpn.isConfigured() {
                do {
                    try await vpn.installAndStart()
                    #if DEBUG
                    print("[BigBrother] VPN tunnel verified and running")
                    #endif
                } catch {
                    #if DEBUG
                    print("[BigBrother] VPN tunnel start failed: \(error.localizedDescription)")
                    #endif
                }
                return
            }

            // Not configured — try to install (will show system VPN permission dialog)
            do {
                try await vpn.installAndStart()
                #if DEBUG
                print("[BigBrother] VPN tunnel installed and started")
                #endif
                return
            } catch {
                #if DEBUG
                print("[BigBrother] VPN tunnel install denied or failed: \(error.localizedDescription)")
                #endif
            }

            // User denied — lock to essential mode after 5 minutes of denials,
            // then keep retrying every 60 seconds.
            let denialStart = Date()
            var essentialApplied = false

            while !(await vpn.isConfigured()) {
                guard !Task.isCancelled else { return }
                // After 5 minutes of denial, lock to essential mode
                if !essentialApplied && Date().timeIntervalSince(denialStart) > 300 {
                    essentialApplied = true
                    await MainActor.run {
                        if let enforcement = self.enforcement {
                            try? enforcement.applyEssentialOnly()
                            #if DEBUG
                            print("[BigBrother] VPN denied for 5+ min — essential mode applied")
                            #endif
                        }
                    }
                }

                try? await Task.sleep(for: .seconds(60))
                guard deviceRole == .child else { return }
                do {
                    try await vpn.installAndStart()
                    // VPN accepted — restore normal enforcement
                    if essentialApplied {
                        await MainActor.run { self.performRestoration() }
                    }
                    #if DEBUG
                    print("[BigBrother] VPN tunnel installed on retry")
                    #endif
                    return
                } catch {
                    #if DEBUG
                    print("[BigBrother] VPN tunnel retry failed: \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }

    /// Whether the VPN tunnel is currently connected (for parent dashboard diagnostics).
    // MARK: - Debug Driving

    #if DEBUG
    /// Debug device ID for parent driving test (matches the enrollment written in configureServices).
    var debugDeviceID: DeviceID {
        DeviceID(rawValue: "PARENT-DEBUG-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "0")")
    }

    /// Debug ChildDevice for use in LocationMapView on parent device.
    var debugChildDevice: ChildDevice? {
        guard deviceRole == .parent, locationService != nil else { return nil }
        let familyID = parentState?.familyID ?? FamilyID(rawValue: "debug")
        return ChildDevice(
            id: debugDeviceID,
            childProfileID: ChildProfileID(rawValue: "parent-debug"),
            familyID: familyID,
            displayName: "My Phone",
            modelIdentifier: UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion
        )
    }

    /// Debug ChildProfile for use in LocationMapView on parent device.
    var debugChildProfile: ChildProfile? {
        guard deviceRole == .parent, locationService != nil else { return nil }
        let familyID = parentState?.familyID ?? FamilyID(rawValue: "debug")
        return ChildProfile(id: ChildProfileID(rawValue: "parent-debug"), familyID: familyID, name: "My Driving")
    }
    #endif

    var isVPNConnected: Bool {
        vpnManager?.isConnected ?? false
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
            // Also log as authorizationLost so parent gets a critical notification
            eventLogger.log(.authorizationLost, details: "FamilyControls authorization revoked — shields may be down")
            // Signal tunnel to block internet immediately
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(false, forKey: "allPermissionsGranted")
            // Force heartbeat so parent sees revocation immediately
            Task { try? await heartbeatService?.sendNow(force: true) }

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
            // Signal tunnel to unblock internet
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(true, forKey: "allPermissionsGranted")

            // Force heartbeat so parent sees restoration immediately
            Task { try? await heartbeatService?.sendNow(force: true) }

            // After FC auth is restored, ManagedSettingsStore may be corrupted.
            // Nuke all stores first, then re-apply from scratch.
            try? enforcement.clearAllRestrictions()

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
    /// Set when this parent's invite has been revoked by the primary parent.
    var isParentRevoked = false

    func refreshDashboard() async throws {
        guard let familyID = parentState?.familyID,
              let cloudKit else { return }

        // Check if this invited parent has been revoked.
        if let inviteCode = parentState?.inviteCode {
            if let invite = try? await cloudKit.fetchEnrollmentInvite(code: inviteCode),
               invite.revoked {
                isParentRevoked = true
                return // Stop loading — parent is locked out.
            }
        }

        // Profiles are the critical query — let this one throw.
        let fetchedProfiles = try await cloudKit.fetchChildProfiles(familyID: familyID)

        // Fetch all secondary data into locals first to avoid flashing
        // stale defaults while awaiting subsequent queries.
        var fetchedDevices: [ChildDevice]?
        var fetchedHeartbeats: [DeviceHeartbeat]?
        var fetchedHBProfiles: [HeartbeatProfile]?
        var fetchedScheduleProfiles: [ScheduleProfile]?

        do {
            fetchedDevices = try await cloudKit.fetchDevices(familyID: familyID)
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to fetch devices: \(error.localizedDescription)")
            #endif
        }

        do {
            fetchedHeartbeats = try await cloudKit.fetchLatestHeartbeats(familyID: familyID)
        } catch {
            NSLog("[BigBrother] Failed to fetch heartbeats: \(error.localizedDescription)")
        }

        do {
            fetchedHBProfiles = try await cloudKit.fetchHeartbeatProfiles(familyID: familyID)
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to fetch heartbeat profiles: \(error.localizedDescription)")
            #endif
        }

        do {
            fetchedScheduleProfiles = try await cloudKit.fetchScheduleProfiles(familyID: familyID)
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to fetch schedule profiles: \(error.localizedDescription)")
            #endif
        }

        // Merge heartbeat data into device records BEFORE publishing to UI.
        // Only assign to @Observable properties when content actually changed
        // to avoid unnecessary SwiftUI re-renders (which tear down navigationDestination views).
        if var devices = fetchedDevices, let heartbeats = fetchedHeartbeats {
            for heartbeat in heartbeats {
                if let idx = devices.firstIndex(where: { $0.id == heartbeat.deviceID }) {
                    devices[idx].lastHeartbeat = heartbeat.timestamp
                    devices[idx].confirmedMode = heartbeat.currentMode
                    devices[idx].confirmedPolicyVersion = heartbeat.policyVersion
                    devices[idx].familyControlsAuthorized = heartbeat.familyControlsAuthorized
                    if let os = heartbeat.osVersion { devices[idx].osVersion = os }
                    if let model = heartbeat.modelIdentifier { devices[idx].modelIdentifier = model }
                }
            }
            preserveLocalDeviceFields(into: &devices)
            if devices != childDevices { childDevices = devices }
            if heartbeats != latestHeartbeats { latestHeartbeats = heartbeats }
        } else if let devices = fetchedDevices {
            var merged = devices
            preserveLocalDeviceFields(into: &merged)
            if merged != childDevices { childDevices = merged }
        } else if let heartbeats = fetchedHeartbeats {
            if heartbeats != latestHeartbeats { latestHeartbeats = heartbeats }
            // Re-merge into existing devices.
            for heartbeat in heartbeats {
                if let idx = childDevices.firstIndex(where: { $0.id == heartbeat.deviceID }) {
                    childDevices[idx].lastHeartbeat = heartbeat.timestamp
                    childDevices[idx].confirmedMode = heartbeat.currentMode
                    childDevices[idx].confirmedPolicyVersion = heartbeat.policyVersion
                    childDevices[idx].familyControlsAuthorized = heartbeat.familyControlsAuthorized
                    if let os = heartbeat.osVersion { childDevices[idx].osVersion = os }
                    if let model = heartbeat.modelIdentifier { childDevices[idx].modelIdentifier = model }
                }
            }
        }

        // Publish remaining data — only assign if changed to avoid unnecessary SwiftUI re-renders.
        if fetchedProfiles != childProfiles { childProfiles = fetchedProfiles }
        if let hbp = fetchedHBProfiles, hbp != heartbeatProfiles { heartbeatProfiles = hbp }
        if let sp = fetchedScheduleProfiles, sp != scheduleProfiles { scheduleProfiles = sp }

        // Cache for instant display on next launch.
        persistDashboardCache()

        // Preserve parent-set fields on remaining paths.

        // Enrich approved app names from heartbeat data.
        enrichApprovedAppNames(from: latestHeartbeats)

        // Check for new unlock requests and post notifications.
        checkForUnlockRequestNotifications(familyID: familyID)

        // Ensure child devices have the latest parent PIN hash.
        await syncPINToChildDevices()

        // Clean up stale pending commands — throttled to once per 5 minutes.
        let cleanupKey = "fr.bigbrother.lastCleanupAt"
        let lastCleanup = UserDefaults.standard.double(forKey: cleanupKey)
        if Date().timeIntervalSince1970 - lastCleanup > 300 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cleanupKey)
            Task.detached { [cloudKit, familyID] in
                await Self.cleanupStaleCommands(cloudKit: cloudKit, familyID: familyID)
            }
        }

        // Full CloudKit cleanup (old applied/expired commands, receipts, events) —
        // throttled to once per day.
        let fullCleanupKey = "fr.bigbrother.lastFullCleanupAt"
        let lastFullCleanup = UserDefaults.standard.double(forKey: fullCleanupKey)
        if Date().timeIntervalSince1970 - lastFullCleanup > 86400 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: fullCleanupKey)
            Task.detached { [cloudKit, familyID] in
                await CloudKitCleanupService.performCleanup(
                    cloudKit: cloudKit,
                    familyID: familyID
                )
            }
        }

        // NOTE: One-time command nuke removed (was nukeKey v3).
        // Stale config commands are handled by cleanupStaleCommands() above.
    }

    /// Mark old pending commands as expired. Runs on the parent because only the record
    /// creator (parent) has write permission in CloudKit public database.
    private static func cleanupStaleCommands(
        cloudKit: any CloudKitServiceProtocol,
        familyID: FamilyID
    ) async {
        do {
            let since = Date().addingTimeInterval(-86400 * 2) // last 2 days
            let commands = try await cloudKit.fetchRecentCommands(familyID: familyID, since: since)
            // Only delete DUPLICATE config commands — keep the newest of each type per target,
            // delete older duplicates. This way a budget change still reaches an offline kid,
            // but 50 identical budget commands get collapsed to 1.
            let pending = commands.filter { $0.status == .pending }

            // Group by (action description + target) to find duplicates.
            var grouped: [String: [RemoteCommand]] = [:]
            for cmd in pending {
                let targetKey: String
                switch cmd.target {
                case .child(let cid): targetKey = "child:\(cid.rawValue)"
                case .device(let did): targetKey = "device:\(did.rawValue)"
                case .allDevices: targetKey = "all"
                }
                let key = "\(cmd.action.displayDescription)|\(targetKey)"
                grouped[key, default: []].append(cmd)
            }

            // For each group with more than 1 command, keep the newest and delete the rest.
            var stale: [RemoteCommand] = []
            for (_, cmds) in grouped where cmds.count > 1 {
                let sorted = cmds.sorted { $0.issuedAt > $1.issuedAt }
                stale.append(contentsOf: sorted.dropFirst()) // Keep newest, delete rest
            }
            guard !stale.isEmpty else { return }
            #if DEBUG
            print("[BigBrother] Parent cleaning up \(stale.count) stale pending commands")
            #endif
            for command in stale {
                try? await cloudKit.deleteCommand(command.id)
            }
        } catch {
            #if DEBUG
            print("[BigBrother] Stale command cleanup failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Preserve parent-set fields from existing in-memory devices when CloudKit
    /// returns nil for those fields (write may not have propagated yet).
    private func preserveLocalDeviceFields(into devices: inout [ChildDevice]) {
        for i in devices.indices {
            if let existing = childDevices.first(where: { $0.id == devices[i].id }) {
                // If the fetched device has nil but our in-memory device has a value,
                // the parent likely set it recently and CloudKit hasn't caught up.
                if devices[i].scheduleProfileID == nil, existing.scheduleProfileID != nil {
                    devices[i].scheduleProfileID = existing.scheduleProfileID
                    devices[i].scheduleProfileVersion = existing.scheduleProfileVersion
                }
                if devices[i].penaltySeconds == nil, existing.penaltySeconds != nil {
                    devices[i].penaltySeconds = existing.penaltySeconds
                }
                if devices[i].penaltyTimerEndTime == nil, existing.penaltyTimerEndTime != nil {
                    devices[i].penaltyTimerEndTime = existing.penaltyTimerEndTime
                }
                if devices[i].selfUnlocksPerDay == nil, existing.selfUnlocksPerDay != nil {
                    devices[i].selfUnlocksPerDay = existing.selfUnlocksPerDay
                }
            }
        }
    }

    /// Start polling for unlock requests every 10 seconds (parent mode).
    func startUnlockRequestPolling() {
        unlockRequestPollTimer?.invalidate()
        guard let familyID = parentState?.familyID else { return }
        let urTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForUnlockRequestNotifications(familyID: familyID)
            }
        }
        RunLoop.main.add(urTimer, forMode: .common)
        unlockRequestPollTimer = urTimer
        // Also check immediately on start.
        checkForUnlockRequestNotifications(familyID: familyID)
        #if DEBUG
        print("[BigBrother] Unlock request polling started (every 10s)")
        #endif
    }

    /// Immediately check for unlock requests (call when app becomes active).
    func checkForUnlockRequestsNow() {
        guard let familyID = parentState?.familyID else { return }
        checkForUnlockRequestNotifications(familyID: familyID)
    }

    /// Stop polling for unlock requests.
    func stopUnlockRequestPolling() {
        unlockRequestPollTimer?.invalidate()
        unlockRequestPollTimer = nil
    }

    // MARK: - Timer Integration

    /// Creates the timer service if the integration is enabled in settings.
    func initializeTimerServiceIfNeeded() {
        let config = TimerIntegrationConfig.load()
        guard config.isEnabled else { return }
        let service = TimerIntegrationService()
        service.onTimerDataChanged = { [weak self] timers in
            self?.relayTimerDataToCloudKit(timers)
        }
        timerService = service
        #if DEBUG
        print("[BigBrother] Timer integration service initialized")
        #endif
    }

    /// Tracks last relayed penalty timer values per child to avoid command spam.
    var lastRelayedPenalty: [ChildProfileID: (seconds: Int?, endTime: Date?)] = [:]

    /// Pushes timer data from Firestore to child device records in CloudKit.
    /// Only sends a command when the values actually change.
    private func relayTimerDataToCloudKit(_ timers: [String: TimerIntegrationService.KidTimerState]) {
        let config = TimerIntegrationConfig.load()

        for mapping in config.kidMappings {
            guard let childID = mapping.childProfileID else { continue }
            let timer = timers[mapping.firestoreKidID]
            let seconds = timer?.penaltySeconds
            let endTime = timer?.timerEndTime

            // Skip no-op "clear penalty" relays — no point sending (0, nil) repeatedly.
            let effectiveSeconds = seconds ?? 0
            let isNoop = effectiveSeconds <= 0 && endTime == nil
            if let last = lastRelayedPenalty[childID],
               last.seconds == seconds && last.endTime == endTime {
                continue
            }
            if isNoop, lastRelayedPenalty[childID] == nil {
                // First snapshot after app relaunch with no active penalty — skip.
                // Only relay a "clear" if we previously relayed a non-zero value.
                lastRelayedPenalty[childID] = (seconds, endTime)
                continue
            }
            lastRelayedPenalty[childID] = (seconds, endTime)

            // Update in-memory for display.
            let devices = childDevices.filter { $0.childProfileID == childID }
            for device in devices {
                if let idx = childDevices.firstIndex(where: { $0.id == device.id }) {
                    childDevices[idx].penaltySeconds = seconds
                    childDevices[idx].penaltyTimerEndTime = endTime
                }
            }

            // Send one command per child (not per device).
            Task {
                try? await sendCommand(
                    target: .child(childID),
                    action: .setPenaltyTimer(seconds: seconds, endTime: endTime)
                )
            }
        }
    }

    /// Fetch recent events and post local notifications for new unlock requests.
    private func checkForUnlockRequestNotifications(familyID: FamilyID) {
        guard let cloudKit else { return }

        Task {
            let since = Date().addingTimeInterval(-1800) // last 30 minutes
            let events = (try? await cloudKit.fetchEventLogs(familyID: familyID, since: since)) ?? []

            for profile in childProfiles {
                let deviceIDs = Set(childDevices.filter { $0.childProfileID == profile.id }.map(\.id))
                UnlockRequestNotificationService.checkAndNotify(
                    events: events,
                    childDeviceIDs: deviceIDs,
                    childName: profile.name,
                    childProfileID: profile.id
                )
            }
        }
    }

    /// Send a command to a specific target (parent mode).
    ///
    /// If the new command is a mode command (lock/unlock/schedule), any older pending
    /// mode commands for the same target are expired first — they're superseded and
    /// would just waste processing time on the child device.
    func sendCommand(target: CommandTarget, action: CommandAction) async throws {
        guard let familyID = parentState?.familyID,
              let cloudKit else { return }

        // setMode is a hard manual override — schedule should be deactivated.
        // temporaryUnlock/timedUnlock/lockUntil are temporary — schedule stays active.
        // returnToSchedule explicitly activates the schedule.
        switch action {
        case .setMode:
            // Clear schedule for the targeted child(ren).
            switch target {
            case .child(let cid): scheduleActiveChildren.remove(cid)
            case .device(let did):
                if let cid = childDevices.first(where: { $0.id == did })?.childProfileID {
                    scheduleActiveChildren.remove(cid)
                }
            case .allDevices:
                scheduleActiveChildren.removeAll()
            }
        case .returnToSchedule:
            switch target {
            case .child(let cid): scheduleActiveChildren.insert(cid)
            case .device(let did):
                if let cid = childDevices.first(where: { $0.id == did })?.childProfileID {
                    scheduleActiveChildren.insert(cid)
                }
            case .allDevices:
                for child in orderedChildProfiles { scheduleActiveChildren.insert(child.id) }
            }
        default:
            break
        }

        // Expire stale pending mode commands for this target BEFORE pushing the new one.
        // This must complete synchronously so the child doesn't pick up stale commands
        // in the window between the old commands existing and the new one arriving.
        if action.isModeCommand {
            do {
                let stale = try await cloudKit.fetchPendingModeCommands(
                    familyID: familyID, target: target
                )
                // Expire all stale commands concurrently for speed.
                await withTaskGroup(of: Void.self) { group in
                    for cmd in stale {
                        group.addTask {
                            try? await cloudKit.updateCommandStatus(cmd.id, status: .expired)
                            #if DEBUG
                            print("[BigBrother] Expired stale pending command: \(cmd.action.displayDescription) (id=\(cmd.id))")
                            #endif
                        }
                    }
                }
            } catch {
                // Non-fatal — child-side dedup handles it as a safety net.
                #if DEBUG
                print("[BigBrother] Failed to expire stale commands: \(error)")
                #endif
            }
        }

        var command = RemoteCommand(
            familyID: familyID,
            target: target,
            action: action,
            issuedBy: "Parent"
        )

        // Sign mode commands with parent's ED25519 private key.
        if action.isModeCommand,
           let privateKeyData = try? keychain.getData(forKey: StorageKeys.commandSigningPrivateKey) {
            command.signatureBase64 = try? CommandSigner.sign(command: command, privateKeyData: privateKeyData)
        }

        try await cloudKit.pushCommand(command)
    }

    /// Push the parent PIN hash to all child devices via remote command.
    /// Tracks the raw (pre-encryption) PIN hash that was last synced.
    /// Persisted so we don't re-sync on every app launch.
    private var lastSyncedPINBase64: String? {
        get { UserDefaults.standard.string(forKey: "lastSyncedPINBase64") }
        set { UserDefaults.standard.set(newValue, forKey: "lastSyncedPINBase64") }
    }

    func syncPINToChildDevices() async {
        // Don't sync if there are no children.
        guard !childProfiles.isEmpty else { return }
        guard let hashData = try? keychain.getData(forKey: StorageKeys.parentPINHash) else { return }

        // Encrypt the PIN hash before sending over CloudKit public database.
        // Use the first parent's raw public key as enrollment secret.
        // Parent stores raw key bytes; this is consistent with child-side decryption.
        let enrollmentSecret: Data? = {
            guard let stored = try? keychain.getData(forKey: StorageKeys.commandSigningPublicKey) else { return nil }
            // Try JSON array format first (shouldn't happen on parent, but defensive)
            if let keys = try? JSONDecoder().decode([String].self, from: stored),
               let first = keys.first,
               let raw = Data(base64Encoded: first) {
                return raw
            }
            return stored
        }()
        // Compare raw hash (pre-encryption) to avoid re-syncing when encryption
        // produces different ciphertext for the same plaintext (random nonce).
        let rawBase64 = hashData.base64EncodedString()
        guard rawBase64 != lastSyncedPINBase64 else { return }

        let dataToSend: String
        if let familyID = parentState?.familyID,
           let encrypted = try? FamilyDerivedKey.encrypt(hashData, familyID: familyID, enrollmentSecret: enrollmentSecret, purpose: "pin-sync") {
            dataToSend = encrypted.base64EncodedString()
        } else {
            dataToSend = rawBase64
        }

        do {
            try await sendCommand(target: .allDevices, action: .syncPINHash(base64: dataToSend))
            // Only mark as synced after successful send.
            lastSyncedPINBase64 = rawBase64
        } catch {
            #if DEBUG
            print("[BigBrother] PIN sync command failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Child Actions

    private var commandPollTimer: Timer?
    private var scheduleSyncTimer: Timer?
    private var eventSyncTimer: Timer?

    /// Start periodic sync for child devices.
    func startChildSync() {
        heartbeatService?.startHeartbeat()
        startCommandPolling()
        startScheduleSync()
        startEventSync()
        DeviceLockMonitor.shared.startMonitoring()

        // Child devices clean up their own old records (parent can't delete
        // child-created records in CloudKit's public database).
        if let familyID = enrollmentState?.familyID, let ck = cloudKit {
            Task.detached {
                await CloudKitCleanupService.performCleanup(cloudKit: ck, familyID: familyID)
            }
        }
    }

    /// On child startup, if there's no local policy snapshot (e.g. fresh install
    /// or app update that cleared storage), recover the intended mode from local
    /// state (ModeStackResolver) first, then fall back to CloudKit commands.
    func recoverModeIfNeeded() async {
        guard deviceRole == .child,
              let enrollment = enrollmentState,
              let cloudKit,
              let commandProcessor = commandProcessor as? CommandProcessorImpl,
              snapshotStore?.loadCurrentSnapshot() == nil else { return }

        #if DEBUG
        print("[BigBrother] No local snapshot — recovering mode")
        #endif

        // First, process any pending commands (they take priority).
        try? await commandProcessor.processIncomingCommands()
        refreshLocalState()

        // If pending commands gave us a snapshot, we're done.
        if snapshotStore?.loadCurrentSnapshot() != nil { return }

        // Use ModeStackResolver as the local source of truth — it reads
        // TemporaryUnlockState, TimedUnlockInfo, lockUntil, schedule profile,
        // and cleans up expired state as a side effect.
        let resolution = ModeStackResolver.resolve(storage: storage)
        let recoveredMode = resolution.mode

        #if DEBUG
        print("[BigBrother] Recovering from ModeStackResolver: \(recoveredMode.rawValue) (\(resolution.reason))")
        #endif
        try? commandProcessor.applyModeDirect(recoveredMode, enrollment: enrollment)
        refreshLocalState()
    }

    /// Stop periodic sync.
    func stopChildSync() {
        heartbeatService?.stopHeartbeat()
        commandPollTimer?.invalidate()
        commandPollTimer = nil
        scheduleSyncTimer?.invalidate()
        scheduleSyncTimer = nil
        eventSyncTimer?.invalidate()
        eventSyncTimer = nil
    }

    /// Poll for commands every 5 seconds for fast response to parent actions.
    /// Uses RunLoop.main + .common mode so polling continues even while the
    /// child is actively scrolling / touching the screen.
    private func startCommandPolling() {
        commandPollTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                try? await self.commandProcessor?.processIncomingCommands()
                await MainActor.run { self.refreshLocalState() }
                // Send heartbeat after processing commands so parent sees mode confirmation quickly.
                try? await self.heartbeatService?.sendNow(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        commandPollTimer = timer
        // Fire immediately.
        Task {
            #if DEBUG
            print("[BigBrother] Command polling started (every 5s)")
            #endif
            try? await commandProcessor?.processIncomingCommands()
            refreshLocalState()
            // Send immediate heartbeat so parent sees confirmed mode without waiting 5 min.
            try? await heartbeatService?.sendNow(force: false)
        }
    }

    /// Sync pending events (e.g. unlock requests from extensions) every 5 seconds.
    /// Short interval ensures unlock requests reach CloudKit quickly so parents
    /// get notified promptly.
    private func startEventSync() {
        eventSyncTimer?.invalidate()
        let evTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.eventLogger?.syncPendingEvents()
                #if DEBUG
                // Dump only newly appended extension diagnostics so stale entries
                // do not keep replaying every cycle.
                let diags = self.storage.readDiagnosticEntries(category: nil)
                    .filter { $0.category == .shieldAction || $0.category == .shieldConfig || $0.category == .activityReport || $0.category == .eventUpload }
                    .filter { diag in
                        guard let lastPrintedAt = self.lastPrintedExtensionDiagnosticAt else {
                            return true
                        }
                        return diag.timestamp > lastPrintedAt
                    }
                    .sorted { $0.timestamp < $1.timestamp }
                for d in diags {
                    print("[BigBrother] ExtDiag[\(d.category.rawValue)] \(d.message)")
                    self.lastPrintedExtensionDiagnosticAt = d.timestamp
                }
                #endif
            }
        }
        RunLoop.main.add(evTimer, forMode: .common)
        eventSyncTimer = evTimer
        #if DEBUG
        print("[BigBrother] Event sync started (every 5s)")
        #endif
    }

    /// Fetch and register the schedule profile assigned to this child device.
    /// Called during child sync to keep DeviceActivity schedules current.
    func syncScheduleProfile() async {
        guard deviceRole == .child,
              let enrollment = enrollmentState,
              let cloudKit else { return }

        do {
            // Fetch this device's record to get the assigned schedule profile ID.
            let devices = try await cloudKit.fetchDevices(familyID: enrollment.familyID)
            guard let myDevice = devices.first(where: { $0.id == enrollment.deviceID }) else { return }

            // Update penalty timer data from parent.
            childPenaltySeconds = myDevice.penaltySeconds
            childPenaltyTimerEndTime = myDevice.penaltyTimerEndTime

            // Cache self-unlock budget from CloudKit device record.
            cacheSelfUnlockBudget(from: myDevice)

            // Sync restrictions from CloudKit — the parent writes restrictionsJSON
            // to the device record when toggling. This ensures the child gets the
            // correct restrictions even if the setRestrictions command was lost.
            if let json = myDevice.restrictionsJSON,
               let data = json.data(using: .utf8),
               let synced = try? JSONDecoder().decode(DeviceRestrictions.self, from: data) {
                let local = storage.readDeviceRestrictions()
                if local != synced {
                    try? storage.writeDeviceRestrictions(synced)
                    // Re-apply enforcement so the change takes effect immediately.
                    if let snapshot = snapshotStore?.loadCurrentSnapshot() {
                        try? enforcement?.apply(snapshot.effectivePolicy)
                    }
                }
            }

            guard let profileID = myDevice.scheduleProfileID else {
                // No schedule profile assigned — clear any existing registration.
                if familyControlsAvailable {
                    ScheduleRegistrar.clearAll(storage: storage)
                }
                return
            }

            // Check if we already have this exact version registered.
            let currentProfile = storage.readActiveScheduleProfile()

            // Skip CloudKit fetch if profile ID and version match what we have locally.
            let localVersionKey = "scheduleProfileVersion.\(enrollment.deviceID.rawValue)"
            let localVersion = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .object(forKey: localVersionKey) as? Date
            if let current = currentProfile,
               current.id == profileID,
               let deviceVersion = myDevice.scheduleProfileVersion,
               let cached = localVersion,
               deviceVersion == cached {
                return
            }

            // Fetch the full schedule profile.
            let profiles = try await cloudKit.fetchScheduleProfiles(familyID: enrollment.familyID)
            guard let profile = profiles.first(where: { $0.id == profileID }) else { return }

            // Skip if local profile matches CloudKit profile.
            // Re-registering DeviceActivity schedules triggers intervalDidStart callbacks,
            // which causes cascading events — only re-register when content actually changed.
            if let current = currentProfile, current == profile {
                return
            }

            if familyControlsAvailable {
                ScheduleRegistrar.register(profile, storage: storage)
                scheduleNextScheduleBGTask()
                // Cache the version so we skip redundant fetches.
                if let deviceVersion = myDevice.scheduleProfileVersion {
                    UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                        .set(deviceVersion, forKey: localVersionKey)
                }
                #if DEBUG
                print("[BigBrother] Schedule profile updated: \(profile.name) (\(profile.unlockedWindows.count) unlocked, \(profile.lockedWindows.count) locked windows)")
                #endif
            }
        } catch {
            #if DEBUG
            print("[BigBrother] Schedule profile sync failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Sync per-app time limit configs from CloudKit and re-register DeviceActivity events.
    func syncTimeLimits() async {
        guard deviceRole == .child,
              let enrollment = enrollmentState,
              let cloudKit else { return }

        do {
            let configs = try await cloudKit.fetchTimeLimitConfigs(childProfileID: enrollment.childProfileID)
            var localLimits = storage.readAppTimeLimits()
            var changed = false

            for config in configs where config.isActive {
                if let idx = localLimits.firstIndex(where: { $0.fingerprint == config.appFingerprint }) {
                    if localLimits[idx].dailyLimitMinutes != config.dailyLimitMinutes {
                        localLimits[idx].dailyLimitMinutes = config.dailyLimitMinutes
                        localLimits[idx].appName = config.appName
                        localLimits[idx].updatedAt = Date()
                        changed = true
                    }
                }
            }

            // Remove limits whose config was deleted in CloudKit
            let activeFingerprints = Set(configs.filter(\.isActive).map(\.appFingerprint))
            let before = localLimits.count
            localLimits.removeAll { $0.dailyLimitMinutes > 0 && !activeFingerprints.contains($0.fingerprint) }
            if localLimits.count != before { changed = true }

            if changed {
                try? storage.writeAppTimeLimits(localLimits)
                if familyControlsAvailable {
                    ScheduleRegistrar.registerTimeLimitEvents(limits: localLimits)
                }
            }
        } catch {
            #if DEBUG
            print("[BigBrother] Time limit sync failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Check for schedule profile changes every 60 seconds.
    private func startScheduleSync() {
        scheduleSyncTimer?.invalidate()
        let schTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.syncScheduleProfile()
                await self.syncTimeLimits()
                // Every 60 seconds: verify enforcement matches ModeStackResolver.
                // This catches missed Monitor callbacks, stale ManagedSettingsStore,
                // and any other drift. If shields are wrong, re-apply immediately.
                self.verifyAndFixEnforcement()
            }
        }
        RunLoop.main.add(schTimer, forMode: .common)
        scheduleSyncTimer = schTimer
        // Fire immediately on startup.
        Task {
            await syncScheduleProfile()
            await syncTimeLimits()
        }
    }

    /// Every-60-second enforcement verification.
    /// Compares ModeStackResolver (what SHOULD be enforced) against actual
    /// ManagedSettingsStore state. If they disagree, re-applies enforcement.
    /// This is the safety net for missed Monitor callbacks.
    private func verifyAndFixEnforcement() {
        guard deviceRole == .child, let enforcement else { return }

        let resolution = ModeStackResolver.resolve(storage: storage)
        let diag = enforcement.shieldDiagnostic()
        let shouldBeShielded = resolution.mode != .unlocked
        let isShielded = diag.shieldsActive || diag.categoryActive

        if shouldBeShielded != isShielded {
            // Mismatch — fix it
            let corrected = EffectivePolicy(
                resolvedMode: resolution.mode,
                isTemporaryUnlock: resolution.isTemporary,
                temporaryUnlockExpiresAt: resolution.expiresAt,
                shieldedCategoriesData: snapshotStore?.loadCurrentSnapshot()?.effectivePolicy.shieldedCategoriesData,
                allowedAppTokensData: snapshotStore?.loadCurrentSnapshot()?.effectivePolicy.allowedAppTokensData,
                warnings: [],
                policyVersion: (snapshotStore?.loadCurrentSnapshot()?.effectivePolicy.policyVersion ?? 0) + 1
            )
            try? enforcement.apply(corrected)

            // Update snapshot so it matches reality
            let snap = PolicySnapshot(
                source: .restoration,
                trigger: "60s enforcement check: shields were \(isShielded ? "UP" : "DOWN"), should be \(shouldBeShielded ? "UP" : "DOWN") (mode: \(resolution.mode.rawValue))",
                effectivePolicy: corrected
            )
            try? storage.commitCorrectedSnapshot(snap)

            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "60s enforcement fix",
                details: "Shields \(isShielded ? "UP" : "DOWN") → \(shouldBeShielded ? "UP" : "DOWN") (mode: \(resolution.mode.rawValue), reason: \(resolution.reason))"
            ))

            // Log an event so the parent is notified via SafetyEventNotificationService.
            eventLogger?.log(.enforcementDegraded, details: "Shields were \(isShielded ? "up" : "down") but should be \(shouldBeShielded ? "up" : "down") — auto-corrected (mode: \(resolution.mode.rawValue))")

            // Write mainAppLastActiveAt so tunnel knows we're alive and fixing things
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "mainAppLastActiveAt")

            // Force heartbeat so parent sees corrected state immediately
            Task {
                try? await heartbeatService?.sendNow(force: true)
            }
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

    // MARK: - Self Unlock

    /// Penalty phase ended — unlock the device for the free time window.
    func applyTimedUnlockStart() {
        guard let info = storage.readTimedUnlockInfo() else { return }
        let remainingFreeTime = Int(info.lockAt.timeIntervalSinceNow)
        guard remainingFreeTime > 0 else { return }
        guard let cmdProcessor = commandProcessor as? CommandProcessorImpl else { return }
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
        ) else { return }
        do {
            try cmdProcessor.applyTemporaryUnlockDirect(
                durationSeconds: remainingFreeTime,
                enrollment: enrollment
            )
            refreshLocalState()
            ModeChangeNotifier.notifyTemporaryUnlock(durationSeconds: remainingFreeTime)
        } catch {
            #if DEBUG
            print("[BigBrother] Timed unlock start failed: \(error)")
            #endif
        }
    }

    /// Ensure device is locked during the penalty phase of a timed unlock.
    /// Called as a safety net from BGTask if the device somehow unlocked.
    func enforcePenaltyPhaseLock() {
        guard enforcement != nil else { return }
        guard let snapshot = storage.readPolicySnapshot() else { return }
        if snapshot.effectivePolicy.resolvedMode == .unlocked {
            // Device is unlocked but should be locked during penalty — re-apply.
            // Save timed unlock info before applyModeDirect clears it.
            let savedInfo = storage.readTimedUnlockInfo()
            let mode: LockMode = storage.readActiveScheduleProfile()?.lockedMode ?? .restricted
            guard let enrollment = try? keychain.get(
                ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
            ) else { return }
            guard let cmdProcessor = commandProcessor as? CommandProcessorImpl else { return }
            try? cmdProcessor.applyModeDirect(mode, enrollment: enrollment)
            // Re-write timed unlock info since applyModeDirect clears it.
            if let info = savedInfo {
                try? storage.writeTimedUnlockInfo(info)
            }
            refreshLocalState()
        }
    }

    /// Free time window ended — re-lock the device.
    func applyTimedUnlockEnd() {
        // Read previous mode BEFORE clearing state.
        // Prefer TimedUnlockInfo.previousMode (set when the timed unlock was created)
        // over TemporaryUnlockState.previousMode (which may be stale if a schedule
        // transition overwrote it while the free phase was active).
        let timedPreviousMode = storage.readTimedUnlockInfo()?.previousMode
        let tempPreviousMode = storage.readTemporaryUnlockState()?.previousMode
        let previousMode = timedPreviousMode ?? tempPreviousMode ?? .restricted
        try? storage.clearTimedUnlockInfo()
        try? storage.clearTemporaryUnlockState()
        guard enforcement != nil else { return }
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
        let isScheduleDriven = defaults.object(forKey: "scheduleDrivenMode") == nil
            || defaults.bool(forKey: "scheduleDrivenMode")
        let mode: LockMode
        if isScheduleDriven, let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
        } else {
            mode = previousMode
        }
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
        ) else { return }
        guard let cmdProcessor = commandProcessor as? CommandProcessorImpl else { return }
        do {
            try cmdProcessor.applyModeDirect(mode, enrollment: enrollment)
            refreshLocalState()
            ModeChangeNotifier.notify(newMode: mode)
        } catch {
            #if DEBUG
            print("[BigBrother] Timed unlock end failed: \(error)")
            #endif
        }
    }

    // MARK: - Schedule Transition Enforcement

    /// Enforce the correct mode based on the active schedule profile.
    /// Called from the 1s timer and BGTask as a safety net in case the
    /// DeviceActivityMonitor extension missed an unlocked window transition.
    func enforceScheduleTransition() {
        guard enforcement != nil else { return }
        guard let profile = storage.readActiveScheduleProfile() else { return }
        // Don't override active temporary/timed unlocks.
        if let temp = storage.readTemporaryUnlockState(), temp.expiresAt > Date() { return }
        if storage.readTimedUnlockInfo() != nil { return }
        // Don't override manual mode commands (parent sent setMode directly).
        // scheduleDrivenMode is set to false by setMode and true by returnToSchedule.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
        if defaults.object(forKey: "scheduleDrivenMode") != nil && !defaults.bool(forKey: "scheduleDrivenMode") {
            return
        }

        let now = Date()
        let expectedMode = profile.resolvedMode(at: now)
        let currentMode = snapshotStore?.loadCurrentSnapshot()?.effectivePolicy.resolvedMode

        if expectedMode != currentMode {
            guard let enrollment = try? keychain.get(
                ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
            ) else { return }
            guard let cmdProcessor = commandProcessor as? CommandProcessorImpl else { return }
            try? cmdProcessor.applyModeDirect(expectedMode, enrollment: enrollment)
            refreshLocalState()
            eventLogger?.log(.policyReconciled, details: "Timer safety net: applied \(expectedMode.rawValue) from schedule")
            #if DEBUG
            print("[BigBrother] Schedule safety net: applied \(expectedMode.rawValue)")
            #endif
        }
    }

    /// Schedule a BGProcessingTask at the next schedule transition time.
    func scheduleNextScheduleBGTask() {
        guard let profile = storage.readActiveScheduleProfile(),
              let nextTransition = profile.nextTransitionTime(from: Date()) else { return }
        AppDelegate.scheduleRelockTask(at: nextTransition)
        #if DEBUG
        print("[BigBrother] Scheduled BGTask for next schedule transition at \(nextTransition)")
        #endif
    }

    /// Trigger a child-initiated self-unlock (15 minutes).
    func applySelfUnlock() {
        guard let cmdProcessor = commandProcessor as? CommandProcessorImpl else { return }
        do {
            try cmdProcessor.applySelfUnlock(durationSeconds: 900)
            refreshLocalState()
            // Send heartbeat so parent sees the self-unlock immediately.
            Task {
                try? await heartbeatService?.sendNow(force: true)
                try? await eventLogger?.syncPendingEvents()
            }
        } catch {
            #if DEBUG
            print("[BigBrother] Self-unlock failed: \(error)")
            #endif
        }
    }

    /// Cache the self-unlock budget from the CloudKit device record into App Group storage.
    private func cacheSelfUnlockBudget(from device: ChildDevice) {
        let budget = device.selfUnlocksPerDay ?? 0
        let today = SelfUnlockState.todayDateString()
        let current = storage.readSelfUnlockState()

        if budget > 0 {
            if let current, current.date == today {
                // Same day — update budget if parent changed it, cap usedCount to new budget.
                if current.budget != budget {
                    try? storage.writeSelfUnlockState(SelfUnlockState(
                        date: today, usedCount: min(current.usedCount, budget), budget: budget
                    ))
                }
            } else {
                // New day or no state — reset counter with new budget.
                try? storage.writeSelfUnlockState(SelfUnlockState(
                    date: today, usedCount: 0, budget: budget
                ))
            }
        } else if current != nil {
            // Budget removed — write state with budget 0 so UI hides the card.
            try? storage.writeSelfUnlockState(SelfUnlockState(
                date: today, usedCount: 0, budget: 0
            ))
        }
    }
}
