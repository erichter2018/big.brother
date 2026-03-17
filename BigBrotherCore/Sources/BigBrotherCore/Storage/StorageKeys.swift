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

    /// bcrypt hash of the parent PIN.
    public static let parentPINHash = "fr.bigbrother.keychain.parentPINHash"

    /// The familyID, also stored in Keychain for tamper resistance.
    public static let familyID = "fr.bigbrother.keychain.familyID"

    /// Last-shielded app info (JSON: appName + tokenBase64 + timestamp).
    /// Written by ShieldConfiguration, read by ShieldAction.
    /// Uses Keychain (securityd) because UserDefaults (cfprefsd) and file writes
    /// fail from extension processes.
    public static let lastShieldedAppKeychain = "fr.bigbrother.keychain.lastShieldedApp"

    // MARK: - UserDefaults Keys (App Group)

    /// Whether onboarding has been completed.
    public static let onboardingCompleted = "fr.bigbrother.onboardingCompleted"

    /// The number of consecutive failed PIN attempts.
    public static let failedPINAttempts = "fr.bigbrother.failedPINAttempts"

    /// Timestamp of the last PIN lockout.
    public static let pinLockoutUntil = "fr.bigbrother.pinLockoutUntil"

    /// Number of consecutive lockouts (escalating: 5m → 15m → 1h → 4h).
    public static let pinLockoutStreak = "fr.bigbrother.pinLockoutStreak"

    /// The lock mode that was last confirmed applied to ManagedSettingsStore.
    public static let lastAppliedMode = "fr.bigbrother.lastAppliedMode"

    /// When enforcement was last applied.
    public static let enforcementLastAppliedAt = "fr.bigbrother.enforcementLastAppliedAt"

    /// Whether a fail-safe mode was applied during the last recovery.
    public static let failSafeApplied = "fr.bigbrother.failSafeApplied"

    /// Whether parent app requires PIN/biometric authentication.
    /// When false, ParentGate is bypassed even if a PIN is configured.
    public static let parentAuthEnabled = "fr.bigbrother.parentAuthEnabled"

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

    /// Enrollment IDs cached in App Group so extensions can create events
    /// without needing Keychain access (which can fail in extension context).
    public static let cachedEnrollmentIDs = "cachedEnrollmentIDs"

    // MARK: - Web Domain Allowlist

    /// JSON-encoded [String] of allowed web domains (e.g. ["google.com", "khan.org"]).
    /// Empty or missing = block all web. Used by enforcement to build shield.webDomains.
    public static let allowedWebDomains = "allowedWebDomains"
}
