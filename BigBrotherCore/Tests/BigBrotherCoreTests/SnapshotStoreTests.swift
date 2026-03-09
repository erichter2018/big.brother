import Testing
@testable import BigBrotherCore
import Foundation

@Suite("PolicySnapshot Store")
struct SnapshotStoreTests {

    let deviceID = DeviceID.generate()

    private func makeStorage() throws -> AppGroupStorage {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return AppGroupStorage(containerURL: tempDir)
    }

    private func makeSnapshot(
        generation: Int64 = 1,
        mode: LockMode = .fullLockdown,
        version: Int64 = 1,
        source: SnapshotSource = .commandApplied,
        authHealth: AuthorizationHealth? = nil
    ) -> PolicySnapshot {
        PolicySnapshot(
            generation: generation,
            source: source,
            deviceID: deviceID,
            intendedMode: mode,
            effectivePolicy: EffectivePolicy(
                resolvedMode: mode,
                policyVersion: version
            ),
            authorizationHealth: authHealth
        )
    }

    // ==========================================================
    // #2: Stale snapshot commit is rejected
    // ==========================================================

    @Test("Stale snapshot commit rejected")
    func staleCommitRejected() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let s1 = makeSnapshot(generation: 2, mode: .fullLockdown)
        let result1 = try store.commit(s1)
        #expect(result1 == .committed(s1))

        // Try to commit with lower generation
        let s2 = makeSnapshot(generation: 1, mode: .unlocked)
        let result2 = try store.commit(s2)
        #expect(result2 == .rejectedAsStale(currentGeneration: 2))

