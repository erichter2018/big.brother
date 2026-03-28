import Foundation
import ManagedSettingsUI
import ManagedSettings
import BigBrotherCore

/// ShieldConfiguration extension — uses default iOS shield UI.
///
/// Still writes app identity to Keychain for ShieldAction to read,
/// but does not customize the shield appearance.
class BigBrotherShieldExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        cacheAppIdentity(application: application)
        return forceCloseShieldConfig ?? ShieldConfiguration()
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        cacheAppIdentity(application: application)
        return forceCloseShieldConfig ?? ShieldConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        return forceCloseShieldConfig ?? ShieldConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        return forceCloseShieldConfig ?? ShieldConfiguration()
    }

    /// Custom shield config shown when web is blocked due to force-close.
    private var forceCloseShieldConfig: ShieldConfiguration? {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard defaults?.bool(forKey: "forceCloseWebBlocked") == true else { return nil }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(text: "Apps Paused", color: .orange),
            subtitle: ShieldConfiguration.Label(text: "Open Big Brother to restore access.", color: .white),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .gray
        )
    }

    /// Cache the app identity to Keychain so ShieldAction can read it.
    /// Also logs diagnostics to App Group for debugging.
    private func cacheAppIdentity(application: Application) {
        let tokenData = try? application.token.map { try JSONEncoder().encode($0) }
        let tokenBase64 = tokenData?.base64EncodedString() ?? "none"
        let resolvedName = application.localizedDisplayName ?? application.bundleIdentifier ?? "App"
        let bundleID = application.bundleIdentifier

        let keychainEntry = LastShieldedAppKeychain(
            appName: resolvedName,
            tokenBase64: tokenBase64,
            bundleID: bundleID,
            timestamp: Date().timeIntervalSince1970
        )
        let keychain = KeychainManager()
        try? keychain.set(keychainEntry, forKey: StorageKeys.lastShieldedAppKeychain)

        // Write diagnostics so debugging is possible.
        let storage = AppGroupStorage()
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .shieldConfig,
            message: "shield: \(resolvedName) token=\(tokenBase64 != "none" ? "yes" : "no") bundle=\(bundleID ?? "nil")"
        ))
    }
}
