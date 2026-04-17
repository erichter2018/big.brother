import Foundation
import Observation
import CloudKit
import UserNotifications
import UIKit
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

    /// Copy a structured screen-time debug block for this child to the pasteboard.
    /// Used for hand-crafted troubleshooting sessions where the parent compares
    /// Big.Brother's tracked values against an Apple Screen Time screenshot.
    /// Grabs data from what the parent has readily available — `latestHeartbeats`
    /// (current reading per device) plus the rolling `heartbeatHistory` (last 3)
    /// — since the parent can't see kid-side DeviceActivity internals directly.
    func copyScreenTimeDebug() {
        let devices = appState.childDevices.filter { $0.childProfileID == child.id }
        let deviceIDs = Set(devices.map { $0.id.rawValue })
        let heartbeats = appState.latestHeartbeats.filter { deviceIDs.contains($0.deviceID.rawValue) }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let todayString: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        var lines: [String] = []
        lines.append("── Big.Brother Screen Time Debug ──")
        lines.append("Child: \(child.name)")
        lines.append("Date:  \(todayString)")
        lines.append("Build: b\(AppConstants.appBuildNumber)")
        lines.append("")

        if heartbeats.isEmpty {
            lines.append("No heartbeats found for this child's devices.")
        } else {
            for hb in heartbeats.sorted(by: { $0.timestamp > $1.timestamp }) {
                let rawName = devices.first(where: { $0.id.rawValue == hb.deviceID.rawValue })?.displayName ?? hb.deviceID.rawValue
                // Prefix with child name so the paste stands on its own next
                // to an Apple Screen Time screenshot (which is also titled
                // "<Kid>'s iPhone"). Skip if the device name already contains
                // the child's name to avoid "Daphne's Daphne's iPhone".
                let devName: String = rawName.localizedCaseInsensitiveContains(child.name)
                    ? rawName
                    : "\(child.name)'s \(rawName)"
                let age = Int(Date().timeIntervalSince(hb.timestamp))
                lines.append("── \(devName) ──")
                lines.append("Heartbeat age:  \(age)s  (ts=\(dateFormatter.string(from: hb.timestamp)))")
                lines.append("Source:         \(hb.heartbeatSource ?? "?")")
                lines.append("Build:          app=b\(hb.appBuildNumber ?? 0) monitor=b\(hb.monitorBuildNumber ?? 0) shield=b\(hb.shieldBuildNumber ?? 0)")
                if let st = hb.screenTimeMinutes {
                    let h = st / 60
                    let m = st % 60
                    lines.append("Screen time:    \(st) min (\(h)h \(m)m)")
                } else {
                    lines.append("Screen time:    not reported")
                }
                if let unlocks = hb.screenUnlockCount {
                    lines.append("Screen unlocks: \(unlocks) today")
                }
                lines.append("DNS blocked:    \(hb.dnsBlockedDomainCount ?? 0) domains")
                if let appUsage = hb.appUsageMinutes, !appUsage.isEmpty {
                    // Keys are FNV-1a fingerprints of ApplicationToken data.
                    // Resolve to the human-readable appName via the child's
                    // TimeLimitConfig list (which is already loaded on this VM
                    // and persists even if the Monitor milestone came from an
                    // app not shown on the current UI).
                    let fingerprintNames = Dictionary(
                        uniqueKeysWithValues: timeLimitConfigs.map { ($0.appFingerprint, $0.appName) }
                    )
                    lines.append("Per-app usage:")
                    let sorted = appUsage.sorted { $0.value > $1.value }
                    for (fingerprint, mins) in sorted.prefix(20) {
                        let name = fingerprintNames[fingerprint] ?? "?(\(fingerprint.prefix(8)))"
                        lines.append("  \(name): \(mins)m")
                    }
                    if sorted.count > 20 {
                        lines.append("  …and \(sorted.count - 20) more")
                    }
                } else {
                    lines.append("Per-app usage:  none reported")
                }
                lines.append("Mode:           \(hb.currentMode.rawValue)")
                // `hb.vpnDetected` is the check for USER-CONFIGURED non-BB VPNs
                // (ipsec/ppp/tap). BB's own tunnel is `utun` which that check
                // deliberately excludes to avoid Private Relay false positives,
                // so vpnDetected is ALWAYS false for BB-only setups and is not
                // a useful signal. `hb.tunnelConnected` is the authoritative
                // "BB's own VPN is up" flag.
                lines.append("BB tunnel:      \(hb.tunnelConnected.map { $0 ? "CONNECTED ✓" : "DISCONNECTED ✗" } ?? "unknown")")
                lines.append("Other VPN:      \(hb.vpnDetected == true ? "detected" : "none")")
                if let blocked = hb.internetBlocked, blocked {
                    lines.append("Internet block: ON (\(hb.internetBlockedReason ?? "unknown"))")
                }
                lines.append("")

                // Rolling history for this device (last 3 from appState).
                if let history = appState.heartbeatHistory[hb.deviceID.rawValue], history.count > 1 {
                    lines.append("History (newest first):")
                    for past in history.prefix(3) {
                        let pastAge = Int(Date().timeIntervalSince(past.timestamp))
                        let st = past.screenTimeMinutes.map { "\($0)m" } ?? "—"
                        lines.append("  \(pastAge)s ago: st=\(st) src=\(past.heartbeatSource ?? "?")")
                    }
                    lines.append("")
                }
            }
        }

        // BB tracks screen time via THREE independent pipelines — the heartbeat
        // field only surfaces the first. The dashboard card shows (1); the
        // ChildDetail AppUsageSection shows (3). The user reported their
        // per-app totals were higher than this dump was reporting, which is
        // because (3) was missing. Include all three so the paste matches
        // whatever on-screen number is being troubleshot.
        //
        //   1. Tunnel unlock→lock session counter → screenTimeMinutes
        //      (above, from heartbeat). Undercounts when main app suspends.
        //   2. Monitor DeviceActivityEvent milestones → appUsageMinutes
        //      (above). Only for explicitly-watched apps (time limits,
        //      always-allowed tokens). Empty if no such apps configured.
        //   3. DNS-query proportional allocation → estimatedAppUsage()
        //      (below). Derived from BBDNSActivity records. This is what
        //      ChildDetail's AppUsageSection displays.
        // Relabeled per three-way audit (codex + gemini + self): DNS-derived
        // "minutes" are proportional-allocation estimates over 15-minute slots,
        // not actual durations. A Pinterest keepalive ping can get credited
        // with a 15-min slot the kid spent on TikTok, because TikTok uses QUIC
        // and makes no visible DNS queries. Treat this as "which apps were
        // seen on the network today", NOT as usage time.
        lines.append("── Network activity hints (DNS — NOT real usage minutes) ──")
        if let snapshot = onlineActivity {
            let usage = snapshot.estimatedAppUsage()
                .sorted { $0.minutes > $1.minutes }
            if usage.isEmpty {
                lines.append("No DNS activity today.")
            } else {
                lines.append("Total DNS queries today: \(snapshot.totalQueries)")
                lines.append("Apps seen on network (ranked by allocation, not real time):")
                for entry in usage.prefix(20) {
                    lines.append("  \(entry.appName): \(Int(entry.minutes)) (hint only)")
                }
                if usage.count > 20 {
                    lines.append("  …and \(usage.count - 20) more")
                }
            }
        } else {
            lines.append("Not loaded — open ChildDetail screen first to populate.")
        }
        lines.append("")

        let text = lines.joined(separator: "\n")
        UIPasteboard.general.string = text
        // Haptic + visible banner. The banner alone was too subtle — users
        // weren't sure the tap had done anything. `.success` feedback is a
        // distinct double-tick tactile pattern so the kid-name tap now
        // registers even when the phone is face-up on a desk.
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        commandFeedback = "✓ Copied: \(child.name)'s screen time debug"
        isCommandError = false
        let snapshot = commandFeedback
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.commandFeedback == snapshot {
                self?.commandFeedback = nil
            }
        }
    }
    var cloudKitError: String?
    var timeline: [TimelineEntry] = []
    /// Daily screen time for the last 7 days (date → minutes). Loaded from CloudKit heartbeats.
    var weeklyScreenTime: [(date: Date, minutes: Int)] = []
    /// Per-day screen time slot data keyed by "yyyy-MM-dd" (slot index → seconds).
    var screenTimeByDay: [String: [Int: Int]] = [:]
    /// Bedtime compliance results keyed by "yyyy-MM-dd".
    var bedtimeCompliance: [String: BedtimeComplianceResult] = [:]

    /// Per-app time limit configs from CloudKit. CloudKit is authoritative;
    /// this list is seeded from a local cache at init so the UI renders
    /// immediately, then replaced by the CK fetch in `loadTimeLimits()`.
    /// Every mutation writes back to the cache so a parent restart picks
    /// up the latest known-good state without waiting for CloudKit.
    var timeLimitConfigs: [TimeLimitConfig] = [] {
        didSet {
            guard didFinishInit else { return }
            persistTimeLimitConfigCache()
        }
    }

    /// Fingerprints of apps blocked for today, persisted in UserDefaults keyed by child+date.
    var blockedForTodayFingerprints: Set<String> {
        didSet { Self.saveBlockedForToday(blockedForTodayFingerprints, childID: child.id) }
    }
    /// Local record of extra-time grants issued today, keyed by fingerprint.
    /// Used to ignore stale pre-grant heartbeat state until the child reports back.
    var grantedExtraTimestamps: [String: TimeInterval] {
        didSet { Self.saveGrantedExtraTimestamps(grantedExtraTimestamps, childID: child.id) }
    }

    /// DNS-based online activity snapshot for this child (today only, with slot data for timeline scrubbing).
    var onlineActivity: DomainActivitySnapshot?
    /// DNS-based online activity merged across last 7 days (aggregate counts, no slot data).
    var onlineActivityWeek: DomainActivitySnapshot?
    /// Per-day DNS snapshots keyed by date string ("2026-03-29"), for timeline day-by-day scrubbing.
    var onlineActivityByDay: [String: DomainActivitySnapshot] = [:]
    private var refreshTask: Task<Void, Never>?
    private var currentDayString: String

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

    /// Local mirror of the last-sent DNS-filtering state for this child. The
    /// authoritative state lives on the child devices' App Group; this is
    /// just UI memory so the parent sees what they last sent across app
    /// launches. Defaults to true (filter ON) since that's the shipped
    /// default.
    var dnsFilteringEnabled: Bool {
        get {
            let key = "dnsFiltering.\(child.id.rawValue)"
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: "dnsFiltering.\(child.id.rawValue)") }
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
        self.currentDayString = Self.todayDateString()
        self.blockedForTodayFingerprints = Self.loadBlockedForToday(childID: child.id)
        self.grantedExtraMinutes = Self.loadGrantedExtra(childID: child.id)
        self.grantedExtraTimestamps = Self.loadGrantedExtraTimestamps(childID: child.id)
        self.selfUnlockBudget = Self.loadSelfUnlockBudget(for: child.id)
        // Seed from persisted cache so Always Allowed / Time-Limited render
        // immediately on Child Detail open. The live CloudKit fetch runs via
        // `loadTimeLimits()` and replaces this with the authoritative list.
        self.timeLimitConfigs = Self.loadCachedTimeLimitConfigs(childID: child.id)
        self.didFinishInit = true
    }

    // MARK: - Time-Limit Config Cache
    //
    // CloudKit is the source of truth for these records, but the parent
    // dashboard needs them available without a round-trip every time the
    // user opens a kid. We persist the last-known list in UserDefaults,
    // keyed by child ID, so the Always Allowed / Time-Limited sections
    // render immediately. `loadTimeLimits()` still fetches fresh from CK
    // on every open to pick up changes from other parent devices.

    private static func timeLimitCacheKey(childID: ChildProfileID) -> String {
        "timeLimitConfigsCache.\(childID.rawValue)"
    }

    private static func loadCachedTimeLimitConfigs(childID: ChildProfileID) -> [TimeLimitConfig] {
        guard let data = UserDefaults.standard.data(forKey: timeLimitCacheKey(childID: childID)),
              let decoded = try? JSONDecoder().decode([TimeLimitConfig].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.appName < $1.appName }
    }

    private static func saveCachedTimeLimitConfigs(
        _ configs: [TimeLimitConfig],
        childID: ChildProfileID
    ) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: timeLimitCacheKey(childID: childID))
    }

    private func persistTimeLimitConfigCache() {
        Self.saveCachedTimeLimitConfigs(timeLimitConfigs, childID: child.id)
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

    private static func todayDateString() -> String {
        dateFormatter.string(from: Date())
    }

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

    private static func grantedExtraTimestampKey(childID: ChildProfileID) -> String {
        let today = dateFormatter.string(from: Date())
        return "grantedExtraAt.\(childID.rawValue).\(today)"
    }

    private static func loadGrantedExtraTimestamps(childID: ChildProfileID) -> [String: TimeInterval] {
        let key = grantedExtraTimestampKey(childID: childID)
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: TimeInterval]) ?? [:]
    }

    private static func saveGrantedExtraTimestamps(
        _ timestamps: [String: TimeInterval],
        childID: ChildProfileID
    ) {
        let key = grantedExtraTimestampKey(childID: childID)
        UserDefaults.standard.set(timestamps, forKey: key)
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
            refreshDayScopedStateIfNeeded()
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
        guard refreshTask == nil else { return }
        ensureDataLoaded()

        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch { return }
                let dayChanged = self?.refreshDayScopedStateIfNeeded() ?? false
                await self?.loadEvents()
                if dayChanged {
                    await self?.loadWeeklyScreenTime()
                    await self?.loadOnlineActivity()
                }
                await self?.loadTimeLimits()
                await self?.loadPendingAppReviews() // Must run after loadTimeLimits
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    var devices: [ChildDevice] {
        // User-set invariant: iPhone ALWAYS above iPad, everywhere. Sorted
        // primarily by `deviceKindSortRank` (iPhone=0 < iPad=1 < other=2),
        // and alphabetical by displayName as tiebreaker so multiple devices
        // of the same kind still have a stable order. Do NOT resort by
        // heartbeat/online state — that causes rows to leapfrog when a
        // device drops offline, which is jarring.
        appState.childDevices
            .filter { $0.childProfileID == child.id }
            .sorted { lhs, rhs in
                if lhs.deviceKindSortRank != rhs.deviceKindSortRank {
                    return lhs.deviceKindSortRank < rhs.deviceKindSortRank
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
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
        if appState.childrenManuallyOverridden.contains(child.id) {
            return false
        }
        return scheduleProfile != nil
    }

    var scheduleNextTransition: Date? {
        scheduleProfile?.nextTransitionTime(from: Date())
    }

    // MARK: - Actions (target all devices for this child)

    func setMode(_ mode: LockMode) async {
        appState.childrenManuallyOverridden.insert(child.id)
        appState.expectedModes[child.id] = (mode, Date())
        await performCommand(.setMode(mode), target: .child(child.id))
    }

    func lockWithDuration(_ duration: LockDuration) async {
        switch duration {
        case .returnToSchedule:
            appState.childrenManuallyOverridden.remove(child.id)
            if let profile = scheduleProfile {
                let scheduleMode = profile.resolvedMode(at: Date())
                appState.expectedModes[child.id] = (scheduleMode, Date())
            } else {
                appState.expectedModes.removeValue(forKey: child.id)
            }
            await performCommand(.returnToSchedule, target: .child(child.id))

        case .indefinite:
            appState.childrenManuallyOverridden.insert(child.id)
            appState.expectedModes[child.id] = (.restricted, Date())
            await performCommand(.setMode(.restricted), target: .child(child.id))

        case .untilMidnight:
            appState.childrenManuallyOverridden.insert(child.id)
            let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
            appState.expectedModes[child.id] = (.restricted, Date())
            await performCommand(.lockUntil(date: midnight), target: .child(child.id))

        case .hours(let h):
            appState.childrenManuallyOverridden.insert(child.id)
            let target = Date().addingTimeInterval(Double(h) * 3600)
            appState.expectedModes[child.id] = (.restricted, Date())
            await performCommand(.lockUntil(date: target), target: .child(child.id))
        }
    }

    /// Lock down: essentialOnly shielding + internet block via VPN DNS blackhole.
    func lockDown(seconds: Int? = nil) async {
        appState.childrenManuallyOverridden.insert(child.id)
        appState.expectedModes[child.id] = (.lockedDown, Date())
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
        appState.childrenManuallyOverridden.insert(child.id)
        appState.expectedModes[child.id] = (.unlocked, Date())
        let expiry = Date().addingTimeInterval(Double(seconds))
        var dict = (try? JSONDecoder().decode([String: Date].self,
            from: UserDefaults.standard.data(forKey: "unlockExpiries") ?? Data())) ?? [:]
        dict[child.id.rawValue] = expiry
        if let encoded = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(encoded, forKey: "unlockExpiries")
        }
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
    func sendAppNameToChild(name: String, fingerprint: String, deviceID: DeviceID?) async {
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
        refreshDayScopedStateIfNeeded()
        StartupWatchdog.log("ChildDetail.refresh start")
        await withDeadline(3) { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            StartupWatchdog.log("ChildDetail.refresh: refreshDashboard()")
            try? await self.appState.refreshDashboard()
            StartupWatchdog.log(String(format: "ChildDetail.refresh: refreshDashboard done (%.2fs)", CFAbsoluteTimeGetCurrent() - t0))

            let t1 = CFAbsoluteTimeGetCurrent()
            async let events: Void = self.loadEvents()
            async let weekly: Void = self.loadWeeklyScreenTime()
            async let online: Void = self.loadOnlineActivity()
            async let limits: Void = self.loadTimeLimits()
            _ = await (events, weekly, online, limits)
            StartupWatchdog.log(String(format: "ChildDetail.refresh: parallel fetches done (%.2fs)", CFAbsoluteTimeGetCurrent() - t1))

            let t2 = CFAbsoluteTimeGetCurrent()
            await self.loadPendingAppReviews()
            StartupWatchdog.log(String(format: "ChildDetail.refresh: pending reviews done (%.2fs)", CFAbsoluteTimeGetCurrent() - t2))
            StartupWatchdog.log(String(format: "ChildDetail.refresh: TOTAL %.2fs", CFAbsoluteTimeGetCurrent() - t0))
        }
        StartupWatchdog.log("ChildDetail.refresh returned")
    }

    // MARK: - App Time Limits

    func loadTimeLimits() async {
        guard let cloudKit = appState.cloudKit else { return }
        if let configs = try? await cloudKit.fetchTimeLimitConfigs(childProfileID: child.id) {
            timeLimitConfigs = configs.sorted { $0.appName < $1.appName }
            persistTimeLimitConfigCache()
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
        await sendAppNameToChild(name: newName, fingerprint: config.appFingerprint, deviceID: config.deviceID)
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
        refreshDayScopedStateIfNeeded()
        blockedForTodayFingerprints.insert(config.appFingerprint)
        grantedExtraMinutes.removeValue(forKey: config.appFingerprint)
        grantedExtraTimestamps.removeValue(forKey: config.appFingerprint)
        await performCommand(
            .blockAppForToday(appFingerprint: config.appFingerprint),
            target: .child(config.childProfileID)
        )
    }

    /// Whether the app is blocked for today (exhausted or manually blocked).
    func isAppBlockedForToday(_ config: TimeLimitConfig) -> Bool {
        if blockedForTodayFingerprints.contains(config.appFingerprint) { return true }
        guard config.dailyLimitMinutes > 0 else { return false }
        return heartbeatReportsAppBlockedToday(config)
    }

    /// Extra minutes granted today, keyed by app fingerprint. Persisted in UserDefaults by child+date.
    var grantedExtraMinutes: [String: Int] {
        didSet { Self.saveGrantedExtra(grantedExtraMinutes, childID: child.id) }
    }

    func grantExtraTime(config: TimeLimitConfig, minutes: Int) async {
        refreshDayScopedStateIfNeeded()
        grantedExtraMinutes[config.appFingerprint, default: 0] += minutes
        grantedExtraTimestamps[config.appFingerprint] = Date().timeIntervalSince1970
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
        let todayStart = Calendar.current.startOfDay(for: Date())
        let deviceIDs = Set(devices.map(\.id))
        var bestHeartbeatUsage = 0
        for hb in appState.latestHeartbeats where deviceIDs.contains(hb.deviceID) {
            guard hb.timestamp >= todayStart else { continue }
            if let usage = hb.appUsageMinutes, let minutes = usage[config.appFingerprint] {
                bestHeartbeatUsage = max(bestHeartbeatUsage, minutes)
            }
        }
        if bestHeartbeatUsage > 0 {
            return Double(bestHeartbeatUsage)
        }
        // Fallback: DNS estimate.
        return estimatedAppUsage(for: config.appName)
    }

    /// Estimated app usage in minutes from DNS data for today.
    func estimatedAppUsage(for appName: String) -> Double {
        guard let activity = onlineActivity,
              activity.date == Self.todayDateString() else {
            return 0
        }
        let usage = activity.estimatedAppUsage()
        return usage.first(where: { $0.appName == appName })?.minutes ?? 0
    }

    @discardableResult
    private func refreshDayScopedStateIfNeeded() -> Bool {
        let today = Self.todayDateString()
        guard today != currentDayString else { return false }
        currentDayString = today
        blockedForTodayFingerprints = Self.loadBlockedForToday(childID: child.id)
        grantedExtraMinutes = Self.loadGrantedExtra(childID: child.id)
        grantedExtraTimestamps = Self.loadGrantedExtraTimestamps(childID: child.id)
        return true
    }

    private func heartbeatReportsAppBlockedToday(_ config: TimeLimitConfig) -> Bool {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let deviceIDs = Set(devices.map(\.id))
        let grantedAt = grantedExtraTimestamps[config.appFingerprint]

        return appState.latestHeartbeats.contains { hb in
            guard deviceIDs.contains(hb.deviceID),
                  hb.timestamp >= todayStart else {
                return false
            }
            if let grantedAt,
               hb.timestamp.timeIntervalSince1970 < grantedAt {
                return false
            }
            return Self.heartbeat(hb, reportsBlockedTodayFor: config)
        }
    }

    private static func heartbeat(
        _ heartbeat: DeviceHeartbeat,
        reportsBlockedTodayFor config: TimeLimitConfig
    ) -> Bool {
        if let bundleID = normalizeBundleID(config.bundleID),
           heartbeat.exhaustedAppBundleIDs?.contains(bundleID) == true {
            return true
        }
        if heartbeat.exhaustedAppFingerprints?.contains(config.appFingerprint) == true {
            return true
        }
        guard isUsefulAppName(config.appName) else { return false }
        let normalizedName = normalizeAppName(config.appName)
        return heartbeat.exhaustedAppNames?.contains(where: {
            normalizeAppName($0) == normalizedName
        }) == true
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
    /// Backed by `AppState.pendingReviewsByChild` so silent-push handlers
    /// can insert new reviews and the UI updates without a manual refresh.
    /// @Observable tracks the read dependency across the boundary.
    var pendingAppReviews: [PendingAppReview] {
        get { appState.pendingReviewsByChild[child.id] ?? [] }
        set { appState.setPendingReviews(newValue, for: child.id) }
    }
    var pendingReviewDiagnostic = ""
    private(set) var blockedAppNames: Set<String> = []

    func isPreviouslyBlocked(_ review: PendingAppReview) -> Bool {
        Self.isUsefulAppName(review.appName) &&
            blockedAppNames.contains(Self.normalizeAppName(review.appName).lowercased())
    }

    private static func normalizeBundleID(_ bundleID: String?) -> String? {
        guard let bid = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bid.isEmpty else {
            return nil
        }
        return bid.lowercased()
    }

    private static func isUsefulAppName(_ name: String) -> Bool {
        let normalized = normalizeAppName(name).lowercased()
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

    private static func review(_ review: PendingAppReview, matches config: TimeLimitConfig) -> Bool {
        // Centralized matcher. Cross-device-safe: bundleID > fingerprint
        // (same-device only, gated on deviceID scope) > useful-app-name.
        AppIdentityMatcher.same(review.identityCandidate, config.identityCandidate)
    }

    private static func review(_ review: PendingAppReview, isSupersededBy config: TimeLimitConfig) -> Bool {
        guard Self.review(review, matches: config) else { return false }
        return config.isActive || config.updatedAt >= review.updatedAt
    }

    private static func reviewsMatch(_ lhs: PendingAppReview, _ rhs: PendingAppReview) -> Bool {
        // Same matcher the review-vs-config path uses. Two reviews from the
        // same device with matching fingerprints are the same app (re-request
        // race); two reviews from different devices match on bundleID or
        // useful name but NOT on fingerprint (tokens are device-local).
        AppIdentityMatcher.same(lhs.identityCandidate, rhs.identityCandidate)
    }

    private func matchingTimeLimitConfig(for review: PendingAppReview) -> TimeLimitConfig? {
        timeLimitConfigs
            .filter { Self.review(review, matches: $0) }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                if $0.isActive != $1.isActive { return $0.isActive && !$1.isActive }
                return $0.id.uuidString > $1.id.uuidString
            }
            .first
    }

    private func matchingTimeLimitConfigIndex(for review: PendingAppReview) -> Int? {
        guard let match = matchingTimeLimitConfig(for: review) else { return nil }
        return timeLimitConfigs.firstIndex(where: { $0.id == match.id })
    }

    func loadPendingAppReviews() async {
        guard let cloudKit = appState.cloudKit else {
            pendingReviewDiagnostic = "No CloudKit service"
            return
        }
        if appState.pendingReviewNeedsRefresh { appState.pendingReviewNeedsRefresh = false }
        do {
            let allFromCK = try await cloudKit.fetchPendingAppReviews(childProfileID: child.id)

            // Drop reviews from dead devices and suppress stale reviews that were
            // already superseded by a newer parent decision. A later re-request
            // still shows up because its review timestamp is newer than the revoke.
            let heartbeatCutoff = Date().addingTimeInterval(-48 * 3600)
            let aliveDeviceIDs: Set<DeviceID> = {
                var ids = Set<DeviceID>()
                for device in devices {
                    if let lastHB = device.lastHeartbeat, lastHB > heartbeatCutoff {
                        ids.insert(device.id)
                    } else if device.lastHeartbeat == nil {
                        ids.insert(device.id)
                    }
                }
                return ids
            }()

            let live: [PendingAppReview]
            let orphans: [PendingAppReview]
            if aliveDeviceIDs.isEmpty {
                live = allFromCK.filter { review in
                    if timeLimitConfigs.contains(where: { Self.review(review, isSupersededBy: $0) }) {
                        return false
                    }
                    return true
                }
                orphans = []
            } else {
                live = allFromCK.filter { review in
                    guard aliveDeviceIDs.contains(review.deviceID) else { return false }
                    if timeLimitConfigs.contains(where: { Self.review(review, isSupersededBy: $0) }) {
                        return false
                    }
                    return true
                }
                orphans = allFromCK.filter { !aliveDeviceIDs.contains($0.deviceID) }
            }

            // Maintain blockedAppNames (used by isPreviouslyBlocked UI hint).
            let blockedConfigs = timeLimitConfigs.filter { !$0.isActive }
            blockedAppNames = Set(blockedConfigs.map { Self.normalizeAppName($0.appName).lowercased() })

            let sorted = live.sorted { $0.createdAt < $1.createdAt }
            pendingAppReviews = sorted
            pendingReviewDiagnostic = "CK: \(allFromCK.count) total, \(sorted.count) live"
            AppReviewNotificationService.checkAndNotify(
                reviews: sorted,
                childName: child.name,
                childProfileID: child.id
            )

            // Background: purge zombie records from dead devices.
            if !orphans.isEmpty {
                Task { [cloudKit] in
                    await withTaskGroup(of: Void.self) { group in
                        for r in orphans {
                            group.addTask { try? await cloudKit.deletePendingAppReview(r.id) }
                        }
                    }
                }
            }
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

    /// Parent decides on a pending app. The decision is child-scoped, so if
    /// the same app is pending on multiple devices right now, all matching
    /// review rows are cleared and each device gets its own fingerprint-specific
    /// command.
    func reviewApp(_ review: PendingAppReview, disposition: AppDisposition, minutes: Int? = nil) async {
        guard let cloudKit = appState.cloudKit else { return }
        let matchingReviews = {
            let matches = pendingAppReviews.filter { Self.reviewsMatch($0, review) }
            return matches.isEmpty ? [review] : matches
        }()
        let matchingIDs = Set(matchingReviews.map(\.id))

        // Delete the pending-review records from CloudKit FIRST — before any
        // other path can refetch and resurrect them, and before the optimistic
        // UI removal. CK delete is the authoritative "this request is closed"
        // signal; everything else (time-limit config, reviewApp command, UI
        // state) is downstream of that authority. No tombstones, no race
        // windows: by the time we remove from UI, the records don't exist
        // on CloudKit anymore, so a concurrent refetch literally cannot see
        // them.
        //
        // If the delete fails (network hiccup), we bail without touching UI
        // state, surface the error, and the user retries. Worst case: the
        // card stays visible with its original disposition, parent can tap
        // again. Better than the old flow where a failed delete meant a
        // re-appearing card after the refresh tick.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for id in matchingIDs {
                    group.addTask { try await cloudKit.deletePendingAppReview(id) }
                }
                try await group.waitForAll()
            }
        } catch {
            showError("Couldn't close the review: \(error.localizedDescription)")
            return
        }

        // CK delete committed. Safe to remove from UI now — nothing can
        // refetch these records because they no longer exist server-side.
        pendingAppReviews.removeAll { matchingIDs.contains($0.id) }
        if pendingAppReviews.isEmpty {
            appState.childrenWithPendingRequests.remove(child.id)
        }

        let dailyMinutes: Int
        let isActive: Bool
        switch disposition {
        case .allowAlways: dailyMinutes = 0; isActive = true
        case .timeLimit:   dailyMinutes = minutes ?? 60; isActive = true
        case .keepBlocked: dailyMinutes = 0; isActive = false
        }

        // Seed local config so the next refresh doesn't re-surface this review.
        if let idx = matchingTimeLimitConfigIndex(for: review) {
            timeLimitConfigs[idx].isActive = isActive
            timeLimitConfigs[idx].dailyLimitMinutes = dailyMinutes
            timeLimitConfigs[idx].appName = review.appName
            if let bid = review.bundleID {
                timeLimitConfigs[idx].bundleID = bid
            }
            timeLimitConfigs[idx].updatedAt = Date()
        } else {
            timeLimitConfigs.append(TimeLimitConfig(
                familyID: review.familyID,
                childProfileID: review.childProfileID,
                appFingerprint: review.appFingerprint,
                appName: review.appName,
                dailyLimitMinutes: dailyMinutes,
                isActive: isActive,
                appCategory: nil,
                bundleID: review.bundleID
            ))
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let category = await AppStoreLookup.lookupCategory(appName: review.appName)

            var seenCommandKeys = Set<String>()
            for matchedReview in matchingReviews {
                let commandKey = "\(matchedReview.deviceID.rawValue)::\(matchedReview.appFingerprint)"
                guard seenCommandKeys.insert(commandKey).inserted else { continue }

                await self.sendAppNameToChild(
                    name: review.appName,
                    fingerprint: matchedReview.appFingerprint,
                    deviceID: matchedReview.deviceID
                )
                await self.performCommand(
                    .reviewApp(
                        fingerprint: matchedReview.appFingerprint,
                        disposition: disposition,
                        minutes: minutes
                    ),
                    target: .device(matchedReview.deviceID)
                )
            }

            if let idx = self.matchingTimeLimitConfigIndex(for: review) {
                var updated = self.timeLimitConfigs[idx]
                updated.dailyLimitMinutes = dailyMinutes
                updated.isActive = isActive
                updated.appName = review.appName
                if let bid = review.bundleID { updated.bundleID = bid }
                if let category { updated.appCategory = category }
                updated.updatedAt = Date()
                do {
                    try await cloudKit.saveTimeLimitConfig(updated)
                    if self.timeLimitConfigs.indices.contains(idx) {
                        self.timeLimitConfigs[idx] = updated
                    }
                } catch {
                    self.showError("Failed to save app config: \(error.localizedDescription)")
                }
            }

            // Matching records were deleted synchronously at the top of this
            // function — no stale-review cleanup needed here anymore.
        }
    }

    /// Case + diacritics insensitive app-name comparison. Matches the child-side
    /// `CommandProcessorImpl.normalizeAppName` so sibling-device fan-out stays
    /// consistent with name-based token resolution on the child.
    private static func appNamesMatch(_ a: String, _ b: String) -> Bool {
        normalizeAppName(a) == normalizeAppName(b)
    }

    private static func normalizeAppName(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - DNS Kill Switch

    /// Remotely enable/disable DNS filtering on all of the child's devices.
    /// Default window when disabling is 24 hours — the tunnel auto-re-enables
    /// after that, so a forgotten "off" can't leave a kid on unfiltered DNS
    /// indefinitely. Shields are unaffected; only DNS policy enforcement is.
    func sendDNSFiltering(enabled: Bool, durationSeconds: Int = 86400) async {
        await performCommand(
            .setDNSFiltering(enabled: enabled, durationSeconds: enabled ? 0 : durationSeconds),
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
