import Foundation

/// Keychain keys and storage identifiers used across the app.
///
/// Centralized here to prevent key mismatches between targets.
public enum StorageKeys {

    // MARK: - Keychain Keys

    /// The device's assigned role (parent / child / unconfigured).
    public static let deviceRole = "fr.bigbrother.keychain.deviceRole"

    /// Serialized ChildEnrollmentState (child devices only).
    public static let enrollmentState = "fr.bigbrother.keychain.enrollmentState"

    /// Serialized ParentState (parent devices only).
    public static let parentState = "fr.bigbrother.keychain.parentState"

    /// PBKDF2 hash of the parent PIN.
    public static let parentPINHash = "fr.bigbrother.keychain.parentPINHash"

    /// The familyID, also stored in Keychain for tamper resistance.
    public static let familyID = "fr.bigbrother.keychain.familyID"

    /// Last-shielded app info (JSON: appName + tokenBase64 + timestamp).
    /// Written by ShieldConfiguration, read by ShieldAction.
    /// Uses Keychain (securityd) because UserDefaults (cfprefsd) and file writes
    /// fail from extension processes.
    public static let lastShieldedAppKeychain = "fr.bigbrother.keychain.lastShieldedApp"

    /// ED25519 private key for signing commands (parent only).
    public static let commandSigningPrivateKey = "fr.bigbrother.keychain.commandSigningPrivateKey"

    /// ED25519 public key for verifying command signatures (child only).
    public static let commandSigningPublicKey = "fr.bigbrother.keychain.commandSigningPublicKey"

    /// AES-256 key for encrypting sensitive App Group files.
    public static let appGroupEncryptionKey = "fr.bigbrother.keychain.appGroupEncryptionKey"

    /// PIN lockout state (Codable struct in Keychain, not UserDefaults).
    public static let pinLockoutState = "fr.bigbrother.keychain.pinLockoutState"

    /// Whether parent app requires PIN/biometric authentication.
    /// Stored in Keychain (not UserDefaults) to prevent child tampering.
    public static let parentAuthEnabled = "fr.bigbrother.keychain.parentAuthEnabled"

    // MARK: - UserDefaults Keys (App Group)

    /// Whether onboarding has been completed.
    public static let onboardingCompleted = "fr.bigbrother.onboardingCompleted"

    /// The lock mode that was last confirmed applied to ManagedSettingsStore.
    public static let lastAppliedMode = "fr.bigbrother.lastAppliedMode"

    /// When enforcement was last applied.
    public static let enforcementLastAppliedAt = "fr.bigbrother.enforcementLastAppliedAt"

    /// Whether a fail-safe mode was applied during the last recovery.
    public static let failSafeApplied = "fr.bigbrother.failSafeApplied"

    // MARK: - App Blocking

    /// App blocking configuration summary (pure-Swift model).
    public static let appBlockingConfig = "appBlockingConfig"

    /// Raw Data storage for FamilyActivitySelection (device-local opaque tokens).
    public static let familyActivitySelection = "familyActivitySelection"

    // MARK: - Per-App Allow List

    /// Serialized Set<ApplicationToken> of permanently allowed apps (device-local).
    public static let allowedAppTokens = "allowedAppTokens"

    /// Pending unlock requests with cached app tokens (device-local).
    /// Array of PendingUnlockRequest — written by ShieldAction, read by CommandProcessor.
    public static let pendingUnlockRequests = "pendingUnlockRequests"

    /// Cached app name → token mapping from ShieldConfiguration extension.
    /// Written when shields are displayed, read by ShieldAction for request details.
    public static let shieldedAppCache = "shieldedAppCache"

    /// Temporarily allowed apps with expiry times (device-local).
    /// Array of TemporaryAllowedAppEntry — written by CommandProcessor, read by Shield extensions.
    public static let temporaryAllowedApps = "temporaryAllowedApps"

    /// Per-app time limits with device-local tokens (child only).
    /// Array of AppTimeLimit — tokens + fingerprints + daily minutes.
    public static let appTimeLimits = "appTimeLimits"

    /// Apps that have exhausted their daily time budget today.
    /// Array of TimeLimitExhaustedApp — written by Monitor, read by enforcement.
    public static let timeLimitExhaustedApps = "timeLimitExhaustedApps"

    /// Enrollment IDs cached in App Group so extensions can create events
    /// without needing Keychain access (which can fail in extension context).
    public static let cachedEnrollmentIDs = "cachedEnrollmentIDs"

    // MARK: - Web Domain Allowlist

    /// JSON-encoded [String] of allowed web domains (e.g. ["google.com", "khan.org"]).
    /// Empty or missing = block all web. Used by enforcement to build shield.webDomains.
    public static let allowedWebDomains = "allowedWebDomains"

    // MARK: - Parent Messages

    /// JSON-encoded [ParentMessage] of messages sent from parent to child.
    public static let parentMessages = "parentMessages"
}
