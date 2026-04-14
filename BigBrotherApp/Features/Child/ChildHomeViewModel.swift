import Foundation
import Observation
import CoreLocation
import CoreMotion
import UIKit
import FamilyControls
import ManagedSettings
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

    /// Whether the current snapshot's policy is driven by a schedule (vs a parent command).
    /// Stored property refreshed by the 1s timer so UI reacts to command changes.
    var isScheduleDriving = false

    // MARK: - Pending App Reviews

    /// Pending app reviews submitted by this child, refreshed periodically.
    var pendingReviews: [PendingAppReview] = []

    /// Snapshot of ACTIVE TimeLimitConfig keys (name, bundleID, fingerprint) pulled from
    /// CloudKit. Used to auto-clean the local pending file when a kid requests an app
    /// that the parent already approved on a sibling device — without this, the request
    /// sits in "Pending Parent Approval" forever because the fingerprint doesn't match
    /// between devices even though the parent already said yes by name.
    private var knownConfigs: [TimeLimitConfig] = []
    private var activeConfigs: [TimeLimitConfig] = []
    private var lastActiveConfigRefresh: Date = .distantPast

    private static func normalizeAppName(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func applyKnownConfigs(_ configs: [TimeLimitConfig]) {
        knownConfigs = configs
        let active = configs.filter(\.isActive)
        activeConfigs = active
        lastActiveConfigRefresh = Date()
        refreshPendingReviews()
    }

    private func fetchKnownTimeLimitConfigs() async -> [TimeLimitConfig] {
        guard let cloudKit = appState.cloudKit,
              let enrollment = try? KeychainManager().get(
                  ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
              ),
              let configs = try? await cloudKit.fetchTimeLimitConfigs(
                  childProfileID: enrollment.childProfileID
              ) else {
            return []
        }
        applyKnownConfigs(configs)
        return configs
    }

    func refreshPendingReviews() {
        guard let data = appState.storage.readRawData(forKey: "pending_review_local.json"),
              let reviews = try? JSONDecoder().decode([PendingAppReview].self, from: data) else {
            pendingReviews = []
            return
        }

        let (live, approved, superseded) = partitionReviews(reviews)

        if !approved.isEmpty || !superseded.isEmpty {
            // Persist the filtered list back so the kid UI and future reads stay clean.
            if let encoded = try? JSONEncoder().encode(live) {
                try? appState.storage.writeRawData(encoded, forKey: "pending_review_local.json")
            }
            // Apply the current parent decision to the freshly requested local token.
            applyResolvedReviewsLocally(approved)
            Task { await deleteResolvedReviews(approved + superseded) }
        }

        pendingReviews = live.sorted { $0.createdAt > $1.createdAt }
    }

    /// Apply the current active config to a resolved review's local token binding.
    /// This is what makes sibling-device and token-rotation re-requests converge
    /// without needing the parent to decide a second time.
    private func applyResolvedReviewsLocally(_ resolved: [PendingAppReview]) {
        for review in resolved {
            guard let b64 = review.tokenDataBase64,
                  let tokenData = Data(base64Encoded: b64),
                  let config = appState.matchingActiveTimeLimitConfig(
                      appName: review.appName,
                      bundleID: review.bundleID,
                      fingerprint: review.appFingerprint,
                      in: activeConfigs
                  ) else { continue }
            _ = appState.applyTimeLimitConfigLocally(
                config,
                tokenData: tokenData,
                fallbackAppName: review.appName,
                bundleID: review.bundleID
            )
        }
    }

    private func partitionReviews(
        _ reviews: [PendingAppReview]
    ) -> (live: [PendingAppReview], approved: [PendingAppReview], superseded: [PendingAppReview]) {
        var live: [PendingAppReview] = []
        var approved: [PendingAppReview] = []
        var superseded: [PendingAppReview] = []
        for review in reviews {
            if let config = appState.matchingTimeLimitConfig(
                appName: review.appName,
                bundleID: review.bundleID,
                fingerprint: review.appFingerprint,
                in: knownConfigs
            ) {
                if config.isActive {
                    approved.append(review)
                    continue
                }
                if config.updatedAt >= review.updatedAt {
                    superseded.append(review)
                    continue
                }
            }
            live.append(review)
        }
        return (live, approved, superseded)
    }

    /// Fetch active TimeLimitConfigs from CloudKit, refresh the name/bundleID/fingerprint
    /// caches, then re-run the local filter so the UI clears matched entries immediately.
    func refreshActiveAppConfigs() async {
        _ = await fetchKnownTimeLimitConfigs()
    }

    func ensureActiveAppConfigsFresh() async {
        if activeConfigs.isEmpty || Date().timeIntervalSince(lastActiveConfigRefresh) > 60 {
            await refreshActiveAppConfigs()
        }
    }

    func submitAppRequest(token: ApplicationToken, name: String, bundleID: String?) async {
        guard let enrollment = appState.enrollmentState else { return }

        let storage = appState.storage
        let encoder = JSONEncoder()

        guard let tokenData = try? encoder.encode(token) else { return }
        let fingerprint = TokenFingerprint.fingerprint(for: tokenData)
        let tokenKey = tokenData.base64EncodedString()

        // Exact-token duplicate suppression on this device only. Cross-device and
        // token-rotation repeats still flow through so they can auto-bind by identity.
        let cachedName = storage.readAllCachedAppNames()[tokenKey]
        let hasUsableCachedName: Bool = {
            guard let n = cachedName?.trimmingCharacters(in: .whitespaces),
                  !n.isEmpty else { return false }
            if n.hasPrefix("App ") { return false }
            if n.hasPrefix("Temporary") { return false }
            if n == "App" || n == "Unknown" { return false }
            return true
        }()
        if hasUsableCachedName {
            if let allowedData = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
               let allowedTokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: allowedData),
               allowedTokens.contains(token) {
                return
            }
            for limit in storage.readAppTimeLimits() where limit.tokenData.base64EncodedString() == tokenKey {
                return
            }
        }

        let localCanonicalName = appState.storedCanonicalAppName(
            fingerprint: fingerprint,
            tokenKey: tokenKey
        )
        let knownConfigs = await fetchKnownTimeLimitConfigs()
        let matchingConfig = appState.matchingTimeLimitConfig(
            appName: name,
            bundleID: bundleID,
            fingerprint: fingerprint,
            in: knownConfigs
        )
        let resolvedName = localCanonicalName ?? matchingConfig?.appName ?? name

        if let config = matchingConfig, config.isActive {
            _ = appState.applyTimeLimitConfigLocally(
                config,
                tokenData: tokenData,
                fallbackAppName: resolvedName,
                bundleID: bundleID
            )
            refreshPendingReviews()
            appState.childConfirmationMessage = "\(config.appName) is ready."
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if self?.appState.childConfirmationMessage == "\(config.appName) is ready." {
                    self?.appState.childConfirmationMessage = nil
                }
            }
            return
        }

        // Replace any stale pending review for the same token fingerprint with the
        // new request. The current token bytes win.
        var existingPending: [PendingAppReview] = {
            guard let data = storage.readRawData(forKey: "pending_review_local.json") else { return [] }
            return (try? JSONDecoder().decode([PendingAppReview].self, from: data)) ?? []
        }()
        existingPending.removeAll { $0.appFingerprint == fingerprint }
        if let encoded = try? JSONEncoder().encode(existingPending) {
            try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
        }

        // Keep the token in the managed picker selection so enforcement can
        // re-bind it locally when the parent approves or auto-approval kicks in.
        var pickerSelection: FamilyActivitySelection
        if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
           let existing = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            pickerSelection = existing
        } else {
            pickerSelection = FamilyActivitySelection()
        }
        pickerSelection.applicationTokens.insert(token)
        if let encoded = try? encoder.encode(pickerSelection) {
            try? storage.writeRawData(encoded, forKey: StorageKeys.familyActivitySelection)
        }

        storage.cacheAppName(resolvedName, forTokenKey: tokenKey)

        let review = PendingAppReview(
            familyID: enrollment.familyID,
            childProfileID: enrollment.childProfileID,
            deviceID: enrollment.deviceID,
            appFingerprint: fingerprint,
            appName: resolvedName,
            bundleID: bundleID,
            nameResolved: true,
            tokenDataBase64: tokenKey
        )

        if localCanonicalName == nil && matchingConfig == nil {
            let watch = UnverifiedAppWatch(
                fingerprint: fingerprint,
                childGivenName: resolvedName,
                deviceID: enrollment.deviceID,
                childProfileID: enrollment.childProfileID
            )
            var watches: [UnverifiedAppWatch] = {
                guard let d = storage.readRawData(forKey: "unverified_app_watches.json") else { return [] }
                return (try? JSONDecoder().decode([UnverifiedAppWatch].self, from: d)) ?? []
            }()
            watches.append(watch)
            if let encoded = try? JSONEncoder().encode(watches) {
                try? storage.writeRawData(encoded, forKey: "unverified_app_watches.json")
            }
        }

        var pending: [PendingAppReview] = {
            guard let data = storage.readRawData(forKey: "pending_review_local.json") else { return [] }
            return (try? JSONDecoder().decode([PendingAppReview].self, from: data)) ?? []
        }()
        pending.append(review)
        if let encoded = try? JSONEncoder().encode(pending) {
            try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
        }

        refreshPendingReviews()

        let enforcementRef = appState.enforcement
        let storageRef = appState.storage
        Task.detached {
            if let snapshot = storageRef.readPolicySnapshot() {
                try? enforcementRef?.apply(snapshot.effectivePolicy)
            }
        }

        _ = try? await appState.cloudKit?.savePendingAppReview(review)
    }

    private func deleteResolvedReviews(_ resolved: [PendingAppReview]) async {
        guard let cloudKit = appState.cloudKit else { return }
        for review in resolved {
            try? await cloudKit.deletePendingAppReview(review.id)
        }
    }

    // MARK: - Parent Messages

    /// Undismissed messages from parents, newest first. Cached to avoid disk reads on every body eval.
    var undismissedMessages: [ParentMessage] = []

    func refreshMessages() {
        undismissedMessages = appState.storage.readParentMessages()
            .filter { !$0.dismissed }
            .sorted { $0.sentAt > $1.sentAt }
    }

    /// Dismiss a parent message by marking it as dismissed in storage.
    func dismissMessage(_ id: UUID) {
        var messages = appState.storage.readParentMessages()
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].dismissed = true
        try? appState.storage.writeParentMessages(messages)
        refreshMessages()
    }

    var currentMode: LockMode {
        // Default to .restricted (fail-safe) when policy hasn't loaded yet.
        // Defaulting to .unlocked caused a confusing "unlocked" flash on launch.
        // .restricted is safer and matches what most schedules use as their default.
        appState.currentEffectivePolicy?.resolvedMode ?? .restricted
    }

    /// True until performRestoration completes — used to show "loading" state.
    var isLoadingInitialState: Bool {
        !appState.isRestored && appState.currentEffectivePolicy == nil
    }

    /// When the internet block expires (from VPN DNS blackhole). Nil if not blocked.
    var internetBlockedUntil: Date? {
        let defaults = UserDefaults.appGroup
        guard let timestamp = defaults?.double(forKey: "internetBlockedUntil"), timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        return date > now ? date : nil
    }

    /// Whether the VPN tunnel is actively blocking internet (any reason).
    var isTunnelInternetBlocked: Bool {
        let defaults = UserDefaults.appGroup
        return defaults?.bool(forKey: "tunnelInternetBlocked") == true
    }

    /// Human-readable reason the tunnel is blocking internet, if any.
    var tunnelInternetBlockedReason: String? {
        let defaults = UserDefaults.appGroup
        guard let reason = defaults?.string(forKey: "tunnelInternetBlockedReason"),
              !reason.isEmpty else { return nil }
        return reason
    }

    /// Whether enforcement is currently being restored (app just came alive).
    var isRestoringEnforcement: Bool {
        let defaults = UserDefaults.appGroup
        let lastActive = defaults?.double(forKey: "mainAppLastActiveAt") ?? 0
        let age = Date().timeIntervalSince1970 - lastActive
        // If app was inactive for >60s and just came back, we're restoring
        return age > 0 && age < 30
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

    /// Contextual lock reason for the mode header subtitle.
    var lockReasonText: String? {
        // Unlocked (not temp) — no reason needed
        if currentMode == .unlocked && !isTemporaryUnlock { return nil }

        // Temp unlock — countdown card already shows, skip
        if isTemporaryUnlock { return nil }

        // Schedule-driven — show next transition time
        if isScheduleDriving, let profile = activeScheduleProfile {
            let inFree = profile.isInUnlockedWindow(at: now)
            let inEssential = profile.isInLockedWindow(at: now)
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"

            if inFree {
                if let transition = profile.nextTransitionTime(from: now) {
                    return "Unlocked until \(formatter.string(from: transition))"
                }
                return "Unlocked"
            } else if inEssential {
                if let transition = profile.nextTransitionTime(from: now) {
                    return "Locked until \(formatter.string(from: transition))"
                }
                return "Locked"
            } else {
                if let transition = profile.nextTransitionTime(from: now) {
                    return "Restricted until \(formatter.string(from: transition))"
                }
                return "Restricted — \(profile.name)"
            }
        }

        // Parent command — don't repeat the mode name, it's already the title
        return nil
    }

    /// Human-readable schedule status, e.g. "Unlocked until 8:00 PM" or "Locked until 3:00 PM".
    var scheduleStatusText: String? {
        guard let profile = activeScheduleProfile else { return nil }
        let inFree = profile.isInUnlockedWindow(at: now)
        let inEssential = profile.isInLockedWindow(at: now)
        let label = inFree ? "Unlocked" : inEssential ? "Locked" : "Restricted"
        if let transition = profile.nextTransitionTime(from: now) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "\(label) until \(formatter.string(from: transition))"
        }
        return label
    }

    /// Today's unlocked windows formatted as start-end pairs.
    var todaysFreeWindows: [(start: String, end: String)] {
        guard let profile = activeScheduleProfile else { return [] }
        let weekday = Calendar.current.component(.weekday, from: now)
        guard let today = DayOfWeek(rawValue: weekday) else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return profile.unlockedWindows
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

    // MARK: - Web & Internet Status

    /// Allowed web domains read from App Group. Empty = all web blocked when restricted/locked.
    var allowedWebDomains: [String] {
        guard let data = UserDefaults.appGroup?
                .string(forKey: StorageKeys.allowedWebDomains)?
                .data(using: .utf8),
              let domains = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return domains.sorted()
    }

    /// Whether web browsing is currently blocked by ManagedSettings (webDomainCategories).
    /// Only true when denyWebWhenRestricted is enabled, or in lockedDown mode.
    var isWebBlocked: Bool {
        guard currentMode != .unlocked else { return false }
        if currentMode == .lockedDown { return true }
        let restrictions = appState.storage.readDeviceRestrictions()
        return restrictions?.denyWebWhenRestricted ?? false
    }

    /// Human-readable explanation of web status for the child.
    var webStatusExplanation: String {
        if currentMode == .lockedDown {
            return "All internet access is paused."
        }
        if isWebBlocked {
            return "Web browsing is paused during this period."
        }
        return "Web browsing is available."
    }

    /// When web access will next be available (next unlock window).
    var webAvailableAt: String? {
        guard isWebBlocked else { return nil }
        if let profile = activeScheduleProfile,
           let transition = profile.nextTransitionTime(from: now) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            if Calendar.current.isDateInToday(transition) {
                return "Available at \(formatter.string(from: transition))"
            } else {
                formatter.dateFormat = "E h:mm a"
                return "Available \(formatter.string(from: transition))"
            }
        }
        return nil
    }

    var needsReauthorization: Bool {
        guard appState.familyControlsAvailable else { return false }
        let current = appState.enforcement?.authorizationStatus ?? .notDetermined
        if current == .authorized { return false }
        // FC auth starts as notDetermined on launch and can take 30+ seconds
        // to validate with Apple servers, especially for .child auth.
        // If we have a persisted auth type (in either defaults store), we were
        // previously authorized — don't show the permissions button for a transient delay.
        let appGroupType = UserDefaults.appGroup?
            .string(forKey: "fr.bigbrother.authorizationType")
        let standardType = UserDefaults.standard.string(forKey: "fr.bigbrother.authorizationType")
        if appGroupType == "child" || appGroupType == "individual"
            || standardType == "child" || standardType == "individual" {
            return false
        }
        // Never been authorized — genuinely needs setup
        return true
    }

    /// Cached VPN status, refreshed periodically.
    var vpnConfigured: Bool = true

    /// True when any required permission is missing. Drives the floating "Permissions" button.
    /// Cached notification authorization status, refreshed periodically.
    var notificationsAuthorized: Bool = true

    var hasPermissionIssues: Bool {
        if needsReauthorization { return true }
        if cachedLocationAuthStatus != .authorizedAlways { return true }
        if CMMotionActivityManager.isActivityAvailable(),
           CMMotionActivityManager.authorizationStatus() != .authorized { return true }
        if !vpnConfigured { return true }
        if !notificationsAuthorized { return true }
        return false
    }

    // MARK: - Location Authorization

    /// Cached location authorization status, refreshed on timer tick.
    var cachedLocationAuthStatus: CLAuthorizationStatus = .notDetermined

    /// True when location tracking is enabled but permission is denied or restricted.
    var needsLocationPermission: Bool {
        guard let locService = appState.locationService, locService.mode != .off else { return false }
        return cachedLocationAuthStatus == .denied || cachedLocationAuthStatus == .restricted
    }

    /// True when location permission hasn't been requested yet.
    var locationNotDetermined: Bool {
        cachedLocationAuthStatus == .notDetermined
    }

    func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func requestLocationPermission() {
        appState.locationService?.setMode(appState.locationService?.mode ?? .onDemand)
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
        return currentMode == .restricted && !isTemporaryUnlock && timedUnlockInfo == nil
    }

    /// Whether the button should be tappable (has remaining budget).
    var canUseSelfUnlock: Bool {
        canShowSelfUnlock && (selfUnlockState?.isAvailable ?? false)
    }

    /// Prevents double-tap from consuming two self-unlocks.
    private var isProcessingSelfUnlock = false

    /// Consume one self-unlock and trigger a 15-minute temporary unlock.
    func useSelfUnlock() {
        guard !isProcessingSelfUnlock else { return }
        isProcessingSelfUnlock = true
        defer { isProcessingSelfUnlock = false }

        let today = SelfUnlockState.todayDateString()
        guard let raw = appState.storage.readSelfUnlockState() else { return }
        let state = raw.resettingIfNeeded(currentDate: today)
        guard state.budget > 0, state.isAvailable,
              currentMode == .restricted, !isTemporaryUnlock, timedUnlockInfo == nil else { return }
        let updated = state.consuming(one: today)
        try? appState.storage.writeSelfUnlockState(updated)
        appState.applySelfUnlock()
        appState.eventLogger?.log(.selfUnlockUsed, details: "Self-unlock used (\(updated.usedCount)/\(updated.budget) today)")
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
        let defaults = UserDefaults.appGroup
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
        let arTimer = Timer(timeInterval: 30, repeats: true) { [weak self] timer in
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
        RunLoop.main.add(arTimer, forMode: .common)
        authRetryTimer = arTimer
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

    func refreshScheduleDriving() {
        isScheduleDriving = UserDefaults.appGroup?.bool(forKey: "scheduleDrivenMode") ?? true
        if let locService = appState.locationService {
            cachedLocationAuthStatus = locService.authorizationStatus
        }
        // Refresh VPN status (async)
        if let vpn = appState.vpnManager {
            Task {
                let configured = await vpn.isConfigured()
                await MainActor.run { vpnConfigured = configured }
            }
        }
        // Refresh notification authorization
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationsAuthorized = settings.authorizationStatus == .authorized
            }
        }

        // Write permission status to App Group.
        // Two flags: enforcement-critical (FC ONLY) for Monitor's hard-lock
        // override, and all-permissions for UI/advisory purposes. Location is
        // for breadcrumbs/geofencing, not shield enforcement — it must NOT
        // force-lock the device. Previously this flag also required
        // location=Always, which silently promoted parent-issued .restricted
        // commands to .locked inside the Monitor (b444 user-visible bug:
        // "switching to restricted from locked didn't drop the individual
        // shields"). Missing notifications, motion, or VPN should also NOT
        // cause the Monitor to force-lock the device.
        let defaults = UserDefaults.appGroup
        let isOK = !hasPermissionIssues
        defaults?.set(isOK, forKey: "allPermissionsGranted")
        let enforcementOK = !needsReauthorization
        defaults?.set(enforcementOK, forKey: "enforcementPermissionsOK")

        // Write per-permission snapshot for parent visibility via heartbeat
        var permStatus: [String: Bool] = [:]
        permStatus["familyControls"] = !needsReauthorization
        permStatus["vpn"] = vpnConfigured
        permStatus["location"] = cachedLocationAuthStatus == .authorizedAlways
        if CMMotionActivityManager.isActivityAvailable() {
            permStatus["motion"] = CMMotionActivityManager.authorizationStatus() == .authorized
        }
        permStatus["notifications"] = notificationsAuthorized
        if let data = try? JSONEncoder().encode(permStatus) {
            defaults?.set(String(data: data, encoding: .utf8), forKey: "permissionSnapshot")
        }

        // Only log authorizationLost for FamilyControls — that's actual tampering.
        // Location, motion, notifications, and VPN are informational, not tamper events.
        let fcWasOK = defaults?.bool(forKey: "familyControlsWasAuthorized") ?? true
        let fcIsOK = !needsReauthorization
        defaults?.set(fcIsOK, forKey: "familyControlsWasAuthorized")

        if fcWasOK && !fcIsOK {
            let storage = AppGroupStorage()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .auth,
                message: "FamilyControls authorization revoked",
                details: "Screen Time permissions disabled"
            ))
            if let enrollment = try? KeychainManager().get(ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState) {
                let entry = EventLogEntry(
                    deviceID: enrollment.deviceID,
                    familyID: enrollment.familyID,
                    eventType: .authorizationLost,
                    details: "FamilyControls authorization revoked — shields disabled"
                )
                try? storage.appendEventLog(entry)
            }
        }
    }

    /// Tracks which timed unlock phase we last saw, to detect transitions.
    private enum TimedPhase { case none, penalty, unlock }
    private var lastTimedPhase: TimedPhase = .none
    private var scheduleCheckCounter = 0

    func startTimer() {
        refreshPINConfigured()
        refreshScheduleDriving()
        refreshMessages()
        refreshPendingReviews()
        Task { await refreshActiveAppConfigs() }
        // Initialize phase without triggering transition actions.
        let startNow = Date()
        if let info = timedUnlockInfo {
            if startNow < info.unlockAt { lastTimedPhase = .penalty }
            else if startNow < info.lockAt { lastTimedPhase = .unlock }
            else { lastTimedPhase = .none }
        }
        let tickTimer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.now = Date()
                self.checkTimedUnlockPhases()
                self.refreshScheduleDriving()
                // Refresh messages every 10s (not every 1s — disk reads).
                self.scheduleCheckCounter += 1
                if self.scheduleCheckCounter >= 10 {
                    self.refreshMessages()
                    self.refreshPendingReviews()
                    self.scheduleCheckCounter = 0
                    self.appState.enforceScheduleTransition()
                    // Pull the latest parent decisions every 60s so pending reviews
                    // for apps the parent already approved on another device vanish.
                    if Date().timeIntervalSince(self.lastActiveConfigRefresh) > 60 {
                        Task { await self.refreshActiveAppConfigs() }
                    }
                }
                if !self.isPINConfigured {
                    self.refreshPINConfigured()
                }
            }
        }
        RunLoop.main.add(tickTimer, forMode: .common)
        timer = tickTimer
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
