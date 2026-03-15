import Foundation
import ManagedSettingsUI
import ManagedSettings
import BigBrotherCore

class BigBrotherShieldExtension: ShieldConfigurationDataSource {

    private static let buildMarker = "shield-config-2026-03-15A"

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        return handleConfiguration(appName: application.localizedDisplayName, bundleID: application.bundleIdentifier, token: application.token)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        return handleConfiguration(appName: application.localizedDisplayName, bundleID: application.bundleIdentifier, token: application.token)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        return handleConfiguration(appName: webDomain.domain, bundleID: nil, token: nil, isWeb: true)
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        return handleConfiguration(appName: webDomain.domain, bundleID: nil, token: nil, isWeb: true)
    }

    private func handleConfiguration(appName: String?, bundleID: String?, token: ApplicationToken?, isWeb: Bool = false) -> ShieldConfiguration {
        let storage = AppGroupStorage()
        let resolvedName = appName ?? bundleID ?? (isWeb ? "Website" : "Blocked App")

        // Encode token for storage.
        let tokenData = try? token.map { try JSONEncoder().encode($0) }
        let tokenBase64 = tokenData?.base64EncodedString() ?? "none"

        // --- PRIMARY BRIDGE: Keychain (securityd) ---
        // ShieldConfiguration CANNOT write to App Group files (sandbox).
        // Keychain uses securityd which is a separate service, not the file sandbox.
        let keychainEntry = LastShieldedAppKeychain(
            appName: resolvedName,
            tokenBase64: tokenBase64,
            bundleID: bundleID,
            timestamp: Date().timeIntervalSince1970
        )
        let keychain = KeychainManager()
        do {
            try keychain.set(keychainEntry, forKey: StorageKeys.lastShieldedAppKeychain)
        } catch {
            // Keychain write failed — ShieldAction will fall back to picker flow.
            // No way to report this from ShieldConfiguration (all write channels blocked).
        }

        // --- SECONDARY: App Group file (may fail from this extension) ---
        let lastApp = LastShieldedApp(appName: resolvedName, tokenBase64: tokenBase64, bundleID: bundleID, cachedAt: Date())
        try? storage.writeLastShieldedApp(lastApp)
        try? storage.appendDiagnosticEntry(DiagnosticEntry(category: .shieldConfig, message: "[\(Self.buildMarker)] \(resolvedName) token=\(tokenBase64 != "none" ? "yes" : "no") bundle=\(bundleID ?? "nil")"))

        // Check if this app is already allowed (race condition: parent just approved).
        if isAppAllowed(storage: storage, token: token, bundle: bundleID) {
            return ShieldConfiguration(
                backgroundBlurStyle: .systemThickMaterial,
                title: ShieldConfiguration.Label(text: resolvedName, color: .white),
                subtitle: ShieldConfiguration.Label(text: "This app is allowed. Tap Open to launch.", color: .init(white: 0.8, alpha: 1.0)),
                primaryButtonLabel: ShieldConfiguration.Label(text: "Open", color: .white),
                primaryButtonBackgroundColor: .systemGreen
            )
        }

        let config = storage.readShieldConfiguration()
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(text: resolvedName, color: .white),
            subtitle: ShieldConfiguration.Label(text: config?.message ?? "This app is restricted.", color: .init(white: 0.8, alpha: 1.0)),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue,
            secondaryButtonLabel: ShieldConfiguration.Label(text: "Ask for More Time", color: .systemBlue)
        )
    }

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
}
