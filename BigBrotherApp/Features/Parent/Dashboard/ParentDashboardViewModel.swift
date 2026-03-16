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

    /// Children whose enforcement is driven by their schedule (no manual override).
    /// Persisted in UserDefaults so it survives app relaunch.
    var scheduleActiveChildren: Set<ChildProfileID> {
        didSet { persistScheduleActiveChildren() }
    }

    private static let scheduleActiveKey = "scheduleActiveChildIDs"
    private static let unlockExpiriesKey = "unlockExpiries"

    init(appState: AppState) {
        self.appState = appState
        // Restore persisted schedule-active set.
        if let raw = UserDefaults.standard.array(forKey: Self.scheduleActiveKey) as? [String] {
            self.scheduleActiveChildren = Set(raw.map { ChildProfileID(rawValue: $0) })
        } else {
            self.scheduleActiveChildren = []
        }
        // Restore persisted unlock expiries (prune expired).
        if let data = UserDefaults.standard.data(forKey: Self.unlockExpiriesKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            let now = Date()
            self.unlockExpiries = decoded
                .filter { $0.value > now }
                .reduce(into: [:]) { $0[ChildProfileID(rawValue: $1.key)] = $1.value }
        }
    }

    private func persistScheduleActiveChildren() {
        let raw = scheduleActiveChildren.map(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.scheduleActiveKey)
    }

    private func persistUnlockExpiries() {
        let raw = unlockExpiries.reduce(into: [String: Date]()) { $0[$1.key.rawValue] = $1.value }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.unlockExpiriesKey)
        }
    }

    // MARK: - Data

    var childProfiles: [ChildProfile] { appState.orderedChildProfiles }
    var childDevices: [ChildDevice] { appState.childDevices }
    var latestHeartbeats: [DeviceHeartbeat] { appState.latestHeartbeats }

    func devices(for child: ChildProfile) -> [ChildDevice] {
        childDevices.filter { $0.childProfileID == child.id }
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
        unlockExpiries.removeAll()
        scheduleActiveChildren.removeAll()
        for child in childProfiles {
            await lockChild(child, duration: duration)
        }
    }

    func unlockAllWithTimer(seconds: Int) async {
        for child in childProfiles {
            await unlockChildWithTimer(child, seconds: seconds)
        }
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

    func lockChild(_ child: ChildProfile, duration: LockDuration = .indefinite) async {
        unlockExpiries.removeValue(forKey: child.id)
        scheduleActiveChildren.remove(child.id)

        switch duration {
        case .returnToSchedule:
            appState.expectedModes.removeValue(forKey: child.id)
            scheduleActiveChildren.insert(child.id)
            await performCommand(.returnToSchedule, target: .child(child.id))

        case .indefinite:
            appState.expectedModes[child.id] = (.dailyMode, Date())
            await performCommand(.setMode(.dailyMode), target: .child(child.id))

        case .untilMidnight:
            let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
            appState.expectedModes[child.id] = (.dailyMode, Date())
            await performCommand(.lockUntil(date: midnight), target: .child(child.id))

        case .hours(let h):
            let target = Date().addingTimeInterval(Double(h) * 3600)
            appState.expectedModes[child.id] = (.dailyMode, Date())
            await performCommand(.lockUntil(date: target), target: .child(child.id))
        }
        // Stop Firebase penalty timer on any lock action.
        await stopPenaltyTimer(for: child)
        startConfirmationPolling()
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
            now = Date()
            unlockExpiries[child.id] = now.addingTimeInterval(Double(seconds))
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
        scheduleActiveChildren.remove(child.id)
        appState.expectedModes[child.id] = (.essentialOnly, Date())
        await performCommand(.setMode(.essentialOnly), target: .child(child.id))
        startConfirmationPolling()
    }

    // MARK: - Schedule Mode

    /// Put a child back on their schedule (clear overrides).
    func scheduleChild(_ child: ChildProfile) async {
        unlockExpiries.removeValue(forKey: child.id)
        appState.expectedModes.removeValue(forKey: child.id)
        scheduleActiveChildren.insert(child.id)
        await performCommand(.returnToSchedule, target: .child(child.id))
        startConfirmationPolling()
    }

    /// Schedule all children. Children without a schedule default to locked (dailyMode)
    /// on the child side via the returnToSchedule command handler.
    func scheduleAll() async {
        for child in childProfiles {
            await scheduleChild(child)
        }
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
            return "Schedule — Locked"
        }
        let now = Date()
        let mode = profile.resolvedMode(at: now)
        let modeLabel = mode == .unlocked ? "Free" : "Locked"

        if let transition = profile.nextTransitionTime(from: now) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            let timeStr = formatter.string(from: transition)
            return "\(profile.name) — \(modeLabel) until \(timeStr)"
        }
        return "\(profile.name) — \(modeLabel)"
    }

    /// The expected mode for a child, combining heartbeat data with parent's knowledge.
    ///
    /// If the parent sent a temporary unlock that should have expired by now,
    /// show "Locked" even if the heartbeat hasn't confirmed it yet (child app
    /// may be terminated by iOS memory pressure).
    func dominantMode(for child: ChildProfile) -> (mode: LockMode, isTemp: Bool) {
        // 0. If schedule is active, use schedule mode — but override if there's
        //    an active temporary unlock (parent-initiated or self-unlock).
        if isScheduleActive(for: child) {
            // Check parent-side unlock expiry first.
            if let expiry = unlockExpiries[child.id], expiry > now {
                return (.unlocked, true)
            }
            // Check heartbeat for device-initiated unlocks (self-unlock).
            let devs = devices(for: child)
            for dev in devs {
                if let hb = heartbeat(for: dev),
                   hb.currentMode == .unlocked,
                   let expiry = hb.temporaryUnlockExpiresAt,
                   expiry > now {
                    return (.unlocked, true)
                }
            }
            // No active unlock — use schedule mode.
            if let profile = scheduleProfile(for: child) {
                let mode = profile.resolvedMode(at: now)
                return (mode, false)
            } else {
                return (.dailyMode, false)
            }
        }

        // 1. Check if parent explicitly set mode — trust until heartbeat confirms.
        if let expected = appState.expectedModes[child.id] {
            let devs = devices(for: child)
            let heartbeatConfirmed = devs.contains { dev in
                guard let hb = heartbeat(for: dev), hb.timestamp > expected.sentAt else { return false }
                return hb.currentMode == expected.mode
            }
            if heartbeatConfirmed {
                appState.expectedModes.removeValue(forKey: child.id)
            } else {
                // Not yet confirmed — show what we sent.
                return (expected.mode, expected.mode == .unlocked)
            }
        }

        // 2. Check if a temporary unlock should have expired.
        if let expiry = unlockExpiries[child.id] {
            if expiry > now {
                // Still within unlock window.
                return (.unlocked, true)
            } else {
                // Expired — the device SHOULD be locked now, regardless of heartbeat.
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
                    // Heartbeat says unlocked but the timer should have expired.
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

    // MARK: - Confirmation Polling

    private var confirmationTask: Task<Void, Never>?

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

    func startCountdownTimer() {
        guard countdownTimer == nil else { return }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                // Prune expired local entries and stop Firebase timers for expired unlocks.
                let expired = self.unlockExpiries.filter { $0.value <= self.now }
                self.unlockExpiries = self.unlockExpiries.filter { $0.value > self.now }
                for (childID, _) in expired {
                    if let child = self.childProfiles.first(where: { $0.id == childID }),
                       self.penaltyTimer(for: child) != nil {
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

        return heartbeatExpiry ?? unlockExpiries[child.id]
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
    }

    /// Formatted penalty timer display for a child. Nil if no timer or integration disabled.
    func penaltyTimerString(for child: ChildProfile) -> String? {
        guard let timer = penaltyTimer(for: child) else { return nil }
        let display = timer.displayString
        return display.isEmpty ? nil : display
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
