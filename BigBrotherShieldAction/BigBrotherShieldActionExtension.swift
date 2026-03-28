import Foundation
import ManagedSettings
import BigBrotherCore

class BigBrotherShieldActionExtension: ShieldActionDelegate {

    private static let buildMarker = "shield-action-2026-03-15A"

    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
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
        // 1. Direct token from application handler (only fires for shield.applications, not categories).
        if let directToken, let data = try? JSONEncoder().encode(directToken) {
            let base64 = data.base64EncodedString()
            // Try to resolve the app name from the token — works in some extension contexts.
            let app = Application(token: directToken)
            let resolvedName = app.localizedDisplayName ?? app.bundleIdentifier ?? "App"
            let resolvedBundle = app.bundleIdentifier
            diag(storage, "directToken resolve: name=\(app.localizedDisplayName ?? "nil") bundle=\(app.bundleIdentifier ?? "nil")")
            return (name: resolvedName, tokenBase64: base64, bundleID: resolvedBundle, source: "directToken")
        }

        // 2. Keychain bridge — written by ShieldConfiguration (securityd, not file sandbox).
        let keychain = KeychainManager()
        if let cached = try? keychain.get(LastShieldedAppKeychain.self, forKey: StorageKeys.lastShieldedAppKeychain) {
            let age = Date().timeIntervalSince1970 - cached.timestamp
            if age < 30, cached.tokenBase64 != "none", !cached.appName.isEmpty {
                return (
                    name: cached.appName,
                    tokenBase64: cached.tokenBase64,
                    bundleID: cached.bundleID,
                    source: "keychain(\(Int(age))s)"
                )
            }
            // Stale or sentinel — log but don't use.
            diag(storage, "Keychain entry stale/invalid: age=\(Int(age))s name=\(cached.appName) token=\(cached.tokenBase64 == "none" ? "none" : "present")")
        } else {
            diag(storage, "Keychain read: no entry found")
        }

        // 3. App Group file — written by ShieldConfiguration (may fail from that extension).
        if let lastApp = storage.readLastShieldedApp(),
           lastApp.tokenBase64 != "none", !lastApp.appName.isEmpty {
            let age = -lastApp.cachedAt.timeIntervalSinceNow
            if age < 30 {
                return (
                    name: lastApp.appName,
                    tokenBase64: lastApp.tokenBase64,
                    bundleID: lastApp.bundleID,
                    source: "appGroup(\(Int(age))s)"
                )
            }
            diag(storage, "App Group entry stale: age=\(Int(age))s name=\(lastApp.appName)")
        } else {
            diag(storage, "App Group read: no valid entry (sentinel or missing)")
        }

        // 4. No identity available.
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

    // MARK: - Primary Button ("OK" / "Open")

    private func handlePrimaryButton(directToken: ApplicationToken?, storage: AppGroupStorage, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let identity = resolveAppIdentity(directToken: directToken, storage: storage)

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

    // MARK: - Secondary Button ("Ask for More Time")

    private func handleSecondaryButton(directToken: ApplicationToken?, storage: AppGroupStorage, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        // Anti-spam: ignore taps within 5s of previous.
        if let previous = storage.readUnlockPickerPendingDate(), -previous.timeIntervalSinceNow < 5 {
            completionHandler(.close)
            return
        }

        // Always set picker pending — fallback path if Keychain bridge fails.
        try? storage.writeUnlockPickerPending()

        let identity = resolveAppIdentity(directToken: directToken, storage: storage)
        let hasToken = identity.tokenBase64 != nil

        diag(storage, "[\(Self.buildMarker)] Secondary: name=\(identity.name) hasToken=\(hasToken) src=\(identity.source)")

        if hasToken, let tokenBase64 = identity.tokenBase64 {
            // --- Token available: create full unlock request ---
            createUnlockRequest(
                storage: storage,
                appName: identity.name,
                tokenBase64: tokenBase64,
                bundleID: identity.bundleID
            )
            diag(storage, "Created unlock request WITH token via \(identity.source)")
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

    // MARK: - Create Unlock Request

    private func createUnlockRequest(storage: AppGroupStorage, appName: String, tokenBase64: String, bundleID: String?) {
        guard let data = storage.readRawData(forKey: StorageKeys.cachedEnrollmentIDs),
              let env = try? JSONDecoder().decode(CachedEnrollmentIDs.self, from: data) else {
            diag(storage, "Cannot create request: no enrollment IDs in App Group")
            return
        }

        let requestID = UUID()

        // Build event details with token.
        var details = "Requesting access to \(appName)"
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
        try? storage.appendEventLog(entry)

        // Pending unlock request (local, for CommandProcessor token lookup).
        if let tokenData = Data(base64Encoded: tokenBase64) {
            let pending = PendingUnlockRequest(
                id: requestID,
                appName: appName,
                tokenData: tokenData,
                requestedAt: Date()
            )
            try? storage.appendPendingUnlockRequest(pending)
        }
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

    // MARK: - Diagnostics

    private func diag(_ storage: AppGroupStorage, _ message: String) {
        try? storage.appendDiagnosticEntry(DiagnosticEntry(category: .shieldAction, message: message))
    }
}
