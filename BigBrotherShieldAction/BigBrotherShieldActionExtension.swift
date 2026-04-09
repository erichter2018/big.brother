import Foundation
import ManagedSettings
import BigBrotherCore
import notify

class BigBrotherShieldActionExtension: ShieldActionDelegate {

    private static let buildMarker = "shield-action-b\(AppConstants.appBuildNumber)"

    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        // Write build number so parent can verify extension version
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(AppConstants.appBuildNumber, forKey: "shieldActionBuildNumber")
        handleAction(action: action, token: application, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handleAction(action: action, token: nil, completionHandler: completionHandler)
    }

    // MARK: - Resolve App Identity

    /// Attempt to identify the blocked app using all available channels.
    /// Returns (appName, tokenBase64, bundleID, source) or falls back to nil values.
    private func resolveAppIdentity(
        directToken: ApplicationToken?,
        storage: AppGroupStorage
    ) -> (name: String, tokenBase64: String?, bundleID: String?, source: String) {
        // Get token data from direct token (reliable for tokenBase64).
        let directBase64: String?
        let directBundle: String?
        if let directToken, let data = try? JSONEncoder().encode(directToken) {
            directBase64 = data.base64EncodedString()
            let app = Application(token: directToken)
            directBundle = app.bundleIdentifier
            diag(storage, "directToken: name=\(app.localizedDisplayName ?? "nil") bundle=\(app.bundleIdentifier ?? "nil")")
        } else {
            directBase64 = nil
            directBundle = nil
        }

        // 1. Darwin notification state bridge — ShieldConfiguration writes app name
        // to notifyd slots (bypasses file sandbox, Keychain, and cfprefsd entirely).
        if let darwinName = readDarwinName(storage: storage) {
            return (
                name: darwinName.name,
                tokenBase64: directBase64,
                bundleID: directBundle ?? darwinName.bundleID,
                source: "darwin(\(darwinName.age)s)"
            )
        }

        // 2. App Group file fallback.
        if let lastApp = storage.readLastShieldedApp(),
           lastApp.tokenBase64 != "none", !lastApp.appName.isEmpty, lastApp.appName != "App" {
            let age = -lastApp.cachedAt.timeIntervalSinceNow
            if age < 300 {
                return (
                    name: lastApp.appName,
                    tokenBase64: directBase64 ?? lastApp.tokenBase64,
                    bundleID: directBundle ?? lastApp.bundleID,
                    source: "appGroup(\(Int(age))s)"
                )
            }
        }

        // 3. Direct token only (name will be "App" but tokenBase64 is valid).
        if let base64 = directBase64 {
            return (name: "App", tokenBase64: base64, bundleID: directBundle, source: "directToken")
        }

        return (name: "", tokenBase64: nil, bundleID: nil, source: "none")
    }

    // MARK: - Action Handling

    private func handleAction(action: ShieldAction, token: ApplicationToken?, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let storage = AppGroupStorage()

        switch action {
        case .primaryButtonPressed:
            handlePrimaryButton(directToken: token, storage: storage, completionHandler: completionHandler)

        case .secondaryButtonPressed:
            handleSecondaryButton(directToken: token, storage: storage, completionHandler: completionHandler)

        @unknown default:
            completionHandler(.close)
        }
    }

    // MARK: - Pending Name Resolution

    /// Check if this is a pending-name-resolution app (1-minute probe limit).
    /// If so, auto-correct: capture name from ShieldConfiguration, set real limit, unblock.
    /// Returns true if handled (caller should return .defer).
    private func tryAutoCorrectNameResolution(identity: (name: String, tokenBase64: String?, bundleID: String?, source: String), storage: AppGroupStorage) -> Bool {
        guard let tokenBase64 = identity.tokenBase64,
              let tokenData = Data(base64Encoded: tokenBase64) else { return false }

        let fp = TokenFingerprint.fingerprint(for: tokenData)
        var limits = storage.readAppTimeLimits()
        guard let idx = limits.firstIndex(where: { $0.fingerprint == fp && $0.pendingNameResolution == true }) else {
            return false
        }

        let realName = (!identity.name.isEmpty && identity.name != "App") ? identity.name : limits[idx].appName
        let resolvedLimit = limits[idx].resolvedDailyLimitMinutes ?? 60

        diag(storage, "Name resolution: \(limits[idx].appName) → \(realName), limit 1m → \(resolvedLimit)m (src: \(identity.source))")

        limits[idx].appName = realName
        limits[idx].bundleID = identity.bundleID ?? limits[idx].bundleID
        limits[idx].dailyLimitMinutes = resolvedLimit
        limits[idx].pendingNameResolution = false
        limits[idx].resolvedDailyLimitMinutes = nil
        limits[idx].updatedAt = Date()
        try? storage.writeAppTimeLimits(limits)

        // Remove from exhausted list so the app unblocks.
        var exhausted = storage.readTimeLimitExhaustedApps()
        exhausted.removeAll { $0.fingerprint == fp }
        try? storage.writeTimeLimitExhaustedApps(exhausted)

        // Signal Monitor to re-apply enforcement.
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "needsEnforcementRefresh")

