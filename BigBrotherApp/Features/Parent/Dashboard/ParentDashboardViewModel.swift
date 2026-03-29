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

    func lockAll(duration: LockDuration = .indefinite) async {
        isSendingCommand = true
        commandFeedback = nil
        unlockExpiries.removeAll()
        timedUnlockPhases.removeAll()
        scheduleActiveChildren.removeAll()
        for child in childProfiles {
            await lockChildQuiet(child, duration: duration)
        }
        commandFeedback = "Lock All sent"
        isSendingCommand = false
        // Track for retry — use .dailyMode as the representative lock action.
        trackPendingCommand(.setMode(.dailyMode), target: .allDevices)
        startConfirmationPolling()
        autoDismissFeedback()
    }

    func lockAllEssential() async {
        isSendingCommand = true
        commandFeedback = nil
        unlockExpiries.removeAll()
        timedUnlockPhases.removeAll()
        timedUnlockPenaltyDeductions.removeAll()
        lockDownExpiries.removeAll()
        scheduleActiveChildren.removeAll()
        for child in childProfiles {
            await essentialChild(child)
        }
        commandFeedback = "Lock All sent"
        isSendingCommand = false
        trackPendingCommand(.setMode(.essentialOnly), target: .allDevices)
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

    /// Lock a child with UI feedback (for individual lock actions).
    func lockChild(_ child: ChildProfile, duration: LockDuration = .indefinite) async {
        await lockChildQuiet(child, duration: duration)
        startConfirmationPolling()
    }

    /// Lock a child without setting commandFeedback (for bulk operations).
    private func lockChildQuiet(_ child: ChildProfile, duration: LockDuration) async {
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
            appState.expectedModes[child.id] = (.dailyMode, Date())
            commandAction = .setMode(.dailyMode)
            try? await appState.sendCommand(target: .child(child.id), action: commandAction)

        case .untilMidnight:
            let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
            appState.expectedModes[child.id] = (.dailyMode, Date())
            commandAction = .lockUntil(date: midnight)
            try? await appState.sendCommand(target: .child(child.id), action: commandAction)

        case .hours(let h):
            let lockTarget = Date().addingTimeInterval(Double(h) * 3600)
            appState.expectedModes[child.id] = (.dailyMode, Date())
            commandAction = .lockUntil(date: lockTarget)
            try? await appState.sendCommand(target: .child(child.id), action: commandAction)
        }
        trackPendingCommand(commandAction, target: .child(child.id))
        // Restore internet in case device was locked down.
        try? await appState.sendCommand(target: .child(child.id), action: .blockInternet(durationSeconds: 0))
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
        // Restore internet in case device was locked down.
        try? await appState.sendCommand(target: .child(child.id), action: .blockInternet(durationSeconds: 0))
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

    func essentialChild(_ child: ChildProfile) async {
        unlockExpiries.removeValue(forKey: child.id)
        timedUnlockPhases.removeValue(forKey: child.id)
        timedUnlockPenaltyDeductions.removeValue(forKey: child.id)
        lockDownExpiries.removeValue(forKey: child.id)
        scheduleActiveChildren.remove(child.id)
        appState.expectedModes[child.id] = (.essentialOnly, Date())
        let action: CommandAction = .setMode(.essentialOnly)
        trackPendingCommand(action, target: .child(child.id))
        await performCommand(action, target: .child(child.id))
        // Restore internet in case device was locked down.
        try? await appState.sendCommand(target: .child(child.id), action: .blockInternet(durationSeconds: 0))
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
            let expiry = Date().addingTimeInterval(Double(seconds))
            lockDownExpiries[child.id] = expiry
            startCountdownTimer()
            print("[BigBrother] SET lockDownExpiry for \(child.name): \(expiry), seconds=\(seconds), dict count=\(lockDownExpiries.count)")
        } else {
            lockDownExpiries.removeValue(forKey: child.id)
            print("[BigBrother] NO lockDownExpiry (seconds=\(String(describing: seconds)))")
        }
        // Send lockedDown mode + internet block as two commands.
        isSendingCommand = true
        do {
            try await appState.sendCommand(target: .child(child.id), action: .setMode(.lockedDown))
            try await appState.sendCommand(target: .child(child.id), action: .blockInternet(durationSeconds: blockDuration))
            let name = appState.childProfiles.first(where: { $0.id == child.id })?.name ?? ""
            commandFeedback = "Locked Down sent to \(name)."
        } catch {
            commandFeedback = "Failed: \(error.localizedDescription)"
            isCommandError = true
        }
        isSendingCommand = false
        trackPendingCommand(.setMode(.essentialOnly), target: .child(child.id))
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
        // Restore internet in case device was locked down.
        try? await appState.sendCommand(target: .child(child.id), action: .blockInternet(durationSeconds: 0))
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
        case .dailyMode: modeLabel = "Restricted"
        case .essentialOnly: modeLabel = "Locked"
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
    func dominantMode(for child: ChildProfile) -> (mode: LockMode, isTemp: Bool, confirmed: Bool) {
        // Compute mode first, then check if heartbeat agrees.
        let result = computeMode(for: child)
        let devs = devices(for: child)
        // No devices enrolled → nothing to confirm, treat as confirmed.
        if devs.isEmpty { return (result.mode, result.isTemp, true) }
        let heartbeatAgrees = devs.allSatisfy { dev in
            guard let hb = heartbeat(for: dev) else { return false }
            return hb.currentMode == result.mode
        }
        return (result.mode, result.isTemp, heartbeatAgrees)
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
                return (.dailyMode, false)
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

        // 3. Check heartbeat-reported expiry.
        let devs = devices(for: child)
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

        // 4. Fall back to heartbeat-reported modes.
        let modes = devs.compactMap(\.confirmedMode)
        // If no heartbeat data at all, assume locked (safer than assuming unlocked).
        if modes.isEmpty { return (.dailyMode, false) }
        if modes.contains(.essentialOnly) { return (.essentialOnly, false) }
        if modes.contains(.dailyMode) { return (.dailyMode, false) }
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
        return .dailyMode
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
                }

                // When penalty phase ends (transitioning to unlock), stop the running
                // Firebase timer and set the correct remaining penalty (original minus consumed).
                for (childID, phase) in self.timedUnlockPhases {
                    if self.now >= phase.penaltyEndsAt,
                       self.now < phase.unlockEndsAt,
                       let child = self.childProfiles.first(where: { $0.id == childID }) {
                        let timer = self.penaltyTimer(for: child)
                        if timer?.isActivelyRunning == true {
                            // Deduct consumed penalty and stop the timer.
                            await self.deductAndStopPenalty(for: child)
                            #if DEBUG
                            print("[BigBrother] Penalty phase ended for \(child.name), stopped timer (device now unlocked)")
                            #endif
                        }
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
                            self.appState.expectedModes[childID] = (.essentialOnly, Date())
                        }
                    }
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
        guard let expiry = lockDownExpiries[child.id] else {
            #if DEBUG
            if appState.expectedModes[child.id]?.mode == .lockedDown {
                print("[BigBrother] lockDownCountdown nil for \(child.name) — no expiry in lockDownExpiries (count: \(lockDownExpiries.count))")
            }
            #endif
            return nil
        }
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
    func penaltyTimer(for child: ChildProfile) -> TimerIntegrationService.KidTimerState? {
        guard let service = appState.timerService else { return nil }
        let config = TimerIntegrationConfig.load()
        return service.timerState(for: child.id, config: config)
    }

    func startPenaltyTimer(for child: ChildProfile) async {
        guard let service = appState.timerService else { return }
        let config = TimerIntegrationConfig.load()
        guard let mapping = config.kidMappings.first(where: { $0.childProfileID == child.id }),
              let familyID = config.firebaseFamilyID else { return }
        await service.startTimer(familyID: familyID, kidID: mapping.firestoreKidID)
    }

    func stopPenaltyTimer(for child: ChildProfile) async {
        guard let service = appState.timerService else { return }
        let config = TimerIntegrationConfig.load()
        guard let mapping = config.kidMappings.first(where: { $0.childProfileID == child.id }),
              let familyID = config.firebaseFamilyID else { return }
        await service.stopTimer(familyID: familyID, kidID: mapping.firestoreKidID)
    }

    func addPenaltyTime(for child: ChildProfile, minutes: Int) async {
        guard let service = appState.timerService else { return }
        let config = TimerIntegrationConfig.load()
        guard let mapping = config.kidMappings.first(where: { $0.childProfileID == child.id }),
              let familyID = config.firebaseFamilyID else { return }
        await service.addTime(familyID: familyID, kidID: mapping.firestoreKidID, minutes: minutes)
    }

    /// Deducts consumed penalty time and stops the Firebase timer.
    /// Uses the pre-computed deduction from when the timed unlock was issued,
    /// so the remaining value is correct regardless of how long the Firebase timer ran.
    func deductAndStopPenalty(for child: ChildProfile) async {
        guard let timerService = appState.timerService else { return }
        let config = TimerIntegrationConfig.load()
        guard let mapping = config.kidMappings.first(where: { $0.childProfileID == child.id }),
              let familyID = config.firebaseFamilyID else { return }

        let timer = penaltyTimer(for: child)
        let originalPenalty = timer?.penaltySeconds ?? 0
        let consumed = timedUnlockPenaltyDeductions[child.id] ?? 0
        let remaining = max(0, originalPenalty - consumed)

        if remaining > 0 {
            await timerService.setPenalty(familyID: familyID, kidID: mapping.firestoreKidID, seconds: remaining)
        } else {
            await timerService.clearTimer(familyID: familyID, kidID: mapping.firestoreKidID)
        }

        // Also send to child via CloudKit.
        await performCommand(
            .setPenaltyTimer(seconds: remaining > 0 ? remaining : nil, endTime: nil),
            target: .child(child.id)
        )
    }

    func clearPenaltyTimer(for child: ChildProfile) async {
        guard let service = appState.timerService else { return }
        let config = TimerIntegrationConfig.load()
        guard let mapping = config.kidMappings.first(where: { $0.childProfileID == child.id }),
              let familyID = config.firebaseFamilyID else { return }
        await service.clearTimer(familyID: familyID, kidID: mapping.firestoreKidID)
        // Clear in-memory penalty data so the display updates immediately
        // and the relay doesn't re-send stale values.
        appState.lastRelayedPenalty[child.id] = (nil, nil)
        let devices = appState.childDevices.filter { $0.childProfileID == child.id }
        for device in devices {
            if let idx = appState.childDevices.firstIndex(where: { $0.id == device.id }) {
                appState.childDevices[idx].penaltySeconds = nil
                appState.childDevices[idx].penaltyTimerEndTime = nil
            }
        }
    }

    /// Formatted penalty timer display for a child. Nil if no timer or integration disabled.
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
