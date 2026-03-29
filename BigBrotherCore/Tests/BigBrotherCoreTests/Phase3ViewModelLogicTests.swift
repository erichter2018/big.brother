import Testing
@testable import BigBrotherCore
import Foundation

/// Tests for model logic and state transitions that back the Phase 3 view models.
/// These exercise the same code paths that view models use, without requiring
/// the app target (which needs Xcode project to compile).
@Suite("Phase 3 View Model Logic")
struct Phase3ViewModelLogicTests {

    let deviceID = DeviceID.generate()
    let familyID = FamilyID.generate()
    let childProfileID = ChildProfileID.generate()

    // MARK: - Schedule Validation

    @Test("Schedule DayOfWeek display helpers")
    func dayOfWeekDisplayHelpers() {
        #expect(DayOfWeek.monday.displayName == "Monday")
        #expect(DayOfWeek.monday.shortName == "Mon")
        #expect(DayOfWeek.monday.initial == "M")
        #expect(DayOfWeek.saturday.initial == "S")
    }

    @Test("Weekdays and weekend sets are correct")
    func daySetHelpers() {
        #expect(DayOfWeek.weekdays.count == 5)
        #expect(DayOfWeek.weekend.count == 2)
        #expect(!DayOfWeek.weekdays.contains(.saturday))
        #expect(!DayOfWeek.weekdays.contains(.sunday))
        #expect(DayOfWeek.weekend.contains(.saturday))
        #expect(DayOfWeek.weekend.contains(.sunday))
    }

    @Test("DayTime comparison works")
    func dayTimeComparison() {
        let morning = DayTime(hour: 8, minute: 0)
        let afternoon = DayTime(hour: 15, minute: 0)
        #expect(morning < afternoon)
        #expect(!(afternoon < morning))
        #expect(morning.minutesSinceMidnight == 480)
    }

    @Test("Schedule round-trips through Codable")
    func scheduleRoundTrip() throws {
        let schedule = Schedule(
            childProfileID: childProfileID,
            familyID: familyID,
            name: "Bedtime",
            mode: .essentialOnly,
            daysOfWeek: DayOfWeek.weekdays,
            startTime: DayTime(hour: 20, minute: 30),
            endTime: DayTime(hour: 23, minute: 0)
        )

        let data = try JSONEncoder().encode(schedule)
        let decoded = try JSONDecoder().decode(Schedule.self, from: data)

        #expect(decoded.name == "Bedtime")
        #expect(decoded.mode == .essentialOnly)
        #expect(decoded.daysOfWeek == DayOfWeek.weekdays)
        #expect(decoded.startTime.hour == 20)
        #expect(decoded.startTime.minute == 30)
        #expect(decoded.endTime.hour == 23)
        #expect(decoded.isActive)
    }

    // MARK: - TemporaryUnlockState Logic

    @Test("TemporaryUnlockState isActive/isExpired")
    func tempUnlockState() {
        let active = TemporaryUnlockState(
            origin: .localPINUnlock,
            previousMode: .essentialOnly,
            expiresAt: Date().addingTimeInterval(1800)
        )
        #expect(active.isActive)
        #expect(!active.isExpired)
        #expect(active.remainingSeconds() > 1700)

        let expired = TemporaryUnlockState(
            origin: .remoteCommand,
            previousMode: .dailyMode,
            expiresAt: Date().addingTimeInterval(-60)
        )
        #expect(!expired.isActive)
        #expect(expired.isExpired)
        #expect(expired.remainingSeconds() == 0)
    }

    @Test("TemporaryUnlockState preserves previousMode")
    func tempUnlockPreviousMode() {
        let state = TemporaryUnlockState(
            origin: .localPINUnlock,
            previousMode: .essentialOnly,
            expiresAt: Date().addingTimeInterval(1800)
        )
        #expect(state.previousMode == .essentialOnly)
        #expect(state.origin == .localPINUnlock)
    }

    // MARK: - AuthorizationHealth

    @Test("AuthorizationHealth transitions")
    func authHealthTransitions() {
        let initial = AuthorizationHealth(currentState: .notDetermined)
        #expect(!initial.isAuthorized)

        let authorized = initial.withTransition(to: .authorized)
        #expect(authorized.isAuthorized)
        #expect(authorized.previousState == .notDetermined)

        let revoked = authorized.withTransition(to: .denied)
        #expect(!revoked.isAuthorized)
        #expect(revoked.wasRevoked)
        #expect(revoked.enforcementDegraded)
    }

    @Test("AuthorizationHealth no-op if same state")
    func authHealthNoOpTransition() {
        let authorized = AuthorizationHealth(currentState: .authorized)
        let same = authorized.withTransition(to: .authorized)
        #expect(same.lastTransitionAt == authorized.lastTransitionAt)
    }

    // MARK: - HeartbeatStatus

    @Test("HeartbeatStatus tracks failures and backoff")
    func heartbeatStatusBackoff() {
        let initial = HeartbeatStatus.initial
        #expect(initial.isHealthy)
        #expect(initial.backoffSeconds() == 0)

        let failed = initial.recordingFailure(reason: "timeout")
        #expect(!failed.isHealthy)
        #expect(failed.consecutiveFailures == 1)
        #expect(failed.backoffSeconds() > 0)

        let succeeded = failed.recordingSuccess()
        #expect(succeeded.isHealthy)
        #expect(succeeded.consecutiveFailures == 0)
    }

    // MARK: - ExtensionSharedState

