import Foundation

/// Canonical versioned snapshot of the currently active policy.
///
/// This is the single local source of truth for enforcement state.
/// Written by the main app to App Group storage via PolicySnapshotStore.
/// Read by the main app and all extensions.
///
/// Every meaningful policy change produces a new snapshot with an
/// incremented generation. Enforcement, reconciliation, and extensions
/// all consume this snapshot.
public struct PolicySnapshot: Sendable, Equatable {

    // MARK: - Identity

    /// Unique identifier for this snapshot.
    public let snapshotID: UUID

    /// Monotonically increasing generation number per device.
    /// Higher generation always wins in staleness checks.
    public let generation: Int64

    // MARK: - Timing

    /// When this snapshot was created.
    public let createdAt: Date

    /// When enforcement was confirmed applied (set after apply).
    public var appliedAt: Date?

    // MARK: - Source

    /// What caused this snapshot to be generated.
    public let source: SnapshotSource

    /// Human-readable trigger description for diagnostics.
    public let trigger: String?

    // MARK: - Context

    /// The device this snapshot applies to.
    public let deviceID: DeviceID?

    /// The intended mode set by the parent (before schedule/temp overrides).
    public let intendedMode: LockMode?

    /// Active schedule at the time of snapshot creation.
    public let activeScheduleID: UUID?

    // MARK: - Resolved Policy

    /// The resolved effective policy (what gets applied to enforcement).
    public let effectivePolicy: EffectivePolicy

    /// Temporary unlock metadata at time of snapshot creation.
    public let temporaryUnlockState: TemporaryUnlockState?

    // MARK: - Health

    /// Authorization health at time of snapshot creation.
    public let authorizationHealth: AuthorizationHealth?

    // MARK: - Fingerprint

    /// Quick equality check for meaningful policy state.
    /// If two snapshots have the same fingerprint, enforcement is identical.
    public let policyFingerprint: String

    // MARK: - Legacy / Compatibility

    /// The child profile associated with this device.
    public let childProfile: ChildProfile?

    /// App build number of the writer.
    public let writerVersion: Int

    /// Legacy alias for createdAt. Existing code may reference this.
    public var writtenAt: Date { createdAt }

    // MARK: - Initialization

    /// Full initializer for Phase 2.6 canonical snapshots.
    public init(
        snapshotID: UUID = UUID(),
        generation: Int64 = 1,
        createdAt: Date = Date(),
        appliedAt: Date? = nil,
        source: SnapshotSource = .initial,
        trigger: String? = nil,
        deviceID: DeviceID? = nil,
        intendedMode: LockMode? = nil,
        activeScheduleID: UUID? = nil,
        effectivePolicy: EffectivePolicy,
        temporaryUnlockState: TemporaryUnlockState? = nil,
        authorizationHealth: AuthorizationHealth? = nil,
        policyFingerprint: String? = nil,
        childProfile: ChildProfile? = nil,
        writerVersion: Int = 1
    ) {
        self.snapshotID = snapshotID
        self.generation = generation
        self.createdAt = createdAt
        self.appliedAt = appliedAt
        self.source = source
        self.trigger = trigger
        self.deviceID = deviceID
        self.intendedMode = intendedMode
        self.activeScheduleID = activeScheduleID
        self.effectivePolicy = effectivePolicy
        self.temporaryUnlockState = temporaryUnlockState
        self.authorizationHealth = authorizationHealth
        self.policyFingerprint = policyFingerprint ?? Self.computeFingerprint(
            resolvedMode: effectivePolicy.resolvedMode,
            policyVersion: effectivePolicy.policyVersion,
            isTemporaryUnlock: effectivePolicy.isTemporaryUnlock,
            authorizationState: authorizationHealth?.currentState
        )
        self.childProfile = childProfile
        self.writerVersion = writerVersion
    }

    // MARK: - Fingerprint

    /// Compute a deterministic fingerprint of the meaningful policy state.
    public static func computeFingerprint(
        resolvedMode: LockMode,
        policyVersion: Int64,
        isTemporaryUnlock: Bool,
        authorizationState: AuthorizationState?
    ) -> String {
        [
            resolvedMode.rawValue,
            "\(policyVersion)",
            "\(isTemporaryUnlock)",
            authorizationState?.rawValue ?? "unknown"
        ].joined(separator: ":")
    }
}

// MARK: - Codable (backward-compatible)

extension PolicySnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case snapshotID, generation, createdAt, appliedAt
        case source, trigger
        case deviceID, intendedMode, activeScheduleID
        case effectivePolicy
        case temporaryUnlockState, authorizationHealth
        case policyFingerprint
        case childProfile, writerVersion
        // Legacy keys
        case writtenAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Existing fields
        effectivePolicy = try container.decode(EffectivePolicy.self, forKey: .effectivePolicy)
        childProfile = try container.decodeIfPresent(ChildProfile.self, forKey: .childProfile)
        writerVersion = try container.decodeIfPresent(Int.self, forKey: .writerVersion) ?? 1

        // Phase 2.6 fields (with backward-compatible defaults)
        snapshotID = try container.decodeIfPresent(UUID.self, forKey: .snapshotID) ?? UUID()
        generation = try container.decodeIfPresent(Int64.self, forKey: .generation) ?? 1

        // Try createdAt first, fall back to legacy writtenAt
        if let created = try container.decodeIfPresent(Date.self, forKey: .createdAt) {
            createdAt = created
        } else if let written = try container.decodeIfPresent(Date.self, forKey: .writtenAt) {
            createdAt = written
        } else {
            createdAt = Date()
        }

        appliedAt = try container.decodeIfPresent(Date.self, forKey: .appliedAt)
        source = try container.decodeIfPresent(SnapshotSource.self, forKey: .source) ?? .initial
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger)
        deviceID = try container.decodeIfPresent(DeviceID.self, forKey: .deviceID)
        intendedMode = try container.decodeIfPresent(LockMode.self, forKey: .intendedMode)
        activeScheduleID = try container.decodeIfPresent(UUID.self, forKey: .activeScheduleID)
        temporaryUnlockState = try container.decodeIfPresent(TemporaryUnlockState.self, forKey: .temporaryUnlockState)
        authorizationHealth = try container.decodeIfPresent(AuthorizationHealth.self, forKey: .authorizationHealth)

        if let fp = try container.decodeIfPresent(String.self, forKey: .policyFingerprint) {
            policyFingerprint = fp
        } else {
            policyFingerprint = Self.computeFingerprint(
                resolvedMode: effectivePolicy.resolvedMode,
                policyVersion: effectivePolicy.policyVersion,
                isTemporaryUnlock: effectivePolicy.isTemporaryUnlock,
                authorizationState: nil
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(snapshotID, forKey: .snapshotID)
        try container.encode(generation, forKey: .generation)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(appliedAt, forKey: .appliedAt)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(trigger, forKey: .trigger)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(intendedMode, forKey: .intendedMode)
        try container.encodeIfPresent(activeScheduleID, forKey: .activeScheduleID)
        try container.encode(effectivePolicy, forKey: .effectivePolicy)
        try container.encodeIfPresent(temporaryUnlockState, forKey: .temporaryUnlockState)
        try container.encodeIfPresent(authorizationHealth, forKey: .authorizationHealth)
        try container.encode(policyFingerprint, forKey: .policyFingerprint)
        try container.encodeIfPresent(childProfile, forKey: .childProfile)
        try container.encode(writerVersion, forKey: .writerVersion)
    }
}
