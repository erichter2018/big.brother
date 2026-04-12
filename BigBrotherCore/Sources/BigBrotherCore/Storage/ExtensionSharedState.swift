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
///
/// ## This is a CACHE, not a source of truth
///
/// `currentMode` below is the mode the last writer committed, which can
/// drift from what `ModeStackResolver.resolve()` would say right now
/// (temp unlock expired, schedule window rolled over, lockUntil elapsed).
/// Consumers asking "what mode is the device in?" should call
/// `ModeStackResolver.resolve(storage:)` instead of reading this field
/// directly. The one legitimate use is the ShieldConfiguration extension,
/// which runs on every shield render and cannot afford the full resolver
/// I/O — it treats this as an acceptable staleness trade-off.
///
/// The tunnel's `seedBlockReasonsOnStart` reads `currentMode` as a seed
/// signal, but cross-checks against freshness (see `seedBlockReasonsOnStart`
/// for the 2h staleness threshold).
public struct ExtensionSharedState: Codable, Sendable, Equatable {
    /// Mode at the last enforcement write. See the type-level note above:
    /// do NOT use this as "what mode is the device in right now" — call
    /// `ModeStackResolver.resolve()` for that.
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
