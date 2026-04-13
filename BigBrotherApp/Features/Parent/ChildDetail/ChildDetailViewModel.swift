import Foundation
import Observation
import CloudKit
import UserNotifications
import BigBrotherCore

/// Bedtime compliance result for a single day.
struct BedtimeComplianceResult {
    let date: String              // "yyyy-MM-dd"
    let bedtimeSlot: Int          // slot index when bedtime starts
    let totalSecondsAfter: Int    // screen time seconds after bedtime
    let violationSlots: [Int]     // which slots had activity after bedtime

    var isCompliant: Bool { totalSecondsAfter < 60 }
    var minutesAfterBedtime: Int { totalSecondsAfter / 60 }

    /// Human-readable bedtime time (e.g. "9:30 PM").
    var bedtimeLabel: String {
        DomainHit.slotLabel(bedtimeSlot)
    }
}

/// A unified timeline entry combining child-reported events and parent-sent commands.
struct TimelineEntry: Identifiable {
    let id: UUID
    let label: String
    let timestamp: Date
    let isCommand: Bool

    /// Status indicator for commands (pending, applied, failed).
    let status: CommandStatus?

    /// Whether this entry is an actionable unlock request from the child.
    let isUnlockRequest: Bool

    /// The device ID that originated this event (for targeted approval).
    let deviceID: DeviceID?

    /// The app name extracted from unlock request details.
    let appName: String?

    /// Token fingerprint from unlock request (for matching to TimeLimitConfig).
    let fingerprint: String?

    /// The event type (for non-command entries).
    let eventType: EventType?

    init(
        id: UUID,
        label: String,
        timestamp: Date,
        isCommand: Bool,
        status: CommandStatus? = nil,
        isUnlockRequest: Bool = false,
        deviceID: DeviceID? = nil,
        appName: String? = nil,
        fingerprint: String? = nil,
        eventType: EventType? = nil
    ) {
        self.id = id
        self.label = label
        self.timestamp = timestamp
        self.isCommand = isCommand
        self.status = status
        self.isUnlockRequest = isUnlockRequest
        self.deviceID = deviceID
        self.appName = appName
        self.fingerprint = fingerprint
        self.eventType = eventType
    }
}

@Observable @MainActor
final class ChildDetailViewModel: CommandSendable {
    /// Session-level dedupe for auto-re-approve. Survives view re-creation but
    /// resets on app restart. Prevents repeated command floods when the parent
    /// reopens the same child detail page.
    private static var autoApprovedSession: Set<UUID> = []

    /// b436 (audit fix): Cross-call per-app-name dedupe. Reentrant calls to
    /// loadPendingAppReviews during an `await performCommand` suspension
    /// would otherwise pick up the same app via a different review ID.
    private static var autoApprovedSessionAppNames: Set<String> = []

    let appState: AppState
    let child: ChildProfile

    var isSendingCommand = false
    var commandFeedback: String?
    var isCommandError = false
    var cloudKitError: String?
    var timeline: [TimelineEntry] = []
    /// Daily screen time for the last 7 days (date → minutes). Loaded from CloudKit heartbeats.
    var weeklyScreenTime: [(date: Date, minutes: Int)] = []
    /// Per-day screen time slot data keyed by "yyyy-MM-dd" (slot index → seconds).
    var screenTimeByDay: [String: [Int: Int]] = [:]
    /// Bedtime compliance results keyed by "yyyy-MM-dd".
    var bedtimeCompliance: [String: BedtimeComplianceResult] = [:]

    /// Per-app time limit configs from CloudKit.
    var timeLimitConfigs: [TimeLimitConfig] = []

    /// Fingerprints of apps blocked for today, persisted in UserDefaults keyed by child+date.
    var blockedForTodayFingerprints: Set<String> {
        didSet { Self.saveBlockedForToday(blockedForTodayFingerprints, childID: child.id) }
    }

    /// DNS-based online activity snapshot for this child (today only, with slot data for timeline scrubbing).
    var onlineActivity: DomainActivitySnapshot?
    /// DNS-based online activity merged across last 7 days (aggregate counts, no slot data).
    var onlineActivityWeek: DomainActivitySnapshot?
    /// Per-day DNS snapshots keyed by date string ("2026-03-29"), for timeline day-by-day scrubbing.
    var onlineActivityByDay: [String: DomainActivitySnapshot] = [:]
    private var refreshTimer: Timer?

    /// Parent-side restriction state for this child (persisted in UserDefaults).
    var restrictions: DeviceRestrictions {
        get { Self.loadRestrictions(for: child.id) }
        set { Self.saveRestrictions(newValue, for: child.id) }
    }