        // Verify original is still persisted
        let loaded = store.loadCurrentSnapshot()
        #expect(loaded?.generation == 2)
        #expect(loaded?.effectivePolicy.resolvedMode == .fullLockdown)
    }

    @Test("Same generation commit rejected")
    func sameGenerationRejected() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let s1 = makeSnapshot(generation: 1)
        _ = try store.commit(s1)

        let s2 = makeSnapshot(generation: 1, mode: .unlocked)
        let result = try store.commit(s2)
        #expect(result == .rejectedAsStale(currentGeneration: 1))
    }

    // ==========================================================
    // #3: Unchanged fingerprint returns .unchanged for routine sources
    // ==========================================================

    @Test("Unchanged fingerprint returns .unchanged for routine sources")
    func unchangedFingerprint() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let s1 = makeSnapshot(generation: 1, mode: .fullLockdown)
        _ = try store.commit(s1)

        // Same mode/version, different generation, routine source
        let s2 = makeSnapshot(generation: 2, mode: .fullLockdown, source: .syncUpdate)
        let result = try store.commit(s2)
        #expect(result == .unchanged)
    }

    @Test("Always-commit sources bypass unchanged detection")
    func alwaysCommitSourcesBypassUnchanged() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let s1 = makeSnapshot(generation: 1, mode: .fullLockdown)
        _ = try store.commit(s1)

        // Same fingerprint but restoration source → always commit
        let s2 = makeSnapshot(generation: 2, mode: .fullLockdown, source: .restoration)
        let result = try store.commit(s2)
        if case .committed = result {
            // expected
        } else {
            Issue.record("Expected committed, got \(result)")
        }
    }

    // ==========================================================
    // #4: Snapshot save/load round-trips correctly
    // ==========================================================

    @Test("Snapshot round-trips through store")
    func snapshotRoundTrip() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let authHealth = AuthorizationHealth(currentState: .authorized)
        let unlockState = TemporaryUnlockState(
            origin: .remoteCommand,
            previousMode: .dailyMode,
            expiresAt: Date().addingTimeInterval(1800)
        )

        let snapshot = PolicySnapshot(
            generation: 1,
            source: .temporaryUnlockStarted,
            trigger: "Parent sent unlock command",
            deviceID: deviceID,
            intendedMode: .dailyMode,
            effectivePolicy: EffectivePolicy(
                resolvedMode: .unlocked,
                isTemporaryUnlock: true,
                temporaryUnlockExpiresAt: Date().addingTimeInterval(1800),
                policyVersion: 3
            ),
            temporaryUnlockState: unlockState,
            authorizationHealth: authHealth,
            childProfile: nil
        )

        _ = try store.commit(snapshot)
        let loaded = store.loadCurrentSnapshot()

        #expect(loaded != nil)
        #expect(loaded?.generation == 1)
        #expect(loaded?.source == .temporaryUnlockStarted)
        #expect(loaded?.trigger == "Parent sent unlock command")
        #expect(loaded?.deviceID == deviceID)
        #expect(loaded?.intendedMode == .dailyMode)
        #expect(loaded?.effectivePolicy.resolvedMode == .unlocked)
        #expect(loaded?.effectivePolicy.isTemporaryUnlock == true)
        #expect(loaded?.temporaryUnlockState?.origin == .remoteCommand)
        #expect(loaded?.authorizationHealth?.isAuthorized == true)
    }

    @Test("Snapshot with all fields round-trips via JSON")
    func snapshotJSONRoundTrip() throws {
        let snapshot = makeSnapshot(generation: 5, mode: .essentialOnly, version: 10, source: .scheduleTransition)

        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PolicySnapshot.self, from: data)

        #expect(decoded.generation == 5)
        #expect(decoded.effectivePolicy.resolvedMode == .essentialOnly)
        #expect(decoded.effectivePolicy.policyVersion == 10)
        #expect(decoded.source == .scheduleTransition)
        #expect(decoded.deviceID == deviceID)
    }

    @Test("Legacy snapshot JSON decodes with defaults")
    func legacySnapshotDecode() throws {
        // Simulate a Phase 2 snapshot JSON (no Phase 2.6 fields)
        let legacyJSON = """
        {
            "effectivePolicy": {
                "resolvedMode": "fullLockdown",
                "isTemporaryUnlock": false,
                "warnings": [],
                "policyVersion": 1,
                "resolvedAt": 0
            },
            "writtenAt": 1000000,
            "writerVersion": 1
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(PolicySnapshot.self, from: legacyJSON)

        #expect(snapshot.effectivePolicy.resolvedMode == .fullLockdown)
        #expect(snapshot.generation == 1)
        #expect(snapshot.source == .initial)
        #expect(snapshot.writerVersion == 1)
        #expect(snapshot.policyFingerprint.contains("fullLockdown"))
    }

    // ==========================================================
    // #5: Snapshot history buffer retains recent items
    // ==========================================================

    @Test("History records transitions")
    func historyRecordsTransitions() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let s1 = makeSnapshot(generation: 1, mode: .unlocked, source: .initial)
        _ = try store.commit(s1)

        let s2 = makeSnapshot(generation: 2, mode: .fullLockdown, source: .commandApplied)
        _ = try store.commit(s2)

        let s3 = makeSnapshot(generation: 3, mode: .dailyMode, version: 2, source: .syncUpdate)
        _ = try store.commit(s3)

        let history = store.loadHistory()
        #expect(history.count == 2)  // Two transitions (s1→s2, s2→s3)

        #expect(history[0].fromMode == .unlocked)
        #expect(history[0].toMode == .fullLockdown)
        #expect(history[0].source == .commandApplied)

        #expect(history[1].fromMode == .fullLockdown)
        #expect(history[1].toMode == .dailyMode)
        #expect(history[1].source == .syncUpdate)
    }

    @Test("History is pruned to max size")
    func historyPruned() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        // Create more transitions than max
        for i in 1...Int64(AppConstants.snapshotHistoryMaxEntries + 10) {
            let mode: LockMode = i % 2 == 0 ? .fullLockdown : .unlocked
            let s = makeSnapshot(generation: i, mode: mode, version: i, source: .commandApplied)
            _ = try store.commit(s)
        }

        let history = store.loadHistory()
        #expect(history.count == AppConstants.snapshotHistoryMaxEntries)
    }

    // ==========================================================
    // #7: Temp unlock expiry restores previous mode via snapshot pipeline
    // ==========================================================

    @Test("Temp unlock expiry via pipeline restores previous mode")
    func tempUnlockExpiryViaStore() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        // 1. Create initial locked snapshot
        let s1 = makeSnapshot(generation: 1, mode: .fullLockdown, source: .initial)
        _ = try store.commit(s1)

        // 2. Create temp unlock snapshot
        let unlockState = TemporaryUnlockState(
            origin: .remoteCommand,
            previousMode: .fullLockdown,
            startedAt: Date().addingTimeInterval(-600),
            expiresAt: Date().addingTimeInterval(-60) // already expired
        )

        let s2 = PolicySnapshot(
            generation: 2,
            source: .temporaryUnlockStarted,
            effectivePolicy: EffectivePolicy(
                resolvedMode: .unlocked,
                isTemporaryUnlock: true,
                temporaryUnlockExpiresAt: Date().addingTimeInterval(-60),
                policyVersion: 1
            ),
            temporaryUnlockState: unlockState
        )
        _ = try store.commit(s2)

        // 3. Now simulate expiry — generate restoration snapshot using pipeline
        let restorationInputs = PolicyPipelineCoordinator.Inputs(
            basePolicy: Policy(
                targetDeviceID: deviceID,
                mode: unlockState.previousMode,  // fullLockdown
                version: 1
            ),
            capabilities: DeviceCapabilities(familyControlsAuthorized: true),
            source: .temporaryUnlockExpired,
            trigger: "Temporary unlock expired"
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: restorationInputs,
            previousSnapshot: store.loadCurrentSnapshot()
        )

        let result = try store.commit(output.snapshot)
        if case .committed(let committed) = result {
            #expect(committed.effectivePolicy.resolvedMode == .fullLockdown)
            #expect(committed.source == .temporaryUnlockExpired)
            #expect(committed.generation == 3)
        } else {
            Issue.record("Expected committed, got \(result)")
        }
    }

    // ==========================================================
    // #10: Enforcement reads snapshot-derived state
    // ==========================================================

    @Test("Enforcement can read committed snapshot")
    func enforcementReadsSnapshot() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let snapshot = makeSnapshot(generation: 1, mode: .dailyMode)
        _ = try store.commit(snapshot)

        // Enforcement reads from same storage
        let readSnapshot = storage.readPolicySnapshot()
        #expect(readSnapshot?.effectivePolicy.resolvedMode == .dailyMode)
    }

    // ==========================================================
    // #11: Extension shared state derived from snapshot
    // ==========================================================

    @Test("Extension state updated on commit")
    func extensionStateUpdatedOnCommit() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let authHealth = AuthorizationHealth(currentState: .authorized)
        let snapshot = PolicySnapshot(
            generation: 1,
            source: .commandApplied,
            effectivePolicy: EffectivePolicy(
                resolvedMode: .fullLockdown,
                policyVersion: 5
            ),
            authorizationHealth: authHealth
        )

        _ = try store.commit(snapshot)

        let extState = storage.readExtensionSharedState()
        #expect(extState != nil)
        #expect(extState?.currentMode == .fullLockdown)
        #expect(extState?.policyVersion == 5)
        #expect(extState?.authorizationAvailable == true)
        #expect(extState?.enforcementDegraded == false)
    }

    @Test("Extension state reflects degraded auth")
    func extensionStateDegradedAuth() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let degradedAuth = AuthorizationHealth(currentState: .denied)
        let snapshot = PolicySnapshot(
            generation: 1,
            source: .authorizationChange,
            effectivePolicy: EffectivePolicy(resolvedMode: .fullLockdown, policyVersion: 1),
            authorizationHealth: degradedAuth
        )

        _ = try store.commit(snapshot)

        let extState = storage.readExtensionSharedState()
        #expect(extState?.authorizationAvailable == false)
        #expect(extState?.enforcementDegraded == true)
    }

    // ==========================================================
    // #12: Reconciliation compares against current snapshot
    // ==========================================================

    @Test("Reconciliation uses snapshot for comparison")
    func reconciliationUsesSnapshot() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let snapshot = makeSnapshot(generation: 1, mode: .fullLockdown)
        _ = try store.commit(snapshot)

        // Reconciler should detect mismatch
        let action = PolicyReconciler.evaluate(
            currentSnapshot: store.loadCurrentSnapshot(),
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

    // ==========================================================
    // #13: Heartbeat aligns with current snapshot
    // ==========================================================

    @Test("Heartbeat can report snapshot metadata")
    func heartbeatAlignedWithSnapshot() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let snapshot = makeSnapshot(generation: 3, mode: .dailyMode, version: 7)
        _ = try store.commit(snapshot)

        let loaded = store.loadCurrentSnapshot()!
        let heartbeat = DeviceHeartbeat(
            deviceID: deviceID,
            familyID: FamilyID.generate(),
            currentMode: loaded.effectivePolicy.resolvedMode,
            policyVersion: loaded.effectivePolicy.policyVersion,
            familyControlsAuthorized: true
        )

        #expect(heartbeat.currentMode == .dailyMode)
        #expect(heartbeat.policyVersion == 7)
    }

    // ==========================================================
    // #14: Duplicate command does not create invalid snapshot
    // ==========================================================

    @Test("Duplicate command same mode detected as unchanged")
    func duplicateCommandNoInvalidSnapshot() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let s1 = makeSnapshot(generation: 1, mode: .fullLockdown, source: .commandApplied)
        _ = try store.commit(s1)

        // Same command result (same mode) — commit detects unchanged
        let s2 = makeSnapshot(generation: 2, mode: .fullLockdown, source: .commandApplied)
        let result = try store.commit(s2)
        #expect(result == .unchanged)

        // Generation stays at 1
        #expect(store.currentGeneration() == 1)
    }

    // ==========================================================
    // Additional: markApplied
    // ==========================================================

    @Test("markApplied sets appliedAt timestamp")
    func markApplied() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        let snapshot = makeSnapshot(generation: 1)
        _ = try store.commit(snapshot)

        #expect(store.loadCurrentSnapshot()?.appliedAt == nil)

        let now = Date()
        try store.markApplied(at: now)

        let loaded = store.loadCurrentSnapshot()
        #expect(loaded?.appliedAt != nil)
    }

    @Test("nextGeneration returns current + 1")
    func nextGeneration() throws {
        let storage = try makeStorage()
        let store = PolicySnapshotStore(storage: storage)

        #expect(store.nextGeneration() == 1)

        let s1 = makeSnapshot(generation: 1)
        _ = try store.commit(s1)

        #expect(store.nextGeneration() == 2)
    }

    // ==========================================================
    // Additional: SnapshotTransition.between
    // ==========================================================

    @Test("SnapshotTransition.between captures mode change")
    func transitionCapturesModeChange() {
        let s1 = makeSnapshot(generation: 1, mode: .unlocked)
        let s2 = makeSnapshot(generation: 2, mode: .fullLockdown, source: .commandApplied)

        let transition = SnapshotTransition.between(from: s1, to: s2)

        #expect(transition.fromMode == .unlocked)
        #expect(transition.toMode == .fullLockdown)
        #expect(transition.source == .commandApplied)
        #expect(transition.changes.contains(where: { $0.contains("unlocked") && $0.contains("fullLockdown") }))
    }

    @Test("SnapshotTransition.between notes no change")
    func transitionNotesNoChange() {
        let s1 = makeSnapshot(generation: 1, mode: .fullLockdown, version: 1)
        let s2 = makeSnapshot(generation: 2, mode: .fullLockdown, version: 1, source: .restoration)

        let transition = SnapshotTransition.between(from: s1, to: s2)

        #expect(transition.fromMode == .fullLockdown)
        #expect(transition.toMode == .fullLockdown)
        #expect(transition.changes.contains(where: { $0.contains("no policy change") }))
    }
}
