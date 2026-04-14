import Foundation
import CloudKit
import CoreLocation
import DeviceActivity
import FamilyControls
import ManagedSettings
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

    /// Rolling history of last 3 heartbeats per device (parent mode).
    /// Keyed by deviceID raw value. Most recent first.
    @ObservationIgnored var heartbeatHistory: [String: [DeviceHeartbeat]] = [:]

    /// Record new heartbeats into the rolling history buffer.
    func recordHeartbeatHistory(_ heartbeats: [DeviceHeartbeat]) {
        for hb in heartbeats {
            let key = hb.deviceID.rawValue
            var history = heartbeatHistory[key] ?? []
            if history.first?.timestamp == hb.timestamp { continue }
            history.insert(hb, at: 0)
            if history.count > 3 { history = Array(history.prefix(3)) }
            heartbeatHistory[key] = history
        }
        if deviceRole == .parent { autoDistributeSigningKeysIfNeeded(heartbeats) }
    }

    @ObservationIgnored private var signingKeyPushSent: Set<DeviceID> = []

    private func ensureSigningKeyExists() {
        guard (try? keychain.getData(forKey: StorageKeys.commandSigningPrivateKey)) == nil else { return }
        let (privateKey, publicKey) = CommandSigner.generateKeyPair()
        try? keychain.setData(privateKey, forKey: StorageKeys.commandSigningPrivateKey)
        try? keychain.setData(publicKey, forKey: StorageKeys.commandSigningPublicKey)
        NSLog("[Parent] Generated missing signing keypair")
    }

    private func autoDistributeSigningKeysIfNeeded(_ heartbeats: [DeviceHeartbeat]) {
        guard let pubKeyData = try? keychain.getData(forKey: StorageKeys.commandSigningPublicKey),
              pubKeyData.count >= 32 else {
            NSLog("[Parent] No signing public key in Keychain — cannot distribute")
            return
        }
        let pubKeyBase64 = pubKeyData.base64EncodedString()

        for hb in heartbeats {
            guard hb.hasSigningKeys == false,
                  !signingKeyPushSent.contains(hb.deviceID) else { continue }
            signingKeyPushSent.insert(hb.deviceID)
            Task {
                try? await sendCommand(
                    target: .device(hb.deviceID),
                    action: .addTrustedSigningKey(publicKeyBase64: pubKeyBase64)
                )
                NSLog("[Parent] Auto-pushed signing key to \(hb.deviceID.rawValue)")
            }
        }
    }

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

    /// Look up child detail view model by device ID (for notification action handling).
    func childDetailViewModel(forDeviceID deviceID: DeviceID) -> ChildDetailViewModel? {
        guard let device = childDevices.first(where: { $0.id == deviceID }) else { return nil }
        return childDetailViewModel(forID: device.childProfileID)
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

    /// Set to true when a requestChildAppPick command is received.
    var showChildAppPick: Bool = false

    /// Expected mode per child, set when any view model sends a mode command.
    /// Used by the dashboard to show the correct mode before heartbeat confirms.
    /// Cleared when a heartbeat confirms the mode.
    var expectedModes: [ChildProfileID: (mode: LockMode, sentAt: Date)] = [:]
    var childrenManuallyOverridden: Set<ChildProfileID> = []
    var pendingReviewNeedsRefresh: Bool = false

    /// Recent commands sent by the parent, for diagnostic interleaving.
    /// Ring buffer of last 20 per child. Shown in diagnostic copy text
    /// alongside the child's enforcement log to reveal delivery delays.
    struct SentCommandEntry {
        let at: Date
        let action: String
        let childID: ChildProfileID
    }
    var sentCommandLog: [SentCommandEntry] = []
    private let sentCommandLogMax = 20

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

    /// Children with pending unlock/time requests (updated by unlock request polling).
    var childrenWithPendingRequests: Set<ChildProfileID> = []

    /// Pending app reviews keyed by child, shared across views.
    /// Single source of truth: push handlers upsert directly, ChildDetailViewModel
    /// reads via a computed property so new requests appear the instant a silent
    /// push lands — no refresh required.
    var pendingReviewsByChild: [ChildProfileID: [PendingAppReview]] = [:]

    /// Flash highlight a specific review after deep-link. ChildDetailView uses this
    /// to scroll-to and briefly pulse the card.
    var highlightedReviewID: UUID?

    /// Upsert a pending review into the shared store. Dedupes by `id`. Replaces
    /// an existing entry if present (e.g., the parent renames the app or the
    /// record is re-sent with updated fields).
    func upsertPendingReview(_ review: PendingAppReview) {
        var current = pendingReviewsByChild[review.childProfileID] ?? []
        if let idx = current.firstIndex(where: { $0.id == review.id }) {
            current[idx] = review
        } else {
            current.append(review)
        }
        pendingReviewsByChild[review.childProfileID] = current
    }

    /// Remove a pending review from the shared store.
    func removePendingReviews(childID: ChildProfileID, matching predicate: (PendingAppReview) -> Bool) {
        guard var current = pendingReviewsByChild[childID] else { return }
        current.removeAll(where: predicate)
        if current.isEmpty {
            pendingReviewsByChild.removeValue(forKey: childID)
        } else {
            pendingReviewsByChild[childID] = current
        }
    }

    /// Replace the full pending list for a child (used after loadPendingAppReviews).
    func setPendingReviews(_ reviews: [PendingAppReview], for childID: ChildProfileID) {
        if reviews.isEmpty {
            pendingReviewsByChild.removeValue(forKey: childID)
        } else {
            pendingReviewsByChild[childID] = reviews
        }
    }

    /// Temporary confirmation message shown on the child home screen (auto-dismisses).
    var childConfirmationMessage: String?

    // MARK: - Debug Mode

    /// Developer mode — shows build numbers, Insights tab, diagnostics.
    /// Persists across app restarts via UserDefaults.
    /// Always false in release/App Store builds.
    #if DEBUG
    var debugMode: Bool = UserDefaults.standard.bool(forKey: "fr.bigbrother.debugMode") {
        didSet { UserDefaults.standard.set(debugMode, forKey: "fr.bigbrother.debugMode") }
    }
    #else
    var debugMode: Bool = false
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
    private var unlockRequestPollTask: Task<Void, Never>?

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
                // Preserve existing displayName (set during enrollment) so tunnel can tag logs.
                let existingName: String? = {
                    guard let data = storage.readRawData(forKey: StorageKeys.cachedEnrollmentIDs),
                          let existing = try? JSONDecoder().decode(CachedEnrollmentIDs.self, from: data) else { return nil }
                    return existing.deviceDisplayName
                }()
                let cached = CachedEnrollmentIDs(deviceID: enrollment.deviceID, familyID: enrollment.familyID, deviceDisplayName: existingName)
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

    nonisolated private static func normalizeAppName(_ appName: String) -> String {
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

    nonisolated private static func isPlaceholderAppName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n.isEmpty || n == "unknown" || n == "an app" || n == "app"
            || n.hasPrefix("blocked app ") || n.contains("token(")
    }

    nonisolated private static func normalizeBundleID(_ bundleID: String?) -> String? {
        guard let bid = bundleID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !bid.isEmpty else {
            return nil
        }
        return bid.lowercased()
    }

    nonisolated private static func isUsefulManagedAppName(_ appName: String) -> Bool {
        let normalized = normalizeAppName(appName).lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.hasPrefix("app ") &&
            !normalized.hasPrefix("temporary") &&
            !normalized.hasPrefix("blocked app ") &&
            !normalized.contains("token(") &&
            !normalized.contains("data:") &&
            !normalized.contains("bytes)")
    }

    nonisolated private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func timeLimitConfigMatches(
        _ config: TimeLimitConfig,
        matchesAppName appName: String,
        bundleID: String?,
        fingerprint: String?
    ) -> Bool {
        let normalizedBundleID = Self.normalizeBundleID(bundleID)
        if let normalizedBundleID,
           Self.normalizeBundleID(config.bundleID) == normalizedBundleID {
            return true
        }
        if let fingerprint, config.appFingerprint == fingerprint {
            return true
        }
        return Self.isUsefulManagedAppName(appName) &&
            Self.normalizeAppName(config.appName) == Self.normalizeAppName(appName)
    }

    private func matchesTimeLimitConfig(_ config: TimeLimitConfig, limit: AppTimeLimit) -> Bool {
        timeLimitConfigMatches(
            config,
            matchesAppName: limit.appName,
            bundleID: limit.bundleID,
            fingerprint: limit.fingerprint
        )
    }

    private func matchesTimeLimitConfig(
        _ config: TimeLimitConfig,
        exhaustedEntry: TimeLimitExhaustedApp,
        nameCache: [String: String]
    ) -> Bool {
        if config.appFingerprint == exhaustedEntry.fingerprint {
            return true
        }
        if timeLimitConfigMatches(
            config,
            matchesAppName: exhaustedEntry.appName,
            bundleID: nil,
            fingerprint: exhaustedEntry.fingerprint
        ) {
            return true
        }
        let tokenKey = exhaustedEntry.tokenData.base64EncodedString()
        if let cachedName = nameCache[tokenKey],
           timeLimitConfigMatches(
               config,
               matchesAppName: cachedName,
               bundleID: nil,
               fingerprint: exhaustedEntry.fingerprint
           ) {
            return true
        }
        return false
    }

    nonisolated private static func shouldPreferTimeLimitConfig(
        _ lhs: TimeLimitConfig,
        over rhs: TimeLimitConfig
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        if lhs.isActive != rhs.isActive {
            return lhs.isActive && !rhs.isActive
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    nonisolated private static func pendingReview(
        _ review: PendingAppReview,
        matches config: TimeLimitConfig
    ) -> Bool {
        if let reviewBundleID = normalizeBundleID(review.bundleID),
           normalizeBundleID(config.bundleID) == reviewBundleID {
            return true
        }
        if config.appFingerprint == review.appFingerprint {
            return true
        }
        return isUsefulManagedAppName(review.appName) &&
            isUsefulManagedAppName(config.appName) &&
            normalizeAppName(review.appName) == normalizeAppName(config.appName)
    }

    nonisolated private static func pendingReview(
        _ review: PendingAppReview,
        isSupersededBy config: TimeLimitConfig
    ) -> Bool {
        guard pendingReview(review, matches: config) else { return false }
        return config.isActive || config.updatedAt >= review.updatedAt
    }

    func matchingTimeLimitConfig(
        appName: String,
        bundleID: String?,
        fingerprint: String,
        in configs: [TimeLimitConfig]
    ) -> TimeLimitConfig? {
        configs
            .filter {
                timeLimitConfigMatches(
                    $0,
                    matchesAppName: appName,
                    bundleID: bundleID,
                    fingerprint: fingerprint
                )
            }
            .sorted { Self.shouldPreferTimeLimitConfig($0, over: $1) }
            .first
    }

    func matchingActiveTimeLimitConfig(
        appName: String,
        bundleID: String?,
        fingerprint: String,
        in configs: [TimeLimitConfig]
    ) -> TimeLimitConfig? {
        matchingTimeLimitConfig(
            appName: appName,
            bundleID: bundleID,
            fingerprint: fingerprint,
            in: configs.filter(\.isActive)
        )
    }

    func storedCanonicalAppName(fingerprint: String, tokenKey: String? = nil) -> String? {
        let defaults = UserDefaults.appGroup

        if let nameMap = defaults?.dictionary(forKey: AppGroupKeys.tokenToAppName) as? [String: String] {
            if let fingerprintName = nameMap["fp:\(fingerprint)"],
               Self.isUsefulManagedAppName(fingerprintName) {
                return fingerprintName
            }
            if let tokenKey,
               let tokenName = nameMap[tokenKey],
               Self.isUsefulManagedAppName(tokenName) {
                return tokenName
            }
        }

        if let harvested = (defaults?.dictionary(forKey: AppGroupKeys.harvestedAppNames) as? [String: String])?[fingerprint],
           Self.isUsefulManagedAppName(harvested) {
            return harvested
        }

        if let tokenKey,
           let cached = storage.readAllCachedAppNames()[tokenKey],
           Self.isUsefulManagedAppName(cached) {
            return cached
        }

        return nil
    }

    private struct ManagedTokenCandidate {
        let tokenData: Data
        let fingerprint: String
        let appName: String?
        let bundleID: String?
    }

    private func localManagedTokenCandidates() -> [ManagedTokenCandidate] {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let limits = storage.readAppTimeLimits()
        let nameCache = storage.readAllCachedAppNames()

        var candidates: [ManagedTokenCandidate] = []
        var seenTokenKeys = Set<String>()

        func append(
            tokenData: Data,
            appName: String?,
            bundleID: String?
        ) {
            let tokenKey = tokenData.base64EncodedString()
            guard seenTokenKeys.insert(tokenKey).inserted else { return }
            candidates.append(
                ManagedTokenCandidate(
                    tokenData: tokenData,
                    fingerprint: TokenFingerprint.fingerprint(for: tokenData),
                    appName: appName,
                    bundleID: bundleID
                )
            )
        }

        for limit in limits {
            append(tokenData: limit.tokenData, appName: limit.appName, bundleID: limit.bundleID)
        }

        var selectionTokens = Set<ApplicationToken>()
        if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
           let selection = try? decoder.decode(FamilyActivitySelection.self, from: data) {
            selectionTokens.formUnion(selection.applicationTokens)
        }
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let allowedTokens = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            selectionTokens.formUnion(allowedTokens)
        }

        for token in selectionTokens {
            guard let tokenData = try? encoder.encode(token) else { continue }
            let tokenKey = tokenData.base64EncodedString()
            let existingLimit = limits.first { $0.tokenData == tokenData }
            let application = Application(token: token)
            append(
                tokenData: tokenData,
                appName: nameCache[tokenKey] ?? existingLimit?.appName ?? application.localizedDisplayName,
                bundleID: existingLimit?.bundleID ?? application.bundleIdentifier
            )
        }

        return candidates
    }

    @discardableResult
    func removeTimeLimitConfigLocally(
        _ config: TimeLimitConfig,
        removeAllowedTokens: Bool,
        shouldReapplyEnforcement: Bool = true
    ) -> Bool {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let limitsBefore = storage.readAppTimeLimits()
        let cache = storage.readAllCachedAppNames()
        var localLimits = limitsBefore
        var exhausted = storage.readTimeLimitExhaustedApps()

        var changed = false

        let originalLimitCount = localLimits.count
        localLimits.removeAll { matchesTimeLimitConfig(config, limit: $0) }
        if localLimits.count != originalLimitCount {
            changed = true
        }

        let originalExhaustedCount = exhausted.count
        exhausted.removeAll { matchesTimeLimitConfig(config, exhaustedEntry: $0, nameCache: cache) }
        if exhausted.count != originalExhaustedCount {
            changed = true
        }

        var allowedTokens = Set<ApplicationToken>()
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let existing = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            allowedTokens = existing
        }

        if removeAllowedTokens {
            let filtered = Set(allowedTokens.filter { token in
                guard let tokenData = try? encoder.encode(token) else { return true }
                let tokenKey = tokenData.base64EncodedString()
                let limit = limitsBefore.first { $0.tokenData == tokenData }
                let application = Application(token: token)
                let appName = cache[tokenKey] ?? limit?.appName ?? application.localizedDisplayName ?? ""
                let bundleID = limit?.bundleID ?? application.bundleIdentifier
                return !timeLimitConfigMatches(
                    config,
                    matchesAppName: appName,
                    bundleID: bundleID,
                    fingerprint: TokenFingerprint.fingerprint(for: tokenData)
                )
            })
            if filtered != allowedTokens {
                allowedTokens = filtered
                changed = true
            }
        }

        guard changed else { return false }

        if let data = try? encoder.encode(allowedTokens) {
            try? storage.writeRawData(data, forKey: StorageKeys.allowedAppTokens)
        }
        try? storage.writeAppTimeLimits(localLimits)
        try? storage.writeTimeLimitExhaustedApps(exhausted)
        if familyControlsAvailable {
            ScheduleRegistrar.registerTimeLimitEvents(limits: localLimits)
        }
        if shouldReapplyEnforcement,
           let snapshot = storage.readPolicySnapshot() {
            try? enforcement?.apply(snapshot.effectivePolicy)
        }
        return true
    }

    @discardableResult
    func applyTimeLimitConfigLocally(
        _ config: TimeLimitConfig,
        tokenData: Data,
        fallbackAppName: String,
        bundleID: String?,
        shouldReapplyEnforcement: Bool = true
    ) -> Bool {
        guard let token = try? JSONDecoder().decode(ApplicationToken.self, from: tokenData) else {
            return false
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let tokenKey = tokenData.base64EncodedString()
        let tokenFingerprint = TokenFingerprint.fingerprint(for: tokenData)
        let resolvedName = Self.isUsefulManagedAppName(config.appName) ? config.appName : fallbackAppName
        let resolvedBundleID = bundleID ?? config.bundleID

        var selection: FamilyActivitySelection
        if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
           let existing = try? decoder.decode(FamilyActivitySelection.self, from: data) {
            selection = existing
        } else {
            selection = FamilyActivitySelection()
        }

        var allowedTokens = Set<ApplicationToken>()
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let existing = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            allowedTokens = existing
        }

        var localLimits = storage.readAppTimeLimits()
        let originalLimits = localLimits
        var exhausted = storage.readTimeLimitExhaustedApps()
        let nameCache = storage.readAllCachedAppNames()

        var changed = false
        let previousWasAlreadyAllowed = allowedTokens.contains(token) ||
            localLimits.contains(where: { matchesTimeLimitConfig(config, limit: $0) && $0.wasAlreadyAllowed })

        let staleRemoved = exhausted.first {
            matchesTimeLimitConfig(config, exhaustedEntry: $0, nameCache: nameCache)
        }
        exhausted.removeAll { matchesTimeLimitConfig(config, exhaustedEntry: $0, nameCache: nameCache) }

        localLimits.removeAll { matchesTimeLimitConfig(config, limit: $0) }

        func isStaleMatch(_ candidate: ApplicationToken) -> Bool {
            guard let candidateData = try? encoder.encode(candidate) else { return false }
            if candidateData == tokenData { return false }

            let candidateKey = candidateData.base64EncodedString()
            let existingLimit = originalLimits.first { $0.tokenData == candidateData }
            let application = Application(token: candidate)
            let candidateName = nameCache[candidateKey] ?? existingLimit?.appName ?? application.localizedDisplayName ?? ""
            let candidateBundleID = existingLimit?.bundleID ?? application.bundleIdentifier

            return timeLimitConfigMatches(
                config,
                matchesAppName: candidateName,
                bundleID: candidateBundleID,
                fingerprint: TokenFingerprint.fingerprint(for: candidateData)
            )
        }

        let filteredSelection = Set(selection.applicationTokens.filter { !isStaleMatch($0) })
        if filteredSelection != selection.applicationTokens {
            selection.applicationTokens = filteredSelection
            changed = true
        }
        if selection.applicationTokens.insert(token).inserted {
            changed = true
        }

        let filteredAllowed = Set(allowedTokens.filter { !isStaleMatch($0) })
        if filteredAllowed != allowedTokens {
            allowedTokens = filteredAllowed
            changed = true
        }

        storage.cacheAppName(resolvedName, forTokenKey: tokenKey)

        if config.dailyLimitMinutes > 0 {
            let newLimit = AppTimeLimit(
                appName: resolvedName,
                tokenData: tokenData,
                bundleID: resolvedBundleID,
                fingerprint: tokenFingerprint,
                dailyLimitMinutes: config.dailyLimitMinutes,
                wasAlreadyAllowed: previousWasAlreadyAllowed
            )
            localLimits.append(newLimit)
            if let staleRemoved,
               staleRemoved.dateString == Self.currentDateString() {
                exhausted.append(TimeLimitExhaustedApp(
                    timeLimitID: newLimit.id,
                    appName: resolvedName,
                    tokenData: tokenData,
                    fingerprint: tokenFingerprint,
                    exhaustedAt: staleRemoved.exhaustedAt,
                    dateString: staleRemoved.dateString
                ))
            }
            changed = true
        } else if staleRemoved != nil {
            changed = true
        }

        if allowedTokens.insert(token).inserted {
            changed = true
        }

        guard changed else { return false }

        if let data = try? encoder.encode(selection) {
            try? storage.writeRawData(data, forKey: StorageKeys.familyActivitySelection)
        }
        if let data = try? encoder.encode(allowedTokens) {
            try? storage.writeRawData(data, forKey: StorageKeys.allowedAppTokens)
        }
        try? storage.writeAppTimeLimits(localLimits)
        try? storage.writeTimeLimitExhaustedApps(exhausted)
        if familyControlsAvailable {
            ScheduleRegistrar.registerTimeLimitEvents(limits: localLimits)
        }
        if shouldReapplyEnforcement,
           let snapshot = storage.readPolicySnapshot() {
            try? enforcement?.apply(snapshot.effectivePolicy)
        }
        return true
    }

    /// Whether FamilyControls/ManagedSettings are available.
    /// These frameworks crash without the FamilyControls entitlement approved by Apple.
    private(set) var familyControlsAvailable: Bool = false

    /// Create and wire all services. Called after init because some services
    /// depend on knowing the device role and enrollment state.
    func configureServices() {
        if deviceRole == .parent {
            ensureSigningKeyExists()
        }

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
            UserDefaults.appGroup?
                .set(authStatus.rawValue, forKey: "familyControlsAuthStatus")

            fcManager.observeAuthorizationChanges { [weak self] newStatus in
                UserDefaults.appGroup?
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
        cmdProcessor.onRequestChildAppPick = { [weak self] in
            self?.showChildAppPick = true
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
                guard UserDefaults.appGroup?.bool(forKey: "showPermissionFixerOnNextLaunch") != true else { return }
                locService?.setMode(mode)
            }
            cmdProcessor.onRequestLocation = { [weak locService] in
                guard UserDefaults.appGroup?.bool(forKey: "showPermissionFixerOnNextLaunch") != true else { return }
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
                guard UserDefaults.appGroup?.bool(forKey: "showPermissionFixerOnNextLaunch") != true else { return }
                Task { @MainActor in
                    try? await self?.enforcement?.requestAuthorization()
                    if locService?.mode == .off {
                        locService?.setMode(.onDemand)
                    }
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
            let debugDefaults = UserDefaults.appGroup
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
                    let defaults = UserDefaults.appGroup
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

        // Restore any persisted debug subscription override.
        subscriptionManager.restoreDebugOverride()

        // Freemium: when subscription expires, unlock non-free children.
        // When subscription resumes, re-apply enforcement.
        subscriptionManager.onStatusChange = { [weak self] oldStatus, newStatus in
            guard let self else { return }
            let wasSubscribed = oldStatus == .subscribed || oldStatus == .trial
            let isNowSubscribed = newStatus == .subscribed || newStatus == .trial
            let sorted = self.childProfiles.sorted { $0.createdAt < $1.createdAt }
            let paidChildren = sorted.dropFirst(SubscriptionManager.freeChildLimit)
            guard !paidChildren.isEmpty else { return }

            Task { @MainActor in
                if wasSubscribed && !isNowSubscribed {
                    // Subscription expired → unlock non-free children
                    for child in paidChildren {
                        try? await self.sendCommand(target: .child(child.id), action: .setMode(.unlocked))
                    }
                } else if !wasSubscribed && isNowSubscribed {
                    // Subscription restored → re-lock non-free children
                    for child in paidChildren {
                        try? await self.sendCommand(target: .child(child.id), action: .returnToSchedule)
                    }
                }
            }
        }
    }

    /// Sync pending app reviews to CloudKit. Reviews stay in the local file
    /// until the parent acts (handleReviewApp removes them). The local file is
    /// the kid's source of truth for the "Pending Parent Approval" card —
    /// wiping after upload made the card go blank as soon as the kid foregrounded
    /// the app, which hides legitimate pending requests until the parent acts.
    private func syncResolvedPendingReviews() async {
        guard let cloudKit else { return }
        guard let data = storage.readRawData(forKey: "pending_review_local.json"),
              let localReviews = try? JSONDecoder().decode([PendingAppReview].self, from: data),
              !localReviews.isEmpty else { return }

        // Backfill the name cache. Cross-reference each review's appFingerprint
        // against familyActivitySelection's tokens to recover the tokenData,
        // then cache (tokenKey → name). Without this, findTokensForAppName
        // fails when the parent's auto-approve sends allowManagedApp.
        if let selData = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
           let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: selData) {
            let encoder = JSONEncoder()
            let resolvedReviews = localReviews.filter { $0.nameResolved }
            let nameByFingerprint = Dictionary(
                uniqueKeysWithValues: resolvedReviews.map { ($0.appFingerprint, $0.appName) }
            )
            for token in selection.applicationTokens {
                guard let tokenData = try? encoder.encode(token) else { continue }
                let fp = TokenFingerprint.fingerprint(for: tokenData)
                if let name = nameByFingerprint[fp] {
                    storage.cacheAppName(name, forTokenKey: tokenData.base64EncodedString())
                }
            }
        }

        // Upload each review (idempotent — savePendingAppReview uses upsert
        // semantics so re-uploading an existing record is harmless). DO NOT
        // wipe the file afterwards; handleReviewApp removes individual entries
        // when the parent decides on each one.
        for review in localReviews {
            _ = try? await cloudKit.savePendingAppReview(review)
        }
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

        // Ping tunnel immediately on launch — clears DNS blackhole ASAP.
        vpnManager?.sendPing()
        UserDefaults.appGroup?
            .set(Date().timeIntervalSince1970, forKey: "mainAppLastActiveAt")

        // One-time migration: denyWebWhenRestricted used to default to true, which was wrong.
        // Reset it to false on all existing devices so web isn't blocked unless the parent
        // explicitly enables it. Future setRestrictions commands will set the correct value.
        let migrationKey = "migration_denyWebWhenLocked_default_fixed"
        let defaults = UserDefaults.appGroup
        if defaults?.bool(forKey: migrationKey) != true {
            var r = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            if r.denyWebWhenRestricted {
                r.denyWebWhenRestricted = false
                try? storage.writeDeviceRestrictions(r)
            }
            defaults?.set(true, forKey: migrationKey)
        }

        guard let enforcement, let eventLogger, let snapshotStore else {
            isRestored = true
            return
        }

        // Pre-load the snapshot from disk synchronously (fast — just file read).
        // This populates the UI immediately so the home screen shows the correct
        // mode instead of the "loading" placeholder for 30+ seconds.
        if let snapshot = snapshotStore.loadCurrentSnapshot() {
            currentEffectivePolicy = snapshot.effectivePolicy
            activeWarnings = snapshot.effectivePolicy.warnings
        }

        // Move the actual enforcement restoration to a background thread.
        // restorer.restore() makes synchronous ManagedSettings reads/writes which
        // can hang for 20-30 seconds when familycontrolsd is slow or degraded.
        // Running it on the main thread freezes the UI on every launch.
        let restorer = AppLaunchRestorer(
            keychain: keychain,
            storage: storage,
            enforcement: enforcement,
            eventLogger: eventLogger,
            snapshotStore: snapshotStore
        )
        // Wrap the call in a nonisolated function so the @Sendable closure
        // doesn't capture the non-Sendable AppLaunchRestorer struct directly.
        let runRestore: @Sendable () -> Void = {
            restorer.restore()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            runRestore()
            // After restoration, refresh the snapshot in case it changed.
            if let snapshot = snapshotStore.loadCurrentSnapshot() {
                DispatchQueue.main.async {
                    self?.currentEffectivePolicy = snapshot.effectivePolicy
                    self?.activeWarnings = snapshot.effectivePolicy.warnings
                }
            }
        }

        // Register the hourly reconciliation schedule so the monitor extension
        // periodically verifies enforcement state, even if the app isn't running.
        if familyControlsAvailable {
            // Move ALL DeviceActivity registration to background thread.
            // startMonitoring() is synchronous and can block for 20-30s with many milestones.
            DispatchQueue.global(qos: .userInitiated).async {
                let scheduleManager = ScheduleManagerImpl()
                do {
                    try scheduleManager.registerReconciliationSchedule()
                } catch {
                    NSLog("[BigBrother] Reconciliation registration FAILED on launch: \(error)")
                }

                // Register usage tracking milestones for screen time reporting.
                ScheduleRegistrar.registerUsageTracking()

                // Log all active activities so we can diagnose registration issues.
                let allActivities = DeviceActivityCenter().activities
                let reconciliation = allActivities.filter { $0.rawValue.hasPrefix("bigbrother.reconciliation") }
                let usage = allActivities.filter { $0.rawValue.hasPrefix("bigbrother.usagetracking") }
                NSLog("[BigBrother] Active activities: \(allActivities.count) total, \(reconciliation.count) reconciliation, \(usage.count) usage tracking")
                for a in reconciliation { NSLog("[BigBrother]   reconciliation: \(a.rawValue)") }
            }
        }

        isRestored = true
    }

    /// Immediate full sync when the child app comes to foreground.
    /// Pulls latest schedule, restrictions, and pending commands from CloudKit,
    /// applies enforcement, and sends a heartbeat so the parent sees current state.
    /// This ensures that when a kid opens BB, everything is instantly up to date.
    private var isForegroundSyncing = false

    /// Task that polls for commands while the app is in foreground.
    /// Push notifications are unreliable (iOS throttles silent pushes, iCloud
    /// account changes break CK subscriptions). This 3-second poll ensures
    /// commands are processed promptly when the parent sends them.
    private var foregroundCommandPollTask: Task<Void, Never>?

    /// Start polling for commands while the app is in foreground.
    func startForegroundCommandPoll() {
        guard deviceRole == .child else { return }
        stopForegroundCommandPoll()
        foregroundCommandPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch { return }
                try? await self?.commandProcessor?.processIncomingCommands()
            }
        }
    }

    /// Stop polling when the app goes to background.
    func stopForegroundCommandPoll() {
        foregroundCommandPollTask?.cancel()
        foregroundCommandPollTask = nil
    }

    func performForegroundSync() {
        guard deviceRole == .child else { return }
        guard !isForegroundSyncing else { return }
        isForegroundSyncing = true

        // Detect stale binary: if the tunnel has a newer build than our in-memory
        // constant, we're running old code after a devicectl install (the tunnel
        // restarts with new code but the app process may be resumed stale).
        // Force exit so iOS relaunches with the new binary.
        let tunnelBuild = UserDefaults.appGroup?
            .integer(forKey: "tunnelBuildNumber") ?? 0
        if tunnelBuild > AppConstants.appBuildNumber {
            exit(0)
        }

        // Ping tunnel IMMEDIATELY — before any async work. This clears schedule
        // DNS blackhole the instant the kid opens the app, not 30+ seconds later.
        vpnManager?.sendPing()
        let fgDefaults = UserDefaults.appGroup
        fgDefaults?.set(Date().timeIntervalSince1970, forKey: "mainAppLastActiveAt")
        fgDefaults?.set(Date().timeIntervalSince1970, forKey: "mainAppLastForegroundAt")

        Task {
            defer {
                Task { @MainActor in
                    self.isForegroundSyncing = false
                }
            }

            // b439: If the guided setup fixer is about to run, SKIP all
            // enforcement/VPN/rescue work. Applying enforcement before the user
            // has granted FC/Location/Motion/Notifications/VPN causes:
            //   - Screen Time prompts fired from the deep-rescue XPC poke
            //   - VPN install dialogs firing before the fixer can render its cards
            //   - A 60-second "locked-looking" UI while verification + recovery
            //     + rescue all run pointlessly
            // We still process incoming commands + sync schedule + send heartbeat
            // so the parent dashboard gets fresh data.
            let syncDefaults = UserDefaults.appGroup
            let fixerActive = syncDefaults?.bool(forKey: "showPermissionFixerOnNextLaunch") == true

            // CRITICAL PATH: process commands immediately — this is what the
            // parent is waiting for. processIncomingCommands handles its own
            // enforcement.apply() call internally via reapplyCurrentEnforcement,
            // so by the time this returns, the snapshot AND shields are updated.
            // Refresh UI right after so the user sees the new mode within
            // ~milliseconds of command processing finishing.
            try? await commandProcessor?.processIncomingCommands()
            await MainActor.run { self.refreshLocalState() }

            if fixerActive {
                // Skip enforcement/VPN/rescue until guided setup finishes.
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Foreground sync: guided setup active, skipping enforcement/VPN/rescue steps"
                ))
                // Fire-and-forget heartbeat so the parent sees liveness.
                let hbService = heartbeatService
                Task.detached { try? await hbService?.sendNow(force: true) }
                vpnManager?.sendPing()
                return
            }

            // EVERYTHING BELOW IS NON-CRITICAL — fire and forget. The user
            // already sees the correct mode at this point. The remaining work
            // is best-effort housekeeping (CK syncs, daemon rescue, heartbeat,
            // VPN install). Awaiting any of it serially used to add 6-15s of
            // pointless blocking after the mode change had already taken
            // effect locally.
            Task.detached { [weak self] in
                await self?.syncResolvedPendingReviews()
                await self?.syncScheduleProfile()

                // Verify enforcement vs ModeStackResolver. Normally redundant
                // (commandProcessor.apply already handled the mode change),
                // but catches stale snapshot/resolution drift caused by
                // schedule transitions or temp-unlock expiry that nothing
                // else nudges.
                await MainActor.run { self?.verifyAndFixEnforcement() }

                // Daemon rescue on every foreground wake — idempotent on a
                // healthy daemon, un-wedges a stuck one. Uses Thread.sleep
                // internally, MUST run off main actor (Task.detached gives
                // us that for free).
                if let enf = await self?.enforcement {
                    enf.forceDaemonRescue()
                }

                if let vpn = await self?.vpnManager {
                    await vpn.restartIfNeeded()
                }

                // Heartbeat so parent sees state immediately.
                try? await self?.heartbeatService?.sendNow(force: true)

                // Ping the tunnel to clear any stale blackholes.
                await MainActor.run { self?.vpnManager?.sendPing() }

                // Final UI refresh in case schedule sync changed mode.
                await MainActor.run { self?.refreshLocalState() }
            }

            // DeviceActivity health check — re-register if activities vanished.
            #if canImport(DeviceActivity)
            DispatchQueue.global(qos: .utility).async {
                let daCenter = DeviceActivityCenter()
                let reconciliationCount = daCenter.activities.filter { $0.rawValue.hasPrefix("bigbrother.reconciliation") }.count
                if reconciliationCount < 4 {
                    NSLog("[AppState] DeviceActivity health check: only \(reconciliationCount)/4 — re-registering")
                    try? ScheduleManagerImpl().registerReconciliationSchedule()
                }
                let usageCount = daCenter.activities.filter { $0.rawValue.hasPrefix("bigbrother.usagetracking") }.count
                if usageCount == 0 {
                    NSLog("[AppState] DeviceActivity health check: usage tracking missing — re-registering")
                    ScheduleRegistrar.registerUsageTracking()
                }
            }
            #endif
        }
    }

    /// Called when the child app proves it is running again after fail-safe mode.
    /// Clears the latched force-close flag and, when needed, restores the
    /// parent-chosen enforcement immediately instead of waiting for the next
    /// reconciliation cycle.
    func handleMainAppResponsive(reapplyEnforcement: Bool) {
        let defaults = UserDefaults.appGroup
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
    ///
    /// b439 (onboarding fix): If the guided setup flag is set (fresh install /
    /// reinstall), do NOT trigger the "Add VPN Configurations?" system dialog
    /// here — it would fire before the PermissionFixerView has a chance to
    /// render, ahead of the stepwise permission flow. The fixer has its own
    /// VPN step that calls installAndStart() in the right sequence. We still
    /// start an existing tunnel if one is already configured (no prompt).
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

            // Not configured. If PermissionFixerView is about to run, let it
            // handle the install in its step — don't fire the VPN system dialog
            // out of order.
            let defaults = UserDefaults.appGroup
            if defaults?.bool(forKey: "showPermissionFixerOnNextLaunch") == true {
                #if DEBUG
                print("[BigBrother] VPN install deferred — PermissionFixerView will handle it")
                #endif
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

        // b439 (UI freeze fix): If the guided setup fixer is active, defer
        // all enforcement work. This handler runs on @MainActor when the FC
        // auth status changes — which happens every time the user taps "Grant
        // Access" in the fixer's FC step. The enforcement.clearAllRestrictions()
        // + enforcement.apply() calls below take the static applyLock and can
        // fall into the deep daemon rescue (~6s of Thread.sleep per rescue
        // attempt, with retries), all on the main thread. Net result: the UI
        // freezes for 30-60+ seconds after each permission grant.
        //
        // During guided setup, skip the enforcement work entirely. The fixer
        // completes, the flag clears, and the next scenePhase=.active cycle
        // triggers a full apply() on a detached task via performForegroundSync.
        // We still update the allPermissionsGranted flags so services know
        // the auth state has changed.
        let fixerActiveDefaults = UserDefaults.appGroup
        let fixerActive = fixerActiveDefaults?.bool(forKey: "showPermissionFixerOnNextLaunch") == true
        if fixerActive {
            if newStatus == .denied || newStatus == .notDetermined {
                eventLogger.log(.familyControlsAuthChanged, details: "Authorization changed during guided setup")
                fixerActiveDefaults?.set(false, forKey: "allPermissionsGranted")
                fixerActiveDefaults?.set(false, forKey: "enforcementPermissionsOK")
            } else if newStatus == .authorized {
                eventLogger.log(.authorizationRestored, details: "Authorization granted during guided setup")
                fixerActiveDefaults?.set(true, forKey: "allPermissionsGranted")
                fixerActiveDefaults?.set(true, forKey: "enforcementPermissionsOK")
                // Update diagnostic write only — no enforcement.apply() here.
                NSLog("[BigBrother] handleAuthorizationChange: FC authorized during guided setup — deferring enforcement to post-fixer")
            }
            return
        }

        let authHealth = storage.readAuthorizationHealth()
        let currentSnapshot = snapshotStore.loadCurrentSnapshot()

        if newStatus == .denied || newStatus == .notDetermined {
            eventLogger.log(.familyControlsAuthChanged, details: "Authorization revoked")
            // Also log as authorizationLost so parent gets a critical notification
            eventLogger.log(.authorizationLost, details: "FamilyControls authorization revoked — shields may be down")
            // Signal tunnel to block internet immediately
            let permDefaults = UserDefaults.appGroup
            permDefaults?.set(false, forKey: "allPermissionsGranted")
            permDefaults?.set(false, forKey: "enforcementPermissionsOK")
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
                    alwaysAllowedTokensData: storage.readRawData(forKey: StorageKeys.allowedAppTokens),
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
                        // b439: Dispatch apply() off the main thread.
                        let enf = enforcement
                        let appliedPolicy = committed.effectivePolicy
                        let capturedSnapshotStore = snapshotStore
                        Task.detached {
                            try? enf.apply(appliedPolicy)
                            try? capturedSnapshotStore.markApplied()
                        }
                        currentEffectivePolicy = appliedPolicy
                        activeWarnings = appliedPolicy.warnings
                    }
                } catch {
                    // Log but don't crash.
                }
            }
        } else if newStatus == .authorized {
            eventLogger.log(.authorizationRestored, details: "Authorization restored")
            // Signal tunnel to unblock internet
            let permDefaults = UserDefaults.appGroup
            permDefaults?.set(true, forKey: "allPermissionsGranted")
            permDefaults?.set(true, forKey: "enforcementPermissionsOK")

            // Force heartbeat so parent sees restoration immediately
            Task { try? await heartbeatService?.sendNow(force: true) }

            // Re-register reconciliation schedules now that FC auth is available.
            // Registration before auth silently fails (DeviceActivity requires FC auth).
            try? ScheduleManagerImpl().registerReconciliationSchedule()
            NSLog("[BigBrother] Reconciliation schedules registered after auth restored")

            // Re-apply enforcement now that authorization is available.
            // b439: Dispatch the clearAllRestrictions + apply chain to a
            // detached task — both take the static applyLock and can block
            // the main thread for 6+ seconds (deep daemon rescue).
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
                    alwaysAllowedTokensData: storage.readRawData(forKey: StorageKeys.allowedAppTokens),
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
                        let enf = enforcement
                        let appliedPolicy = committed.effectivePolicy
                        let capturedSnapshotStore = snapshotStore
                        Task.detached {
                            // After FC auth is restored, ManagedSettingsStore
                            // may be corrupted — nuke all stores first, then
                            // re-apply from scratch.
                            try? enf.clearAllRestrictions()
                            try? enf.apply(appliedPolicy)
                            try? capturedSnapshotStore.markApplied()
                        }
                        currentEffectivePolicy = appliedPolicy
                        activeWarnings = appliedPolicy.warnings
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

        // Fetch all secondary data in PARALLEL. Previously sequential (4 round-trips
        // in series) which dominated the 30-60s refresh. Each task swallows its own
        // error locally so one slow/failing fetch doesn't cascade.
        async let devicesTask: [ChildDevice]? = {
            do { return try await cloudKit.fetchDevices(familyID: familyID) }
            catch { NSLog("[BigBrother] fetchDevices failed: \(error.localizedDescription)"); return nil }
        }()
        async let heartbeatsTask: [DeviceHeartbeat]? = {
            do { return try await cloudKit.fetchLatestHeartbeats(familyID: familyID) }
            catch { NSLog("[BigBrother] fetchLatestHeartbeats failed: \(error.localizedDescription)"); return nil }
        }()
        async let hbProfilesTask: [HeartbeatProfile]? = {
            do { return try await cloudKit.fetchHeartbeatProfiles(familyID: familyID) }
            catch { NSLog("[BigBrother] fetchHeartbeatProfiles failed: \(error.localizedDescription)"); return nil }
        }()
        async let scheduleProfilesTask: [ScheduleProfile]? = {
            do { return try await cloudKit.fetchScheduleProfiles(familyID: familyID) }
            catch { NSLog("[BigBrother] fetchScheduleProfiles failed: \(error.localizedDescription)"); return nil }
        }()

        let fetchedDevices = await devicesTask
        let fetchedHeartbeats = await heartbeatsTask
        let fetchedHBProfiles = await hbProfilesTask
        let fetchedScheduleProfiles = await scheduleProfilesTask

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
            recordHeartbeatHistory(heartbeats)
        } else if let devices = fetchedDevices {
            var merged = devices
            preserveLocalDeviceFields(into: &merged)
            if merged != childDevices { childDevices = merged }
        } else if let heartbeats = fetchedHeartbeats {
            if heartbeats != latestHeartbeats { latestHeartbeats = heartbeats }
            recordHeartbeatHistory(heartbeats)
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

        // Check for new pending app reviews and post notifications.
        // Push subscription wakes the app, but the notification post lives in
        // ChildDetailViewModel which only runs when that view is open. Without
        // this hook, parent only sees pending requests by manually opening the
        // child's detail screen.
        await checkForPendingAppReviewNotifications()

        // Ensure child devices have the latest parent PIN hash.
        await syncPINToChildDevices()

        // Pre-process driving routes and speed limits in background.
        // Runs on a background queue, throttled internally (skips if already running).
        // Populates RouteCache and SpeedLimitService disk cache so LocationMapView
        // loads instantly when the parent opens a child's driving history.
        if let familyID = parentState?.familyID {
            RouteProcessingService.shared.processIfNeeded(
                cloudKit: cloudKit,
                childDevices: childDevices,
                familyID: familyID
            )
        }

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

    /// Timestamp of last parent-initiated schedule assignment (optimistic UI).
    /// Used to prevent stale CK reads from reverting the in-memory schedule.
    var lastScheduleAssignmentAt: Date?

    /// Preserve parent-set fields from existing in-memory devices when CloudKit
    /// returns nil or stale values for those fields (write may not have propagated yet).
    private func preserveLocalDeviceFields(into devices: inout [ChildDevice]) {
        for i in devices.indices {
            if let existing = childDevices.first(where: { $0.id == devices[i].id }) {
                // If the fetched device has nil but our in-memory device has a value,
                // the parent likely set it recently and CloudKit hasn't caught up.
                if devices[i].scheduleProfileID == nil, existing.scheduleProfileID != nil {
                    devices[i].scheduleProfileID = existing.scheduleProfileID
                    devices[i].scheduleProfileVersion = existing.scheduleProfileVersion
                }
                // Guard against stale CK reads reverting a recent schedule assignment.
                // If parent just assigned a new schedule (< 30s ago) and CK returns a
                // different ID, keep the in-memory value — CK hasn't propagated yet.
                if let assignedAt = lastScheduleAssignmentAt,
                   Date().timeIntervalSince(assignedAt) < 30,
                   devices[i].scheduleProfileID != existing.scheduleProfileID,
                   existing.scheduleProfileID != nil {
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
        unlockRequestPollTask?.cancel()
        guard let familyID = parentState?.familyID else { return }
        unlockRequestPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch { return }
                self?.checkForUnlockRequestNotifications(familyID: familyID)
            }
        }
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
        unlockRequestPollTask?.cancel()
        unlockRequestPollTask = nil
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

        // Snapshot the @MainActor state we need, then run all CloudKit work
        // on a detached Task so this doesn't fight the main thread with the
        // user's pull-to-refresh or dashboard rendering.
        let profiles = childProfiles
        let devices = childDevices

        Task.detached { [cloudKit] in
            let since = Date().addingTimeInterval(-1800)
            let events = (try? await cloudKit.fetchEventLogs(familyID: familyID, since: since)) ?? []
            let heartbeatCutoff = Date().addingTimeInterval(-48 * 3600)

            // Fan out the per-child CK reads in parallel so 6 kids take ~1 round-trip,
            // not 6×. Each task returns that child's ID only if it has live reviews.
            let pendingChildIDs = await withTaskGroup(of: ChildProfileID?.self) { group in
                for profile in profiles {
                    let childDevicesForProfile = devices.filter { $0.childProfileID == profile.id }
                    let deviceIDs = Set(childDevicesForProfile.map(\.id))
                    group.addTask {
                        await Self.evaluatePendingReviewsForChild(
                            cloudKit: cloudKit,
                            profile: profile,
                            events: events,
                            childDevicesForProfile: childDevicesForProfile,
                            deviceIDs: deviceIDs,
                            heartbeatCutoff: heartbeatCutoff
                        )
                    }
                }
                var collected = Set<ChildProfileID>()
                for await result in group {
                    if let id = result { collected.insert(id) }
                }
                return collected
            }

            await MainActor.run { [weak self] in
                self?.childrenWithPendingRequests = pendingChildIDs
            }
        }
    }

    private static func evaluatePendingReviewsForChild(
        cloudKit: CloudKitServiceProtocol,
        profile: ChildProfile,
        events: [EventLogEntry],
        childDevicesForProfile: [ChildDevice],
        deviceIDs: Set<DeviceID>,
        heartbeatCutoff: Date
    ) async -> ChildProfileID? {
        async let configsTask: [TimeLimitConfig] = (try? await cloudKit.fetchTimeLimitConfigs(childProfileID: profile.id)) ?? []
        async let reviewsTask: [PendingAppReview] = (try? await cloudKit.fetchPendingAppReviews(childProfileID: profile.id)) ?? []
        let configs = await configsTask
        let allReviews = await reviewsTask

        UnlockRequestNotificationService.checkAndNotify(
            events: events,
            childDeviceIDs: deviceIDs,
            childName: profile.name,
            childProfileID: profile.id,
            timeLimitConfigs: configs
        )

        let aliveDeviceIDs: Set<DeviceID> = {
            var ids = Set<DeviceID>()
            for device in childDevicesForProfile {
                if let lastHB = device.lastHeartbeat, lastHB > heartbeatCutoff {
                    ids.insert(device.id)
                } else if device.lastHeartbeat == nil {
                    ids.insert(device.id)
                }
            }
            return ids
        }()
        let liveReviews = allReviews.filter { review in
            if !aliveDeviceIDs.isEmpty && !aliveDeviceIDs.contains(review.deviceID) { return false }
            if configs.contains(where: { Self.pendingReview(review, isSupersededBy: $0) }) { return false }
            return true
        }

        // Fire-and-forget deletes; don't block the set computation.
        let stale = allReviews.filter { r in !liveReviews.contains(where: { $0.id == r.id }) }
        if !stale.isEmpty {
            Task.detached { [cloudKit] in
                await withTaskGroup(of: Void.self) { group in
                    for r in stale {
                        group.addTask { try? await cloudKit.deletePendingAppReview(r.id) }
                    }
                }
            }
        }

        return liveReviews.isEmpty ? nil : profile.id
    }

    /// Fetch pending app reviews for all children and post local notifications
    /// for any new ones. Called from refreshDashboard so the parent gets a banner
    /// without needing to open ChildDetailView. Dedup is handled inside
    /// AppReviewNotificationService via UserDefaults-tracked IDs + fingerprints.
    private func checkForPendingAppReviewNotifications() async {
        guard let cloudKit else { return }
        // Fetch each child's pending reviews in parallel. Parent-side filtering
        // is just zombie-device purge — kid-side auto-cleanup drops duplicates
        // for already-approved apps before they reach CK.
        let profiles = childProfiles
        let devicesByChild = Dictionary(grouping: childDevices, by: \.childProfileID)
        let heartbeatCutoff = Date().addingTimeInterval(-48 * 3600)

        await withTaskGroup(of: (ChildProfile, [PendingAppReview], [PendingAppReview])?.self) { group in
            for profile in profiles {
                let kidDevices = devicesByChild[profile.id] ?? []
                group.addTask { [cloudKit] in
                    let all = (try? await cloudKit.fetchPendingAppReviews(childProfileID: profile.id)) ?? []
                    guard !all.isEmpty else { return nil }
                    let configs = (try? await cloudKit.fetchTimeLimitConfigs(childProfileID: profile.id)) ?? []
                    let alive: Set<DeviceID> = {
                        var ids = Set<DeviceID>()
                        for d in kidDevices {
                            if let hb = d.lastHeartbeat, hb > heartbeatCutoff { ids.insert(d.id) }
                            else if d.lastHeartbeat == nil { ids.insert(d.id) }
                        }
                        return ids
                    }()
                    let live = (alive.isEmpty ? all : all.filter { alive.contains($0.deviceID) }).filter { review in
                        if configs.contains(where: { Self.pendingReview(review, isSupersededBy: $0) }) {
                            return false
                        }
                        return true
                    }
                    let orphans = alive.isEmpty ? [] : all.filter { !alive.contains($0.deviceID) }
                    return (profile, live, orphans)
                }
            }
            for await result in group {
                guard let (profile, live, orphans) = result else { continue }
                AppReviewNotificationService.checkAndNotify(
                    reviews: live,
                    childName: profile.name,
                    childProfileID: profile.id
                )
                setPendingReviews(live, for: profile.id)
                if !orphans.isEmpty {
                    let ck = cloudKit
                    Task.detached { [ck] in
                        await withTaskGroup(of: Void.self) { g in
                            for r in orphans {
                                g.addTask { try? await ck.deletePendingAppReview(r.id) }
                            }
                        }
                    }
                }
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

        // Record for diagnostic interleaving.
        let childID: ChildProfileID? = {
            switch target {
            case .child(let cid): return cid
            case .device(let did): return childDevices.first(where: { $0.id == did })?.childProfileID
            case .allDevices: return nil
            }
        }()
        if let childID {
            sentCommandLog.append(SentCommandEntry(at: Date(), action: action.displayDescription, childID: childID))
            if sentCommandLog.count > sentCommandLogMax {
                sentCommandLog.removeFirst(sentCommandLog.count - sentCommandLogMax)
            }
        }
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

    private var commandPollTask: Task<Void, Never>?
    private var scheduleSyncTask: Task<Void, Never>?
    private var eventSyncTask: Task<Void, Never>?

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
              cloudKit != nil,
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
        commandPollTask?.cancel()
        commandPollTask = nil
        scheduleSyncTask?.cancel()
        scheduleSyncTask = nil
        eventSyncTask?.cancel()
        eventSyncTask = nil
    }

    /// Poll for commands every 5 seconds for fast response to parent actions.
    /// A Task loop is used (not `Timer.scheduledTimer`) so the cadence
    /// doesn't slip when the main run loop is busy with scroll/touch and
    /// so cancellation is structured through the task tree.
    private func startCommandPolling() {
        commandPollTask?.cancel()
        commandPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch { return }
                guard let self else { return }
                try? await self.commandProcessor?.processIncomingCommands()
                await MainActor.run { self.refreshLocalState() }
                // Send heartbeat after processing commands so parent sees mode confirmation quickly.
                try? await self.heartbeatService?.sendNow(force: false)
            }
        }
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
        eventSyncTask?.cancel()
        eventSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch { return }
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

            // Backfill display name in cached enrollment IDs so the tunnel
            // can tag enforcement log records with the actual device name
            // (UIDevice.current.name returns generic "iPhone"/"iPad" since iOS 16).
            if !myDevice.displayName.isEmpty {
                if let data = storage.readRawData(forKey: StorageKeys.cachedEnrollmentIDs),
                   var cached = try? JSONDecoder().decode(CachedEnrollmentIDs.self, from: data),
                   cached.deviceDisplayName != myDevice.displayName {
                    cached.deviceDisplayName = myDevice.displayName
                    if let updated = try? JSONEncoder().encode(cached) {
                        try? storage.writeRawData(updated, forKey: StorageKeys.cachedEnrollmentIDs)
                    }
                }
            }

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
                // No schedule profile assigned — clear any existing registration
                // and recompute effective mode so the device doesn't stay in a stale
                // schedule-driven state (e.g., overlocked after schedule removal).
                if familyControlsAvailable {
                    ScheduleRegistrar.clearAll(storage: storage)
                }
                let resolution = ModeStackResolver.resolve(storage: storage)
                if let snapshot = snapshotStore?.loadCurrentSnapshot(),
                   snapshot.effectivePolicy.resolvedMode != resolution.mode {
                    let corrected = EffectivePolicy(
                        resolvedMode: resolution.mode,
                        controlAuthority: resolution.controlAuthority,
                        shieldedCategoriesData: snapshot.effectivePolicy.shieldedCategoriesData,
                        allowedAppTokensData: snapshot.effectivePolicy.allowedAppTokensData,
                        deviceRestrictions: snapshot.effectivePolicy.deviceRestrictions,
                        warnings: [],
                        policyVersion: snapshot.effectivePolicy.policyVersion + 1
                    )
                    let snap = PolicySnapshot(
                        source: .restoration,
                        trigger: "Schedule profile cleared — recomputed mode to \(resolution.mode.rawValue)",
                        effectivePolicy: corrected
                    )
                    _ = try? storage.commitCorrectedSnapshot(snap)
                    try? enforcement?.apply(corrected)
                }
                return
            }

            // Check if we already have this exact version registered.
            let currentProfile = storage.readActiveScheduleProfile()

            // Skip CloudKit fetch if profile ID and version match what we have locally.
            let localVersionKey = "scheduleProfileVersion.\(enrollment.deviceID.rawValue)"
            let localVersion = UserDefaults.appGroup?
                .object(forKey: localVersionKey) as? Date
            if let current = currentProfile,
               current.id == profileID,
               let deviceVersion = myDevice.scheduleProfileVersion,
               let cached = localVersion,
               deviceVersion == cached {
                return
            }

            // Guard against stale CK device record reads reverting a fresh assignment.
            // When the command processor registers a new profile locally, it writes the
            // profile immediately. If this sync cycle reads a stale device record with
            // the OLD scheduleProfileID, we'd fetch and re-register the old profile,
            // undoing the new assignment. Check: if local profile has a DIFFERENT ID
            // than what CK says, and the local profile was registered recently (< 30s),
            // the CK read is likely stale — skip this cycle.
            if let current = currentProfile, current.id != profileID {
                let localAge = Date().timeIntervalSince(current.updatedAt)
                if localAge < 30 {
                    #if DEBUG
                    print("[BigBrother] Schedule sync skipped: local \(current.name) (\(current.id.uuidString.prefix(8))) registered \(Int(localAge))s ago, CK says \(profileID.uuidString.prefix(8)) — likely stale read")
                    #endif
                    return
                }
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
                    UserDefaults.appGroup?
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
            var changed = false
            let candidates = localManagedTokenCandidates()

            for config in configs where !config.isActive {
                if removeTimeLimitConfigLocally(
                    config,
                    removeAllowedTokens: true,
                    shouldReapplyEnforcement: false
                ) {
                    changed = true
                }
            }

            for config in configs where config.isActive {
                if let candidate = candidates.first(where: {
                    timeLimitConfigMatches(
                        config,
                        matchesAppName: $0.appName ?? "",
                        bundleID: $0.bundleID,
                        fingerprint: $0.fingerprint
                    )
                }), applyTimeLimitConfigLocally(
                    config,
                    tokenData: candidate.tokenData,
                    fallbackAppName: candidate.appName ?? config.appName,
                    bundleID: candidate.bundleID,
                    shouldReapplyEnforcement: false
                ) {
                    changed = true
                }
            }

            if changed, let snapshot = storage.readPolicySnapshot() {
                try? enforcement?.apply(snapshot.effectivePolicy)
            }
        } catch {
            #if DEBUG
            print("[BigBrother] Time limit sync failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Enforcement verification every 10 seconds + schedule sync every 60 seconds.
    /// The 10-second check is the PRIMARY enforcement mechanism for background mode changes.
    /// ManagedSettingsStore writes from backgrounded apps are unreliable (iOS platform limitation).
    /// The Monitor extension trigger (stopMonitoring) is also unreliable.
    /// This 10-second check is what actually catches and fixes shield mismatches.
    private var enforcementTickCount = 0
    private func startScheduleSync() {
        scheduleSyncTask?.cancel()
        scheduleSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch { return }
                guard let self else { return }
                // Verify enforcement every 10 seconds (fast path)
                self.verifyAndFixEnforcement()
                // Schedule sync every 60 seconds (slow path — CloudKit queries)
                self.enforcementTickCount += 1
                if self.enforcementTickCount % 6 == 0 {
                    await self.syncScheduleProfile()
                    await self.syncTimeLimits()
                }
            }
        }
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
    ///
    /// ## Related reconcile paths — keep in sync
    ///
    /// There are currently THREE overlapping reconcile paths in the main app.
    /// If you change the logic here, audit the other two:
    ///
    /// 1. `AppState.verifyAndFixEnforcement` (this method) — 60s timer safety
    ///    net. Has command-recent grace (10s), direct temp-unlock file
    ///    short-circuit, and lockUntil cleanup.
    /// 2. `HeartbeatServiceImpl.reconcileEnforcement` — runs after every
    ///    successful heartbeat (~5 min). Simpler — no grace period, no
    ///    lockUntil cleanup. Intended as a post-heartbeat "while we're
    ///    awake, make sure shields match resolver" pass.
    /// 3. `EnforcementServiceImpl.forceDaemonRescue` — runs on every
    ///    foreground wake. Non-destructive if shields already match what
    ///    the snapshot's `resolvedMode` says. NOT driven by the resolver
    ///    (uses the snapshot directly) because the rescue is about the
    ///    daemon itself wedging, not about stack drift.
    ///
    /// These three should eventually share a single
    /// `reconcileFromResolver(_:trigger:)` helper on EnforcementServiceImpl
    /// so the "build corrected policy → apply → commit snapshot → log"
    /// sequence lives in one place. Not done yet because the three paths
    /// have different threading (main-actor vs Task.detached) and
    /// different preconditions that need careful untangling.
    private func verifyAndFixEnforcement() {
        guard deviceRole == .child, let enforcement else { return }

        // Skip if a command was just processed (within 10s).
        let cmdDefaults = UserDefaults.appGroup
        let lastCommandAt = cmdDefaults?.double(forKey: "fr.bigbrother.lastCommandProcessedAt") ?? 0
        if Date().timeIntervalSince1970 - lastCommandAt < 10 { return }

        // Skip if enforcement was recently applied — XPC reads from
        // ManagedSettingsStore are stale for several seconds after a write.
        // Without this, every 10s tick reads "shields down" (stale XPC),
        // triggers a false mismatch, and re-applies. The apply() dedup
        // catches this too, but skipping the XPC read is cheaper.
        if let lastApply = EnforcementServiceImpl.lastApplyTime,
           Date().timeIntervalSince(lastApply) < 15 { return }

        // DIRECT temp unlock file check FIRST, before ModeStackResolver.
        // ModeStackResolver sometimes fails to see the file (reason unknown — possibly
        // file system race, monotonic clock guard, or cross-process timing).
        // If the file exists and hasn't expired, that's ALWAYS authoritative.
        if let tempState = storage.readTemporaryUnlockState(),
           tempState.expiresAt > Date() {
            let tempDiag = enforcement.shieldDiagnostic()
            let isShielded = tempDiag.shieldsActive || tempDiag.categoryActive
            if isShielded {
                // Shields are UP but temp unlock is active — clear all shields.
                // b439: Dispatch to detached task — clearAllRestrictions takes
                // the static applyLock and can block the main thread.
                let enf = enforcement
                Task.detached {
                    try? enf.clearAllRestrictions()
                }
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Temp unlock override",
                    details: "Shields were UP during active temp unlock (expires \(tempState.expiresAt)) — forced DOWN"
                ))
            }
            return // Temp unlock is active — don't let anything else override it
        }

        // Periodic cleanup of expired lockUntil state (resolve() is read-only).
        ModeStackResolver.cleanupExpiredLockUntil()

        let resolution = ModeStackResolver.resolve(storage: storage)

        let diag = enforcement.shieldDiagnostic()
        let shouldBeShielded = resolution.mode != .unlocked
        let isShielded = diag.shieldsActive || diag.categoryActive

        if shouldBeShielded != isShielded {
            // Mismatch — fix it.
            //
            // b459: isTemporaryUnlock MUST only be true when the resolved
            // mode is actually .unlocked. ModeStackResolver.Resolution.isTemporary
            // can be true for lockUntil and timedUnlock penalty modes where
            // the resolved mode is .restricted — if we copied isTemporary
            // through naively, apply()'s old early-return (and any other
            // reader) would clearAllShieldStores on a locked device.
            let effectivelyTempUnlock = resolution.isTemporary && resolution.mode == .unlocked
            let corrected = EffectivePolicy(
                resolvedMode: resolution.mode,
                isTemporaryUnlock: effectivelyTempUnlock,
                temporaryUnlockExpiresAt: effectivelyTempUnlock ? resolution.expiresAt : nil,
                shieldedCategoriesData: snapshotStore?.loadCurrentSnapshot()?.effectivePolicy.shieldedCategoriesData,
                allowedAppTokensData: snapshotStore?.loadCurrentSnapshot()?.effectivePolicy.allowedAppTokensData,
                warnings: [],
                policyVersion: (snapshotStore?.loadCurrentSnapshot()?.effectivePolicy.policyVersion ?? 0) + 1
            )
            // b439: Dispatch the heavy apply() to a detached task so we don't
            // block the main thread. apply() takes the static applyLock and
            // can fall into the deep daemon rescue (6+ seconds).
            let enf = enforcement
            let capturedCorrected = corrected
            Task.detached {
                try? enf.apply(capturedCorrected)
            }

            // Update snapshot so it matches reality
            let snap = PolicySnapshot(
                source: .restoration,
                trigger: "60s enforcement check: shields were \(isShielded ? "UP" : "DOWN"), should be \(shouldBeShielded ? "UP" : "DOWN") (mode: \(resolution.mode.rawValue))",
                effectivePolicy: corrected
            )
            _ = try? storage.commitCorrectedSnapshot(snap)

            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "60s enforcement fix",
                details: "Shields \(isShielded ? "UP" : "DOWN") → \(shouldBeShielded ? "UP" : "DOWN") (mode: \(resolution.mode.rawValue), reason: \(resolution.reason))"
            ))

            // Log an event so the parent is notified via SafetyEventNotificationService.
            eventLogger?.log(.enforcementDegraded, details: "Shields were \(isShielded ? "up" : "down") but should be \(shouldBeShielded ? "up" : "down") — auto-corrected (mode: \(resolution.mode.rawValue))")

            // Write mainAppLastActiveAt so tunnel knows we're alive and fixing things
            UserDefaults.appGroup?
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
        let defaults = UserDefaults.appGroup ?? .standard
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

            // Verify shields applied — .child auth can silently reject writes
            // after temp unlock expiry. Retry with delay if needed.
            if mode != .unlocked, let enforcement {
                let diag = enforcement.shieldDiagnostic()
                if !diag.shieldsActive && !diag.categoryActive {
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .enforcement,
                        message: "Shield re-apply failed after unlock expiry (app path) — retrying in 2s"
                    ))
                    // Retry after delay — dispatched to avoid blocking main thread.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                        try? cmdProcessor.applyModeDirect(mode, enrollment: enrollment)
                    }
                    return // Don't check retry result synchronously
                }
            }

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
        let defaults = UserDefaults.appGroup ?? .standard
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
