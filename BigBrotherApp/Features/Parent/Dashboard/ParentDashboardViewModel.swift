import Foundation
import Observation
import BigBrotherCore

@Observable @MainActor
final class ParentDashboardViewModel: CommandSendable {
    let appState: AppState

    var loadingState: ViewLoadingState<[ChildProfile]> = .idle
    var isSendingCommand = false
    var commandFeedback: String?
    var isCommandError = false

    /// Tracks temporary unlock expiry per child (parent-side countdown).
    /// Persisted in UserDefaults so it survives app relaunch.
    var unlockExpiries: [ChildProfileID: Date] = [:] {
        didSet { persistUnlockExpiries() }
    }
    var now = Date()
    private var countdownTimer: Timer?

    /// Proxy for appState.scheduleActiveChildren (shared across all view models).
    private var scheduleActiveChildren: Set<ChildProfileID> {
        get { appState.scheduleActiveChildren }
        set { appState.scheduleActiveChildren = newValue }
    }

    /// Tracks timed unlock phases (penalty → unlock) per child.
    struct TimedUnlockPhase: Codable {
        let penaltyEndsAt: Date
        let unlockEndsAt: Date
    }
    var timedUnlockPhases: [ChildProfileID: TimedUnlockPhase] = [:] {
        didSet { persistTimedUnlockPhases() }
    }
    /// How many penalty seconds to deduct when the timed unlock window expires.
    /// Stored at unlock time so the expire handler knows the correct remaining value.
    var timedUnlockPenaltyDeductions: [ChildProfileID: Int] = [:]
    /// Tracks when a timed lock-down (internet block) expires per child.
    var lockDownExpiries: [ChildProfileID: Date] = [:]

    // MARK: - Family Pause

