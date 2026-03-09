import Testing
@testable import BigBrotherCore
import Foundation

@Suite("Policy Pipeline Coordinator")
struct PolicyPipelineTests {

    let deviceID = DeviceID.generate()

    private func makePolicy(
        mode: LockMode = .fullLockdown,
        version: Int64 = 1,
        temporaryUnlockUntil: Date? = nil
    ) -> Policy {
        Policy(
            targetDeviceID: deviceID,
            mode: mode,
            temporaryUnlockUntil: temporaryUnlockUntil,
            version: version
        )
    }

    private func makeInputs(
        mode: LockMode = .fullLockdown,
        version: Int64 = 1,
        source: SnapshotSource = .commandApplied,
        trigger: String? = nil,
        temporaryUnlockState: TemporaryUnlockState? = nil,
        authorizationHealth: AuthorizationHealth? = nil,
        capabilities: DeviceCapabilities? = nil,
        temporaryUnlockUntil: Date? = nil
    ) -> PolicyPipelineCoordinator.Inputs {
        PolicyPipelineCoordinator.Inputs(
            basePolicy: makePolicy(mode: mode, version: version, temporaryUnlockUntil: temporaryUnlockUntil),
            capabilities: capabilities ?? DeviceCapabilities(familyControlsAuthorized: true, isOnline: true),
            temporaryUnlockState: temporaryUnlockState,
            authorizationHealth: authorizationHealth,
            deviceID: deviceID,
            source: source,
            trigger: trigger
        )
    }

    // ==========================================================
    // #1: Snapshot generation increments version/generation
    // ==========================================================

    @Test("First snapshot gets generation 1")
    func firstSnapshotGeneration() {
        let inputs = makeInputs(source: .initial)
        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs, previousSnapshot: nil
        )
        #expect(output.snapshot.generation == 1)
        #expect(output.snapshot.source == .initial)
        #expect(!output.modeChanged)
    }

    @Test("Subsequent snapshot increments generation")
    func incrementsGeneration() {
        let inputs1 = makeInputs(mode: .fullLockdown, source: .initial)
        let output1 = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs1, previousSnapshot: nil
        )

        let inputs2 = makeInputs(mode: .unlocked, source: .commandApplied)
        let output2 = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs2, previousSnapshot: output1.snapshot
        )

        #expect(output2.snapshot.generation == 2)
        #expect(output2.modeChanged)
        #expect(output2.previousMode == .fullLockdown)
    }

    @Test("Generation always increments from previous")
    func generationAlwaysIncrements() {
        var previous: PolicySnapshot? = nil
        for i in 1...5 {
            let inputs = makeInputs(mode: .fullLockdown, version: Int64(i), source: .syncUpdate)
            let output = PolicyPipelineCoordinator.generateSnapshot(
                from: inputs, previousSnapshot: previous
            )
            #expect(output.snapshot.generation == Int64(i))
            previous = output.snapshot
        }
    }

    // ==========================================================
    // #3: No-op detection (unchanged fingerprint)
    // ==========================================================

    @Test("Same inputs produce same fingerprint")
    func sameFingerprintForSameInputs() {
        let inputs = makeInputs(mode: .fullLockdown, version: 1, source: .commandApplied)
        let output1 = PolicyPipelineCoordinator.generateSnapshot(from: inputs, previousSnapshot: nil)
        let output2 = PolicyPipelineCoordinator.generateSnapshot(from: inputs, previousSnapshot: output1.snapshot)

        #expect(output1.snapshot.policyFingerprint == output2.snapshot.policyFingerprint)
    }

    @Test("Different modes produce different fingerprints")
    func differentFingerprintsForDifferentModes() {
        let output1 = PolicyPipelineCoordinator.generateSnapshot(
            from: makeInputs(mode: .fullLockdown), previousSnapshot: nil
        )
        let output2 = PolicyPipelineCoordinator.generateSnapshot(
            from: makeInputs(mode: .unlocked), previousSnapshot: nil
        )

        #expect(output1.snapshot.policyFingerprint != output2.snapshot.policyFingerprint)
    }

    // ==========================================================
    // #6: Temp unlock start creates expected snapshot transition
    // ==========================================================

    @Test("Temporary unlock produces unlocked snapshot")
    func tempUnlockSnapshot() {
        let expiresAt = Date().addingTimeInterval(1800)
        let unlockState = TemporaryUnlockState(
            origin: .remoteCommand,
            previousMode: .fullLockdown,
            expiresAt: expiresAt
        )

        let inputs = makeInputs(
            mode: .fullLockdown,
            source: .temporaryUnlockStarted,
            temporaryUnlockState: unlockState,
            temporaryUnlockUntil: expiresAt
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(from: inputs, previousSnapshot: nil)
        #expect(output.snapshot.effectivePolicy.resolvedMode == .unlocked)
        #expect(output.snapshot.effectivePolicy.isTemporaryUnlock)
        #expect(output.snapshot.temporaryUnlockState != nil)
        #expect(output.snapshot.source == .temporaryUnlockStarted)
    }

    // ==========================================================
    // #8: Authorization degradation reflected in snapshot
    // ==========================================================

    @Test("Auth degradation reflected in snapshot")
    func authDegradationInSnapshot() {
        let degradedAuth = AuthorizationHealth(currentState: .denied)
        let inputs = makeInputs(
            mode: .fullLockdown,
            source: .authorizationChange,
            authorizationHealth: degradedAuth,
            capabilities: DeviceCapabilities(familyControlsAuthorized: false)
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(from: inputs, previousSnapshot: nil)
        #expect(output.snapshot.authorizationHealth?.enforcementDegraded == true)
        #expect(output.snapshot.effectivePolicy.warnings.contains(.familyControlsNotAuthorized))
        #expect(output.snapshot.source == .authorizationChange)
    }

    // ==========================================================
    // #9: Authorization restoration produces reconciled snapshot
    // ==========================================================

    @Test("Auth restoration produces clean snapshot")
    func authRestorationSnapshot() {
        let restoredAuth = AuthorizationHealth(
            currentState: .authorized,
            previousState: .denied
        )
        let inputs = makeInputs(
            mode: .fullLockdown,
            source: .authorizationChange,
            authorizationHealth: restoredAuth,
            capabilities: DeviceCapabilities(familyControlsAuthorized: true)
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(from: inputs, previousSnapshot: nil)
        #expect(output.snapshot.authorizationHealth?.isAuthorized == true)
        #expect(!output.snapshot.effectivePolicy.warnings.contains(.familyControlsNotAuthorized))
    }

    // ==========================================================
    // Snapshot carries context fields correctly
    // ==========================================================

    @Test("Snapshot carries deviceID and intendedMode")
    func snapshotContextFields() {
        let inputs = makeInputs(mode: .dailyMode, source: .syncUpdate, trigger: "Policy v3 from CloudKit")
        let output = PolicyPipelineCoordinator.generateSnapshot(from: inputs, previousSnapshot: nil)

        #expect(output.snapshot.deviceID == deviceID)
        #expect(output.snapshot.intendedMode == .dailyMode)
        #expect(output.snapshot.trigger == "Policy v3 from CloudKit")
    }

    @Test("modeChanged is false when mode stays the same")
    func modeUnchanged() {
        let prev = PolicyPipelineCoordinator.generateSnapshot(
            from: makeInputs(mode: .fullLockdown, version: 1, source: .initial),
            previousSnapshot: nil
        ).snapshot

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: makeInputs(mode: .fullLockdown, version: 2, source: .syncUpdate),
            previousSnapshot: prev
        )

        #expect(!output.modeChanged)
    }
}