    @Test("ExtensionSharedState builds from snapshot")
    func extensionSharedState() {
        let policy = EffectivePolicy(
            resolvedMode: .dailyMode,
            isTemporaryUnlock: false,
            policyVersion: 3
        )
        let snapshot = PolicySnapshot(
            deviceID: deviceID,
            effectivePolicy: policy,
            authorizationHealth: AuthorizationHealth(currentState: .authorized)
        )
        let authHealth = AuthorizationHealth(currentState: .authorized)

        let ext = ExtensionSharedState.from(
            snapshot: snapshot,
            authHealth: authHealth,
            shieldConfig: nil
        )

        #expect(ext.currentMode == .dailyMode)
        #expect(!ext.isTemporaryUnlock)
        #expect(ext.authorizationAvailable)
        #expect(!ext.enforcementDegraded)
        #expect(ext.policyVersion == 3)
    }

    @Test("ExtensionSharedState degraded when auth unavailable")
    func extensionSharedStateDegraded() {
        let policy = EffectivePolicy(resolvedMode: .essentialOnly, policyVersion: 1)
        let snapshot = PolicySnapshot(
            deviceID: deviceID,
            effectivePolicy: policy,
            authorizationHealth: AuthorizationHealth(currentState: .denied)
        )
        let authHealth = AuthorizationHealth(currentState: .denied)

        let ext = ExtensionSharedState.from(
            snapshot: snapshot,
            authHealth: authHealth,
            shieldConfig: nil
        )

        #expect(!ext.authorizationAvailable)
        #expect(ext.enforcementDegraded)
    }

    // MARK: - LockMode display

    @Test("LockMode displayName")
    func lockModeDisplayName() {
        #expect(LockMode.unlocked.displayName == "Unlocked")
        #expect(LockMode.dailyMode.displayName == "Restricted")
        #expect(LockMode.essentialOnly.displayName == "Locked")
        #expect(LockMode.lockedDown.displayName == "Locked Down")
    }

    // MARK: - DiagnosticEntry

    @Test("DiagnosticEntry round-trip")
    func diagnosticRoundTrip() throws {
        let entry = DiagnosticEntry(
            category: .enforcement,
            message: "Applied policy",
            details: "Mode: essentialOnly"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DiagnosticEntry.self, from: data)
        #expect(decoded.category == .enforcement)
        #expect(decoded.message == "Applied policy")
        #expect(decoded.details == "Mode: essentialOnly")
    }

    // MARK: - Snapshot Transition Computation

    @Test("SnapshotTransition detects mode change")
    func snapshotTransitionModeChange() {
        let prev = PolicySnapshot(
            generation: 1,
            effectivePolicy: EffectivePolicy(resolvedMode: .essentialOnly, policyVersion: 1)
        )
        let curr = PolicySnapshot(
            generation: 2,
            source: .commandApplied,
            effectivePolicy: EffectivePolicy(resolvedMode: .unlocked, policyVersion: 2)
        )

        let transition = SnapshotTransition.between(from: prev, to: curr)
        #expect(transition.fromMode == .essentialOnly)
        #expect(transition.toMode == .unlocked)
        #expect(transition.changes.contains { $0.contains("Mode:") })
    }

    // MARK: - ChildDevice online status

    @Test("ChildDevice isOnline heuristic")
    func childDeviceOnline() {
        let online = ChildDevice(
            childProfileID: childProfileID,
            familyID: familyID,
            displayName: "Test iPad",
            modelIdentifier: "iPad14,1",
            osVersion: "17.0",
            lastHeartbeat: Date().addingTimeInterval(-120)
        )
        #expect(online.isOnline)

        let offline = ChildDevice(
            childProfileID: childProfileID,
            familyID: familyID,
            displayName: "Test iPhone",
            modelIdentifier: "iPhone15,2",
            osVersion: "17.0",
            lastHeartbeat: Date().addingTimeInterval(-900)
        )
        #expect(!offline.isOnline)

        let never = ChildDevice(
            childProfileID: childProfileID,
            familyID: familyID,
            displayName: "New Device",
            modelIdentifier: "iPhone15,2",
            osVersion: "17.0"
        )
        #expect(!never.isOnline)
    }

    // MARK: - Pipeline through temp unlock

    @Test("Pipeline produces correct snapshot for local PIN unlock")
    func pipelineTempUnlock() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = AppGroupStorage(containerURL: tempDir)
        let snapshotStore = PolicySnapshotStore(storage: storage)

        // Set up initial snapshot.
        let initialPolicy = EffectivePolicy(resolvedMode: .essentialOnly, policyVersion: 1)
        let initialSnapshot = PolicySnapshot(
            generation: 1,
            deviceID: deviceID,
            effectivePolicy: initialPolicy
        )
        let initialResult = try snapshotStore.commit(initialSnapshot)
        #expect(initialResult == .committed(initialSnapshot))

        // Simulate local PIN unlock.
        let expiresAt = Date().addingTimeInterval(1800)
        let unlockState = TemporaryUnlockState(
            origin: .localPINUnlock,
            previousMode: .essentialOnly,
            expiresAt: expiresAt
        )

        let policy = Policy(
            targetDeviceID: deviceID,
            mode: .essentialOnly,
            temporaryUnlockUntil: expiresAt,
            version: 2
        )
        let capabilities = DeviceCapabilities(familyControlsAuthorized: true, isOnline: true)

        let inputs = PolicyPipelineCoordinator.Inputs(
            basePolicy: policy,
            capabilities: capabilities,
            temporaryUnlockState: unlockState,
            authorizationHealth: nil,
            deviceID: deviceID,
            source: .temporaryUnlockStarted,
            trigger: "Local PIN unlock"
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs, previousSnapshot: initialSnapshot
        )

        #expect(output.snapshot.effectivePolicy.resolvedMode == .unlocked)
        #expect(output.snapshot.effectivePolicy.isTemporaryUnlock)
        #expect(output.snapshot.generation > initialSnapshot.generation)
    }
}
