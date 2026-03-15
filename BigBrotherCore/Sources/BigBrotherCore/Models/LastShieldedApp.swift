import Foundation

/// The most recently shielded app, written by ShieldConfiguration and read by ShieldAction.
///
/// When enforcement uses `shield.applicationCategories = .all()`, ShieldAction receives
/// an `ActivityCategoryToken` (no individual app info). But ShieldConfiguration still
/// receives the individual `Application` object with its token. By caching the last
/// shielded app here, ShieldAction's category handler can recover the app identity.
///
/// Timing is deterministic: ShieldConfiguration runs first (to display the shield),
/// then the user taps a button, then ShieldAction runs.
public struct LastShieldedApp: Codable, Sendable {
    /// Human-readable app name.
    public let appName: String
    /// Encoded ApplicationToken data (base64).
    public let tokenBase64: String
    /// Bundle identifier for the app.
    public let bundleID: String?
    /// When this entry was written.
    public let cachedAt: Date

    public init(appName: String, tokenBase64: String, bundleID: String? = nil, cachedAt: Date = Date()) {
        self.appName = appName
        self.tokenBase64 = tokenBase64
        self.bundleID = bundleID
        self.cachedAt = cachedAt
    }
}

/// Keychain-backed version of LastShieldedApp for cross-extension data sharing.
///
/// securityd (Keychain) works from extension processes, unlike cfprefsd (UserDefaults)
/// which detaches from the app group container in extensions.
public struct LastShieldedAppKeychain: Codable, Sendable {
    public let appName: String
    public let tokenBase64: String
    public let bundleID: String?
    public let timestamp: TimeInterval

    public init(appName: String, tokenBase64: String, bundleID: String?, timestamp: TimeInterval) {
        self.appName = appName
        self.tokenBase64 = tokenBase64
        self.bundleID = bundleID
        self.timestamp = timestamp
    }
}