    /// Driving safety settings for this child.
    var drivingSettings: DrivingSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "drivingSettings.\(child.id.rawValue)"),
                  let s = try? JSONDecoder().decode(DrivingSettings.self, from: data) else {
                return .default
            }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "drivingSettings.\(child.id.rawValue)")
            }
        }
    }

    /// Named places for this family.
    var namedPlaces: [NamedPlace] = []

    /// Whether to show the named place editor sheet.
    var showNamedPlaceEditor = false

    /// Safe search enabled state (persisted per child in UserDefaults).
    var safeSearchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "safeSearch.\(child.id.rawValue)") }
        set { UserDefaults.standard.set(newValue, forKey: "safeSearch.\(child.id.rawValue)") }
    }

    /// Whether any of this child's devices use .child FamilyControls authorization.
    /// Auto-detected from heartbeats. When true, system restrictions are enforceable.
    var hasChildAuthorization: Bool {
        let deviceIDs = Set(devices.map(\.id))
        return appState.latestHeartbeats
            .filter { deviceIDs.contains($0.deviceID) }
            .contains { $0.isChildAuthorization == true }
    }

    private var didFinishInit = false

    init(appState: AppState, child: ChildProfile) {
        self.appState = appState
        self.child = child
        self.blockedForTodayFingerprints = Self.loadBlockedForToday(childID: child.id)
        self.grantedExtraMinutes = Self.loadGrantedExtra(childID: child.id)
        self.selfUnlockBudget = Self.loadSelfUnlockBudget(for: child.id)
        self.didFinishInit = true
    }

    private func showError(_ message: String) {
        cloudKitError = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if cloudKitError == message { cloudKitError = nil }
        }
    }

    // MARK: - Self Unlock Budget

    /// Self-unlock budget for this child (persisted in UserDefaults, synced to CloudKit).
    /// Stored property so @Observable can track mutations for Stepper binding.
    var selfUnlockBudget: Int = 0 {
        didSet {
            guard didFinishInit, selfUnlockBudget != oldValue else { return }
            Self.saveSelfUnlockBudget(selfUnlockBudget, for: child.id)
            debounceSelfUnlockBudget()
        }
    }

    /// Debounce task for self-unlock budget saves — waits 1s after last change.
    private var budgetDebounceTask: Task<Void, Never>?

    private func debounceSelfUnlockBudget() {
        budgetDebounceTask?.cancel()
        let budget = selfUnlockBudget
        let childID = child.id
        let lastSentKey = "selfUnlockBudgetLastSent.\(childID.rawValue)"
        let lastSent = UserDefaults.standard.integer(forKey: lastSentKey)
        guard budget != lastSent else { return }
        budgetDebounceTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            do {
                try await appState.sendCommand(
                    target: .child(child.id),
                    action: .setSelfUnlockBudget(count: budget)
                )
                // Only mark as sent after successful delivery.
                UserDefaults.standard.set(budget, forKey: lastSentKey)
            } catch {
                #if DEBUG
                print("[BigBrother] Self-unlock budget sync failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Self-unlocks used today, read from the latest heartbeat across all devices.
    var selfUnlocksUsedToday: Int? {
        let deviceIDs = Set(devices.map(\.id))
        let values = appState.latestHeartbeats
            .filter { deviceIDs.contains($0.deviceID) }
            .compactMap(\.selfUnlocksUsedToday)
        guard !values.isEmpty else { return nil }
        return values.max()
    }

    /// Send self-unlock budget via command queue (debounced by caller).
    private func saveSelfUnlockBudgetToCloudKit(_ budget: Int) async {
        try? await appState.sendCommand(
            target: .child(child.id),
            action: .setSelfUnlockBudget(count: budget)
        )
    }

    private static func loadSelfUnlockBudget(for childID: ChildProfileID) -> Int {
        UserDefaults.standard.integer(forKey: "selfUnlockBudget.\(childID.rawValue)")
    }

    private static func saveSelfUnlockBudget(_ budget: Int, for childID: ChildProfileID) {
        UserDefaults.standard.set(budget, forKey: "selfUnlockBudget.\(childID.rawValue)")
    }

    // MARK: - Blocked For Today Persistence

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func blockedKey(childID: ChildProfileID) -> String {
        let today = dateFormatter.string(from: Date())
        return "blockedForToday.\(childID.rawValue).\(today)"
    }

    private static func loadBlockedForToday(childID: ChildProfileID) -> Set<String> {
        let key = blockedKey(childID: childID)
        let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(arr)
    }

    private static func saveBlockedForToday(_ fingerprints: Set<String>, childID: ChildProfileID) {
        let key = blockedKey(childID: childID)
        UserDefaults.standard.set(Array(fingerprints), forKey: key)
    }

    /// Toggle a single restriction and send to all child devices.
    func toggleRestriction(_ keyPath: WritableKeyPath<DeviceRestrictions, Bool>) {
        var r = restrictions
        r[keyPath: keyPath].toggle()
        restrictions = r
        Task { await sendRestrictions(r) }
    }

    private func sendRestrictions(_ r: DeviceRestrictions) async {
        await performCommand(.setRestrictions(r), target: .child(child.id))
        // Also write restrictions to CloudKit device records so the child can
        // pull them during periodic sync — commands can fail silently.
        guard let cloudKit = appState.cloudKit else { return }
        let devices = appState.childDevices.filter { $0.childProfileID == child.id }
        guard let json = try? JSONEncoder().encode(r),
              let str = String(data: json, encoding: .utf8) else { return }
        for device in devices {
            try? await cloudKit.updateDeviceFields(
                deviceID: device.id,
                fields: [CKFieldName.restrictionsJSON: str as CKRecordValue]
            )
        }
    }

    // MARK: - Restriction Persistence (parent-side, per child)

    private static func restrictionsKey(for childID: ChildProfileID) -> String {
        "restrictions.\(childID.rawValue)"
    }

    private static func loadRestrictions(for childID: ChildProfileID) -> DeviceRestrictions {
        guard let data = UserDefaults.standard.data(forKey: restrictionsKey(for: childID)),
              let r = try? JSONDecoder().decode(DeviceRestrictions.self, from: data) else {
            return DeviceRestrictions()
        }
        return r
    }

    private static func saveRestrictions(_ r: DeviceRestrictions, for childID: ChildProfileID) {
        if let data = try? JSONEncoder().encode(r) {
            UserDefaults.standard.set(data, forKey: restrictionsKey(for: childID))
        }
    }

    /// Loads data eagerly on first access — not dependent on view lifecycle.
    private var hasLoadedInitialData = false

    func ensureDataLoaded() {
        guard !hasLoadedInitialData else { return }
        hasLoadedInitialData = true
        Task { @MainActor in
            async let e: () = loadEvents()
            async let s: () = loadWeeklyScreenTime()
            async let o: () = loadOnlineActivity()
            // Time limits must load BEFORE pending reviews — the review filter
            // checks timeLimitConfigs to hide already-approved apps.
            await loadTimeLimits()
            async let p: () = loadPendingAppReviews()
            _ = await (e, s, o, p)
        }
    }

    func startAutoRefresh() {
        guard refreshTimer == nil else { return }
        ensureDataLoaded()

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.loadEvents()
                await self?.loadTimeLimits()
                await self?.loadPendingAppReviews() // Must run after loadTimeLimits
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    var devices: [ChildDevice] {
        appState.childDevices.filter { $0.childProfileID == child.id }
    }

    /// Approved apps across all of this child's devices.
    var approvedAppsForChild: [ApprovedApp] {
        let deviceIDs = Set(devices.map(\.id))
        return appState.approvedApps.filter { deviceIDs.contains($0.deviceID) }
    }

    func heartbeat(for device: ChildDevice) -> DeviceHeartbeat? {
        appState.latestHeartbeats.first { $0.deviceID == device.id }
    }

    /// Rolling history of last 3 heartbeats for a device (most recent first).
    func heartbeatHistory(for device: ChildDevice) -> [DeviceHeartbeat] {
        appState.heartbeatHistory[device.id.rawValue] ?? []
    }

    /// Format heartbeat history as copyable text for troubleshooting.
    func formattedHeartbeatHistory(for device: ChildDevice) -> String {
        let history = heartbeatHistory(for: device)
        guard !history.isEmpty else { return "No heartbeat history available." }

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"

        let deviceName = DeviceIcon.displayName(for: device.modelIdentifier)
        var lines: [String] = ["Heartbeat History: \(deviceName) (\(child.name))"]
        lines.append("Device ID: \(device.id.rawValue)")
        lines.append("Exported: \(df.string(from: Date()))")
        lines.append(String(repeating: "-", count: 50))

        for (i, hb) in history.enumerated() {
            let age = Int(-hb.timestamp.timeIntervalSinceNow)
            let ageStr = age < 60 ? "\(age)s ago" : "\(age / 60)m ago"
            lines.append("")
            lines.append("[\(i + 1)] \(df.string(from: hb.timestamp)) (\(ageStr))")
            lines.append("  Mode: \(hb.currentMode.rawValue)  Policy: v\(hb.policyVersion)")
            lines.append("  Source: \(hb.heartbeatSource ?? "unknown")  Seq: \(hb.heartbeatSeq.map(String.init) ?? "?")")
            lines.append("  Shields: \(hb.shieldsActive.map { $0 ? "UP" : "DOWN" } ?? "?")  Category: \(hb.shieldCategoryActive.map { $0 ? "active" : "off" } ?? "?")  Apps: \(hb.shieldedAppCount.map(String.init) ?? "?")")
            lines.append("  Battery: \(hb.batteryLevel.map { "\(Int($0 * 100))%" } ?? "?")  Charging: \(hb.isCharging.map { $0 ? "yes" : "no" } ?? "?")")
            lines.append("  Build: b\(hb.appBuildNumber ?? 0)  Main: b\(hb.mainAppLastLaunchedBuild ?? 0)")
            lines.append("  DNS blocked: \(hb.dnsBlockedDomainCount ?? 0)  Tunnel: \(hb.tunnelConnected.map { $0 ? "connected" : "off" } ?? "?")")
            lines.append("  Internet blocked: \(hb.internetBlocked.map { $0 ? "YES" : "no" } ?? "?")")
            lines.append("  FC auth: \(hb.familyControlsAuthorized ? "yes" : "NO")  Type: \(hb.familyControlsAuthType ?? "?")")
            lines.append("  Schedule: \(hb.scheduleResolvedMode ?? "none")  Shield reason: \(hb.lastShieldChangeReason ?? "?")")
            lines.append("  Screen: \(hb.isDeviceLocked.map { $0 ? "locked" : "unlocked" } ?? "?")  ScreenTime: \(hb.screenTimeMinutes.map { "\($0)m" } ?? "?")")
            if let err = hb.enforcementError { lines.append("  ERROR: \(err)") }
            if let tempExp = hb.temporaryUnlockExpiresAt {
                lines.append("  Temp unlock expires: \(df.string(from: tempExp))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The schedule profile assigned to this child (from any of their devices).
    var scheduleProfile: ScheduleProfile? {
        for dev in devices {
            if let profileID = dev.scheduleProfileID {
                return appState.scheduleProfiles.first { $0.id == profileID }
            }
        }
        return nil
    }

    // MARK: - Device Issue Detection

    struct DeviceIssue: Identifiable {
        let id: DeviceID
        let deviceName: String
        let isIPad: Bool
        let shieldsDown: Bool
        let internetBlocked: Bool
        let dnsBlockingActive: Bool
        let dnsBlockedCount: Int
        let reason: String
    }

    /// Active issues across all devices for this child.
    var deviceIssues: [DeviceIssue] {
        var issues: [DeviceIssue] = []
        for device in devices {
            guard let hb = heartbeat(for: device) else { continue }
            let isStale = hb.timestamp.timeIntervalSinceNow < -600
            let isIPad = device.modelIdentifier.lowercased().contains("ipad")

            // Shields down when they shouldn't be
            let shouldBeShielded = hb.currentMode != .unlocked
            let shieldsDown = shouldBeShielded && hb.shieldsActive == false && hb.shieldCategoryActive != true
            // Skip if temp unlock is still active
            if shieldsDown, let exp = hb.temporaryUnlockExpiresAt, exp > Date() { continue }

            // Internet blocked
            let internetBlocked = hb.internetBlocked == true

            // DNS blocking as fallback
            let dnsCount = hb.dnsBlockedDomainCount ?? 0
            let dnsActive = dnsCount > 0

            if shieldsDown || internetBlocked {
                var reasons: [String] = []

                if shieldsDown {
                    if hb.heartbeatSource == "vpnTunnel" {
                        reasons.append("App was killed or suspended — shield state may be stale")
                    } else {
                        reasons.append("App is running but ManagedSettings are empty — open the app on this device to re-apply")
                    }
                    if dnsActive {
                        reasons.append("DNS fallback active — blocking \(dnsCount) domain\(dnsCount == 1 ? "" : "s") via VPN tunnel")
                    } else if hb.tunnelConnected == true {
                        reasons.append("VPN tunnel connected but no DNS blocking active")
                    } else {
                        reasons.append("VPN tunnel not connected — no fallback protection")
                    }
                }
                if internetBlocked {
                    if let reason = hb.internetBlockedReason, !reason.isEmpty {
                        reasons.append("Internet blocked: \(reason)")
                    } else {
                        reasons.append("Internet blocked by tunnel")
                    }
                }
                if isStale {
                    let mins = Int(-hb.timestamp.timeIntervalSinceNow / 60)
                    reasons.append("Last seen \(mins) min ago")
                }
                issues.append(DeviceIssue(
                    id: device.id,
                    deviceName: device.displayName,
                    isIPad: isIPad,
                    shieldsDown: shieldsDown,
                    internetBlocked: internetBlocked,
                    dnsBlockingActive: dnsActive,
                    dnsBlockedCount: dnsCount,
                    reason: reasons.joined(separator: "\n")
                ))
            }
        }
        return issues
    }

    /// Whether any device has an active issue (for dashboard red name indicator).
    var hasDeviceIssues: Bool { !deviceIssues.isEmpty }

    /// Temporarily unlocked app names from heartbeats for this child's devices.
    var temporaryAllowedAppsForChild: [String] {
        let deviceIDs = Set(devices.map(\.id))
        return appState.latestHeartbeats
            .filter { deviceIDs.contains($0.deviceID) }
            .flatMap { $0.temporaryAllowedAppNames ?? [] }
    }

    /// Allowed app names from heartbeat that the parent hasn't tracked yet.
    /// These represent apps allowed on the device but not in the parent's ApprovedApp list.
    var heartbeatAllowedAppsForChild: [String] {
        let deviceIDs = Set(devices.map(\.id))
        let trackedNames = Set(approvedAppsForChild.map { $0.appName.lowercased() })
        return appState.latestHeartbeats
            .filter { deviceIDs.contains($0.deviceID) }
            .flatMap { $0.allowedAppNames ?? [] }
            .filter { !trackedNames.contains($0.lowercased()) }
    }

    /// Remaining seconds on a temporary unlock across this child's devices.
    /// Falls back to parent-side unlock tracking when heartbeat hasn't confirmed yet.
    var remainingUnlockSeconds: Int? {
        let now = Date()
        let devs = devices
        let heartbeatExpiry = devs.compactMap { dev -> Date? in
            guard let hb = appState.latestHeartbeats.first(where: { $0.deviceID == dev.id }),
                  hb.currentMode == .unlocked,
                  let exp = hb.temporaryUnlockExpiresAt,
                  exp > now else { return nil }
            return exp
        }.max()

        // Fall back to parent-side tracking (set immediately when unlock is sent).
        let key = "unlockExpiries"
        let parentExpiry: Date? = {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([String: Date].self, from: data),
                  let exp = decoded[child.id.rawValue],
                  exp > now else { return nil }
            return exp
        }()

        guard let expiry = heartbeatExpiry ?? parentExpiry else { return nil }
        let secs = Int(expiry.timeIntervalSince(now))
        return secs > 0 ? secs : nil
    }

    var activeMode: LockMode? {
        if let (mode, _) = appState.expectedModes[child.id] {
            return mode
        }
        return heartbeats.first?.currentMode
    }

    var isTemporaryUnlock: Bool {
        guard activeMode == .unlocked else { return false }
        return remainingUnlockSeconds != nil
    }

    var isScheduleDriven: Bool {
        if appState.expectedModes[child.id] != nil { return false }
        return scheduleProfile != nil
    }

    var scheduleNextTransition: Date? {
        scheduleProfile?.nextTransitionTime(from: Date())
    }

    // MARK: - Actions (target all devices for this child)

    func setMode(_ mode: LockMode) async {
        appState.expectedModes[child.id] = (mode, Date())
        await performCommand(.setMode(mode), target: .child(child.id))
    }

    func lockWithDuration(_ duration: LockDuration) async {
        switch duration {
        case .returnToSchedule:
            // Set optimistic mode to what the schedule resolves to right now.
            if let profile = scheduleProfile {
                let scheduleMode = profile.resolvedMode(at: Date())
                appState.expectedModes[child.id] = (scheduleMode, Date())
            } else {
                appState.expectedModes.removeValue(forKey: child.id)
            }
            await performCommand(.returnToSchedule, target: .child(child.id))

        case .indefinite:
            appState.expectedModes[child.id] = (.restricted, Date())
            await performCommand(.setMode(.restricted), target: .child(child.id))

        case .untilMidnight:
            let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
            appState.expectedModes[child.id] = (.restricted, Date())
            await performCommand(.lockUntil(date: midnight), target: .child(child.id))

        case .hours(let h):
            let target = Date().addingTimeInterval(Double(h) * 3600)
            appState.expectedModes[child.id] = (.restricted, Date())
            await performCommand(.lockUntil(date: target), target: .child(child.id))
        }
    }

    /// Lock down: essentialOnly shielding + internet block via VPN DNS blackhole.
    func lockDown(seconds: Int? = nil) async {
        appState.expectedModes[child.id] = (.lockedDown, Date())
        let _ = seconds ?? 86400
        isSendingCommand = true
        do {
            try await appState.sendCommand(target: .child(child.id), action: .setMode(.lockedDown))
            commandFeedback = "Locked Down sent."
        } catch {
            commandFeedback = "Failed: \(error.localizedDescription)"
            isCommandError = true
        }
        isSendingCommand = false
    }

    func temporaryUnlock(seconds: Int = 24 * 3600) async {
        appState.expectedModes[child.id] = (.unlocked, Date())
        await performCommand(.temporaryUnlock(durationSeconds: seconds), target: .child(child.id))
    }

    /// Revoke all allowed apps on all of this child's devices.
    func revokeAllApps() async {
        await performCommand(.revokeAllApps, target: .child(child.id))
        // Clear parent-side tracking too.
        let deviceIDs = Set(devices.map(\.id))
        let remaining = appState.approvedApps.filter { !deviceIDs.contains($0.deviceID) }
        appState.approvedApps = remaining
    }

    /// Revoke all allowed apps on a specific device.
    func revokeAllApps(for device: ChildDevice) async {
        await performCommand(.revokeAllApps, target: .device(device.id))
        appState.approvedApps.removeAll { $0.deviceID == device.id }
    }

    /// Unenroll a device: send unenroll command and delete the device record.
    func unenrollDevice(_ device: ChildDevice) async {
        await performCommand(.unenroll, target: .device(device.id))
        guard let cloudKit = appState.cloudKit else { return }
        do {
            try await cloudKit.deleteDevice(device.id)
            appState.childDevices.removeAll { $0.id == device.id }
            appState.latestHeartbeats.removeAll { $0.deviceID == device.id }
        } catch {
            commandFeedback = "Failed to delete device: \(error.localizedDescription)"
        }
    }

    /// Send requestAppConfiguration command to a specific device.
    func requestAppConfiguration(for device: ChildDevice) async {
        await performCommand(.requestAppConfiguration, target: .device(device.id))
    }

    /// Open the always-allowed apps picker on a specific child device.
    func requestAlwaysAllowedSetup(for device: ChildDevice) async {
        await performCommand(.requestAlwaysAllowedSetup, target: .device(device.id))
    }

    /// Approve an unlock request — sends a per-app temporary unlock to the requesting device.
    func approveUnlock(requestID: UUID, deviceID: DeviceID?, seconds: Int, appName: String?) async {
        if let deviceID {
            await performCommand(.temporaryUnlockApp(requestID: requestID, durationSeconds: seconds), target: .device(deviceID))
        } else {
            await performCommand(.temporaryUnlockApp(requestID: requestID, durationSeconds: seconds), target: .child(child.id))
        }
        // Remove from UI and CloudKit — request has been handled.
        await removeUnlockRequest(id: requestID)
    }

    /// Permanently allow an app — only possible when we have the app token.
    func allowAppPermanently(requestID: UUID, appName: String, deviceID: DeviceID?) async {
        let targetDeviceID = deviceID ?? devices.first?.id
        if let deviceID {
            await performCommand(.allowApp(requestID: requestID), target: .device(deviceID))
        } else {
            await performCommand(.allowApp(requestID: requestID), target: .child(child.id))
        }
        // Track the approval on the parent side for display and revocation.
        if let targetDeviceID {
            appState.addApprovedApp(ApprovedApp(
                id: requestID,
                appName: appName,
                deviceID: targetDeviceID
            ))
        }
        // Remove from UI and CloudKit — request has been handled.
        await removeUnlockRequest(id: requestID)
    }

    /// Revoke a previously approved app.
    func revokeApp(_ app: ApprovedApp) async {
        await performCommand(.blockManagedApp(appName: app.appName), target: .device(app.deviceID))
        guard !isCommandError else { return }
        appState.removeApprovedApp(appName: app.appName, deviceID: app.deviceID)
    }

    /// Names revoked this session — excluded from the always-allowed display
    /// until the next heartbeat confirms the change.
    var revokedAppNames: Set<String> = []
    var localAlwaysAllowedNames: Set<String> = []

    /// Revoke an always-allowed app by name across all child devices.
    func revokeApp(named name: String) async {
        revokedAppNames.insert(name)
        await performCommand(.blockManagedApp(appName: name), target: .child(child.id))
    }

    /// Send an app name to the child device so ShieldAction uses it in future requests.
    func sendAppNameToChild(name: String, rawAppName: String, deviceID: DeviceID?) async {
        guard let fingerprint = ParentAppNameMapping.extractFingerprint(from: rawAppName) else { return }
        if let deviceID {
            await performCommand(.nameApp(fingerprint: fingerprint, name: name), target: .device(deviceID))
        } else {
            await performCommand(.nameApp(fingerprint: fingerprint, name: name), target: .child(child.id))
        }
    }

    /// Send web filter domain list to all of this child's devices.
    func sendWebFilterDomains(_ domains: [String]) async {
        await performCommand(.setAllowedWebDomains(domains: domains), target: .child(child.id))
    }

    /// Deny an unlock request — removes from timeline and deletes from CloudKit.
    func denyUnlockRequest(id: UUID) async {
        await removeUnlockRequest(id: id)
    }

    /// Remove an unlock request from UI and CloudKit.
    private func removeUnlockRequest(id: UUID) async {
        timeline.removeAll { $0.id == id }
        guard let cloudKit = appState.cloudKit else { return }
        try? await cloudKit.deleteEventLog(id)
    }

    // MARK: - Timeline

    /// Event types to show in the child detail "Recent Activity" feed.
    /// Only high-signal events that warrant parent attention.
    private static let visibleEventTypes: Set<EventType> = [
        .unlockRequested,
        .selfUnlockUsed,
        .speedingDetected,
        .phoneWhileDriving,
        .hardBrakingDetected,
        .tripCompleted,
        .namedPlaceArrival,
        .namedPlaceDeparture,
        .authorizationLost,
        .enforcementDegraded,
        .enrollmentRevoked,
        .sosAlert,
        .newAppDetected,
    ]

    /// Parse event details for display, stripping TOKEN payloads and truncating.
    /// Returns (displayDetails, appName).
    private static func parseEventDetails(_ event: EventLogEntry) -> (String?, String?) {
        guard let details = event.details else {
            return (nil, nil)
        }

        // Strip TOKEN payload if present (any event type).
        var cleanDetails: String
        if let tokenRange = details.range(of: "\nTOKEN:") {
            cleanDetails = String(details[..<tokenRange.lowerBound])
        } else {
            cleanDetails = details
        }

        // Truncate overly long details for display.
        if cleanDetails.count > 120 {
            cleanDetails = String(cleanDetails.prefix(120)) + "…"
        }

        // Extract app name from unlock requests.
        let appName: String?
        if event.eventType == .unlockRequested {
            if cleanDetails.hasPrefix("Requesting more time for ") {
                appName = String(cleanDetails.dropFirst("Requesting more time for ".count))
            } else if cleanDetails.hasPrefix("Requesting access to ") {
                appName = String(cleanDetails.dropFirst("Requesting access to ".count))
            } else {
                appName = nil
            }
        } else {
            appName = nil
        }

        return (cleanDetails, appName)
    }

    func loadEvents() async {
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }

        let since = Date().addingTimeInterval(-86400) // last 24h
        let childDeviceIDs = Set(devices.map(\.id))

        // Fetch child-reported events and parent-sent commands in parallel.
        async let eventsTask = cloudKit.fetchEventLogs(familyID: familyID, since: since)
        async let commandsTask = cloudKit.fetchRecentCommands(familyID: familyID, since: since)

        let allEvents = (try? await eventsTask) ?? []
        let allCommands = (try? await commandsTask) ?? []

        // Build timeline from child-reported events (filtered to this child's devices).
        var entries: [TimelineEntry] = allEvents
            .filter { event in
                childDeviceIDs.contains(event.deviceID) &&
                Self.visibleEventTypes.contains(event.eventType)
            }
            .map { event in
                let (displayDetails, extractedAppName) = Self.parseEventDetails(event)
                let fp = UnlockRequestNotificationService.extractFingerprint(from: event.details)

                // Resolve app name from TimeLimitConfig by fingerprint if name is generic.
                var resolvedName = extractedAppName
                if (resolvedName == nil || resolvedName == "App" || resolvedName == "an app"),
                   let fp, let config = self.timeLimitConfigs.first(where: { $0.appFingerprint == fp }) {
                    resolvedName = config.appName
                }

                return TimelineEntry(
                    id: event.id,
                    label: displayDetails ?? event.eventType.displayName,
                    timestamp: event.timestamp,
                    isCommand: false,
                    isUnlockRequest: event.eventType == .unlockRequested,
                    deviceID: event.deviceID,
                    appName: resolvedName,
                    fingerprint: fp,
                    eventType: event.eventType
                )
            }

        // Add parent-sent commands that target this child or their devices.
        // Deduplicate: skip commands whose action is already reflected by a
        // child-reported event within 30 seconds (the child logged it).
        let eventTimestamps = Set(entries.map { Int($0.timestamp.timeIntervalSince1970) })

        for cmd in allCommands {
            guard commandTargetsChild(cmd, childDeviceIDs: childDeviceIDs) else { continue }

            // Skip if a child event already covers this command (within 30s window).
            let cmdEpoch = Int(cmd.issuedAt.timeIntervalSince1970)
            let _ = (-30...30).contains(where: { offset in
                eventTimestamps.contains(cmdEpoch + offset)
            })

            // Only show pending commands less than 1 hour old.
            // Older pending commands either succeeded silently or are stuck.
            guard cmd.status == .pending,
                  cmd.issuedAt.timeIntervalSinceNow > -3600 else { continue }

            entries.append(TimelineEntry(
                id: cmd.id,
                label: "Sent: \(cmd.action.displayDescription) (pending)",
                timestamp: cmd.issuedAt,
                isCommand: true,
                status: cmd.status
            ))
        }

        // Sort newest first.
        timeline = entries.sorted { $0.timestamp > $1.timestamp }
    }

    /// Check if a command targets this child's devices.
    private func commandTargetsChild(_ cmd: RemoteCommand, childDeviceIDs: Set<DeviceID>) -> Bool {
        switch cmd.target {
        case .device(let deviceID):
            return childDeviceIDs.contains(deviceID)
        case .child(let profileID):
            return profileID == child.id
        case .allDevices:
            return true
        }
    }

    /// Save the child profile to CloudKit (used for avatar changes, name edits, etc.).
    func saveProfile(_ profile: ChildProfile) async {
        guard let cloudKit = appState.cloudKit else { return }
        do {
            try await cloudKit.saveChildProfile(profile)
            // Update in-memory state so dashboard refreshes immediately
            if let idx = appState.childProfiles.firstIndex(where: { $0.id == profile.id }) {
                appState.childProfiles[idx] = profile
            }
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to save profile: \(error)")
            #endif
        }
    }

    func refresh() async {
        try? await appState.refreshDashboard()
        await loadEvents()
        await loadWeeklyScreenTime()
        await loadOnlineActivity()
        await loadTimeLimits()
    }

    // MARK: - App Time Limits

    func loadTimeLimits() async {
        guard let cloudKit = appState.cloudKit else { return }
        if let configs = try? await cloudKit.fetchTimeLimitConfigs(childProfileID: child.id) {
            timeLimitConfigs = configs.sorted { $0.appName < $1.appName }
        }

        // Backfill categories for existing configs that don't have one
        backfillCategories()
    }

    /// Look up App Store categories for configs missing them. Best-effort, saves to CK.
    private func backfillCategories() {
        let uncategorized = timeLimitConfigs.filter { $0.appCategory == nil && $0.isActive }
        guard !uncategorized.isEmpty, let cloudKit = appState.cloudKit else { return }
        Task {
            for config in uncategorized {
                guard let category = await AppStoreLookup.lookupCategory(appName: config.appName) else { continue }
                guard let idx = timeLimitConfigs.firstIndex(where: { $0.id == config.id }) else { continue }
                var updated = timeLimitConfigs[idx]
                updated.appCategory = category
                updated.updatedAt = Date()
                try? await cloudKit.saveTimeLimitConfig(updated)
                timeLimitConfigs[idx] = updated
            }
        }
    }

    func requestTimeLimitSetup(for device: ChildDevice) async {
        await performCommand(.requestTimeLimitSetup, target: .device(device.id))
    }

    func setTimeLimit(config: TimeLimitConfig, minutes: Int) async {
        guard let cloudKit = appState.cloudKit else { return }
        var updated = config
        updated.dailyLimitMinutes = minutes
        updated.updatedAt = Date()
        do {
            try await cloudKit.saveTimeLimitConfig(updated)
        } catch {
            showError("Failed to save time limit: \(error.localizedDescription)")
            return
        }
        if let idx = timeLimitConfigs.firstIndex(where: { $0.id == config.id }) {
            timeLimitConfigs[idx] = updated
        }
        // Send command to child so the device-side limit updates immediately
        await performCommand(
            .reviewApp(fingerprint: config.appFingerprint, disposition: .timeLimit, minutes: minutes),
            target: .child(config.childProfileID)
        )
    }

    func removeTimeLimit(config: TimeLimitConfig) async {
        guard let cloudKit = appState.cloudKit else { return }
        // Deactivate — keep record in CloudKit so name auto-populates if re-added
        var updated = config
        updated.isActive = false
        updated.updatedAt = Date()
        do {
            try await cloudKit.saveTimeLimitConfig(updated)
        } catch {
            showError("Failed to remove time limit: \(error.localizedDescription)")
            return
        }
        if let idx = timeLimitConfigs.firstIndex(where: { $0.id == config.id }) {
            timeLimitConfigs[idx] = updated
        }
        await performCommand(.removeTimeLimit(appFingerprint: config.appFingerprint), target: .child(config.childProfileID))
    }

    func renameTimeLimit(config: TimeLimitConfig, newName: String) async {
        guard let cloudKit = appState.cloudKit else { return }
        var updated = config
        updated.appName = newName
        updated.updatedAt = Date()
        do {
            try await cloudKit.saveTimeLimitConfig(updated)
        } catch {
            showError("Failed to rename app: \(error.localizedDescription)")
            return
        }
        if let idx = timeLimitConfigs.firstIndex(where: { $0.id == config.id }) {
            timeLimitConfigs[idx] = updated
        }
        await sendAppNameToChild(name: newName, rawAppName: config.appName, deviceID: config.deviceID)
    }

    /// Convert a time-limited app to always allowed.
    /// Updates the existing CloudKit config to 0 minutes (= always allowed).
    func convertToAlwaysAllowed(config: TimeLimitConfig) async {
        guard let cloudKit = appState.cloudKit else { return }
        var updated = config
        updated.dailyLimitMinutes = 0
        updated.updatedAt = Date()
        do {
            try await cloudKit.saveTimeLimitConfig(updated)
        } catch {
            showError("Failed to save always-allowed: \(error.localizedDescription)")
            return
        }
        if let idx = timeLimitConfigs.firstIndex(where: { $0.id == config.id }) {
            timeLimitConfigs[idx] = updated
        }
        await performCommand(
            .reviewApp(fingerprint: config.appFingerprint, disposition: .allowAlways, minutes: nil),
            target: .child(config.childProfileID)
        )
    }

    /// Convert an always-allowed app to time-limited.
    /// Updates the existing CloudKit config with the new limit.
    func convertToTimeLimited(config: TimeLimitConfig, minutes: Int) async {
        guard let cloudKit = appState.cloudKit else { return }
        var updated = config
        updated.dailyLimitMinutes = minutes
        updated.updatedAt = Date()
        do {
            try await cloudKit.saveTimeLimitConfig(updated)
        } catch {
            showError("Failed to save time limit: \(error.localizedDescription)")
            return
        }
        if let idx = timeLimitConfigs.firstIndex(where: { $0.id == config.id }) {
            timeLimitConfigs[idx] = updated
        }
        await performCommand(
            .reviewApp(fingerprint: config.appFingerprint, disposition: .timeLimit, minutes: minutes),
            target: .child(config.childProfileID)
        )
    }

    /// Revoke an always-allowed app (deactivate in CloudKit, block on device).
    /// Keeps the record so the name auto-populates if re-added later.
    func revokeAlwaysAllowed(config: TimeLimitConfig) async {
        guard let cloudKit = appState.cloudKit else { return }
        var updated = config
        updated.isActive = false
        updated.updatedAt = Date()
        do {
            try await cloudKit.saveTimeLimitConfig(updated)
        } catch {
            showError("Failed to revoke app: \(error.localizedDescription)")
            return
        }
        if let idx = timeLimitConfigs.firstIndex(where: { $0.id == config.id }) {
            timeLimitConfigs[idx] = updated
        }
        await performCommand(
            .reviewApp(fingerprint: config.appFingerprint, disposition: .keepBlocked, minutes: nil),
            target: .child(config.childProfileID)
        )
    }

    func blockAppForToday(config: TimeLimitConfig) async {
        blockedForTodayFingerprints.insert(config.appFingerprint)
        grantedExtraMinutes.removeValue(forKey: config.appFingerprint)
        await performCommand(
            .blockAppForToday(appFingerprint: config.appFingerprint),
            target: .child(config.childProfileID)
        )
    }

    /// Whether the app is blocked for today (exhausted or manually blocked).
    func isAppBlockedForToday(_ config: TimeLimitConfig) -> Bool {
        if blockedForTodayFingerprints.contains(config.appFingerprint) { return true }
        guard config.dailyLimitMinutes > 0 else { return false }
        return appUsageMinutes(for: config) >= Double(config.dailyLimitMinutes)
    }

    /// Extra minutes granted today, keyed by app fingerprint. Persisted in UserDefaults by child+date.
    var grantedExtraMinutes: [String: Int] {
        didSet { Self.saveGrantedExtra(grantedExtraMinutes, childID: child.id) }
    }

    func grantExtraTime(config: TimeLimitConfig, minutes: Int) async {
        grantedExtraMinutes[config.appFingerprint, default: 0] += minutes
        dismissRequest(for: config)
        await performCommand(.grantExtraTime(appFingerprint: config.appFingerprint, extraMinutes: minutes), target: .child(config.childProfileID))
    }

    /// Dismissed request IDs — user explicitly denied or acted on them.
    /// Request IDs dismissed this session (optimistic UI removal before CK delete completes).
    private var dismissedRequestIDs: Set<String> = []

    /// Whether this app has a pending "more time" request from the child.
    func hasPendingTimeRequest(for config: TimeLimitConfig) -> Bool {
        pendingTimeRequest(for: config) != nil
    }

    /// Find the pending time request entry for a config, if any.
    /// Matches by fingerprint first (reliable), then falls back to name.
    func pendingTimeRequest(for config: TimeLimitConfig) -> TimelineEntry? {
        timeline.first { entry in
            guard entry.isUnlockRequest, !dismissedRequestIDs.contains(entry.id.uuidString) else { return false }
            // Match by fingerprint (reliable)
            if let fp = entry.fingerprint, fp == config.appFingerprint { return true }
            // Fallback: match by name
            if let name = entry.appName, name == config.appName { return true }
            return false
        }
    }

    /// Whether this child has ANY pending time requests (for dashboard dot).
    /// Returns false if data hasn't loaded yet to avoid stale dots.
    var hasPendingTimeRequests: Bool {
        guard hasLoadedInitialData else { return false }
        return timeline.contains { $0.isUnlockRequest && !dismissedRequestIDs.contains($0.id.uuidString) }
    }

    /// Deny a time request — remove from UI and delete from CloudKit.
    func denyTimeRequest(for config: TimeLimitConfig) {
        dismissRequest(for: config)
    }

    /// Remove a request from the UI immediately and delete from CloudKit in the background.
    private func dismissRequest(for config: TimeLimitConfig) {
        guard let entry = pendingTimeRequest(for: config) else { return }
        let eventID = entry.id
        dismissedRequestIDs.insert(eventID.uuidString)
        timeline.removeAll { $0.id == eventID }
        // Clear the parent notification for this request.
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["unlock-\(eventID.uuidString)"]
        )
        // Remove from pending set so blue dot clears.
        appState.childrenWithPendingRequests.remove(child.id)
        // Delete from CloudKit so it never comes back.
        Task {
            try? await appState.cloudKit?.deleteEventLog(eventID)
        }
    }

    private static func grantedExtraKey(childID: ChildProfileID) -> String {
        let today = dateFormatter.string(from: Date())
        return "grantedExtra.\(childID.rawValue).\(today)"
    }

    static func loadGrantedExtra(childID: ChildProfileID) -> [String: Int] {
        let key = grantedExtraKey(childID: childID)
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    private static func saveGrantedExtra(_ extras: [String: Int], childID: ChildProfileID) {
        let key = grantedExtraKey(childID: childID)
        UserDefaults.standard.set(extras, forKey: key)
    }


    /// App usage in minutes. Uses precise DeviceActivityEvent data when available
    /// (from heartbeat's appUsageMinutes), falls back to DNS estimate.
    func appUsageMinutes(for config: TimeLimitConfig) -> Double {
        // Precise: from DeviceActivityEvent milestones via heartbeat.
        let deviceIDs = Set(devices.map(\.id))
        for hb in appState.latestHeartbeats where deviceIDs.contains(hb.deviceID) {
            if let usage = hb.appUsageMinutes, let minutes = usage[config.appFingerprint] {
                return Double(minutes)
            }
        }
        // Fallback: DNS estimate.
        return estimatedAppUsage(for: config.appName)
    }

    /// Estimated app usage in minutes from DNS data for today.
    func estimatedAppUsage(for appName: String) -> Double {
        guard let activity = onlineActivity else { return 0 }
        let usage = activity.estimatedAppUsage()
        return usage.first(where: { $0.appName == appName })?.minutes ?? 0
    }

    /// Fetch daily screen time snapshots for the last 7 days.
    func loadWeeklyScreenTime() async {
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }

        let deviceIDs = Set(devices.map(\.id))
        guard !deviceIDs.isEmpty else { return }

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase
        let today = Calendar.current.startOfDay(for: Date())

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        // Build date strings for last 7 days
        let dateStrings: [String] = (0..<7).compactMap { daysAgo in
            guard let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) else { return nil }
            return fmt.string(from: date)
        }

        // Fetch BBScreenTime records for all devices x all days in parallel
        var dailyMax: [String: Int] = [:]
        var slotsByDay: [String: [Int: Int]] = [:]

        await withTaskGroup(of: (String, Int, [Int: Int])?.self) { group in
            for deviceID in deviceIDs {
                for dateStr in dateStrings {
                    group.addTask {
                        let recordID = CKRecord.ID(recordName: "BBScreenTime_\(deviceID.rawValue)_\(dateStr)")
                        do {
                            let record = try await db.record(for: recordID)
                            let minutes = (record["minutes"] as? Int) ?? 0

                            // Parse slot data
                            var slots: [Int: Int] = [:]
                            if let json = record["slotsJSON"] as? String,
                               let data = json.data(using: .utf8),
                               let parsed = try? JSONDecoder().decode([String: Int].self, from: data) {
                                for (k, v) in parsed {
                                    if let idx = Int(k) { slots[idx] = v }
                                }
                            }

                            return minutes > 0 ? (dateStr, minutes, slots) : nil
                        } catch {
                            return nil
                        }
                    }
                }
            }

            for await result in group {
                guard let (dateStr, minutes, slots) = result else { continue }
                dailyMax[dateStr] = max(dailyMax[dateStr] ?? 0, minutes)
                // Merge slots across devices
                if !slots.isEmpty {
                    var merged = slotsByDay[dateStr] ?? [:]
                    for (s, secs) in slots { merged[s, default: 0] += secs }
                    slotsByDay[dateStr] = merged
                }
            }
        }

        // Fallback: if no BBScreenTime records found, try the legacy heartbeat approach
        if dailyMax.isEmpty {
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today
            let allHeartbeats = (try? await cloudKit.fetchHeartbeats(familyID: familyID, since: sevenDaysAgo)) ?? []
            let childHeartbeats = allHeartbeats.filter { deviceIDs.contains($0.deviceID) }
            for hb in childHeartbeats {
                guard let mins = hb.screenTimeMinutes, mins > 0 else { continue }
                let key = fmt.string(from: hb.timestamp)
                dailyMax[key] = max(dailyMax[key] ?? 0, mins)
            }
        }

        // Build sorted array for last 7 days
        var result: [(date: Date, minutes: Int)] = []
        for dayOffset in (-6...0) {
            guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let key = fmt.string(from: date)
            result.append((date: date, minutes: dailyMax[key] ?? 0))
        }
        weeklyScreenTime = result
        screenTimeByDay = slotsByDay

        // Compute bedtime compliance from slot data + schedule
        computeBedtimeCompliance(slotsByDay: slotsByDay)
    }

    private func computeBedtimeCompliance(slotsByDay: [String: [Int: Int]]) {
        // Find schedule profile for this child
        let deviceIDs = Set(devices.map(\.id))
        let scheduleProfileID = appState.childDevices
            .filter { deviceIDs.contains($0.id) }
            .compactMap(\.scheduleProfileID)
            .first

        guard let profileID = scheduleProfileID,
              let profile = appState.scheduleProfiles.first(where: { $0.id == profileID }) else {
            bedtimeCompliance = [:]
            return
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        var results: [String: BedtimeComplianceResult] = [:]
        for (dateStr, slots) in slotsByDay {
            // Determine the day of week for this date
            guard let date = fmt.date(from: dateStr) else { continue }
            let weekdayIndex = Calendar.current.component(.weekday, from: date) // 1=Sun, 7=Sat
            let dayOfWeek = DayOfWeek(rawValue: weekdayIndex)
            guard let dayOfWeek,
                  let bedtimeSlot = profile.bedtimeSlot(for: dayOfWeek) else { continue }

            // Find slots after bedtime that had screen time
            let violations = slots.filter { $0.key >= bedtimeSlot && $0.value > 0 }
            let totalSecs = violations.values.reduce(0, +)
            results[dateStr] = BedtimeComplianceResult(
                date: dateStr,
                bedtimeSlot: bedtimeSlot,
                totalSecondsAfter: totalSecs,
                violationSlots: violations.keys.sorted()
            )
        }
        bedtimeCompliance = results
    }

    /// Fetch DNS activity from CloudKit for this child's devices.
    func loadOnlineActivity() async {
        guard appState.cloudKit != nil,
              let familyID = appState.parentState?.familyID else { return }

        let deviceIDs = Set(devices.map(\.id))
        guard !deviceIDs.isEmpty else { return }

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let today = fmt.string(from: now)

        // Build date strings for last 7 days
        let dateStrings: [String] = (0..<7).compactMap { daysAgo in
            guard let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) else { return nil }
            return fmt.string(from: date)
        }

        // Fetch all days for all devices in parallel
        var allDomainsByName: [String: DomainHit] = [:]
        var weekTotalQueries = 0
        // Per-day: merge multiple devices into one snapshot per date
        var dayDomains: [String: [String: DomainHit]] = [:]  // date → (domain → hit)
        var dayTotals: [String: Int] = [:]

        await withTaskGroup(of: (String, DeviceID, [DomainHit], Int)?.self) { group in
            for deviceID in deviceIDs {
                for dateStr in dateStrings {
                    group.addTask {
                        let recordID = CKRecord.ID(recordName: "BBDNSActivity_\(deviceID.rawValue)_\(dateStr)")
                        do {
                            let record = try await db.record(for: recordID)
                            guard let json = record["domainsJSON"] as? String,
                                  let data = json.data(using: .utf8),
                                  let domains = try? JSONDecoder().decode([DomainHit].self, from: data) else {
                                return nil
                            }
                            let total = (record["totalQueries"] as? Int) ?? domains.reduce(0) { $0 + $1.count }
                            return (dateStr, deviceID, domains, total)
                        } catch {
                            return nil
                        }
                    }
                }
            }

            for await result in group {
                guard let (dateStr, _, domains, total) = result else { continue }

                // Per-day accumulation (merge multiple devices for same day)
                dayTotals[dateStr, default: 0] += total
                var dayMap = dayDomains[dateStr] ?? [:]
                for hit in domains {
                    if var existing = dayMap[hit.domain] {
                        existing.count += hit.count
                        if hit.firstSeen < existing.firstSeen { existing.firstSeen = hit.firstSeen }
                        if hit.lastSeen > existing.lastSeen { existing.lastSeen = hit.lastSeen }
                        if hit.flagged && !existing.flagged {
                            existing.flagged = true
                            existing.category = hit.category
                        }
                        // Merge slot counts across devices
                        if let newSlots = hit.slotCounts {
                            var merged = existing.slotCounts ?? [:]
                            for (s, c) in newSlots { merged[s, default: 0] += c }
                            existing.slotCounts = merged
                        }
                        dayMap[hit.domain] = existing
                    } else {
                        dayMap[hit.domain] = hit
                    }
                }
                dayDomains[dateStr] = dayMap

                // Merge into 7-day aggregate (sum counts, drop slot data)
                weekTotalQueries += total
                for hit in domains {
                    if var existing = allDomainsByName[hit.domain] {
                        existing.count += hit.count
                        if hit.firstSeen < existing.firstSeen { existing.firstSeen = hit.firstSeen }
                        if hit.lastSeen > existing.lastSeen { existing.lastSeen = hit.lastSeen }
                        if hit.flagged && !existing.flagged {
                            existing.flagged = true
                            existing.category = hit.category
                        }
                        allDomainsByName[hit.domain] = existing
                    } else {
                        var weekHit = hit
                        weekHit.slotCounts = nil
                        allDomainsByName[hit.domain] = weekHit
                    }
                }
            }
        }

        // Build per-day snapshots
        var byDay: [String: DomainActivitySnapshot] = [:]
        for (dateStr, domainMap) in dayDomains {
            byDay[dateStr] = DomainActivitySnapshot(
                deviceID: deviceIDs.first!,
                familyID: familyID,
                date: dateStr,
                timestamp: now,
                domains: Array(domainMap.values),
                totalQueries: dayTotals[dateStr] ?? 0
            )
        }
        onlineActivityByDay = byDay
        onlineActivity = byDay[today]

        if !allDomainsByName.isEmpty {
            onlineActivityWeek = DomainActivitySnapshot(
                deviceID: deviceIDs.first!,
                familyID: familyID,
                date: "7-day",
                timestamp: now,
                domains: Array(allDomainsByName.values),
                totalQueries: weekTotalQueries
            )
        } else {
            onlineActivityWeek = nil
        }
    }

    // MARK: - Location

    /// All heartbeats for this child's devices.
    var heartbeats: [DeviceHeartbeat] {
        let deviceIDs = Set(devices.map(\.id))
        return appState.latestHeartbeats.filter { deviceIDs.contains($0.deviceID) }
    }

    /// Set the location tracking mode on all of this child's devices.
    func sendLocationMode(_ mode: LocationTrackingMode) async {
        await performCommand(.setLocationMode(mode), target: .child(child.id))
    }

    /// Request the child device to report its current location immediately.
    func requestLocation() async {
        await performCommand(.requestLocation, target: .child(child.id))
    }

    // MARK: - Pending App Reviews

    /// Apps selected by the child awaiting parent review.
    var pendingAppReviews: [PendingAppReview] = []
    var pendingReviewDiagnostic = ""
    private(set) var blockedAppNames: Set<String> = []

    func isPreviouslyBlocked(_ review: PendingAppReview) -> Bool {
        review.nameResolved && blockedAppNames.contains(review.appName.lowercased())
    }

    func loadPendingAppReviews() async {
        guard let cloudKit = appState.cloudKit else {
            pendingReviewDiagnostic = "No CloudKit service"
            return
        }
        do {
            // Show reviews even for already-approved apps — a review for an approved app
            // means the token rotated (stale) and needs refreshing. Previously these were
            // hidden, leaving the parent with a blue dot they couldn't act on. The actual
            // dedupe is by app NAME below (approvedAppNames), since fingerprint changes
            // when the token rotates.

            let allFromCK = try await cloudKit.fetchPendingAppReviews(childProfileID: child.id)

            // ── Bug 4 fix: filter out reviews from dead devices ──
            // Reviews from uninstalled devices persist in CK forever.
            // Only keep reviews from devices that are currently enrolled
            // for this child. Delete orphans in the background.
            //
            // SAFETY: if the device list is empty (hasn't loaded yet
            // after a fresh app launch), skip the purge entirely.
            // Without this guard, a race between dashboard refresh and
            // loadPendingAppReviews causes ALL reviews to be classified
            // as orphans and deleted on every kill+relaunch.
            // ── Bug 4 fix: purge reviews from dead devices ──
            // A device is "dead" if it has no heartbeat in 48+ hours.
            // Checking device registration alone isn't enough — uninstalled
            // devices stay registered in CK but stop sending heartbeats.
            let now = Date()
            let heartbeatCutoff = now.addingTimeInterval(-48 * 3600)
            let aliveDeviceIDs: Set<DeviceID> = {
                var ids = Set<DeviceID>()
                for device in devices {
                    if let lastHB = device.lastHeartbeat, lastHB > heartbeatCutoff {
                        ids.insert(device.id)
                    } else if device.lastHeartbeat == nil {
                        // No heartbeat data yet — don't purge, could be freshly enrolled
                        ids.insert(device.id)
                    }
                }
                return ids
            }()
            let all: [PendingAppReview]
            if aliveDeviceIDs.isEmpty {
                NSLog("[ChildDetail] No alive devices — skipping zombie purge")
                all = allFromCK
            } else {
                all = allFromCK.filter { aliveDeviceIDs.contains($0.deviceID) }
                let orphans = allFromCK.filter { !aliveDeviceIDs.contains($0.deviceID) }
                for orphan in orphans {
                    try? await cloudKit.deletePendingAppReview(orphan.id)
                }
                if !orphans.isEmpty {
                    NSLog("[ChildDetail] Purged \(orphans.count) zombie reviews from dead devices")
                }
            }

            let blockedConfigs = timeLimitConfigs.filter { !$0.isActive }
            blockedAppNames = Set(blockedConfigs.map { $0.appName.lowercased() })
            let blockedFingerprints = Set(blockedConfigs.map { $0.appFingerprint })
            let blockedBundleIDs = Set(blockedConfigs.compactMap { $0.bundleID?.lowercased() })

            func isBlocked(_ review: PendingAppReview) -> Bool {
                if let bid = review.bundleID?.lowercased(), blockedBundleIDs.contains(bid) { return true }
                if blockedFingerprints.contains(review.appFingerprint) { return true }
                if review.nameResolved && blockedAppNames.contains(review.appName.lowercased()) { return true }
                return false
            }

            let notBlocked = all.filter { !isBlocked($0) }
            let blockedReviews = all.filter { isBlocked($0) }
            for review in blockedReviews {
                try? await cloudKit.deletePendingAppReview(review.id)
            }

            // ── Bug 2 fix: auto-approve only if the app is confirmed
            //    on the REQUESTING device's heartbeat ──
            // Previously auto-approve checked ALL devices' heartbeats,
            // which silently ate reviews from new devices (the app was
            // "approved" on device A so device B's request got auto-
            // approved and hidden from the parent). The parent never
            // saw the request, and if the command failed, the kid was
            // stuck. Now: only auto-approve if the REQUESTING device's
            // own heartbeat already lists the app in allowedAppNames.
            // Cross-device approvals show as new reviews for the parent.
            // Auto-approve: TimeLimitConfig is the single source of truth.
            // If the app has an active config (from any prior approval on
            // any device), auto-approve it, send the command, and delete
            // the CK review. If the command doesn't land, the kid
            // re-requests and it auto-approves again. No heartbeat
            // checking, no cross-device scoping — TimeLimitConfigs are
            // child-scoped and persist across devices.
            // Auto-approve cascade: bundleID → name → fingerprint.
            // bundleID survives token rotation and renames.
            let activeConfigs = timeLimitConfigs.filter(\.isActive)
            let approvedBundleIDs = Set(activeConfigs.compactMap { $0.bundleID?.lowercased() })
            let approvedConfigNames = Set(activeConfigs.map { $0.appName.lowercased() })
            let approvedConfigFingerprints = Set(activeConfigs.map { $0.appFingerprint })
            let candidates = notBlocked.filter { review in
                guard review.nameResolved else { return false }
                if let bid = review.bundleID?.lowercased(), approvedBundleIDs.contains(bid) { return true }
                if approvedConfigNames.contains(review.appName.lowercased()) { return true }
                if approvedConfigFingerprints.contains(review.appFingerprint) { return true }
                return false
            }

            // Session-level dedupe — never re-send for the same review ID twice.
            let unsent = candidates.filter {
                !Self.autoApprovedSession.contains($0.id) &&
                !Self.autoApprovedSessionAppNames.contains($0.appName.lowercased())
            }
            // Per-DEVICE per-app dedup — each device gets ONE command per
            // app name. The old global dedup kept one review across ALL
            // devices, so a dead phone's review could win and the live
            // iPad's review would be deduped out — iPad never got the
            // command.
            var seenPerDevice = Set<String>()
            let toSend = unsent.filter { review in
                let key = "\(review.deviceID.rawValue)|\(review.appName.lowercased())"
                return seenPerDevice.insert(key).inserted
            }
            for review in toSend {
                Self.autoApprovedSession.insert(review.id)
                Self.autoApprovedSessionAppNames.insert(review.appName.lowercased())
            }
            for review in unsent where !toSend.contains(where: { $0.id == review.id }) {
                Self.autoApprovedSession.insert(review.id)
                Self.autoApprovedSessionAppNames.insert(review.appName.lowercased())
            }

            // Send commands grouped by device.
            let toSendByDevice = Dictionary(grouping: toSend, by: { $0.deviceID })
            for (deviceID, reviews) in toSendByDevice {
                let decisions = reviews.map { review -> AppReviewDecision in
                    let matchingConfig = activeConfigs.first { cfg in
                        if let bid = review.bundleID?.lowercased(), let cbid = cfg.bundleID?.lowercased(), bid == cbid { return true }
                        if cfg.appName.lowercased() == review.appName.lowercased() { return true }
                        if cfg.appFingerprint == review.appFingerprint { return true }
                        return false
                    }
                    let disposition: AppDisposition
                    let minutes: Int?
                    if let config = matchingConfig, config.dailyLimitMinutes > 0 {
                        disposition = .timeLimit
                        minutes = config.dailyLimitMinutes
                    } else {
                        disposition = .allowAlways
                        minutes = nil
                    }
                    return AppReviewDecision(
                        fingerprint: review.appFingerprint,
                        disposition: disposition,
                        minutes: minutes
                    )
                }
                await performCommand(
                    .reviewApps(decisions: decisions),
                    target: .device(deviceID)
                )
                NSLog("[ChildDetail] Auto-re-approved \(reviews.count) apps for device \(deviceID.rawValue.prefix(8)) in one batch")
            }
            // Delete ALL candidate reviews from CK — both the ones we
            // sent commands for AND duplicates. This covers:
            //   - toSend reviews (command sent, can be re-requested if
            //     delivery fails)
            //   - session-deduped duplicates (same app, extra CK records)
            //   - cross-device duplicates (dead phone + live iPad both
            //     had a review — dead phone's was processed, iPad's is
            //     a duplicate by name)
            for review in candidates {
                try? await cloudKit.deletePendingAppReview(review.id)
            }

            // Remaining = reviews NOT auto-approved and NOT blocked.
            // These show in the parent UI for manual review.
            // Filter by review ID, NOT by name. The old name-based filter
            // had a cross-device collision: if device A's "Pinterest" was
            // auto-approved, the name went into the exclusion set and
            // device B's "Pinterest" (which was NOT a candidate) got
            // silently dropped too. Using IDs means only the specific
            // reviews that matched auto-approve are excluded.
            let candidateIDs = Set(candidates.map { $0.id })
            let remaining = notBlocked.filter { review in
                !candidateIDs.contains(review.id)
            }

            // Deduplicate by fingerprint — keep the one with latest updatedAt
            // (preserves parent renames over older duplicates)
            var seen: [String: PendingAppReview] = [:]
            for review in remaining {
                if let existing = seen[review.appFingerprint] {
                    if review.updatedAt > existing.updatedAt { seen[review.appFingerprint] = review }
                } else {
                    seen[review.appFingerprint] = review
                }
            }
            let deduped = Array(seen.values)
            let resolved = deduped.filter(\.nameResolved)
            let autoApproved = all.count - remaining.count
            pendingReviewDiagnostic = "CK: \(all.count) total, \(autoApproved) auto-re-approved, \(deduped.count) unique, \(resolved.count) named"
            let sorted = deduped.sorted { $0.createdAt < $1.createdAt }
            pendingAppReviews = sorted

            // Notify parent of new reviews
            AppReviewNotificationService.checkAndNotify(
                reviews: sorted,
                childName: child.name,
                childProfileID: child.id
            )
        } catch {
            pendingReviewDiagnostic = "CK ERROR: \(error.localizedDescription)"
        }
    }

    /// Rename a pending review (parent types the real name after child tells them).
    func renameReview(_ review: PendingAppReview, newName: String) async {
        guard let idx = pendingAppReviews.firstIndex(where: { $0.id == review.id }) else { return }
        var updated = pendingAppReviews[idx]
        updated.appName = newName
        updated.nameResolved = true
        updated.updatedAt = Date()
        guard let cloudKit = appState.cloudKit else { return }
        do {
            try await cloudKit.savePendingAppReview(updated)
        } catch {
            showError("Failed to rename review: \(error.localizedDescription)")
            return
        }
        pendingAppReviews[idx] = updated
    }

    /// Delete all pending app reviews for this child from CloudKit.
    func clearAllPendingReviews() async {
        guard let cloudKit = appState.cloudKit else { return }
        // Delete everything from CloudKit (fetch fresh to catch duplicates)
        let allFromCK: [PendingAppReview]
        do {
            allFromCK = try await cloudKit.fetchPendingAppReviews(childProfileID: child.id)
        } catch {
            showError("Failed to fetch reviews: \(error.localizedDescription)")
            return
        }
        var failures = 0
        for review in allFromCK {
            do {
                try await cloudKit.deletePendingAppReview(review.id)
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            showError("Failed to delete \(failures) of \(allFromCK.count) reviews")
        }
        // Reload from CK to reflect actual state
        await loadPendingAppReviews()
        pendingReviewDiagnostic = failures == 0 ? "Cleared" : "Cleared with \(failures) errors"
    }

    /// Send the child app picker command to a specific device.
    func requestChildAppPick(for device: ChildDevice) async {
        await performCommand(.requestChildAppPick, target: .device(device.id))
    }

    /// Parent decides on a pending app: allow always, time limit, or keep blocked.
    func reviewApp(_ review: PendingAppReview, disposition: AppDisposition, minutes: Int? = nil) async {
        guard let cloudKit = appState.cloudKit else { return }

        // Send command to child device
        await performCommand(
            .reviewApp(fingerprint: review.appFingerprint, disposition: disposition, minutes: minutes),
            target: .device(review.deviceID)
        )

        // Create or update CloudKit config — source of truth for app status.
        // For .keepBlocked: create an INACTIVE config so loadPendingAppReviews
        // knows to suppress future requests for this app (Bug 1 fix).
        // For .allowAlways/.timeLimit: create an ACTIVE config as before.
        let dailyMinutes: Int
        let configIsActive: Bool
        switch disposition {
        case .allowAlways:
            dailyMinutes = 0
            configIsActive = true
        case .timeLimit:
            dailyMinutes = minutes ?? 60
            configIsActive = true
        case .keepBlocked:
            dailyMinutes = 0
            configIsActive = false
        }

        let category = await AppStoreLookup.lookupCategory(appName: review.appName)

        if let existingIdx = timeLimitConfigs.firstIndex(where: {
            $0.appFingerprint == review.appFingerprint ||
            ($0.bundleID != nil && $0.bundleID == review.bundleID)
        }) {
            var updated = timeLimitConfigs[existingIdx]
            updated.dailyLimitMinutes = dailyMinutes
            updated.isActive = configIsActive
            updated.appName = review.appName
            if let bid = review.bundleID { updated.bundleID = bid }
            if let category { updated.appCategory = category }
            updated.updatedAt = Date()
            do {
                try await cloudKit.saveTimeLimitConfig(updated)
            } catch {
                showError("Failed to save app config: \(error.localizedDescription)")
                return
            }
            timeLimitConfigs[existingIdx] = updated
        } else {
            let config = TimeLimitConfig(
                familyID: review.familyID,
                childProfileID: review.childProfileID,
                appFingerprint: review.appFingerprint,
                appName: review.appName,
                dailyLimitMinutes: dailyMinutes,
                isActive: configIsActive,
                appCategory: category,
                bundleID: review.bundleID
            )
            do {
                try await cloudKit.saveTimeLimitConfig(config)
            } catch {
                showError("Failed to save app config: \(error.localizedDescription)")
                return
            }
            timeLimitConfigs.append(config)
        }

        // Delete the pending review from CloudKit
        do {
            try await cloudKit.deletePendingAppReview(review.id)
        } catch {
            showError("Failed to delete review: \(error.localizedDescription)")
            return
        }

        // Only update local state after CK operations succeed
        pendingAppReviews.removeAll { $0.appFingerprint == review.appFingerprint }

        // Delete ALL CloudKit records with this fingerprint (best-effort, catches duplicates)
        let allForChild = (try? await cloudKit.fetchPendingAppReviews(childProfileID: review.childProfileID)) ?? []
        for dup in allForChild where dup.appFingerprint == review.appFingerprint {
            try? await cloudKit.deletePendingAppReview(dup.id)
        }
    }

    // MARK: - Permissions

    /// Re-request all permissions on the child device (Screen Time + Location).
    /// Parent should be physically holding the child device when sending this.
    func requestPermissions() async {
        await performCommand(.requestPermissions, target: .child(child.id))
    }

    /// Re-request permissions for a specific device.
    func requestPermissions(for device: ChildDevice) async {
        await performCommand(.requestPermissions, target: .device(device.id))
    }

    // MARK: - Home Geofence

    /// Whether a home geofence is configured for any of this child's devices.
    var hasHomeGeofence: Bool {
        for device in devices {
            let key = "homeLatitude.\(device.id.rawValue)"
            if UserDefaults.standard.object(forKey: key) != nil {
                return true
            }
        }
        return false
    }

    /// Set the home location for geofence relaunch. Sends to all child devices
    /// via command so the child's LocationService can register the geofence.
    func setHomeLocation(latitude: Double, longitude: Double) async {
        // Persist on parent side for display.
        for device in devices {
            UserDefaults.standard.set(latitude, forKey: "homeLatitude.\(device.id.rawValue)")
            UserDefaults.standard.set(longitude, forKey: "homeLongitude.\(device.id.rawValue)")
        }
        // Send to child devices so they store in App Group defaults.
        await performCommand(
            .setHomeLocation(latitude: latitude, longitude: longitude),
            target: .child(child.id)
        )
    }

    // MARK: - Safe Search

    func sendSafeSearch(enabled: Bool) async {
        await performCommand(
            .setSafeSearch(enabled: enabled),
            target: .child(child.id)
        )
    }

    // MARK: - Driving Safety

    func sendDrivingSettings() async {
        await performCommand(
            .setDrivingSettings(drivingSettings),
            target: .child(child.id)
        )
    }

    // MARK: - Named Places

    func loadNamedPlaces() async {
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }
        do {
            namedPlaces = try await cloudKit.fetchNamedPlaces(familyID: familyID)
        } catch {
            #if DEBUG
            print("[ChildDetail] Failed to load named places: \(error.localizedDescription)")
            #endif
        }
    }

    func saveNamedPlace(_ place: NamedPlace) async {
        guard let cloudKit = appState.cloudKit else { return }
        do {
            try await cloudKit.saveNamedPlace(place)
            await loadNamedPlaces()
            // Tell child devices to sync geofences
            await performCommand(.syncNamedPlaces, target: .child(child.id))
        } catch {
            #if DEBUG
            print("[ChildDetail] Failed to save named place: \(error.localizedDescription)")
            #endif
        }
    }

    func deleteNamedPlace(at indexSet: IndexSet) async {
        guard let cloudKit = appState.cloudKit else { return }
        for index in indexSet {
            let place = namedPlaces[index]
            do {
                try await cloudKit.deleteNamedPlace(place.id)
            } catch {
                #if DEBUG
                print("[ChildDetail] Failed to delete named place: \(error.localizedDescription)")
                #endif
            }
        }
        await loadNamedPlaces()
        await performCommand(.syncNamedPlaces, target: .child(child.id))
    }
}
