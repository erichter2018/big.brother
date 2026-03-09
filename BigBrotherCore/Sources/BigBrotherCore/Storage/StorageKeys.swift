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

    // MARK: - UserDefaults Keys (App Group)

    /// Whether onboarding has been completed.
    public static let onboardingCompleted = "fr.bigbrother.onboardingCompleted"

    /// The number of consecutive failed PIN attempts.
    public static let failedPINAttempts = "fr.bigbrother.failedPINAttempts"

    /// Timestamp of the last PIN lockout.
    public static let pinLockoutUntil = "fr.bigbrother.pinLockoutUntil"

    /// The lock mode that was last confirmed applied to ManagedSettingsStore.
    public static let lastAppliedMode = "fr.bigbrother.lastAppliedMode"

    /// When enforcement was last applied.
    public static let enforcementLastAppliedAt = "fr.bigbrother.enforcementLastAppliedAt"

    /// Whether a fail-safe mode was applied during the last recovery.
    public static let failSafeApplied = "fr.bigbrother.failSafeApplied"
}
