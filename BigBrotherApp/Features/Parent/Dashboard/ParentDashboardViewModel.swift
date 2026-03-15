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
    var unlockExpiries: [ChildProfileID: Date] = [:]
    /// When parent explicitly locked a child — suppresses stale heartbeat countdowns.
    private var lockedAt: [ChildProfileID: Date] = [:]
    var now = Date()
    private var countdownTimer: Timer?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Data

    var childProfiles: [ChildProfile] { appState.childProfiles }
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

    func lockAll() async {
        unlockExpiries.removeAll()
        let lockTime = Date()
        for child in childProfiles { lockedAt[child.id] = lockTime }
        await performCommand(.setMode(.dailyMode), target: .allDevices)
        startConfirmationPolling()
    }

    func unlockAll(seconds: Int = 24 * 3600) async {
        now = Date()
        let expiry = now.addingTimeInterval(Double(seconds))
        for child in childProfiles {
            unlockExpiries[child.id] = expiry
            lockedAt.removeValue(forKey: child.id)
        }
        startCountdownTimer()
        await performCommand(.temporaryUnlock(durationSeconds: seconds), target: .allDevices)
        startConfirmationPolling()
    }

    // MARK: - Per-Child Actions

    func lockChild(_ child: ChildProfile) async {
        unlockExpiries.removeValue(forKey: child.id)
        lockedAt[child.id] = Date()
        await performCommand(.setMode(.dailyMode), target: .child(child.id))
        startConfirmationPolling()
    }

    func unlockChild(_ child: ChildProfile, seconds: Int = 24 * 3600) async {
        now = Date()
        unlockExpiries[child.id] = now.addingTimeInterval(Double(seconds))
        lockedAt.removeValue(forKey: child.id)
        startCountdownTimer()
        await performCommand(.temporaryUnlock(durationSeconds: seconds), target: .child(child.id))
        startConfirmationPolling()
    }

    func essentialChild(_ child: ChildProfile) async {
        unlockExpiries.removeValue(forKey: child.id)
        lockedAt[child.id] = Date()
        await performCommand(.setMode(.essentialOnly), target: .child(child.id))
        startConfirmationPolling()
    }

    /// The dominant mode across a child's devices (worst-case: if any device is locked, show locked).
    func dominantMode(for child: ChildProfile) -> (mode: LockMode, isTemp: Bool) {
        let devs = devices(for: child)
        let modes = devs.compactMap(\.confirmedMode)
        if modes.isEmpty { return (.unlocked, false) }
        // Priority: essentialOnly > dailyMode > unlocked
        if modes.contains(.essentialOnly) { return (.essentialOnly, false) }
        if modes.contains(.dailyMode) { return (.dailyMode, false) }
        // Check if any device is in temp unlock
        let anyTemp = devs.contains { heartbeat(for: $0)?.currentMode == .unlocked && $0.confirmedMode == .unlocked }
        return (.unlocked, anyTemp)
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
                // Prune expired local entries.
                self.unlockExpiries = self.unlockExpiries.filter { $0.value > self.now }
            }
        }
    }

    func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Grace period after locking — ignore heartbeat countdowns during this window
    /// because the child may not have processed the lock command yet.
    private static let lockGracePeriod: TimeInterval = 30

    /// Best-known expiry for a child's temporary unlock.
    /// Prefers heartbeat-reported expiry (truth from child device),
    /// falls back to local expiry (immediate feedback before heartbeat arrives).
    /// Suppressed for 30s after parent explicitly locks the child.
    func effectiveExpiry(for child: ChildProfile) -> Date? {
        // If parent locked recently, suppress all heartbeat countdowns.
        if let lockTime = lockedAt[child.id],
           now.timeIntervalSince(lockTime) < Self.lockGracePeriod {
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
