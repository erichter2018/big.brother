import Foundation
import Observation
import BigBrotherCore

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

    init(
        id: UUID,
        label: String,
        timestamp: Date,
        isCommand: Bool,
        status: CommandStatus? = nil,
        isUnlockRequest: Bool = false,
        deviceID: DeviceID? = nil,
        appName: String? = nil
    ) {
        self.id = id
        self.label = label
        self.timestamp = timestamp
        self.isCommand = isCommand
        self.status = status
        self.isUnlockRequest = isUnlockRequest
        self.deviceID = deviceID
        self.appName = appName
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

    /// Poll CloudKit for updated heartbeats every 10s so device status stays current.
    func startAutoRefresh() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { [weak self] in
                try? await self?.appState.refreshDashboard()
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
            try await appState.sendCommand(target: .child(child.id), action: .blockInternet(durationSeconds: blockDuration))
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

    /// Event types that are internal housekeeping and clutter the timeline.
    private static let filteredEventTypes: Set<EventType> = [
        .heartbeatSent, .policyReconciled
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
                !Self.filteredEventTypes.contains(event.eventType)
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
                    appName: extractedAppName
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

            if !hasCoveringEvent || cmd.status == .pending {
                let statusLabel: String
                switch cmd.status {
                case .applied: statusLabel = ""
                case .pending: statusLabel = " (pending)"
                case .delivered: statusLabel = " (delivered)"
                case .failed: statusLabel = " (failed)"
                case .expired: statusLabel = " (expired)"
                }

                entries.append(TimelineEntry(
                    id: cmd.id,
                    label: "Sent: \(cmd.action.displayDescription)\(statusLabel)",
                    timestamp: cmd.issuedAt,
                    isCommand: true,
                    status: cmd.status
                ))
            }
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

    func refresh() async {
        try? await appState.refreshDashboard()
        await loadEvents()
        await loadWeeklyScreenTime()
    }

    /// Fetch heartbeats from the last 7 days to build daily screen time trend.
    func loadWeeklyScreenTime() async {
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }

        let deviceIDs = Set(devices.map(\.id))
        guard !deviceIDs.isEmpty else {
            #if DEBUG
            print("[BigBrother] loadWeeklyScreenTime: no devices for \(child.name), skipping")
            #endif
            return
        }
        let today = Calendar.current.startOfDay(for: Date())
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today

        let allHeartbeats = (try? await cloudKit.fetchHeartbeats(familyID: familyID, since: sevenDaysAgo)) ?? []

        // Filter to this child's devices, extract max screen time per day
        let childHeartbeats = allHeartbeats.filter { deviceIDs.contains($0.deviceID) }

        var dailyMax: [String: Int] = [:]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        for hb in childHeartbeats {
            guard let mins = hb.screenTimeMinutes, mins > 0,
                  hb.heartbeatSource != "vpnExtension" else { continue }
            let key = fmt.string(from: hb.timestamp)
            dailyMax[key] = max(dailyMax[key] ?? 0, mins)
        }

        // Build sorted array for last 7 days
        var result: [(date: Date, minutes: Int)] = []
        for dayOffset in (-6...0) {
            guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let key = fmt.string(from: date)
            result.append((date: date, minutes: dailyMax[key] ?? 0))
        }
        weeklyScreenTime = result
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
