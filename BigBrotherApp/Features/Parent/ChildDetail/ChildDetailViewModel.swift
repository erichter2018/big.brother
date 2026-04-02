import Foundation
import Observation
import CloudKit
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
        self.eventType = eventType
    }
}

@Observable @MainActor
final class ChildDetailViewModel: CommandSendable {
    let appState: AppState
    let child: ChildProfile

    var isSendingCommand = false
    var commandFeedback: String?
    var isCommandError = false
    var timeline: [TimelineEntry] = []
    /// Daily screen time for the last 7 days (date → minutes). Loaded from CloudKit heartbeats.
    var weeklyScreenTime: [(date: Date, minutes: Int)] = []
    /// Per-day screen time slot data keyed by "yyyy-MM-dd" (slot index → seconds).
    var screenTimeByDay: [String: [Int: Int]] = [:]
    /// Bedtime compliance results keyed by "yyyy-MM-dd".
    var bedtimeCompliance: [String: BedtimeComplianceResult] = [:]

    /// Per-app time limit configs from CloudKit.
    var timeLimitConfigs: [TimeLimitConfig] = []

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
        self.selfUnlockBudget = Self.loadSelfUnlockBudget(for: child.id)
        self.didFinishInit = true
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
            _ = await (e, s, o)
        }
    }

    func startAutoRefresh() {
        guard refreshTimer == nil else { return }
        ensureDataLoaded()

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.loadEvents()
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

            if shieldsDown || internetBlocked {
                var reasons: [String] = []
                if isStale {
                    let mins = Int(-hb.timestamp.timeIntervalSinceNow / 60)
                    reasons.append("Last seen \(mins) min ago — issue may persist")
                }
                if shieldsDown {
                    reasons.append("Shields down — mode is \(hb.currentMode.rawValue) but ManagedSettings empty")
                    if hb.heartbeatSource == "vpnTunnel" {
                        reasons.append("App not running (heartbeat from tunnel)")
                    }
                    if let reason = hb.lastShieldChangeReason {
                        reasons.append("Last shield change: \(reason)")
                    }
                }
                if internetBlocked {
                    if let reason = hb.internetBlockedReason, !reason.isEmpty {
                        reasons.append("DNS blocked: \(reason)")
                    } else {
                        reasons.append("DNS blocked by tunnel")
                    }
                }
                issues.append(DeviceIssue(
                    id: device.id,
                    deviceName: device.displayName,
                    isIPad: isIPad,
                    shieldsDown: shieldsDown,
                    internetBlocked: internetBlocked,
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

    // MARK: - Actions (target all devices for this child)

    func setMode(_ mode: LockMode) async {
        appState.expectedModes[child.id] = (mode, Date())
        await performCommand(.setMode(mode), target: .child(child.id))
    }

    func lockWithDuration(_ duration: LockDuration) async {
        switch duration {
        case .returnToSchedule:
            appState.expectedModes.removeValue(forKey: child.id)
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
        let blockDuration = seconds ?? 86400
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
        if event.eventType == .unlockRequested,
           cleanDetails.hasPrefix("Requesting access to ") {
            appName = String(cleanDetails.dropFirst("Requesting access to ".count))
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
                // Extract app name from "Requesting access to AppName\nTOKEN:..." details.
                // Strip the TOKEN payload for display.
                let (displayDetails, extractedAppName) = Self.parseEventDetails(event)

                return TimelineEntry(
                    id: event.id,
                    label: displayDetails ?? event.eventType.displayName,
                    timestamp: event.timestamp,
                    isCommand: false,
                    isUnlockRequest: event.eventType == .unlockRequested,
                    deviceID: event.deviceID,
                    appName: extractedAppName,
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
            let hasCoveringEvent = (-30...30).contains(where: { offset in
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
    }

    func requestTimeLimitSetup(for device: ChildDevice) async {
        await performCommand(.requestTimeLimitSetup, target: .device(device.id))
    }

    func setTimeLimit(config: TimeLimitConfig, minutes: Int) async {
        guard let cloudKit = appState.cloudKit else { return }
        var updated = config
        updated.dailyLimitMinutes = minutes
        updated.updatedAt = Date()
        try? await cloudKit.saveTimeLimitConfig(updated)
        if let idx = timeLimitConfigs.firstIndex(where: { $0.id == config.id }) {
            timeLimitConfigs[idx] = updated
        }
    }

    func removeTimeLimit(config: TimeLimitConfig) async {
        guard let cloudKit = appState.cloudKit else { return }
        try? await cloudKit.deleteTimeLimitConfig(config.id)
        timeLimitConfigs.removeAll { $0.id == config.id }
        // Send command to all child devices to stop monitoring
        await performCommand(.removeTimeLimit(appFingerprint: config.appFingerprint), target: .child(config.childProfileID))
    }

    func grantExtraTime(config: TimeLimitConfig, minutes: Int) async {
        await performCommand(.grantExtraTime(appFingerprint: config.appFingerprint, extraMinutes: minutes), target: .child(config.childProfileID))
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
        guard let cloudKit = appState.cloudKit,
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

    /// Re-request all permissions on the child device (Screen Time + Location).
    /// Parent should be physically holding the child device when sending this.
    func requestPermissions() async {
        await performCommand(.requestPermissions, target: .child(child.id))
    }

    /// Re-request permissions for a specific device.
    func requestPermissions(for device: ChildDevice) async {
        await performCommand(.requestPermissions, target: .device(device.id))
    }

    /// Request a device to re-authorize FamilyControls, attempting .child first.
    /// Use this to upgrade from .individual to .child after adding the kid to Family Sharing.
    /// Parent must be physically at the child device to approve the .child authorization.
    func requestReauthorization(for device: ChildDevice) async {
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
