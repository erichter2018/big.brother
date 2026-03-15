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

    var currentMode: LockMode {
        appState.currentEffectivePolicy?.resolvedMode ?? .unlocked
    }

    var isTemporaryUnlock: Bool {
        appState.currentEffectivePolicy?.isTemporaryUnlock ?? false
    }

    var temporaryUnlockState: TemporaryUnlockState? {
        appState.storage.readTemporaryUnlockState()
    }

    var needsReauthorization: Bool {
        appState.familyControlsAvailable && appState.enforcement?.authorizationStatus != .authorized
    }

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
        authRetryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.needsReauthorization else {
                    self?.stopAuthRetry()
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

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        startAuthRetryIfNeeded()
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        stopAuthRetry()
    }
}