        // Update local pending review with resolved name for CloudKit sync.
        if let data = storage.readRawData(forKey: "pending_review_local.json"),
           var pendingReviews = try? JSONDecoder().decode([PendingAppReview].self, from: data),
           let reviewIdx = pendingReviews.firstIndex(where: { $0.appFingerprint == fp }) {
            pendingReviews[reviewIdx].appName = realName
            pendingReviews[reviewIdx].nameResolved = true
            pendingReviews[reviewIdx].updatedAt = Date()
            if let encoded = try? JSONEncoder().encode(pendingReviews) {
                try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
            }
        }

        return true
    }

    // MARK: - Primary Button ("OK" / "Open")

    private func handlePrimaryButton(directToken: ApplicationToken?, storage: AppGroupStorage, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let identity = resolveAppIdentity(directToken: directToken, storage: storage)

        if tryAutoCorrectNameResolution(identity: identity, storage: storage) {
            completionHandler(.defer)
            return
        }

        // Resolve pending review names — ShieldConfiguration can't write to App Group,
        // so ShieldAction does it using the name from the Keychain bridge.
        tryResolvePendingReviewName(identity: identity, storage: storage)

        var isAllowed = false
        if let base64 = identity.tokenBase64, let data = Data(base64Encoded: base64),
           let appToken = try? JSONDecoder().decode(ApplicationToken.self, from: data) {
            isAllowed = isAppAllowed(storage: storage, token: appToken, bundle: identity.bundleID)
        }
        if !isAllowed {
            isAllowed = isAppAllowed(storage: storage, token: nil, bundle: identity.bundleID)
        }

        diag(storage, "[\(Self.buildMarker)] Primary: \(identity.name) allowed=\(isAllowed) src=\(identity.source)")

        completionHandler(isAllowed ? .defer : .close)
    }

    /// Resolve pending app review name from Keychain bridge data.
    /// ShieldConfiguration writes the app name to Keychain but CANNOT write to App Group.
    /// ShieldAction bridges the gap by reading from Keychain and writing to App Group.
    private func tryResolvePendingReviewName(
        identity: (name: String, tokenBase64: String?, bundleID: String?, source: String),
        storage: AppGroupStorage
    ) {
        guard !identity.name.isEmpty, identity.name != "App",
              let tokenBase64 = identity.tokenBase64,
              let tokenData = Data(base64Encoded: tokenBase64) else {
            diag(storage, "PendingReview: skip — no valid identity (name=\(identity.name) token=\(identity.tokenBase64 != nil ? "yes" : "nil"))")
            return
        }

        let fp = TokenFingerprint.fingerprint(for: tokenData)

        guard let data = storage.readRawData(forKey: "pending_review_local.json"),
              var reviews = try? JSONDecoder().decode([PendingAppReview].self, from: data) else {
            diag(storage, "PendingReview: no local file or decode failed")
            return
        }

        let unresolved = reviews.filter { !$0.nameResolved }
        diag(storage, "PendingReview: \(reviews.count) total, \(unresolved.count) unresolved, myFP=\(fp.prefix(8)), storedFPs=\(unresolved.map { $0.appFingerprint.prefix(8) })")

        // Try fingerprint match first
        if let idx = reviews.firstIndex(where: { $0.appFingerprint == fp && !$0.nameResolved }) {
            reviews[idx].appName = identity.name
            reviews[idx].bundleID = identity.bundleID
            reviews[idx].nameResolved = true
            reviews[idx].updatedAt = Date()

            if let encoded = try? JSONEncoder().encode(reviews) {
                try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
            }
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "pendingReviewNeedsSync")
            diag(storage, "Resolved pending review (fp match): \(identity.name) fp=\(fp.prefix(8)) src=\(identity.source)")
            return
        }

        // Fingerprint didn't match — try resolving the oldest unresolved review.
        // Cross-process JSONEncoder output can differ, making fingerprints unreliable.
        if let idx = reviews.firstIndex(where: { !$0.nameResolved }) {
            diag(storage, "PendingReview: FP MISMATCH — using fallback (oldest unresolved). myFP=\(fp), storedFP=\(reviews[idx].appFingerprint)")
            reviews[idx].appName = identity.name
            reviews[idx].bundleID = identity.bundleID
            reviews[idx].nameResolved = true
            reviews[idx].updatedAt = Date()

            if let encoded = try? JSONEncoder().encode(reviews) {
                try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
            }
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "pendingReviewNeedsSync")
            diag(storage, "Resolved pending review (fallback): \(identity.name) src=\(identity.source)")
        }
    }

    // MARK: - Secondary Button ("Ask for More Time")

    private func handleSecondaryButton(directToken: ApplicationToken?, storage: AppGroupStorage, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let identity = resolveAppIdentity(directToken: directToken, storage: storage)

        // If pending name resolution, auto-correct instead of creating a request.
        if tryAutoCorrectNameResolution(identity: identity, storage: storage) {
            diag(storage, "Secondary: auto-corrected pending name resolution — unblocking app")
            completionHandler(.defer)
            return
        }

        // Resolve pending review names via Keychain bridge
        tryResolvePendingReviewName(identity: identity, storage: storage)

        // Anti-spam: ignore taps within 30s of previous.
        if let previous = storage.readUnlockPickerPendingDate(), -previous.timeIntervalSinceNow < 30 {
            completionHandler(.close)
            return
        }

        // Always set picker pending — fallback path if Keychain bridge fails.
        do {
            try storage.writeUnlockPickerPending()
        } catch {
            diag(storage, "CRITICAL: Failed to write unlock picker pending flag: \(error.localizedDescription)")
        }
        let hasToken = identity.tokenBase64 != nil

        diag(storage, "[\(Self.buildMarker)] Secondary: name=\(identity.name) hasToken=\(hasToken) src=\(identity.source)")

        if hasToken, let tokenBase64 = identity.tokenBase64 {
            // --- Token available: create full unlock request ---
            // Check if this is a time-limit-exhausted app (vs general restriction).
            let isTimeLimited = isTimeLimitExhausted(storage: storage, tokenBase64: tokenBase64)

            let success = createUnlockRequest(
                storage: storage,
                appName: identity.name,
                tokenBase64: tokenBase64,
                bundleID: identity.bundleID,
                isTimeLimitRequest: isTimeLimited
            )
            if success {
                diag(storage, "Created unlock request WITH token via \(identity.source)")
            } else {
                diag(storage, "Unlock request FAILED — child's request may not reach parent (src: \(identity.source))")
            }
        } else {
            // --- No token: picker-only flow ---
            // Do NOT create an unlockRequested event (parent can't approve without token).
            // The picker will create the proper event when child opens BigBrother.
            diag(storage, "No token — picker-only flow (no event created)")
        }

        // Call completion synchronously — extensions have very limited execution time
        // and async delays risk the extension being killed before the handler fires.
        completionHandler(.close)
    }

    // MARK: - Time Limit Check

    private func isTimeLimitExhausted(storage: AppGroupStorage, tokenBase64: String) -> Bool {
        guard let tokenData = Data(base64Encoded: tokenBase64) else { return false }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        return storage.readTimeLimitExhaustedApps()
            .filter { $0.dateString == today }
            .contains { $0.tokenData == tokenData }
    }

    // MARK: - Create Unlock Request

    @discardableResult
    private func createUnlockRequest(storage: AppGroupStorage, appName: String, tokenBase64: String, bundleID: String?, isTimeLimitRequest: Bool = false) -> Bool {
        guard let data = storage.readRawData(forKey: StorageKeys.cachedEnrollmentIDs),
              let env = try? JSONDecoder().decode(CachedEnrollmentIDs.self, from: data) else {
            diag(storage, "Cannot create request: no enrollment IDs in App Group")
            return false
        }

        let requestID = UUID()

        // Build event details with token and fingerprint.
        let fingerprint = Data(base64Encoded: tokenBase64).map { TokenFingerprint.fingerprint(for: $0) } ?? ""
        var details = isTimeLimitRequest
            ? "Requesting more time for \(appName)"
            : "Requesting access to \(appName)"
        if !fingerprint.isEmpty { details += "\nFINGERPRINT:\(fingerprint)" }
        if let b = bundleID { details += "\nBUNDLE:\(b)" }
        details += "\nTOKEN:\(tokenBase64)"

        // Event log entry (synced to CloudKit so parent sees the request).
        let entry = EventLogEntry(
            id: requestID,
            deviceID: env.deviceID,
            familyID: env.familyID,
            eventType: .unlockRequested,
            details: details
        )

        var eventLogOk = false
        do {
            try storage.appendEventLog(entry)
            eventLogOk = true
        } catch {
            diag(storage, "CRITICAL: Failed to write event log for unlock request: \(error.localizedDescription)")
        }

        // Pending unlock request (local, for CommandProcessor token lookup).
        var pendingOk = false
        if let tokenData = Data(base64Encoded: tokenBase64) {
            let pending = PendingUnlockRequest(
                id: requestID,
                appName: appName,
                tokenData: tokenData,
                requestedAt: Date()
            )
            do {
                try storage.appendPendingUnlockRequest(pending)
                pendingOk = true
            } catch {
                diag(storage, "CRITICAL: Failed to write pending unlock request: \(error.localizedDescription)")
            }
        }

        // If both writes failed, try writing a raw marker as a last resort.
        if !eventLogOk && !pendingOk {
            diag(storage, "CRITICAL: Both event log and pending request writes failed — writing fallback marker")
            try? storage.writeRawData(
                "unlock_request_\(requestID.uuidString)_\(appName)_\(Date().timeIntervalSince1970)".data(using: .utf8),
                forKey: "pending_unlock_marker"
            )
            return false
        }

        return true
    }

    // MARK: - Allowed Check

    private func isAppAllowed(storage: AppGroupStorage, token: ApplicationToken?, bundle: String?) -> Bool {
        if let token, let data = storage.readRawData(forKey: "allowedAppTokens"),
           let allowedTokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data),
           allowedTokens.contains(token) { return true }

        let tempEntries = storage.readTemporaryAllowedApps()
        if let token, let tokenData = try? JSONEncoder().encode(token) {
            for entry in tempEntries where entry.isValid && entry.tokenData == tokenData { return true }
        }

        if let bundle, !bundle.isEmpty {
            for entry in tempEntries where entry.isValid && entry.bundleID == bundle { return true }
            if let data = storage.readRawData(forKey: "allowedBundleIDs"),
               let allowedBundles = try? JSONDecoder().decode(Set<String>.self, from: data),
               allowedBundles.contains(bundle) { return true }
        }
        return false
    }

    // MARK: - Darwin Notification Name Bridge

    /// Read app name from Darwin notification state slots written by ShieldConfiguration.
    private func readDarwinName(storage: AppGroupStorage) -> (name: String, bundleID: String?, age: Int)? {
        let prefix = "group.fr.bigbrother.shared.shield"

        // Read meta slot: lower 32 bits = name length, upper 32 bits = timestamp
        guard let meta = getNotifyState("\(prefix).meta"), meta != 0 else {
            diag(storage, "Darwin: no meta slot")
            return nil
        }

        let nameLen = Int(meta & 0xFFFFFFFF)
        let timestamp = Double(meta >> 32)
        let age = Int(Date().timeIntervalSince1970) - Int(timestamp)

        guard nameLen > 0, nameLen <= 32, age < 60 else {
            diag(storage, "Darwin: meta invalid (len=\(nameLen) age=\(age)s)")
            return nil
        }

        // Read name from 8-byte chunks
        var nameBytes: [UInt8] = []
        for i in 0..<4 {
            guard let val = getNotifyState("\(prefix).n\(i)") else { break }
            for j in 0..<8 {
                let byte = UInt8((val >> (UInt64(j) * 8)) & 0xFF)
                if nameBytes.count < nameLen {
                    nameBytes.append(byte)
                }
            }
        }

        guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty, name != "App" else {
            diag(storage, "Darwin: name decode failed (bytes=\(nameBytes.count))")
            return nil
        }

        diag(storage, "Darwin bridge: name=\(name) age=\(age)s")
        return (name: name, bundleID: nil, age: age)
    }

    private func getNotifyState(_ name: String) -> UInt64? {
        var token: Int32 = 0
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return nil }
        var state: UInt64 = 0
        let result = notify_get_state(token, &state)
        notify_cancel(token)
        return result == NOTIFY_STATUS_OK ? state : nil
    }

    // MARK: - Diagnostics

    private func diag(_ storage: AppGroupStorage, _ message: String) {
        try? storage.appendDiagnosticEntry(DiagnosticEntry(category: .shieldAction, message: message))
    }
}
