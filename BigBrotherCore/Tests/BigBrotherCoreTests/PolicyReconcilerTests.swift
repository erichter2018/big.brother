import Testing
@testable import BigBrotherCore
import Foundation

@Suite("Policy Reconciler")
struct PolicyReconcilerTests {

    let deviceID = DeviceID.generate()

    private func makeSnapshot(
        mode: LockMode = .locked,
        version: Int64 = 1,
        isTemporaryUnlock: Bool = false,
        temporaryUnlockExpiresAt: Date? = nil
    ) -> PolicySnapshot {
        PolicySnapshot(
            effectivePolicy: EffectivePolicy(
                resolvedMode: mode,
                isTemporaryUnlock: isTemporaryUnlock,
                temporaryUnlockExpiresAt: temporaryUnlockExpiresAt,
                policyVersion: version
            )
        )
    }

    // MARK: - #11: Policy reconciliation detects and repairs mismatch

    @Test("Detects mode mismatch and recommends reapply")
    func detectsMismatch() {
        let snapshot = makeSnapshot(mode: .locked)
        let action = PolicyReconciler.evaluate(
            currentSnapshot: snapshot,
            lastAppliedMode: .unlocked,
            authorizationHealth: AuthorizationHealth(currentState: .authorized),
            temporaryUnlockState: nil,
            trigger: .heartbeatCycle
        )

        if case .reapplyEnforcement(let reason) = action {
            #expect(reason.contains("drift"))
        } else {
            Issue.record("Expected reapplyEnforcement, got \(action)")
        }
    }

    @Test("No change when modes match on heartbeat cycle")
    func noChangeWhenMatching() {
        let snapshot = makeSnapshot(mode: .locked)
        let action = PolicyReconciler.evaluate(
            currentSnapshot: snapshot,
            lastAppliedMode: .locked,
            authorizationHealth: AuthorizationHealth(currentState: .authorized),
            temporaryUnlockState: nil,
            trigger: .heartbeatCycle
        )

        #expect(action == .noChangeNeeded)
    }

    @Test("Cannot enforce when no snapshot")
    func cannotEnforceWithoutSnapshot() {
        let action = PolicyReconciler.evaluate(
            currentSnapshot: nil,
            lastAppliedMode: .unlocked,
            authorizationHealth: AuthorizationHealth(currentState: .authorized),
            temporaryUnlockState: nil,
            trigger: .appLaunch
        )

        if case .cannotEnforce = action {
            // expected
        } else {
            Issue.record("Expected cannotEnforce, got \(action)")
        }
    }

    @Test("App launch with no prior mode triggers reapply")
    func appLaunchFirstEnforcement() {
        let snapshot = makeSnapshot(mode: .restricted)
        let action = PolicyReconciler.evaluate(
            currentSnapshot: snapshot,
            lastAppliedMode: nil,
            authorizationHealth: AuthorizationHealth(currentState: .authorized),
            temporaryUnlockState: nil,
            trigger: .appLaunch
        )

        if case .reapplyEnforcement(let reason) = action {
            #expect(reason.contains("launch"))
        } else {
            Issue.record("Expected reapplyEnforcement, got \(action)")
        }
    }

    @Test("Sync completed always triggers reapply")
    func syncCompletedReapply() {
        let snapshot = makeSnapshot(mode: .locked)
        let action = PolicyReconciler.evaluate(
            currentSnapshot: snapshot,
            lastAppliedMode: .locked,
            authorizationHealth: AuthorizationHealth(currentState: .authorized),
            temporaryUnlockState: nil,
            trigger: .syncCompleted
        )

        if case .reapplyEnforcement = action {
            // expected
        } else {
            Issue.record("Expected reapplyEnforcement, got \(action)")
        }
    }

    @Test("Authorization restored triggers reapply")
    func authRestoredReapply() {
        let snapshot = makeSnapshot(mode: .locked)
        let action = PolicyReconciler.evaluate(
            currentSnapshot: snapshot,
            lastAppliedMode: .locked,
            authorizationHealth: AuthorizationHealth(currentState: .authorized),
            temporaryUnlockState: nil,
            trigger: .authorizationRestored
        )

        if case .reapplyEnforcement(let reason) = action {
            #expect(reason.contains("restored"))
        } else {
            Issue.record("Expected reapplyEnforcement, got \(action)")
        }
    }

    @Test("Expired temporary unlock returns previousMode")
    func expiredTempUnlock() {
        let snapshot = makeSnapshot(mode: .unlocked, isTemporaryUnlock: true)
        let unlock = TemporaryUnlockState(
            origin: .remoteCommand,
            previousMode: .restricted,
            startedAt: Date().addingTimeInterval(-3600),
            expiresAt: Date().addingTimeInterval(-60)
        )

        let action = PolicyReconciler.evaluate(
            currentSnapshot: snapshot,
            lastAppliedMode: .unlocked,
            authorizationHealth: AuthorizationHealth(currentState: .authorized),
            temporaryUnlockState: unlock,
            trigger: .heartbeatCycle
        )

        #expect(action == .expireTemporaryUnlock(previousMode: .restricted))
    }

    @Test("Degraded enforcement when authorization denied")
    func degradedOnAuthDenied() {
        let snapshot = makeSnapshot(mode: .locked)
        let action = PolicyReconciler.evaluate(
            currentSnapshot: snapshot,
            lastAppliedMode: .locked,
            authorizationHealth: AuthorizationHealth(currentState: .denied),
            temporaryUnlockState: nil,
            trigger: .heartbeatCycle
        )

        if case .applyDegradedEnforcement(let reason) = action {
            #expect(reason.contains("denied"))
        } else {
            Issue.record("Expected applyDegradedEnforcement, got \(action)")
        }
    }
}
