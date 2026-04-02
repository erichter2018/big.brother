import Foundation

/// Lightweight read model for extension consumption.
///
/// Extensions (DeviceActivityMonitor, ShieldConfiguration, ShieldAction)
/// need a minimal, fast-to-decode view of enforcement state.
/// This struct provides exactly what extensions need without requiring
/// them to parse the full PolicySnapshot.
///
/// Written by the main app whenever enforcement state changes.
/// Read by extensions on demand.
public struct ExtensionSharedState: Codable, Sendable, Equatable {
    /// The currently enforced lock mode.
    public let currentMode: LockMode

    /// Whether a temporary unlock is active.
    public let isTemporaryUnlock: Bool

    /// When the temporary unlock expires (nil if not active).
    public let temporaryUnlockExpiresAt: Date?

    /// Whether FamilyControls authorization is available.
    public let authorizationAvailable: Bool

    /// Whether enforcement is in a degraded state.
    public let enforcementDegraded: Bool

    /// Shield configuration for the ShieldConfiguration extension.
    public let shieldConfig: ShieldConfig

    /// When this state was written.
    public let writtenAt: Date

    /// The policy version this state was derived from.
    public let policyVersion: Int64

    /// Who is currently driving enforcement (schedule, parent, temp unlock, etc.).
    /// nil for backward compatibility with old state files (treated as .schedule).
    public let controlAuthority: ControlAuthority?

    public init(
        currentMode: LockMode,
        isTemporaryUnlock: Bool = false,
        temporaryUnlockExpiresAt: Date? = nil,
        authorizationAvailable: Bool = true,
        enforcementDegraded: Bool = false,
        shieldConfig: ShieldConfig = ShieldConfig(),
        writtenAt: Date = Date(),
        policyVersion: Int64 = 0,
        controlAuthority: ControlAuthority? = nil
    ) {
        self.currentMode = currentMode
        self.isTemporaryUnlock = isTemporaryUnlock
        self.temporaryUnlockExpiresAt = temporaryUnlockExpiresAt
        self.authorizationAvailable = authorizationAvailable
        self.enforcementDegraded = enforcementDegraded
        self.shieldConfig = shieldConfig
        self.writtenAt = writtenAt
        self.policyVersion = policyVersion
        self.controlAuthority = controlAuthority
    }

    /// Build from available backend state.
    public static func from(
        snapshot: PolicySnapshot?,
        authHealth: AuthorizationHealth?,
        shieldConfig: ShieldConfig?
    ) -> ExtensionSharedState {
        let policy = snapshot?.effectivePolicy
        let authAvailable = authHealth?.isAuthorized ?? false

        return ExtensionSharedState(
            currentMode: policy?.resolvedMode ?? .restricted,
            isTemporaryUnlock: policy?.isTemporaryUnlock ?? false,
            temporaryUnlockExpiresAt: policy?.temporaryUnlockExpiresAt,
            authorizationAvailable: authAvailable,
            enforcementDegraded: !authAvailable && (policy?.resolvedMode ?? .restricted) != .unlocked,
            shieldConfig: shieldConfig ?? ShieldConfig(),
            writtenAt: Date(),
            policyVersion: policy?.policyVersion ?? 0,
            controlAuthority: policy?.controlAuthority
        )
    }
}
