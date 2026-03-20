import Foundation
import Observation
import BigBrotherCore

@Observable
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
            // Clear Firebase timers for phases that expired while app was closed.
            if !expired.isEmpty {
                let expiredChildIDs = expired.map { ChildProfileID(rawValue: $0.key) }
                Task {
                    for childID in expiredChildIDs {
                        if let child = self.appState.childProfiles.first(where: { $0.id == childID })
                            ?? self.appState.orderedChildProfiles.first(where: { $0.id == childID }) {
                            await self.clearPenaltyTimer(for: child)
                        }
                    }
                }
            }
        }
    }

    deinit {
        countdownTimer?.invalidate()
        confirmationTask?.cancel()
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
        now = Date()
        // Don't clear scheduleActiveChildren — children return to schedule after expiry.
        let expiry = now.addingTimeInterval(Double(seconds))
        for child in childProfiles {
            unlockExpiries[child.id] = expiry
            appState.expectedModes.removeValue(forKey: child.id)
        }
        startCountdownTimer()
        await performCommand(.temporaryUnlock(durationSeconds: seconds), target: .allDevices)
        startConfirmationPolling()
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
        scheduleActiveChildren.remove(child.id)

        switch duration {
        case .returnToSchedule:
            appState.expectedModes.removeValue(forKey: child.id)
            scheduleActiveChildren.insert(child.id)
            try? await appState.sendCommand(target: .child(child.id), action: .returnToSchedule)

        case .indefinite:
            appState.expectedModes[child.id] = (.dailyMode, Date())
            try? await appState.sendCommand(target: .child(child.id), action: .setMode(.dailyMode))

        case .untilMidnight:
            let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
            appState.expectedModes[child.id] = (.dailyMode, Date())
            try? await appState.sendCommand(target: .child(child.id), action: .lockUntil(date: midnight))

        case .hours(let h):
            let target = Date().addingTimeInterval(Double(h) * 3600)
            appState.expectedModes[child.id] = (.dailyMode, Date())
            try? await appState.sendCommand(target: .child(child.id), action: .lockUntil(date: target))
        }
        // Stop Firebase penalty timer on any lock action.
        await stopPenaltyTimer(for: child)
    }

    func unlockChild(_ child: ChildProfile, seconds: Int = 24 * 3600) async {
        now = Date()
        unlockExpiries[child.id] = now.addingTimeInterval(Double(seconds))
        // Don't remove from scheduleActiveChildren — child returns to schedule after expiry.
        appState.expectedModes.removeValue(forKey: child.id)
        startCountdownTimer()
        await performCommand(.temporaryUnlock(durationSeconds: seconds), target: .child(child.id))
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
            // Send timed unlock command — child device handles the delay.
            // Device stays locked during penalty, then unlocks for remaining time.
            now = Date()
            let unlockAt = now.addingTimeInterval(Double(penaltySecs))
            let lockAt = now.addingTimeInterval(Double(seconds))
            timedUnlockPhases[child.id] = TimedUnlockPhase(
                penaltyEndsAt: unlockAt, unlockEndsAt: lockAt
            )
            startCountdownTimer()
            await performCommand(
                .timedUnlock(totalSeconds: seconds, penaltySeconds: penaltySecs),
                target: .child(child.id)
            )
            startConfirmationPolling()
        }
    }

    func essentialChild(_ child: ChildProfile) async {
        unlockExpiries.removeValue(forKey: child.id)
        timedUnlockPhases.removeValue(forKey: child.id)
        scheduleActiveChildren.remove(child.id)
        appState.expectedModes[child.id] = (.essentialOnly, Date())
        await performCommand(.setMode(.essentialOnly), target: .child(child.id))
        startConfirmationPolling()
    }

    // MARK: - Schedule Mode

    /// Put a child back on their schedule (clear overrides).
    func scheduleChild(_ child: ChildProfile) async {
        unlockExpiries.removeValue(forKey: child.id)
        timedUnlockPhases.removeValue(forKey: child.id)
        appState.expectedModes.removeValue(forKey: child.id)
        scheduleActiveChildren.insert(child.id)
        await performCommand(.returnToSchedule, target: .child(child.id))
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
            appState.expectedModes.removeValue(forKey: child.id)
            scheduleActiveChildren.insert(child.id)
            try? await appState.sendCommand(target: .child(child.id), action: .returnToSchedule)
        }
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
        let mode = profile.resolvedMode(at: now)
        let isFree = mode == .unlocked
        let modeLabel: String
        switch mode {
        case .unlocked: modeLabel = "Free"
        case .essentialOnly: modeLabel = "Essential"
        case .dailyMode: modeLabel = "Locked"
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
        // 0. Check if parent explicitly set mode — this takes priority over everything
        //    (including schedule) because it represents the most recent parent intent.
        //    Covers setMode from both dashboard and child detail views.
        if let expected = appState.expectedModes[child.id] {
            let devs = devices(for: child)
            let confirmed = !devs.isEmpty && devs.allSatisfy { dev in
                heartbeat(for: dev)?.currentMode == expected.mode
            }
            if confirmed || now.timeIntervalSince(expected.sentAt) <= 120 {
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
            let devs = devices(for: child)
            for dev in devs {
                if let hb = heartbeat(for: dev),
                   hb.currentMode == .unlocked,
                   let expiry = hb.temporaryUnlockExpiresAt,
                   expiry > now {
                    return (.unlocked, true)
                }
            }
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
        if modes.isEmpty { return (.unlocked, false) }
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
                latestHeartbeats.first(where: { $0.deviceID == dev.id })?.currentMode == expected.mode
            }
            if confirmed {
                appState.expectedModes.removeValue(forKey: childID)
                scheduleActiveChildren.remove(childID)
            } else if now.timeIntervalSince(expected.sentAt) > 120 {
                appState.expectedModes.removeValue(forKey: childID)
                scheduleActiveChildren.remove(childID)
            }
        }
    }

    // MARK: - Confirmation Polling

    private var confirmationTask: Task<Void, Never>?

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

    /// After sending a command, poll CloudKit every 3s for up to 30s
    /// to pick up the child's updated heartbeat. Stops early if heartbeat changes.
    private func startConfirmationPolling() {
        confirmationTask?.cancel()
        let previousHeartbeats = appState.latestHeartbeats
        confirmationTask = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                do {
                    try await self.appState.refreshDashboard()
                    // Update loading state without flashing the spinner.
                    if !self.appState.childProfiles.isEmpty {
                        self.loadingState = .loaded(self.appState.childProfiles)
                    }
                    // Stop early if any heartbeat mode changed.
                    if self.appState.latestHeartbeats != previousHeartbeats {
                        #if DEBUG
                        print("[BigBrother] Heartbeat change detected, stopping confirmation poll")
                        #endif
                        return
                    }
                } catch {
                    // Non-fatal — keep polling.
                }
            }
        }
    }

    // MARK: - Countdown Timer

    private var lastHeartbeatRefresh = Date()
    private var isRefreshing = false

    func startCountdownTimer() {
        guard countdownTimer == nil else { return }
        lastHeartbeatRefresh = Date()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
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

                // Clear penalty timer when penalty phase ends (device unlocks),
                // not when the whole unlock window expires.
                for (childID, phase) in self.timedUnlockPhases {
                    if self.now >= phase.penaltyEndsAt,
                       self.now < phase.unlockEndsAt,
                       let child = self.childProfiles.first(where: { $0.id == childID }) {
                        // Check if we already cleared this timer (avoid repeated calls).
                        let timer = self.penaltyTimer(for: child)
                        if timer?.penaltySeconds ?? 0 > 0 || timer?.isActivelyRunning == true {
                            await self.clearPenaltyTimer(for: child)
                            #if DEBUG
                            print("[BigBrother] Penalty phase ended for \(child.name), cleared timer (device now unlocked)")
                            #endif
                        }
                    }
                }

                // Prune fully expired timed unlock phases.
                let expiredPhases = self.timedUnlockPhases.filter { $0.value.unlockEndsAt <= self.now }
                if !expiredPhases.isEmpty {
                    self.timedUnlockPhases = self.timedUnlockPhases.filter { $0.value.unlockEndsAt > self.now }
                    for (childID, _) in expiredPhases {
                        #if DEBUG
                        print("[BigBrother] Timed unlock fully expired for child \(childID.rawValue.prefix(8))")
                        #endif
                        if let child = self.childProfiles.first(where: { $0.id == childID }) {
                            await self.clearPenaltyTimer(for: child)
                        }
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
            }
        }
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
