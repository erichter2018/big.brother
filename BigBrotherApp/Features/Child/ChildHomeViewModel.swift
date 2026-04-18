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
        // Build the identity context ONCE per refresh. Previously each of 30
        // reviews re-scanned the entire FamilyActivitySelection (600+ token
        // encodes on the main actor per refresh) — gemini audit flagged this
        // as an O(N*M) UI hang. Now one pass, then O(1) lookups.
        let context = IdentityContext.build(appState: appState)

        // Prune reviews whose app is already intact locally (allowedTokens or
        // an existing AppTimeLimit). These pending entries can linger when a
        // parent approves via a different path (reviewApp command landing
        // before this refresh, a sibling's auto-approve path, etc.) — the
        // "intact" check removes the gap between kid sees pending / parent
        // already acted.
        pruneAlreadyIntactReviews(context: context)

        guard let data = appState.storage.readRawData(forKey: AppGroupKeys.pendingReviewLocalJSON),
              let reviews = try? JSONDecoder().decode([PendingAppReview].self, from: data) else {
            pendingReviews = []
            return
        }

        let (live, approved, superseded) = partitionReviews(reviews)

        if !approved.isEmpty || !superseded.isEmpty {
            // Apply FIRST, then mutate the local file based on per-review
            // outcome. Three states:
            //   applied  → remove from local file (done)
            //   superseded → remove from local file (matched a non-active or
            //                older config, will never come back)
            //   approved-but-failed-to-apply → KEEP in local file but flip
            //                syncStatus to .resolved so the tunnel's
            //                syncResolvedPendingReviews skips it on re-upload.
            //                Codex audit flagged the resurrection loop where
            //                unresolved local reviews kept re-uploading to the
            //                CK records we just deleted, bouncing the parent's
            //                dashboard. The ShieldConfiguration reads the file
            //                without filtering on syncStatus, so the kid's
            //                shield still shows "pending review" and they can
            //                re-tap to submit a fresh request.
            let appliedIDs = applyResolvedReviewsLocally(approved, context: context)
            let supersededIDs = Set(superseded.map(\.id))
            let approvedIDs = Set(approved.map(\.id))
            let failedToApplyIDs = approvedIDs.subtracting(appliedIDs)
            let removeIDs = appliedIDs.union(supersededIDs)

            var mutated = false
            var rewritten = reviews
            if !removeIDs.isEmpty {
                rewritten.removeAll { removeIDs.contains($0.id) }
                mutated = true
            }
            for i in rewritten.indices where failedToApplyIDs.contains(rewritten[i].id) {
                if rewritten[i].syncStatus != .resolved {
                    rewritten[i].syncStatus = .resolved
                    mutated = true
                }
            }
            if mutated, let encoded = try? JSONEncoder().encode(rewritten) {
                try? appState.storage.writeRawData(encoded, forKey: AppGroupKeys.pendingReviewLocalJSON)
            }

            // Delete ALL approved+superseded from CloudKit — the parent's
            // TimeLimitConfig is the authoritative "approved" signal, so the
            // CK PendingAppReview records are stale regardless of whether the
            // local apply just succeeded. The failed-to-apply entries are now
            // marked .resolved locally (above), so the tunnel sync won't
            // re-upload and resurrect them.
            Task { await deleteResolvedReviews(approved + superseded) }
        }

        pendingReviews = live.filter { $0.syncStatus != .resolved }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Apply the current active config to each resolved review's local token
    /// binding. Returns the IDs of reviews that actually applied so the caller
    /// can leave unapplied ones in pending for a retry. Silently-dropped
    /// reviews are now logged with the specific failure reason so we can debug
    /// batch-approval drops from kid diagnostics instead of wondering which
    /// half "took."
    ///
    /// When the local review's tokenData is missing or no longer decodes (iOS
    /// rotates ApplicationToken bytes occasionally, and cross-device syncs
    /// carry sibling-device tokens that don't resolve locally), we fall back
    /// to the current FamilyActivitySelection + cached-name lookup to find a
    /// fresh token with the same identity — same path the command processor
    /// uses for direct reviewApp commands.
    private func applyResolvedReviewsLocally(
        _ resolved: [PendingAppReview],
        context: IdentityContext
    ) -> Set<UUID> {
        var applied: Set<UUID> = []
        for review in resolved {
            guard let config = appState.matchingActiveTimeLimitConfig(
                appName: review.appName,
                bundleID: review.bundleID,
                fingerprint: review.appFingerprint,
                in: activeConfigs
            ) else {
                BBLog("[pendingReview] skip apply fp=\(review.appFingerprint.prefix(8)) name=\(review.appName): no matching active TimeLimitConfig")
                continue
            }

            let localTokenData = review.tokenDataBase64.flatMap { Data(base64Encoded: $0) }
            let freshTokenData = context.lookupFreshToken(
                fingerprint: review.appFingerprint,
                appName: review.appName,
                bundleID: review.bundleID
            )

            // Apply ALL distinct candidates, not just the first that returns
            // true — codex audit flagged the false-success path: a stale
            // sibling-device or rotated token can decode, get inserted into
            // allowedTokens, return true, and block the picker-fresh fallback.
            // The correct-for-this-device token wins at shield-check time;
            // any extra stale entries in allowedTokens are harmless bloat.
            var candidates: [(label: String, data: Data)] = []
            if let local = localTokenData {
                candidates.append(("local", local))
            }
            if let fresh = freshTokenData, fresh != localTokenData {
                candidates.append(("picker-fresh", fresh))
            }

            guard !candidates.isEmpty else {
                BBLog("[pendingReview] skip apply fp=\(review.appFingerprint.prefix(8)) name=\(review.appName): no token (local=nil, picker=nil)")
                continue
            }

            var appliedLabels: [String] = []
            for candidate in candidates {
                let ok = appState.applyTimeLimitConfigLocally(
                    config,
                    tokenData: candidate.data,
                    fallbackAppName: review.appName,
                    bundleID: review.bundleID
                )
                if ok { appliedLabels.append(candidate.label) }
            }

            if !appliedLabels.isEmpty {
                applied.insert(review.id)
                if appliedLabels.contains("picker-fresh") && appliedLabels.contains("local") == false {
                    BBLog("[pendingReview] recovered via picker-fresh only fp=\(review.appFingerprint.prefix(8)) name=\(review.appName)")
                }
            } else {
                BBLog("[pendingReview] skip apply fp=\(review.appFingerprint.prefix(8)) name=\(review.appName): all \(candidates.count) candidates failed")
            }
        }
        return applied
    }

    /// Remove pending reviews whose app is already fully handled on the local
    /// device — either in `allowedTokens` (allowAlways) or represented by an
    /// existing `AppTimeLimit`. Happens when a reviewApp command landed before
    /// this CK-pull refresh, or when a sibling auto-approve applied the config
    /// via `applyTimeLimitConfigLocally` on a different entry point.
    ///
    /// Closes the "kid sees pending, parent already acted" gap: if the local
    /// state shows the app is done, the pending card should not linger.
    ///
    /// **Strict identity only.** Uses `strictIdentityMatch` (bundleID bilateral
    /// OR fingerprint bilateral, never name-only). Codex audit flagged that
    /// the full AppIdentityMatcher.same could name-match against a misnamed
    /// row — ShieldAction has a fallback that assigns the "oldest unresolved"
    /// pending name to a freshly-shielded app, and `lookupFreshToken` uses
    /// name. A name-only prune could delete a legitimately-pending review
    /// that happens to share a normalized name with an already-allowed app.
    private func pruneAlreadyIntactReviews(context: IdentityContext) {
        let storage = appState.storage
        guard let data = storage.readRawData(forKey: AppGroupKeys.pendingReviewLocalJSON),
              let reviews = try? JSONDecoder().decode([PendingAppReview].self, from: data),
              !reviews.isEmpty else {
            return
        }

        let appLimits = storage.readAppTimeLimits()

        var toRemove: [PendingAppReview] = []
        var kept: [PendingAppReview] = []
        for review in reviews {
            let reviewCandidate = AppIdentityMatcher.Candidate(
                bundleID: review.bundleID,
                fingerprint: review.appFingerprint,
                appName: review.appName,
                deviceID: review.deviceID
            )

            let allowedMatch = context.allowedCandidates.contains { allowed in
                Self.strictIdentityMatch(allowed, reviewCandidate)
            }
            if allowedMatch {
                toRemove.append(review)
                continue
            }

            if appLimits.contains(where: {
                Self.strictIdentityMatch(
                    AppIdentityMatcher.Candidate(
                        bundleID: $0.bundleID,
                        fingerprint: $0.fingerprint,
                        appName: $0.appName
                    ),
                    reviewCandidate
                )
            }) {
                toRemove.append(review)
                continue
            }

            kept.append(review)
        }

        guard !toRemove.isEmpty else { return }

        if let encoded = try? JSONEncoder().encode(kept) {
            try? storage.writeRawData(encoded, forKey: AppGroupKeys.pendingReviewLocalJSON)
        }
        for r in toRemove {
            BBLog("[pendingReview] prune-intact fp=\(r.appFingerprint.prefix(8)) name=\(r.appName) (already allowed/limited locally)")
        }
        // Also clean up CK records for the pruned reviews so the parent
        // dashboard doesn't keep showing them.
        Task { await deleteResolvedReviews(toRemove) }
    }

    /// Strong identity match for prune decisions only. Either:
    ///   - both sides have bundleIDs AND they match (authoritative), OR
    ///   - both sides have fingerprints AND they match AND device scopes are
    ///     compatible (via AppIdentityMatcher.same, which enforces that).
    /// Rejects name-only matches — a misnamed pending entry should never
    /// cause us to delete a legit CK record.
    private static func strictIdentityMatch(
        _ a: AppIdentityMatcher.Candidate,
        _ b: AppIdentityMatcher.Candidate
    ) -> Bool {
        if let abid = AppIdentityMatcher.normalizeBundleID(a.bundleID),
           let bbid = AppIdentityMatcher.normalizeBundleID(b.bundleID) {
            return abid == bbid
        }
        if let afp = a.fingerprint, let bfp = b.fingerprint, afp == bfp {
            // Fall through to AppIdentityMatcher.same for the device-scope
            // compatibility check (fingerprints across sibling devices are
            // collisions, not matches).
            return AppIdentityMatcher.same(a, b)
        }
        return false
    }

    /// Pre-computed lookup tables for picker tokens and allowed tokens, built
    /// once per refresh cycle. Replaces the O(N*M) per-review scans that
    /// gemini flagged as a main-thread UI hang.
    private struct IdentityContext {
        let pickerByFingerprint: [String: Data]
        let pickerByBundleID: [String: Data]
        let pickerByName: [String: Data]
        let allowedCandidates: [AppIdentityMatcher.Candidate]

        static func build(appState: AppState) -> IdentityContext {
            let storage = appState.storage
            let encoder = JSONEncoder()
            let nameCache = storage.readAllCachedAppNames()

            var pickerByFingerprint: [String: Data] = [:]
            var pickerByBundleID: [String: Data] = [:]
            var pickerByName: [String: Data] = [:]
            if let selData = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
               let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: selData) {
                for token in selection.applicationTokens {
                    guard let tokenData = try? encoder.encode(token) else { continue }
                    let tokenKey = tokenData.base64EncodedString()
                    let fp = TokenFingerprint.fingerprint(for: tokenData)
                    pickerByFingerprint[fp] = tokenData
                    if let bid = AppIdentityMatcher.normalizeBundleID(Application(token: token).bundleIdentifier) {
                        // First write wins — picker may have multiple entries
                        // with the same bundleID during token rotation; the
                        // first one encountered is likely freshest.
                        if pickerByBundleID[bid] == nil {
                            pickerByBundleID[bid] = tokenData
                        }
                    }
                    if let cached = nameCache[tokenKey],
                       AppIdentityMatcher.isUsefulAppName(cached) {
                        let normalized = AppIdentityMatcher.normalizeAppName(cached)
                        if pickerByName[normalized] == nil {
                            pickerByName[normalized] = tokenData
                        }
                    }
                }
            }

            var allowedCandidates: [AppIdentityMatcher.Candidate] = []
            if let ad = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
               let allowedTokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: ad) {
                for token in allowedTokens {
                    guard let tokenData = try? encoder.encode(token) else { continue }
                    let tokenKey = tokenData.base64EncodedString()
                    let fp = TokenFingerprint.fingerprint(for: tokenData)
                    let cached = nameCache[tokenKey]
                    let useful = cached.flatMap {
                        AppIdentityMatcher.isUsefulAppName($0) ? $0 : nil
                    }
                    allowedCandidates.append(AppIdentityMatcher.Candidate(
                        bundleID: Application(token: token).bundleIdentifier,
                        fingerprint: fp,
                        appName: useful ?? ""
                    ))
                }
            }

            return IdentityContext(
                pickerByFingerprint: pickerByFingerprint,
                pickerByBundleID: pickerByBundleID,
                pickerByName: pickerByName,
                allowedCandidates: allowedCandidates
            )
        }

        /// Fresh-token lookup: fingerprint > bundleID > name. Returns the
        /// picker-encoded tokenData so `applyTimeLimitConfigLocally` can
        /// decode it against the CURRENT device's token set.
        func lookupFreshToken(
            fingerprint: String,
            appName: String,
            bundleID: String?
        ) -> Data? {
            if let data = pickerByFingerprint[fingerprint] { return data }
            if let bid = AppIdentityMatcher.normalizeBundleID(bundleID),
               let data = pickerByBundleID[bid] {
                return data
            }
            if AppIdentityMatcher.isUsefulAppName(appName),
               let data = pickerByName[AppIdentityMatcher.normalizeAppName(appName)] {
                return data
            }
            return nil
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

        // A previously-rejected config (isActive == false) is NOT a permanent
        // block — the kid can always re-submit. The parent's reject is a
        // one-time "no for now"; letting the kid ask again respects them
        // being able to explain themselves or try later. Fall through to the
        // normal pending-review creation path below.

        // Replace any stale pending review for the same token fingerprint with the
        // new request. The current token bytes win.
        var existingPending: [PendingAppReview] = {
            guard let data = storage.readRawData(forKey: AppGroupKeys.pendingReviewLocalJSON) else { return [] }
            return (try? JSONDecoder().decode([PendingAppReview].self, from: data)) ?? []
        }()
        existingPending.removeAll { $0.appFingerprint == fingerprint }
        if let encoded = try? JSONEncoder().encode(existingPending) {
            try? storage.writeRawData(encoded, forKey: AppGroupKeys.pendingReviewLocalJSON)
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
            guard let data = storage.readRawData(forKey: AppGroupKeys.pendingReviewLocalJSON) else { return [] }
            return (try? JSONDecoder().decode([PendingAppReview].self, from: data)) ?? []
        }()
        pending.append(review)
        if let encoded = try? JSONEncoder().encode(pending) {
            try? storage.writeRawData(encoded, forKey: AppGroupKeys.pendingReviewLocalJSON)
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
        guard let timestamp = defaults?.double(forKey: AppGroupKeys.internetBlockedUntil), timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        return date > now ? date : nil
    }

    /// Whether the VPN tunnel is actively blocking internet (any reason).
    var isTunnelInternetBlocked: Bool {
        let defaults = UserDefaults.appGroup
        return defaults?.bool(forKey: AppGroupKeys.tunnelInternetBlocked) == true
    }

    /// Human-readable reason the tunnel is blocking internet, if any.
    var tunnelInternetBlockedReason: String? {
        let defaults = UserDefaults.appGroup
        guard let reason = defaults?.string(forKey: AppGroupKeys.tunnelInternetBlockedReason),
              !reason.isEmpty else { return nil }
        return reason
    }

    /// Whether enforcement is currently being restored (app just came alive).
    var isRestoringEnforcement: Bool {
        let defaults = UserDefaults.appGroup
        let lastActive = defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
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
                // In restricted mode, the next transition may lead to locked
                // (MORE restrictive) rather than unlocked. Saying "Restricted
                // until 9:30 PM" is misleading when 9:30 PM is the handoff to
                // locked — the child reads it as relief coming. Report the
                // next actual unlock time, with a day-of-week prefix when it's
                // not today.
                if let nextUnlock = profile.nextTime(resolvingTo: .unlocked, from: now) {
                    let calendar = Calendar.current
                    if calendar.isDateInToday(nextUnlock) {
                        return "Restricted until \(formatter.string(from: nextUnlock))"
                    } else {
                        let dayFormatter = DateFormatter()
                        dayFormatter.dateFormat = "E h:mm a"
                        return "Restricted until \(dayFormatter.string(from: nextUnlock))"
                    }
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
        // When restricted, report the next time we'll actually be unlocked —
        // not the next boundary, since that may lead to locked (stricter).
        let boundary: Date? = inFree || inEssential
            ? profile.nextTransitionTime(from: now)
            : profile.nextTime(resolvingTo: .unlocked, from: now)
        if let transition = boundary {
            let calendar = Calendar.current
            let formatter = DateFormatter()
            if calendar.isDateInToday(transition) {
                formatter.dateFormat = "h:mm a"
            } else {
                formatter.dateFormat = "E h:mm a"
            }
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
        guard let profile = activeScheduleProfile,
              let next = profile.nextTime(resolvingTo: .unlocked, from: now) else { return nil }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(next) {
            formatter.dateFormat = "h:mm a"
            return "Available at \(formatter.string(from: next))"
        } else {
            formatter.dateFormat = "E h:mm a"
            return "Available \(formatter.string(from: next))"
        }
    }

    var needsReauthorization: Bool {
        guard appState.familyControlsAvailable else { return false }
        let current = appState.enforcement?.authorizationStatus ?? .notDetermined
        if current == .authorized { return false }
        // `.denied` is terminal — user (or ScreenTime passcode) explicitly
        // declined. Previously the code fell through to the "has persisted
        // auth type → skip button" escape, which masked Isla's iPad showing
        // FC:DENY while the Permissions button stayed hidden. Always show
        // the fixer on .denied so the parent has a visible fix path.
        if current == .denied { return true }
        // `.notDetermined` is transient: FC can take 30+ seconds to validate
        // on launch, especially for .child auth. If a persisted auth type
        // exists (app group or standard defaults), assume we're in that
        // revalidation window and avoid flashing the button at the kid.
        let appGroupType = UserDefaults.appGroup?
            .string(forKey: AppGroupKeys.authorizationType)
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
        let appName = defaults?.string(forKey: AppGroupKeys.lastShieldedAppName) ?? "nil"
        let bundleID = defaults?.string(forKey: AppGroupKeys.lastShieldedBundleID) ?? "nil"
        let tokenBase64 = defaults?.string(forKey: AppGroupKeys.lastShieldedTokenBase64)
        let timestamp = defaults?.double(forKey: AppGroupKeys.lastShieldedTimestamp) ?? 0

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
        defaults?.removeObject(forKey: AppGroupKeys.lastShieldedAppName)
        defaults?.removeObject(forKey: AppGroupKeys.lastShieldedBundleID)
        defaults?.removeObject(forKey: AppGroupKeys.lastShieldedTokenBase64)
        defaults?.removeObject(forKey: AppGroupKeys.lastShieldedTimestamp)
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
        isScheduleDriving = UserDefaults.appGroup?.bool(forKey: AppGroupKeys.scheduleDrivenMode) ?? true
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
        defaults?.set(isOK, forKey: AppGroupKeys.allPermissionsGranted)
        let enforcementOK = !needsReauthorization
        defaults?.set(enforcementOK, forKey: AppGroupKeys.enforcementPermissionsOK)

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
            defaults?.set(String(data: data, encoding: .utf8), forKey: AppGroupKeys.permissionSnapshot)
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

        // Use clock-manipulation-aware helpers: if the kid advances the
        // device date forward in Settings, isInPenaltyPhase stays true and
        // the foreground timer won't promote them into the free window
        // early. The helpers fall back to raw wall-clock when uptime data
        // is missing (e.g., after a reboot).
        let currentPhase: TimedPhase
        if info.isInPenaltyPhase(at: now) {
            currentPhase = .penalty
        } else if info.isInFreePhase(at: now) {
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
