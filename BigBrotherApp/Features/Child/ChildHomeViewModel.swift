import Foundation
import Observation
import BigBrotherCore

@Observable @MainActor
final class ChildHomeViewModel {
    let appState: AppState

    var now = Date()
    private var timer: Timer?
    private var authRetryTimer: Timer?

    var isRequestingAuth = false
    var authFeedback: String?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Whether a parent PIN is configured in Keychain (independent of parentAuthEnabled toggle).
    /// Stored property so @Observable triggers UI updates; refreshed by the 1s timer.
    var isPINConfigured = false

    var currentMode: LockMode {
        appState.currentEffectivePolicy?.resolvedMode ?? .unlocked
    }

    var isTemporaryUnlock: Bool {
        appState.currentEffectivePolicy?.isTemporaryUnlock ?? false
    }

    var temporaryUnlockState: TemporaryUnlockState? {
        appState.storage.readTemporaryUnlockState()
    }

    // MARK: - Timed Unlock (Penalty Offset)

    var timedUnlockInfo: TimedUnlockInfo? {
        appState.storage.readTimedUnlockInfo()
    }

    // MARK: - Schedule

    /// Active schedule profile from App Group storage.
    var activeScheduleProfile: ScheduleProfile? {
        appState.storage.readActiveScheduleProfile()
    }