    /// Whether the family pause button is shown in the dashboard toolbar.
    var familyPauseEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "familyPauseEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "familyPauseEnabled") }
    }

    /// When the current family pause expires (nil = not paused).
    var familyPauseExpiresAt: Date? {
        get {
            let ts = UserDefaults.standard.double(forKey: "familyPauseExpiresAt")
            guard ts > 0 else { return nil }
            let date = Date(timeIntervalSince1970: ts)
            return date > Date() ? date : nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "familyPauseExpiresAt")
            } else {
                UserDefaults.standard.removeObject(forKey: "familyPauseExpiresAt")
            }
        }
    }

    var isFamilyPaused: Bool { familyPauseExpiresAt != nil }

    /// Snapshot of parent-side state before pause, so we can restore on unpause.
    struct PauseSnapshot: Codable {
        let pausedAt: Date
        let unlockExpiries: [String: Date]           // ChildProfileID.rawValue → expiry
        let timedUnlockPhases: [String: TimedUnlockPhase]
        let timedUnlockPenaltyDeductions: [String: Int]
        let scheduleActiveChildIDs: [String]
        let expectedModes: [String: String]          // childID → LockMode.rawValue
    }

    private var pauseSnapshot: PauseSnapshot? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "familyPauseSnapshot") else { return nil }
            return try? JSONDecoder().decode(PauseSnapshot.self, from: data)
        }
        set {
            if let snapshot = newValue, let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "familyPauseSnapshot")
            } else {
                UserDefaults.standard.removeObject(forKey: "familyPauseSnapshot")
            }
        }
    }

    func pauseAll() async {
        // Snapshot current state before pausing
        pauseSnapshot = PauseSnapshot(
            pausedAt: Date(),
            unlockExpiries: Dictionary(uniqueKeysWithValues: unlockExpiries.map { ($0.key.rawValue, $0.value) }),
            timedUnlockPhases: Dictionary(uniqueKeysWithValues: timedUnlockPhases.map { ($0.key.rawValue, $0.value) }),
            timedUnlockPenaltyDeductions: Dictionary(uniqueKeysWithValues: timedUnlockPenaltyDeductions.map { ($0.key.rawValue, $0.value) }),
            scheduleActiveChildIDs: scheduleActiveChildren.map(\.rawValue),
            expectedModes: Dictionary(uniqueKeysWithValues: appState.expectedModes.compactMap { k, v in
                (k.rawValue, v.mode.rawValue)
            })
        )

        let duration = 3600 // 1 hour
        familyPauseExpiresAt = Date().addingTimeInterval(Double(duration))
        await lockDownAll(seconds: duration)
    }

    func unpauseAll() async {
        let snapshot = pauseSnapshot
        let pausedAt = snapshot?.pausedAt ?? Date()
        let pauseDuration = Date().timeIntervalSince(pausedAt)

        familyPauseExpiresAt = nil
        pauseSnapshot = nil
        isSendingCommand = true

        for child in childProfiles {
            lockDownExpiries.removeValue(forKey: child.id)
            let childKey = child.id.rawValue

            // Check if this child had an active temporary unlock when paused
            if let originalExpiry = snapshot?.unlockExpiries[childKey] {
                let remaining = originalExpiry.timeIntervalSince(pausedAt)
                if remaining > 10 {
                    // Re-issue temp unlock with remaining time
                    let restoredExpiry = Date().addingTimeInterval(remaining)
                    unlockExpiries[child.id] = restoredExpiry
                    appState.expectedModes[child.id] = (.unlocked, Date())
                    try? await appState.sendCommand(
                        target: .child(child.id),
                        action: .temporaryUnlock(durationSeconds: Int(remaining))
                    )
                    continue
                }
            }

            // Check if this child had a timed unlock phase when paused
            if let phase = snapshot?.timedUnlockPhases[childKey] {
                let penaltyRemaining = phase.penaltyEndsAt.timeIntervalSince(pausedAt)
                let unlockRemaining = phase.unlockEndsAt.timeIntervalSince(pausedAt)
                if unlockRemaining > 10 {
                    // Shift the phase forward by pause duration
                    let newPhase = TimedUnlockPhase(
                        penaltyEndsAt: Date().addingTimeInterval(max(0, penaltyRemaining)),
                        unlockEndsAt: Date().addingTimeInterval(unlockRemaining)
                    )
                    timedUnlockPhases[child.id] = newPhase
                    if let deduction = snapshot?.timedUnlockPenaltyDeductions[childKey] {
                        timedUnlockPenaltyDeductions[child.id] = deduction
                    }

                    // Re-send timed unlock with remaining total seconds
                    let penaltySecs = Int(max(0, penaltyRemaining))
                    let totalSecs = Int(unlockRemaining)
                    appState.expectedModes[child.id] = (.unlocked, Date())
                    try? await appState.sendCommand(
                        target: .child(child.id),
                        action: .timedUnlock(totalSeconds: totalSecs, penaltySeconds: penaltySecs)
                    )
                    continue
                }
            }

            // Default: return to schedule
            if snapshot?.scheduleActiveChildIDs.contains(childKey) ?? true {
                scheduleActiveChildren.insert(child.id)
            }
            appState.expectedModes[child.id] = nil
            try? await appState.sendCommand(target: .child(child.id), action: .returnToSchedule)
        }

        commandFeedback = "Unpause — restored previous states"
        isSendingCommand = false
        startCountdownTimer()
        startConfirmationPolling()
        autoDismissFeedback()
    }

    private static let unlockExpiriesKey = "unlockExpiries"
    private static let timedUnlockPhasesKey = "timedUnlockPhases"

    init(appState: AppState) {
        self.appState = appState
        // Migrate old schedule-active data to appState if needed.
        if appState.scheduleActiveChildren.isEmpty,
           let raw = UserDefaults.standard.array(forKey: "scheduleActiveChildIDs") as? [String],
           !raw.isEmpty {
            appState.scheduleActiveChildren = Set(raw.map { ChildProfileID(rawValue: $0) })
            UserDefaults.standard.removeObject(forKey: "scheduleActiveChildIDs")
        }
        // Restore persisted unlock expiries (prune expired).
        if let data = UserDefaults.standard.data(forKey: Self.unlockExpiriesKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            let now = Date()
            self.unlockExpiries = decoded
                .filter { $0.value > now }
                .reduce(into: [:]) { $0[ChildProfileID(rawValue: $1.key)] = $1.value }
        }
        // Restore persisted timed unlock phases (prune expired).
        if let data = UserDefaults.standard.data(forKey: Self.timedUnlockPhasesKey),
           let decoded = try? JSONDecoder().decode([String: TimedUnlockPhase].self, from: data) {
            let now = Date()
            let active = decoded.filter { $0.value.unlockEndsAt > now }
            let expired = decoded.filter { $0.value.unlockEndsAt <= now }
            self.timedUnlockPhases = active
                .reduce(into: [:]) { $0[ChildProfileID(rawValue: $1.key)] = $1.value }
            // Stop (not clear) Firebase timers for phases that expired while app was closed.
            // stopPenaltyTimer preserves remaining penalty time (e.g., 5h - 2h = 3h).
            // clearPenaltyTimer would zero it out, which is wrong.
            if !expired.isEmpty {
                let expiredChildIDs = expired.map { ChildProfileID(rawValue: $0.key) }
                Task {
                    for childID in expiredChildIDs {
                        if let child = self.appState.childProfiles.first(where: { $0.id == childID })
                            ?? self.appState.orderedChildProfiles.first(where: { $0.id == childID }) {
                            await self.stopPenaltyTimer(for: child)
                        }
                    }
                }
            }
        }
        // Restart countdown timer if there are active phases or expiries to track.
        if !unlockExpiries.isEmpty || !timedUnlockPhases.isEmpty {
            startCountdownTimer()
        }
    }

    nonisolated deinit {
        // Timer invalidation handled by stopCountdownTimer() when view disappears.
    }

    private func persistUnlockExpiries() {
        let raw = unlockExpiries.reduce(into: [String: Date]()) { $0[$1.key.rawValue] = $1.value }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.unlockExpiriesKey)
        }
    }

    private func persistTimedUnlockPhases() {
        let raw = timedUnlockPhases.reduce(into: [String: TimedUnlockPhase]()) { $0[$1.key.rawValue] = $1.value }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.timedUnlockPhasesKey)
        }
    }

    // MARK: - Data

    var childProfiles: [ChildProfile] { appState.orderedChildProfiles }
    var childDevices: [ChildDevice] { appState.childDevices }
    var latestHeartbeats: [DeviceHeartbeat] { appState.latestHeartbeats }

    /// Devices for a child, sorted so iPhones come before iPads.
    /// This makes heartbeat age, mode, and status prefer the phone when a kid has both.
    func devices(for child: ChildProfile) -> [ChildDevice] {
        childDevices
            .filter { $0.childProfileID == child.id }
            .sorted { lhs, _ in lhs.displayName.localizedCaseInsensitiveContains("iPhone") }
    }

    func heartbeat(for device: ChildDevice) -> DeviceHeartbeat? {
        latestHeartbeats.first { $0.deviceID == device.id }
    }

    // MARK: - Loading

    func loadDashboard() async {
        loadingState = .loading
        do {
            try await appState.refreshDashboard()
            if appState.childProfiles.isEmpty {
                loadingState = .empty("No children configured yet.")
            } else {
                loadingState = .loaded(appState.childProfiles)
            }
        } catch {
            loadingState = .error(error.localizedDescription)
        }
    }

    // MARK: - Global Actions

    func restrictAll(duration: LockDuration = .indefinite) async {
        isSendingCommand = true
        commandFeedback = nil
        unlockExpiries.removeAll()
        timedUnlockPhases.removeAll()
        scheduleActiveChildren.removeAll()
        for child in childProfiles {
            await restrictChildQuiet(child, duration: duration)
        }
        commandFeedback = "Lock All sent"
        isSendingCommand = false
        // Track for retry — use .restricted as the representative lock action.
        trackPendingCommand(.setMode(.restricted), target: .allDevices)
        startConfirmationPolling()
        autoDismissFeedback()
    }

    func lockAll() async {
        isSendingCommand = true
        commandFeedback = nil
        unlockExpiries.removeAll()
        timedUnlockPhases.removeAll()
        timedUnlockPenaltyDeductions.removeAll()
        lockDownExpiries.removeAll()
        scheduleActiveChildren.removeAll()
        for child in childProfiles {
            await lockChild(child)
        }
        commandFeedback = "Lock All sent"
        isSendingCommand = false
        trackPendingCommand(.setMode(.locked), target: .allDevices)
        startConfirmationPolling()
        autoDismissFeedback()
    }

    func unlockAllWithTimer(seconds: Int) async {
        isSendingCommand = true
        commandFeedback = nil
        for child in childProfiles {
            await unlockChildWithTimer(child, seconds: seconds)
        }
        commandFeedback = "Unlock All + timer sent"
        isSendingCommand = false
        autoDismissFeedback()
    }

    func unlockAll(seconds: Int = 24 * 3600) async {
        isSendingCommand = true
        commandFeedback = nil
        // Unlock each child individually so per-child expiry extension works correctly.
        for child in childProfiles {
            await unlockChild(child, seconds: seconds)
        }
        commandFeedback = "Unlock All sent"
        isSendingCommand = false
        autoDismissFeedback()
    }

    // MARK: - Per-Child Actions

    /// Restrict a child with UI feedback (for individual restrict actions).
    func restrictChild(_ child: ChildProfile, duration: LockDuration = .indefinite) async {
        await restrictChildQuiet(child, duration: duration)
        startConfirmationPolling()
    }

    /// Lock a child without setting commandFeedback (for bulk operations).
    private func restrictChildQuiet(_ child: ChildProfile, duration: LockDuration) async {
        unlockExpiries.removeValue(forKey: child.id)
        timedUnlockPhases.removeValue(forKey: child.id)
        timedUnlockPenaltyDeductions.removeValue(forKey: child.id)
        lockDownExpiries.removeValue(forKey: child.id)
        scheduleActiveChildren.remove(child.id)

        let commandAction: CommandAction
        switch duration {
        case .returnToSchedule:
            appState.expectedModes.removeValue(forKey: child.id)
            scheduleActiveChildren.insert(child.id)
            commandAction = .returnToSchedule
            try? await appState.sendCommand(target: .child(child.id), action: commandAction)

        case .indefinite:
            appState.expectedModes[child.id] = (.restricted, Date())
            commandAction = .setMode(.restricted)
            try? await appState.sendCommand(target: .child(child.id), action: commandAction)

        case .untilMidnight:
            let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
            appState.expectedModes[child.id] = (.restricted, Date())
            commandAction = .lockUntil(date: midnight)
            try? await appState.sendCommand(target: .child(child.id), action: commandAction)

        case .hours(let h):
            let lockTarget = Date().addingTimeInterval(Double(h) * 3600)
            appState.expectedModes[child.id] = (.restricted, Date())
            commandAction = .lockUntil(date: lockTarget)
            try? await appState.sendCommand(target: .child(child.id), action: commandAction)
        }
        trackPendingCommand(commandAction, target: .child(child.id))
        // Internet is now mode-driven — no separate blockInternet command needed.
        // Tunnel auto-unblocks when mode changes away from .lockedDown.
        // Stop Firebase penalty timer on any lock action.
        await stopPenaltyTimer(for: child)
    }

    func unlockChild(_ child: ChildProfile, seconds: Int = 24 * 3600) async {
        now = Date()

        // Compute absolute expiry: extend existing expiry or start fresh.
        let currentExpiry = unlockExpiries[child.id]
        let newExpiry: Date
        if let currentExpiry, currentExpiry > now {
            // Already unlocked — extend by the requested amount
            newExpiry = currentExpiry.addingTimeInterval(Double(seconds))
        } else {
            // Locked or expired — start fresh from now
            newExpiry = now.addingTimeInterval(Double(seconds))
        }
        unlockExpiries[child.id] = newExpiry

        // Send the absolute duration from NOW to the child device.
        let durationFromNow = max(1, Int(newExpiry.timeIntervalSince(now)))

        appState.expectedModes.removeValue(forKey: child.id)
        startCountdownTimer()
        let action: CommandAction = .temporaryUnlock(durationSeconds: durationFromNow)
        trackPendingCommand(action, target: .child(child.id))
        await performCommand(action, target: .child(child.id))
        // Internet is now mode-driven — no separate blockInternet command needed.
        // Tunnel auto-unblocks when mode changes away from .lockedDown.
        startConfirmationPolling()
    }

    /// Unlock child with penalty offset.
    /// If no penalty → immediate unlock for full duration.
    /// If penalty exists → device stays locked during penalty, then unlocks for remaining time.
    /// Total window = seconds. Penalty portion consumed first.
    func unlockChildWithTimer(_ child: ChildProfile, seconds: Int) async {
        // Don't remove from scheduleActiveChildren — child returns to schedule after expiry.

        // Start the penalty timer in Firebase FIRST.
        await startPenaltyTimer(for: child)

        // Read penalty AFTER starting — use the banked penaltySeconds
        // (not remainingSeconds which depends on async Firestore listener).
        let timer = penaltyTimer(for: child)
        let penaltySecs = timer?.penaltySeconds ?? 0

        if penaltySecs <= 0 {
            // No penalty — immediate unlock for full duration.
            await unlockChild(child, seconds: seconds)
        } else {
            // Timed unlock with penalty offset.
            // totalSeconds = requested free time window.
            // penaltySeconds = current penalty (consumed first).
            // Actual free time = max(0, totalSeconds - penaltySeconds).
            // If penalty >= total, the kid gets 0 free time but penalty decreases.
            now = Date()
            let actualFreeTime = max(0, seconds - penaltySecs)
            let penaltyConsumed = min(penaltySecs, seconds)
            let windowEnd = now.addingTimeInterval(Double(seconds))

            if actualFreeTime > 0 {
                // Kid gets some free time after serving penalty.
                let unlockAt = now.addingTimeInterval(Double(penaltyConsumed))
                timedUnlockPhases[child.id] = TimedUnlockPhase(
                    penaltyEndsAt: unlockAt, unlockEndsAt: windowEnd
                )
            } else {
                // Penalty exceeds free time — device stays locked the entire window.
                // Show penalty phase consuming the full duration.
                timedUnlockPhases[child.id] = TimedUnlockPhase(
                    penaltyEndsAt: windowEnd, unlockEndsAt: windowEnd
                )
            }
            // Store how much penalty to deduct when the window expires.
            // This is used by the countdown timer to set the correct remaining value
            // instead of reading the live Firebase countdown (which includes unconsumed time).
            timedUnlockPenaltyDeductions[child.id] = penaltyConsumed

            startCountdownTimer()
            let action: CommandAction = .timedUnlock(totalSeconds: seconds, penaltySeconds: penaltySecs)
            trackPendingCommand(action, target: .child(child.id))
            await performCommand(action, target: .child(child.id))

            startConfirmationPolling()
        }
    }

    func lockChild(_ child: ChildProfile) async {
        unlockExpiries.removeValue(forKey: child.id)
        timedUnlockPhases.removeValue(forKey: child.id)
        timedUnlockPenaltyDeductions.removeValue(forKey: child.id)
        lockDownExpiries.removeValue(forKey: child.id)
        scheduleActiveChildren.remove(child.id)
        appState.expectedModes[child.id] = (.locked, Date())
        let action: CommandAction = .setMode(.locked)
        trackPendingCommand(action, target: .child(child.id))
        await performCommand(action, target: .child(child.id))
        // Internet is now mode-driven — no separate blockInternet command needed.
        // Tunnel auto-unblocks when mode changes away from .lockedDown.
        startConfirmationPolling()
    }

    /// Lock down a child: essentialOnly + internet blocked.
    /// seconds: duration for internet block. nil = indefinite (24h auto-expire).
    func lockDownChild(_ child: ChildProfile, seconds: Int? = nil) async {
        unlockExpiries.removeValue(forKey: child.id)
        timedUnlockPhases.removeValue(forKey: child.id)
        timedUnlockPenaltyDeductions.removeValue(forKey: child.id)
        lockDownExpiries.removeValue(forKey: child.id)
        scheduleActiveChildren.remove(child.id)
        appState.expectedModes[child.id] = (.lockedDown, Date())
        // Track lock-down expiry for countdown display.
        let blockDuration = seconds ?? 86400 // 24h default
        if let seconds, seconds < 86400 {
            lockDownExpiries[child.id] = Date().addingTimeInterval(Double(seconds))
            startCountdownTimer()
        } else {
            lockDownExpiries.removeValue(forKey: child.id)
        }
        // Send lockedDown mode — internet blocking is inherent to the mode.
        isSendingCommand = true
        do {
            try await appState.sendCommand(target: .child(child.id), action: .setMode(.lockedDown))
            let name = appState.childProfiles.first(where: { $0.id == child.id })?.name ?? ""
            commandFeedback = "Locked Down sent to \(name)."
        } catch {
            commandFeedback = "Failed: \(error.localizedDescription)"
            isCommandError = true
        }
        isSendingCommand = false
        trackPendingCommand(.setMode(.locked), target: .child(child.id))
        await stopPenaltyTimer(for: child)
        startConfirmationPolling()
        autoDismissFeedback()
    }

    func lockDownAll(seconds: Int? = nil) async {
        isSendingCommand = true
        commandFeedback = nil
        unlockExpiries.removeAll()
        timedUnlockPhases.removeAll()
        timedUnlockPenaltyDeductions.removeAll()
        lockDownExpiries.removeAll()
        scheduleActiveChildren.removeAll()
        for child in childProfiles {
            await lockDownChild(child, seconds: seconds)
        }
        commandFeedback = "Lock Down All sent"
        isSendingCommand = false
        trackPendingCommand(.setMode(.lockedDown), target: .allDevices)
        startConfirmationPolling()
        autoDismissFeedback()
    }

    // MARK: - Schedule Mode

    /// Send requestHeartbeat to all devices. Triggers silent push → app wakes → heartbeat.
    func pingAllDevices() async {
        try? await appState.sendCommand(target: .allDevices, action: .requestHeartbeat)
        try? await appState.refreshDashboard()
    }

    /// Put a child back on their schedule (clear overrides).
    func scheduleChild(_ child: ChildProfile) async {
        unlockExpiries.removeValue(forKey: child.id)
        timedUnlockPhases.removeValue(forKey: child.id)
        timedUnlockPenaltyDeductions.removeValue(forKey: child.id)
        lockDownExpiries.removeValue(forKey: child.id)
        appState.expectedModes.removeValue(forKey: child.id)
        scheduleActiveChildren.insert(child.id)
        let action: CommandAction = .returnToSchedule
        trackPendingCommand(action, target: .child(child.id))
        await performCommand(action, target: .child(child.id))
        // Internet is now mode-driven — no separate blockInternet command needed.
        // Tunnel auto-unblocks when mode changes away from .lockedDown.
        startConfirmationPolling()
    }

    /// Schedule all children. Children without a schedule default to locked (dailyMode)
    /// on the child side via the returnToSchedule command handler.
    func scheduleAll() async {
        isSendingCommand = true
        commandFeedback = nil
        for child in childProfiles {
            unlockExpiries.removeValue(forKey: child.id)
            timedUnlockPhases.removeValue(forKey: child.id)
            timedUnlockPenaltyDeductions.removeValue(forKey: child.id)
            appState.expectedModes.removeValue(forKey: child.id)
            scheduleActiveChildren.insert(child.id)
            try? await appState.sendCommand(target: .child(child.id), action: .returnToSchedule)
        }
        trackPendingCommand(.returnToSchedule, target: .allDevices)
        commandFeedback = "Schedule All sent"
        isSendingCommand = false
        startConfirmationPolling()
        autoDismissFeedback()
    }

    /// Whether a child is currently in schedule-driven mode.
    func isScheduleActive(for child: ChildProfile) -> Bool {
        scheduleActiveChildren.contains(child.id)
    }

    /// Look up the schedule profile assigned to a child's device(s).
    func scheduleProfile(for child: ChildProfile) -> ScheduleProfile? {
        let devs = devices(for: child)
        for dev in devs {
            if let profileID = dev.scheduleProfileID {
                return appState.scheduleProfiles.first { $0.id == profileID }
            }
        }
        return nil
    }

    /// Human-readable schedule label, e.g. "School Day — Free until 8 PM".
    /// Returns "Locked" for children with no schedule profile.
    func scheduleLabel(for child: ChildProfile) -> String? {
        guard isScheduleActive(for: child) else { return nil }
        guard let profile = scheduleProfile(for: child) else {
            return nil // no actual schedule profile assigned
        }
        return "\(profile.name) Schedule"
    }

    /// Status line for a schedule-active child, e.g. "Locked until 3:00 PM".
    func scheduleStatus(for child: ChildProfile) -> (label: String, isFree: Bool)? {
        guard isScheduleActive(for: child) else { return nil }
        guard let profile = scheduleProfile(for: child) else { return nil }
        // Use live Date(), not self.now — self.now only updates when the countdown
        // timer is running (during active unlocks). Schedule status must always be current.
        let mode = profile.resolvedMode(at: Date())
        let isFree = mode == .unlocked
        let modeLabel: String
        switch mode {
        case .unlocked: modeLabel = "Free"
        case .restricted: modeLabel = "Restricted"
        case .locked: modeLabel = "Locked"
        case .lockedDown: modeLabel = "Locked Down"
        }

        if let transition = profile.nextTransitionTime(from: self.now) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return ("\(modeLabel) until \(formatter.string(from: transition))", isFree)
        }
        return (modeLabel, isFree)
    }

    /// The expected mode for a child, combining heartbeat data with parent's knowledge.
    ///
    /// If the parent sent a temporary unlock that should have expired by now,
    /// show "Locked" even if the heartbeat hasn't confirmed it yet (child app
    /// may be terminated by iOS memory pressure).
    /// Returns the dominant mode plus which device types have mismatches (empty = all confirmed).
    func dominantMode(for child: ChildProfile) -> (mode: LockMode, isTemp: Bool, confirmed: Bool, mismatchedDeviceTypes: [String]) {
        let result = computeMode(for: child)
        let devs = devices(for: child)
        if devs.isEmpty { return (result.mode, result.isTemp, true, []) }
        var mismatched: [String] = []
        for dev in devs {
            guard let hb = heartbeat(for: dev) else {
                mismatched.append(dev.modelIdentifier.lowercased().contains("ipad") ? "ipad" : "iphone")
                continue
            }
            if hb.currentMode != result.mode {
                mismatched.append(dev.modelIdentifier.lowercased().contains("ipad") ? "ipad" : "iphone")
            }
        }
        return (result.mode, result.isTemp, mismatched.isEmpty, mismatched)
    }

    private func computeMode(for child: ChildProfile) -> (mode: LockMode, isTemp: Bool) {
        // 0a. Active lock-down with expiry always wins — this is parent's explicit intent
        // and must not be overridden by heartbeat or schedule until the timer expires.
        if let expiry = lockDownExpiries[child.id], expiry > now {
            return (.lockedDown, false)
        }
        // 0a-bis. Indefinite lock-down (no expiry but expectedMode is lockedDown).
        if appState.expectedModes[child.id]?.mode == .lockedDown,
           lockDownExpiries[child.id] == nil {
            return (.lockedDown, false)
        }

        // 0. Check if parent explicitly set mode — this takes priority over everything
        //    (including schedule) because it represents the most recent parent intent.
        //    Covers setMode from both dashboard and child detail views.
        if let expected = appState.expectedModes[child.id] {
            let devs = devices(for: child)
            let confirmed = !devs.isEmpty && devs.allSatisfy { dev in
                guard let hbMode = heartbeat(for: dev)?.currentMode else { return false }
                return hbMode == expected.mode
            }
            // Lock commands get a longer timeout — command delivery via heartbeat
            // can take up to 5 minutes. Unlock commands confirm faster (120s).
            let timeout: TimeInterval = expected.mode == .unlocked ? 120 : 600
            if confirmed || now.timeIntervalSince(expected.sentAt) <= timeout {
                return (expected.mode, expected.mode == .unlocked)
            }
            // Timed out and not confirmed — fall through to other sources.
            // Cleanup happens in pruneConfirmedModes() via the timer.
        }

        // 1. If schedule is active, use schedule mode — but override if there's
        //    an active temporary unlock (parent-initiated or self-unlock).
        if isScheduleActive(for: child) {
            if let phase = timedUnlockPhases[child.id] {
                if now < phase.penaltyEndsAt {
                    return (lastKnownLockedMode(for: child), false)
                } else if now < phase.unlockEndsAt {
                    return (.unlocked, true)
                }
            }
            if let expiry = unlockExpiries[child.id], expiry > now {
                return (.unlocked, true)
            }
            // Don't check heartbeat for temp unlocks here — if the parent just
            // sent returnToSchedule, the heartbeat still shows the old unlock
            // until the child processes the command. Trust the schedule instead.
            if let profile = scheduleProfile(for: child) {
                return (profile.resolvedMode(at: now), false)
            } else {
                return (.restricted, false)
            }
        }

        // 2a. Check timed unlock phases (penalty → unlock).
        if let phase = timedUnlockPhases[child.id] {
            if now < phase.penaltyEndsAt {
                return (lastKnownLockedMode(for: child), false)
            } else if now < phase.unlockEndsAt {
                return (.unlocked, true)
            } else {
                // Phase expired — don't mutate state here (this is called during render).
                // The timer callback prunes expired phases.
                return (lastKnownLockedMode(for: child), false)
            }
        }

        // 2b. Check if a temporary unlock should have expired.
        if let expiry = unlockExpiries[child.id] {
            if expiry > now {
                return (.unlocked, true)
            } else {
                return (lastKnownLockedMode(for: child), false)
            }
        }

        // 3. Check heartbeat-reported expiry — but NOT if the parent just sent
        //    returnToSchedule. The heartbeat is stale and still shows the old temp
        //    unlock; trust the schedule instead until the child confirms.
        let devs = devices(for: child)
        if !scheduleActiveChildren.contains(child.id) {
            for dev in devs {
                if let hb = heartbeat(for: dev),
                   let expiry = hb.temporaryUnlockExpiresAt,
                   hb.currentMode == .unlocked {
                    if expiry > now {
                        return (.unlocked, true)
                    } else {
                        return (lastKnownLockedMode(for: child), false)
                    }
                }
            }
        }

        // 4. Fall back to heartbeat-reported modes.
        let modes = devs.compactMap(\.confirmedMode)
        // If no heartbeat data at all, assume locked (safer than assuming unlocked).
        if modes.isEmpty { return (.restricted, false) }
        if modes.contains(.locked) { return (.locked, false) }
        if modes.contains(.restricted) { return (.restricted, false) }
        return (.unlocked, false)
    }

    /// The mode the device should revert to after a temp unlock expires.
    /// Uses the last heartbeat's non-unlocked mode, defaulting to dailyMode.
    private func lastKnownLockedMode(for child: ChildProfile) -> LockMode {
        let devs = devices(for: child)
        for dev in devs {
            if let mode = dev.confirmedMode, mode != .unlocked {
                return mode
            }
        }
        return .restricted
    }

    /// Prune confirmed or timed-out expectedModes. Called from timer, NOT during render.
    private func pruneConfirmedModes() {
        for (childID, expected) in appState.expectedModes {
            let devs = childDevices.filter { $0.childProfileID == childID }
            let confirmed = !devs.isEmpty && devs.allSatisfy { dev in
                guard let hbMode = latestHeartbeats.first(where: { $0.deviceID == dev.id })?.currentMode else { return false }
                // Only confirm when heartbeat matches the EXACT mode the parent sent.
                // Don't treat essentialOnly as confirming dailyMode or vice versa —
                // that causes premature expectedMode removal and UI flicker.
                return hbMode == expected.mode
            }
            // Lock commands get a longer timeout (600s) to account for up to 5-minute
            // command delivery via heartbeat polling. Unlock commands use 120s.
            let timeout: TimeInterval = expected.mode == .unlocked ? 120 : 600
            if confirmed {
                appState.expectedModes.removeValue(forKey: childID)
                pendingCommands.removeValue(forKey: childID)
                scheduleActiveChildren.remove(childID)
            } else if now.timeIntervalSince(expected.sentAt) > timeout {
                appState.expectedModes.removeValue(forKey: childID)
                pendingCommands.removeValue(forKey: childID)
                scheduleActiveChildren.remove(childID)
            }
        }
    }

    // MARK: - Confirmation Polling

    private var confirmationTask: Task<Void, Never>?

    /// Tracks pending commands per child so we can re-send on heartbeat mismatch.
    private struct PendingCommand {
        let action: CommandAction
        let target: CommandTarget
        var retryCount: Int = 0
    }
    private var pendingCommands: [ChildProfileID: PendingCommand] = [:]

    /// Maximum number of automatic re-sends when heartbeat disagrees after polling.
    private static let maxCommandRetries = 2

    /// Auto-dismiss command feedback after 10 seconds.
    private func autoDismissFeedback() {
        let feedback = commandFeedback
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if self?.commandFeedback == feedback {
                self?.commandFeedback = nil
            }
        }
    }

    /// Track a command for potential re-send if heartbeat doesn't confirm.
    private func trackPendingCommand(_ action: CommandAction, target: CommandTarget) {
        switch target {
        case .child(let childID):
            pendingCommands[childID] = PendingCommand(action: action, target: target)
        case .allDevices:
            for child in childProfiles {
                pendingCommands[child.id] = PendingCommand(action: action, target: .child(child.id))
            }
        case .device:
            break // Device-level commands don't need retry tracking
        }
    }

    /// After sending a command, poll CloudKit every 3s for up to 30s
    /// to pick up the child's updated heartbeat. Stops early if heartbeat changes.
    /// If heartbeat still disagrees after polling, re-sends the command (up to 2 retries).
    private func startConfirmationPolling() {
        confirmationTask?.cancel()
        let previousHeartbeats = appState.latestHeartbeats
        confirmationTask = Task { [weak self] in
            // Poll every 3s for up to 30s.
            var confirmed = false
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                do {
                    try await self.appState.refreshDashboard()
                    if !self.appState.childProfiles.isEmpty {
                        self.loadingState = .loaded(self.appState.childProfiles)
                    }
                    if self.appState.latestHeartbeats != previousHeartbeats {
                        #if DEBUG
                        print("[BigBrother] Heartbeat change detected, stopping confirmation poll")
                        #endif
                        confirmed = true
                        break
                    }
                } catch {
                    // Non-fatal — keep polling.
                }
            }

            guard let self, !Task.isCancelled else { return }

            // If heartbeat didn't change, check for mismatches and re-send.
            if !confirmed {
                await self.retryUnconfirmedCommands()
            }

            // Clear confirmed pending commands.
            self.pruneConfirmedPendingCommands()
        }
    }

    /// Re-send commands for children whose heartbeat still disagrees with the expected mode.
    private func retryUnconfirmedCommands() async {
        var retried = false
        for (childID, pending) in pendingCommands {
            guard pending.retryCount < Self.maxCommandRetries else {
                #if DEBUG
                print("[BigBrother] Max retries (\(Self.maxCommandRetries)) reached for child \(childID.rawValue.prefix(8))")
                #endif
                continue
            }

            // Check if heartbeat still disagrees.
            guard let expected = appState.expectedModes[childID] else { continue }
            let devs = childDevices.filter { $0.childProfileID == childID }
            let agrees = !devs.isEmpty && devs.allSatisfy { dev in
                guard let hbMode = latestHeartbeats.first(where: { $0.deviceID == dev.id })?.currentMode else { return false }
                if hbMode == expected.mode { return true }
                if expected.mode != .unlocked && hbMode != .unlocked { return true }
                return false
            }

            if !agrees {
                #if DEBUG
                let childName = childProfiles.first(where: { $0.id == childID })?.name ?? childID.rawValue.prefix(8).description
                print("[BigBrother] Heartbeat mismatch for \(childName) after polling — re-sending command (retry \(pending.retryCount + 1)/\(Self.maxCommandRetries))")
                #endif

                pendingCommands[childID]?.retryCount += 1
                // Re-send the command with adjusted duration for temporary unlocks.
                // Use remaining time from the original expiry, not the full duration,
                // so retries don't extend the unlock window.
                let retryAction: CommandAction
                switch pending.action {
                case .temporaryUnlock:
                    if let expiry = unlockExpiries[childID] {
                        let remaining = Int(expiry.timeIntervalSinceNow)
                        retryAction = remaining > 0 ? .temporaryUnlock(durationSeconds: remaining) : pending.action
                    } else {
                        retryAction = pending.action
                    }
                default:
                    retryAction = pending.action
                }
                try? await appState.sendCommand(target: pending.target, action: retryAction)
                try? await appState.sendCommand(target: pending.target, action: .requestHeartbeat)
                retried = true
            }
        }

        // If we retried anything, poll again for confirmation.
        if retried {
            startConfirmationPolling()
        }
    }

    /// Remove pending commands that have been confirmed by heartbeat.
    private func pruneConfirmedPendingCommands() {
        pendingCommands = pendingCommands.filter { (childID, _) in
            // Keep only commands that still have an unconfirmed expectedMode.
            appState.expectedModes[childID] != nil
        }
    }

    // MARK: - Countdown Timer

    private var lastHeartbeatRefresh = Date()
    private var isRefreshing = false
    private var lastPingedDevices: [DeviceID: Date] = [:]

    /// Auto-ping child devices whose heartbeat is stale (>15 min).
    /// Sends requestHeartbeat command which triggers a silent push → wakes app → health check.
    /// Throttled to once per 15 min per device to avoid spam.
    private func autoPingStaleDevices() async {
        let staleThreshold: TimeInterval = 900 // 15 minutes
        let pingCooldown: TimeInterval = 900   // Don't re-ping within 15 min

        for child in childProfiles {
            let devs = devices(for: child)
            for dev in devs {
                guard let hb = heartbeat(for: dev) else { continue }
                let age = Date().timeIntervalSince(hb.timestamp)
                guard age > staleThreshold else { continue }

                // Don't ping if we pinged recently
                if let lastPing = lastPingedDevices[dev.id],
                   Date().timeIntervalSince(lastPing) < pingCooldown { continue }

                lastPingedDevices[dev.id] = Date()
                try? await appState.sendCommand(
                    target: .device(dev.id),
                    action: .requestHeartbeat
                )
            }
        }
    }

    func startCountdownTimer() {
        guard countdownTimer == nil else { return }
        lastHeartbeatRefresh = Date()
        // Use Timer.init (not .scheduledTimer) to avoid scheduling on a background
        // thread's RunLoop when called from an async context. Explicitly add to
        // RunLoop.main in .common mode so it fires even during UI interaction.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                self.pruneConfirmedModes()

                // Refresh heartbeats every 15 seconds to pick up confirmation changes.
                // Guard against stacking: skip if a previous refresh is still in-flight.
                if self.now.timeIntervalSince(self.lastHeartbeatRefresh) >= 15, !self.isRefreshing {
                    self.lastHeartbeatRefresh = self.now
                    self.isRefreshing = true
                    defer { self.isRefreshing = false }
                    try? await self.appState.refreshDashboard()
                    if !self.appState.childProfiles.isEmpty {
                        self.loadingState = .loaded(self.appState.childProfiles)
                    }
                    // Auto-ping stale devices in the background — don't block the refresh cycle.
                    Task { await self.autoPingStaleDevices() }
                }

                // When penalty phase ends (transitioning to unlock), clear the Firebase timer.
                // Check both: timer still running (we catch it mid-countdown) OR
                // timer already expired naturally (Firebase countdown finished before we checked).
                for (childID, phase) in self.timedUnlockPhases {
                    if self.now >= phase.penaltyEndsAt,
                       self.now < phase.unlockEndsAt,
                       self.timedUnlockPenaltyDeductions[childID] != nil,
                       let child = self.childProfiles.first(where: { $0.id == childID }) {
                        // Deduct consumed penalty and clear/stop the timer.
                        await self.deductAndStopPenalty(for: child)
                        // Remove deduction so we don't re-fire every second.
                        self.timedUnlockPenaltyDeductions.removeValue(forKey: childID)
                        #if DEBUG
                        print("[BigBrother] Penalty phase ended for \(child.name), timer cleared (device now unlocked)")
                        #endif
                    }
                }

                // Prune fully expired timed unlock phases.
                // Deduct consumed penalty and stop the timer.
                let expiredPhases = self.timedUnlockPhases.filter { $0.value.unlockEndsAt <= self.now }
                if !expiredPhases.isEmpty {
                    self.timedUnlockPhases = self.timedUnlockPhases.filter { $0.value.unlockEndsAt > self.now }
                    for (childID, _) in expiredPhases {
                        #if DEBUG
                        print("[BigBrother] Timed unlock fully expired for child \(childID.rawValue.prefix(8))")
                        #endif
                        if let child = self.childProfiles.first(where: { $0.id == childID }) {
                            await self.deductAndStopPenalty(for: child)
                        }
                        self.timedUnlockPenaltyDeductions.removeValue(forKey: childID)
                    }
                }
                // Prune expired unlock expiries and stop Firebase timers.
                let expired = self.unlockExpiries.filter { $0.value <= self.now }
                self.unlockExpiries = self.unlockExpiries.filter { $0.value > self.now }
                for (childID, _) in expired {
                    if let child = self.childProfiles.first(where: { $0.id == childID }) {
                        await self.stopPenaltyTimer(for: child)
                    }
                }

                // Prune expired lock-down expiries and revert display to essentialOnly.
                let expiredLockDowns = self.lockDownExpiries.filter { $0.value <= self.now }
                if !expiredLockDowns.isEmpty {
                    self.lockDownExpiries = self.lockDownExpiries.filter { $0.value > self.now }
                    for (childID, _) in expiredLockDowns {
                        // Internet auto-unblocks in tunnel; revert parent display to Locked.
                        if self.appState.expectedModes[childID]?.mode == .lockedDown {
                            self.appState.expectedModes[childID] = (.locked, Date())
                        }
                    }
                }

                // Auto-unpause when family pause expires
                if self.isFamilyPaused, let pauseExpiry = self.familyPauseExpiresAt, pauseExpiry <= self.now {
                    await self.unpauseAll()
                }

                // Always keep self.now updated so schedule status stays current.
                // The timer runs at 1s regardless — the 15s heartbeat refresh
                // inside the timer handles dashboard data freshness.
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Best-known expiry for a child's temporary unlock.
    /// Prefers heartbeat-reported expiry (truth from child device),
    /// falls back to local expiry (immediate feedback before heartbeat arrives).
    /// Suppressed for 30s after parent explicitly locks the child.
    func effectiveExpiry(for child: ChildProfile) -> Date? {
        // Timed unlock phases: return the end of the current phase.
        if let phase = timedUnlockPhases[child.id] {
            if now < phase.penaltyEndsAt {
                return phase.penaltyEndsAt  // countdown to penalty end
            } else if now < phase.unlockEndsAt {
                return phase.unlockEndsAt   // countdown to unlock end
            }
            // Both expired — fall through.
        }

        // If parent sent a lock/essential and heartbeat hasn't confirmed yet, suppress countdowns.
        if let expected = appState.expectedModes[child.id], expected.mode != .unlocked {
            return unlockExpiries[child.id] // local only (nil after lock)
        }

        // After grace period, trust heartbeat data.
        // Only use expiry if the device actually reports unlocked mode.
        let devs = devices(for: child)
        let heartbeatExpiry = devs.compactMap { dev -> Date? in
            guard let hb = heartbeat(for: dev),
                  hb.currentMode == .unlocked,
                  let expiry = hb.temporaryUnlockExpiresAt,
                  expiry > now else { return nil }
            return expiry
        }.max()

        // Use whichever is later — the parent's local expiry may reflect
        // a recent extend that the heartbeat hasn't confirmed yet.
        let localExpiry = unlockExpiries[child.id]
        switch (heartbeatExpiry, localExpiry) {
        case let (hb?, local?): return max(hb, local)
        case let (hb?, nil):    return hb
        case let (nil, local?): return local
        case (nil, nil):        return nil
        }
    }

    /// Remaining seconds for a child's temporary unlock. Nil if not active.
    func remainingSeconds(for child: ChildProfile) -> Int? {
        guard let expiry = effectiveExpiry(for: child) else { return nil }
        let secs = Int(expiry.timeIntervalSince(now))
        return secs > 0 ? secs : nil
    }

    /// Formatted countdown string (e.g. "14:32", "1:23:05").
    func countdownString(for child: ChildProfile) -> String? {
        guard let secs = remainingSeconds(for: child) else { return nil }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Formatted countdown for a timed lock-down (e.g. "14:32").
    func lockDownCountdown(for child: ChildProfile) -> String? {
        guard let expiry = lockDownExpiries[child.id] else { return nil }
        let secs = max(0, Int(expiry.timeIntervalSince(now)))
        guard secs > 0 else { return nil }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Timer Integration

    /// Returns the AllowanceTracker penalty timer state for a child, if integration is enabled.
    // MARK: - Penalty Timer (Firebase with CloudKit fallback)

    /// Returns Firebase timer state if available, otherwise builds state from CloudKit device data.
    func penaltyTimer(for child: ChildProfile) -> TimerIntegrationService.KidTimerState? {
        // Try Firebase first
        if let service = appState.timerService {
            let config = TimerIntegrationConfig.load()
            if let state = service.timerState(for: child.id, config: config) {
                return state
            }
        }
        // Fallback: build from CloudKit device data
        let devs = appState.childDevices.filter { $0.childProfileID == child.id }
        guard let dev = devs.first else { return nil }
        let seconds = dev.penaltySeconds ?? 0
        let endTime = dev.penaltyTimerEndTime
        guard seconds > 0 || endTime != nil else { return nil }
        return TimerIntegrationService.KidTimerState(
            firestoreKidID: "",
            name: child.name,
            avatarColor: child.avatarColor,
            avatarUrl: nil,
            penaltySeconds: seconds,
            timerEndTime: endTime
        )
    }

    private var hasFirebaseTimer: Bool { appState.timerService != nil }

    private func firebaseMapping(for child: ChildProfile) -> (service: TimerIntegrationService, familyID: String, kidID: String)? {
        guard let service = appState.timerService else { return nil }
        let config = TimerIntegrationConfig.load()
        guard let mapping = config.kidMappings.first(where: { $0.childProfileID == child.id }),
              let familyID = config.firebaseFamilyID else { return nil }
        return (service, familyID, mapping.firestoreKidID)
    }

    func startPenaltyTimer(for child: ChildProfile) async {
        if let fb = firebaseMapping(for: child) {
            await fb.service.startTimer(familyID: fb.familyID, kidID: fb.kidID)
        } else {
            // CloudKit-native: start countdown from banked seconds
            let devs = appState.childDevices.filter { $0.childProfileID == child.id }
            let seconds = devs.first?.penaltySeconds ?? 0
            guard seconds > 0 else { return }
            let endTime = Date().addingTimeInterval(Double(seconds))
            await updatePenaltyOnDevices(child: child, seconds: seconds, endTime: endTime)
        }
    }

    func stopPenaltyTimer(for child: ChildProfile) async {
        if let fb = firebaseMapping(for: child) {
            await fb.service.stopTimer(familyID: fb.familyID, kidID: fb.kidID)
        } else {
            // CloudKit-native: save remaining seconds, clear endTime
            let timer = penaltyTimer(for: child)
            let remaining = timer?.remainingSeconds ?? 0
            await updatePenaltyOnDevices(child: child, seconds: remaining, endTime: nil)
        }
    }

    func addPenaltyTime(for child: ChildProfile, minutes: Int) async {
        if let fb = firebaseMapping(for: child) {
            await fb.service.addTime(familyID: fb.familyID, kidID: fb.kidID, minutes: minutes)
        } else {
            // CloudKit-native: add to banked or extend running timer
            let timer = penaltyTimer(for: child)
            let addSeconds = minutes * 60
            if let endTime = timer?.timerEndTime, endTime > Date() {
                let newEnd = endTime.addingTimeInterval(Double(addSeconds))
                let newSeconds = (timer?.penaltySeconds ?? 0) + addSeconds
                await updatePenaltyOnDevices(child: child, seconds: newSeconds, endTime: newEnd)
            } else {
                let newSeconds = (timer?.penaltySeconds ?? 0) + addSeconds
                await updatePenaltyOnDevices(child: child, seconds: newSeconds, endTime: nil)
            }
        }
    }

    func deductAndStopPenalty(for child: ChildProfile) async {
        let timer = penaltyTimer(for: child)
        let originalPenalty = timer?.penaltySeconds ?? 0
        let consumed = timedUnlockPenaltyDeductions[child.id] ?? 0
        let remaining = max(0, originalPenalty - consumed)

        if let fb = firebaseMapping(for: child) {
            if remaining > 0 {
                await fb.service.setPenalty(familyID: fb.familyID, kidID: fb.kidID, seconds: remaining)
            } else {
                await fb.service.clearTimer(familyID: fb.familyID, kidID: fb.kidID)
            }
        }
        // Always send to child via CloudKit
        await performCommand(
            .setPenaltyTimer(seconds: remaining > 0 ? remaining : nil, endTime: nil),
            target: .child(child.id)
        )
    }

    func clearPenaltyTimer(for child: ChildProfile) async {
        if let fb = firebaseMapping(for: child) {
            await fb.service.clearTimer(familyID: fb.familyID, kidID: fb.kidID)
        }
        // Clear via CloudKit
        appState.lastRelayedPenalty[child.id] = (nil, nil)
        await updatePenaltyOnDevices(child: child, seconds: nil, endTime: nil)
    }

    /// Update penalty on all CloudKit device records for a child + send command.
    private func updatePenaltyOnDevices(child: ChildProfile, seconds: Int?, endTime: Date?) async {
        let devices = appState.childDevices.filter { $0.childProfileID == child.id }
        for device in devices {
            if let idx = appState.childDevices.firstIndex(where: { $0.id == device.id }) {
                appState.childDevices[idx].penaltySeconds = seconds
                appState.childDevices[idx].penaltyTimerEndTime = endTime
            }
        }
        await performCommand(
            .setPenaltyTimer(seconds: seconds, endTime: endTime),
            target: .child(child.id)
        )
    }

    /// Formatted penalty timer display for a child.
    func penaltyTimerString(for child: ChildProfile) -> String? {
        guard let timer = penaltyTimer(for: child) else { return nil }
        let display = timer.displayString
        return display.isEmpty ? nil : display
    }

    /// Unlock origin for a child's active temporary unlock (from heartbeat).
    /// Whether the child is currently in the penalty phase of a timed unlock.
    func isInPenaltyPhase(for child: ChildProfile) -> Bool {
        guard let phase = timedUnlockPhases[child.id] else { return false }
        return now < phase.penaltyEndsAt
    }

    /// Countdown string for the unlock window during penalty phase (counts down to unlockEndsAt).
    func penaltyWindowCountdown(for child: ChildProfile) -> String? {
        guard let phase = timedUnlockPhases[child.id], now < phase.penaltyEndsAt else { return nil }
        let secs = max(0, Int(phase.unlockEndsAt.timeIntervalSince(now)))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    func unlockOrigin(for child: ChildProfile) -> TemporaryUnlockOrigin? {
        // If the parent initiated this unlock (tracked by unlockExpiries or timedUnlockPhases),
        // always report .remoteCommand — the heartbeat may still carry a stale origin
        // from a previous self-unlock or PIN unlock.
        if unlockExpiries[child.id] != nil || timedUnlockPhases[child.id] != nil {
            return .remoteCommand
        }
        let deviceIDs = Set(appState.childDevices.filter { $0.childProfileID == child.id }.map(\.id))
        return appState.latestHeartbeats
            .filter { deviceIDs.contains($0.deviceID) }
            .compactMap(\.temporaryUnlockOrigin)
            .first
    }

    // MARK: - Self Unlocks

    /// Self-unlocks used today for a child (from heartbeat data).
    func selfUnlocksUsedToday(for child: ChildProfile) -> Int? {
        let deviceIDs = Set(appState.childDevices.filter { $0.childProfileID == child.id }.map(\.id))
        let values = appState.latestHeartbeats
            .filter { deviceIDs.contains($0.deviceID) }
            .compactMap(\.selfUnlocksUsedToday)
        guard !values.isEmpty else { return nil }
        return values.max()
    }

    /// Self-unlock budget for a child (from parent-side UserDefaults cache).
    func selfUnlockBudget(for child: ChildProfile) -> Int? {
        let budget = UserDefaults.standard.integer(forKey: "selfUnlockBudget.\(child.id.rawValue)")
        return budget > 0 ? budget : nil
    }

    // MARK: - Delete

    func deleteChild(_ child: ChildProfile) async {
        do {
            try await appState.cloudKit?.deleteChildProfile(child.id)
            await loadDashboard()
        } catch {
            commandFeedback = "Failed to delete: \(error.localizedDescription)"
            isCommandError = true
        }
    }
}
