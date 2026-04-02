import Foundation

/// Canonical pipeline for generating PolicySnapshots.
///
/// This is a pure function: no side effects, no framework dependencies, no storage.
/// Given all inputs, it produces a new PolicySnapshot ready for commit.
///
/// All policy-changing events should flow through this coordinator:
/// - Command applied (setMode, temporaryUnlock)
/// - Temporary unlock started / expired
/// - Sync pulled newer policy
/// - App launch restoration
/// - Schedule transition
/// - Authorization state change
/// - Fail-safe mode activation
public struct PolicyPipelineCoordinator {

    /// All inputs needed to generate a canonical snapshot.
    public struct Inputs: Sendable {
        public let basePolicy: Policy
        public let schedule: Schedule?
        public let currentTime: Date
        public let alwaysAllowedTokensData: Data?
        public let alwaysAllowedCategories: Set<String>
        public let capabilities: DeviceCapabilities
        public let temporaryUnlockState: TemporaryUnlockState?
        public let authorizationHealth: AuthorizationHealth?
        public let childProfile: ChildProfile?
        public let deviceID: DeviceID?
        public let source: SnapshotSource
        public let trigger: String?
        public let controlAuthority: ControlAuthority?
        public let deviceRestrictions: DeviceRestrictions?

        public init(
            basePolicy: Policy,
            schedule: Schedule? = nil,
            currentTime: Date = Date(),
            alwaysAllowedTokensData: Data? = nil,
            alwaysAllowedCategories: Set<String> = [],
            capabilities: DeviceCapabilities,
            temporaryUnlockState: TemporaryUnlockState? = nil,
            authorizationHealth: AuthorizationHealth? = nil,
            childProfile: ChildProfile? = nil,
            deviceID: DeviceID? = nil,
            source: SnapshotSource,
            trigger: String? = nil,
            controlAuthority: ControlAuthority? = nil,
            deviceRestrictions: DeviceRestrictions? = nil
        ) {
            self.basePolicy = basePolicy
            self.schedule = schedule
            self.currentTime = currentTime
            self.alwaysAllowedTokensData = alwaysAllowedTokensData
            self.alwaysAllowedCategories = alwaysAllowedCategories
            self.capabilities = capabilities
            self.temporaryUnlockState = temporaryUnlockState
            self.authorizationHealth = authorizationHealth
            self.childProfile = childProfile
            self.deviceID = deviceID
            self.source = source
            self.trigger = trigger
            self.controlAuthority = controlAuthority
            self.deviceRestrictions = deviceRestrictions
        }
    }

    /// The output of snapshot generation.
    public struct Output: Sendable {
        /// The newly generated snapshot.
        public let snapshot: PolicySnapshot

        /// Whether the effective mode changed from the previous snapshot.
        public let modeChanged: Bool

        /// The previous mode, if there was a previous snapshot.
        public let previousMode: LockMode?
    }

    /// Generate a new PolicySnapshot from the given inputs.
    ///
    /// This is the single canonical path for all policy changes.
    /// Uses PolicyResolver for policy resolution, then wraps the result
    /// in a fully populated PolicySnapshot.
    ///
    /// - Parameters:
    ///   - inputs: All policy inputs.
    ///   - previousSnapshot: The current snapshot (for generation numbering and diff).
    /// - Returns: The generated snapshot and change metadata.
    public static func generateSnapshot(
        from inputs: Inputs,
        previousSnapshot: PolicySnapshot?
    ) -> Output {
        // 1. Resolve effective policy using existing PolicyResolver
        let effective = PolicyResolver.resolve(
            basePolicy: inputs.basePolicy,
            schedule: inputs.schedule,
            currentTime: inputs.currentTime,
            alwaysAllowedTokensData: inputs.alwaysAllowedTokensData,
            alwaysAllowedCategories: inputs.alwaysAllowedCategories,
            capabilities: inputs.capabilities,
            controlAuthority: inputs.controlAuthority,
            deviceRestrictions: inputs.deviceRestrictions
        )

        // 2. Compute generation
        let generation = (previousSnapshot?.generation ?? 0) + 1

        // 3. Build snapshot
        let snapshot = PolicySnapshot(
            generation: generation,
            createdAt: inputs.currentTime,
            source: inputs.source,
            trigger: inputs.trigger,
            deviceID: inputs.deviceID,
            intendedMode: inputs.basePolicy.mode,
            activeScheduleID: inputs.schedule?.id,
            effectivePolicy: effective,
            temporaryUnlockState: inputs.temporaryUnlockState,
            authorizationHealth: inputs.authorizationHealth,
            childProfile: inputs.childProfile
        )

        // 4. Detect mode change
        let previousMode = previousSnapshot?.effectivePolicy.resolvedMode
        let modeChanged = previousMode != nil && previousMode != effective.resolvedMode

        return Output(
            snapshot: snapshot,
            modeChanged: modeChanged,
            previousMode: previousMode
        )
    }
}