    /// Human-readable schedule status, e.g. "Free until 8:00 PM" or "Locked until 3:00 PM".
    var scheduleStatusText: String? {
        guard let profile = activeScheduleProfile else { return nil }
        let inFree = profile.isInFreeWindow(at: now)
        let label = inFree ? "Free" : "Locked"
        if let transition = profile.nextTransitionTime(from: now) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "\(label) until \(formatter.string(from: transition))"
        }
        return label
    }

    /// Today's free windows formatted as start–end pairs.
    var todaysFreeWindows: [(start: String, end: String)] {
        guard let profile = activeScheduleProfile else { return [] }
        let weekday = Calendar.current.component(.weekday, from: now)
        guard let today = DayOfWeek(rawValue: weekday) else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return profile.freeWindows
            .filter { $0.daysOfWeek.contains(today) }
            .sorted { $0.startTime < $1.startTime }
            .map { window in
                var startComps = Calendar.current.dateComponents([.year, .month, .day], from: now)
                startComps.hour = window.startTime.hour
                startComps.minute = window.startTime.minute
                var endComps = startComps
                endComps.hour = window.endTime.hour
                endComps.minute = window.endTime.minute
                let startStr = Calendar.current.date(from: startComps).map { formatter.string(from: $0) } ?? ""
                let endStr = Calendar.current.date(from: endComps).map { formatter.string(from: $0) } ?? ""
                return (start: startStr, end: endStr)
            }
    }

    var needsReauthorization: Bool {
        appState.familyControlsAvailable && appState.enforcement?.authorizationStatus != .authorized
    }

    // MARK: - Self Unlock

    /// Self-unlock state from App Group storage, with automatic midnight reset.
    var selfUnlockState: SelfUnlockState? {
        guard let state = appState.storage.readSelfUnlockState() else { return nil }
        return state.resettingIfNeeded(currentDate: SelfUnlockState.todayDateString())
    }

    /// Whether the self-unlock card should be visible.
    var canShowSelfUnlock: Bool {
        guard let state = selfUnlockState, state.budget > 0 else { return false }
        return currentMode == .dailyMode && !isTemporaryUnlock && timedUnlockInfo == nil
    }

    /// Whether the button should be tappable (has remaining budget).
    var canUseSelfUnlock: Bool {
        canShowSelfUnlock && (selfUnlockState?.isAvailable ?? false)
    }

    /// Consume one self-unlock and trigger a 15-minute temporary unlock.
    func useSelfUnlock() {
        let today = SelfUnlockState.todayDateString()
        guard let raw = appState.storage.readSelfUnlockState() else { return }
        let state = raw.resettingIfNeeded(currentDate: today)
        guard state.budget > 0, state.isAvailable,
              currentMode == .dailyMode, !isTemporaryUnlock, timedUnlockInfo == nil else { return }
        let updated = state.consuming(one: today)
        try? appState.storage.writeSelfUnlockState(updated)
        appState.applySelfUnlock()
    }

    // MARK: - Penalty Timer (relayed from parent via CloudKit)

    var penaltyTimerEndTime: Date? { appState.childPenaltyTimerEndTime }
    var penaltySeconds: Int? { appState.childPenaltySeconds }

    var authStatusDescription: String {
        guard let status = appState.enforcement?.authorizationStatus else { return "unknown" }
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not determined"
        }
    }

    var warnings: [CapabilityWarning] {
        appState.activeWarnings.filter { warning in
            if warning == .tokensMissingForDevice, let config = appBlockingConfig, config.isConfigured {
                return false
            }
            return true
        }
    }

    var appBlockingConfig: AppBlockingConfig? {
        appState.storage.readAppBlockingConfig()
    }

    var lastReconciliation: Date? {
        appState.snapshotStore?.loadCurrentSnapshot()?.appliedAt
    }

    var resolvedAppNames: [String] = []
    var researchEntries: [DiagnosticEntry] = []

    func refreshAppNameCache() {
        let cache = appState.storage.readAllCachedAppNames()
        let useful = cache.values.filter(Self.isUsefulAppName(_:))
        resolvedAppNames = useful.sorted()
    }

    func loadResearchDiagnostics() {
        researchEntries = appState.storage
            .readDiagnosticEntries(category: .tokenNameResearch)
            .suffix(20)
            .map { $0 }
    }

    func refreshNameResolutionState(reason: String) {
        refreshAppNameCache()
        logNameResolution("cache refresh [\(reason)]: \(resolvedAppNames.count) recognized app(s)")
        probeShieldConfigDefaults()
        loadResearchDiagnostics()
    }

    /// Read UserDefaults keys that ShieldConfiguration writes, to verify extension → app IPC.
    private func probeShieldConfigDefaults() {
        let defaults = UserDefaults(suiteName: "group.fr.bigbrother.shared")
        let appName = defaults?.string(forKey: "lastShielded.appName") ?? "nil"
        let bundleID = defaults?.string(forKey: "lastShielded.bundleID") ?? "nil"
        let tokenBase64 = defaults?.string(forKey: "lastShielded.tokenBase64")
        let timestamp = defaults?.double(forKey: "lastShielded.timestamp") ?? 0

        let age = timestamp > 0 ? String(format: "%.0fs ago", Date().timeIntervalSince1970 - timestamp) : "no timestamp"
        let tokenSnippet = tokenBase64.map { String($0.prefix(12)) + "..." } ?? "nil"
        logNameResolution("shield probe: app=\(appName) bundleID=\(bundleID) token=\(tokenSnippet) (\(age))")
    }

    func logNameResolution(_ message: String) {
        try? appState.storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .tokenNameResearch,
            message: message
        ))
    }

    private static func isUsefulAppName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.hasPrefix("blocked app ")
    }

    private static func shouldRetainUploadedUnlockRequest(_ event: EventLogEntry) -> Bool {
        guard event.eventType == .unlockRequested, event.uploadState == .uploaded else {
            return false
        }
        guard let details = event.details else {
            return false
        }
        return details.contains("\nTOKEN:")
    }

    var resetFeedback: String?

    /// Clean up corrupted shield cache file on launch.
    /// The pre-creation code used to write "{}" which can't be decoded as LastShieldedApp.
    /// Delete it so ShieldConfiguration can create it fresh.
    func cleanupShieldCacheFile() {
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
        ) {
            let fileURL = containerURL.appendingPathComponent("last_shielded_app.json")
            if let data = try? Data(contentsOf: fileURL),
               data.count <= 4 { // "{}" or "null" or empty — corrupt
                try? FileManager.default.removeItem(at: fileURL)
                #if DEBUG
                print("[BigBrother] Deleted corrupt last_shielded_app.json (\(data.count) bytes)")
                #endif
            }
        }
    }

    /// Purge all stale uploaded events from the queue so only fresh events are synced.
    /// Call on launch to prevent re-uploading old CloudKit records that cause conflicts.
    func purgeUploadedEvents() {
        let events = appState.storage.readPendingEventLogs()
        let retainedUnlockRequests = events.filter(Self.shouldRetainUploadedUnlockRequest(_:))
        let staleCount = events.filter {
            $0.uploadState != .pending && !Self.shouldRetainUploadedUnlockRequest($0)
        }.count
        if staleCount > 0 {
            let freshOnly = events.filter {
                $0.uploadState == .pending || Self.shouldRetainUploadedUnlockRequest($0)
            }
            if let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
            ) {
                let queueURL = containerURL.appendingPathComponent("event_log_queue.json")
                if let data = try? JSONEncoder().encode(freshOnly) {
                    try? data.write(to: queueURL, options: [.atomic, .noFileProtection])
                    #if DEBUG
                    print("[BigBrother] Purged \(staleCount) stale events, kept \(freshOnly.count) entries including \(retainedUnlockRequests.count) uploaded unlock requests")
                    #endif
                }
            }
        }
    }

    /// Reset corrupted shield cache state and force ShieldConfiguration to re-run.
    func resetShieldCache() {
        // 1. Delete the corrupted last_shielded_app.json (contains "{}")
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
        ) {
            let lastShieldedURL = containerURL.appendingPathComponent("last_shielded_app.json")
            try? FileManager.default.removeItem(at: lastShieldedURL)
        }

        // 2. Reset the UserDefaults keys for shield cache
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.removeObject(forKey: "lastShielded.appName")
        defaults?.removeObject(forKey: "lastShielded.bundleID")
        defaults?.removeObject(forKey: "lastShielded.tokenBase64")
        defaults?.removeObject(forKey: "lastShielded.timestamp")
        defaults?.synchronize()

        // 3. Prune old events — keep only last 10 unlock requests
        pruneStaleEvents()

        logNameResolution("Shield cache reset — delete app and reinstall if issue persists")
        resetFeedback = "Shield cache reset. Try Ask for More Time again."
    }

    private func pruneStaleEvents() {
        var events = appState.storage.readPendingEventLogs()
        let unlockEvents = events.filter { $0.eventType == .unlockRequested }
        if unlockEvents.count > 10 {
            // Keep only the 10 most recent unlock requests
            let sortedUnlocks = unlockEvents.sorted { $0.timestamp > $1.timestamp }
            let staleIDs = Set(sortedUnlocks.dropFirst(10).map(\.id))
            events.removeAll { staleIDs.contains($0.id) }
            if let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
            ) {
                let queueURL = containerURL.appendingPathComponent("event_log_queue.json")
                if let data = try? JSONEncoder().encode(events) {
                    try? data.write(to: queueURL, options: [.atomic, .noFileProtection])
                }
            }
        }
    }

    func requestAuthorization() async {
        guard !isRequestingAuth else { return }
        isRequestingAuth = true
        authFeedback = nil

        do {
            try await appState.enforcement?.requestAuthorization()
            if appState.enforcement?.authorizationStatus == .authorized {
                authFeedback = "Screen Time authorized"
                appState.eventLogger?.log(.authorizationRestored, details: "Manual re-authorization succeeded")
                stopAuthRetry()
            } else {
                authFeedback = "Authorization not granted. Make sure Screen Time is enabled in Settings > Screen Time."
            }
        } catch {
            authFeedback = "Authorization failed: \(error.localizedDescription)"
        }

        isRequestingAuth = false
    }

    func startAuthRetryIfNeeded() {
        guard needsReauthorization else { return }

        authRetryTimer?.invalidate()
        authRetryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.needsReauthorization else {
                    self.stopAuthRetry()
                    return
                }
                await self.silentAuthRetry()
            }
        }
    }

    private func silentAuthRetry() async {
        guard !isRequestingAuth, needsReauthorization else { return }

        do {
            try await appState.enforcement?.requestAuthorization()
            if appState.enforcement?.authorizationStatus == .authorized {
                authFeedback = "Screen Time authorized"
                appState.eventLogger?.log(.authorizationRestored, details: "Background re-authorization succeeded")
                stopAuthRetry()
            }
        } catch {
            return
        }
    }

    private func stopAuthRetry() {
        authRetryTimer?.invalidate()
        authRetryTimer = nil
    }

    /// Immediately sync pending events to CloudKit so unlock requests
    /// from ShieldAction reach the parent ASAP.
    func syncEventsNow() {
        Task {
            try? await appState.eventLogger?.syncPendingEvents()
        }
    }

    /// Send a heartbeat immediately so the parent dashboard reflects the state change.
    private func sendHeartbeatNow() {
        Task {
            try? await appState.heartbeatService?.sendNow(force: true)
        }
    }

    func refreshPINConfigured() {
        isPINConfigured = (try? appState.keychain.getData(forKey: StorageKeys.parentPINHash)) != nil
    }

    /// Tracks which timed unlock phase we last saw, to detect transitions.
    private enum TimedPhase { case none, penalty, unlock }
    private var lastTimedPhase: TimedPhase = .none

    func startTimer() {
        refreshPINConfigured()
        // Initialize phase without triggering transition actions.
        let startNow = Date()
        if let info = timedUnlockInfo {
            if startNow < info.unlockAt { lastTimedPhase = .penalty }
            else if startNow < info.lockAt { lastTimedPhase = .unlock }
            else { lastTimedPhase = .none }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.now = Date()
                self.checkTimedUnlockPhases()
                if !self.isPINConfigured {
                    self.refreshPINConfigured()
                }
            }
        }
        startAuthRetryIfNeeded()
    }

    /// Check timed unlock phases and apply enforcement on transitions.
    /// This is the main-app safety net — the monitor extension should also handle this,
    /// but it may not fire if iOS killed it.
    private func checkTimedUnlockPhases() {
        guard let info = appState.storage.readTimedUnlockInfo() else {
            lastTimedPhase = .none
            return
        }

        let currentPhase: TimedPhase
        if now < info.unlockAt {
            currentPhase = .penalty
        } else if now < info.lockAt {
            currentPhase = .unlock
        } else {
            currentPhase = .none
        }

        // Penalty ended → unlock device
        if lastTimedPhase == .penalty && currentPhase == .unlock {
            let remaining = Int(info.lockAt.timeIntervalSince(now))
            if remaining > 0 {
                appState.applyTimedUnlockStart()
                sendHeartbeatNow()
            }
        }

        // Free time ended → re-lock device and clear state
        if lastTimedPhase == .unlock && currentPhase == .none {
            appState.applyTimedUnlockEnd()
            sendHeartbeatNow()
        }

        // Fully expired on first check (app launched after both phases passed)
        if lastTimedPhase == .none && currentPhase == .none && now >= info.lockAt {
            try? appState.storage.clearTimedUnlockInfo()
        }

        lastTimedPhase = currentPhase
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        stopAuthRetry()
    }
}
