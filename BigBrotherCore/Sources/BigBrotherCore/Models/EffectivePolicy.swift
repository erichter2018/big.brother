import Foundation

/// The resolved policy after combining base mode, schedule, temporary unlock,
/// always-allowed apps, and device capability limitations.
///
/// This is what actually gets applied to ManagedSettingsStore.
/// Written to App Group storage as part of PolicySnapshot so extensions can read it.
public struct EffectivePolicy: Codable, Sendable, Equatable {
    /// The mode that was resolved after considering priority:
    /// temp unlock > schedule > base policy.
    public let resolvedMode: LockMode

    /// Whether this effective state is from a temporary unlock.
    public let isTemporaryUnlock: Bool

    /// When the temporary unlock expires (nil if not a temp unlock).
    public let temporaryUnlockExpiresAt: Date?

    /// Serialized category tokens to shield. Framework-specific encoding.
    /// nil = no shielding (unlocked). Empty = shield all (full lockdown).
    public let shieldedCategoriesData: Data?

    /// Serialized app tokens that are explicitly allowed (exceptions to shielding).
    public let allowedAppTokensData: Data?

    /// Warnings about enforcement limitations.
    public let warnings: [CapabilityWarning]

    /// The policy version this was resolved from.
    public let policyVersion: Int64

    /// When this effective policy was computed.
    public let resolvedAt: Date

    public init(
        resolvedMode: LockMode,
        isTemporaryUnlock: Bool = false,
        temporaryUnlockExpiresAt: Date? = nil,
        shieldedCategoriesData: Data? = nil,
        allowedAppTokensData: Data? = nil,
        warnings: [CapabilityWarning] = [],
        policyVersion: Int64,
        resolvedAt: Date = Date()
    ) {
        self.resolvedMode = resolvedMode
        self.isTemporaryUnlock = isTemporaryUnlock
        self.temporaryUnlockExpiresAt = temporaryUnlockExpiresAt
        self.shieldedCategoriesData = shieldedCategoriesData
        self.allowedAppTokensData = allowedAppTokensData
        self.warnings = warnings
        self.policyVersion = policyVersion
        self.resolvedAt = resolvedAt
    }
}

/// Warnings surfaced when the enforcement cannot fully match the intended policy.
public enum CapabilityWarning: String, Codable, Sendable, Equatable {
    /// FamilyControls .individual authorization has not been granted or was revoked.
    case familyControlsNotAuthorized

    /// Some system apps (Phone, Settings) cannot be blocked by ManagedSettings.
    case someSystemAppsCannotBeBlocked

    /// Schedule enforcement depends on DeviceActivityMonitor extension;
    /// if the app is terminated, the extension may not fire reliably.
    case scheduleMayNotFireIfAppKilled

    /// Device is offline; cached policy is being used.
    case offlineUsingCachedPolicy

    /// App-specific tokens were expected but are missing for this device.
    case tokensMissingForDevice

    /// Enforcement is degraded due to authorization loss or other issues.
    case enforcementDegraded

    /// A fail-safe mode was applied due to error recovery.
    case failSafeModeApplied
}
