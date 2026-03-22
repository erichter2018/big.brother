import Foundation

/// Compact backend model describing current enforcement health and limitations.
///
/// Consumed by UI in Phase 3. Built from PolicySnapshot, AuthorizationHealth,
/// and TemporaryUnlockState.
public struct EnforcementStatus: Codable, Sendable, Equatable {
    /// Whether FamilyControls authorization is available.
    public let authorizationAvailable: Bool

    /// Whether a temporary unlock is currently active.
    public let temporaryUnlockActive: Bool

    /// When enforcement was last applied to ManagedSettingsStore.
    public let enforcementLastAppliedAt: Date?

    /// Whether enforcement is in a degraded state (auth missing, etc).
    public let isDegraded: Bool

    /// Whether a fail-safe mode was applied due to error recovery.
    public let failSafeApplied: Bool

    /// The currently enforced lock mode.
    public let currentMode: LockMode

    /// Whether the current mode is best-effort only (some apps may not be blocked).
    public let currentModeIsBestEffort: Bool

    /// Active capability warnings.
    public let warnings: [CapabilityWarning]

    public init(
        authorizationAvailable: Bool,
        temporaryUnlockActive: Bool = false,
        enforcementLastAppliedAt: Date? = nil,
        isDegraded: Bool = false,
        failSafeApplied: Bool = false,
        currentMode: LockMode = .dailyMode,
        currentModeIsBestEffort: Bool = false,
        warnings: [CapabilityWarning] = []
    ) {
        self.authorizationAvailable = authorizationAvailable
        self.temporaryUnlockActive = temporaryUnlockActive
        self.enforcementLastAppliedAt = enforcementLastAppliedAt
        self.isDegraded = isDegraded
        self.failSafeApplied = failSafeApplied
        self.currentMode = currentMode
        self.currentModeIsBestEffort = currentModeIsBestEffort
        self.warnings = warnings
    }

    /// Build an EnforcementStatus from available backend state.
    public static func from(
        snapshot: PolicySnapshot?,
        authHealth: AuthorizationHealth?,
        temporaryUnlockState: TemporaryUnlockState?,
        enforcementLastAppliedAt: Date?,
        failSafeApplied: Bool = false
    ) -> EnforcementStatus {
        let authAvailable = authHealth?.isAuthorized ?? false
        let tempActive = temporaryUnlockState?.isActive ?? false
        let mode = snapshot?.effectivePolicy.resolvedMode ?? .dailyMode
        let warnings = snapshot?.effectivePolicy.warnings ?? []

        let isDegraded = !authAvailable
            || warnings.contains(.familyControlsNotAuthorized)
            || failSafeApplied

        let bestEffort = mode != .unlocked && !authAvailable

        return EnforcementStatus(
            authorizationAvailable: authAvailable,
            temporaryUnlockActive: tempActive,
            enforcementLastAppliedAt: enforcementLastAppliedAt,
            isDegraded: isDegraded,
            failSafeApplied: failSafeApplied,
            currentMode: mode,
            currentModeIsBestEffort: bestEffort,
            warnings: warnings
        )
    }
}
