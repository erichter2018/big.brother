import Testing
@testable import BigBrotherCore
import Foundation

@Suite("Phase 2.5 Hardening")
struct HardeningTests {

    let deviceID = DeviceID.generate()
    let familyID = FamilyID.generate()

    private func makeStorage() throws -> AppGroupStorage {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return AppGroupStorage(containerURL: tempDir)
    }

    // ==========================================================
    // #1: Processed command persistence survives restart
    // ==========================================================

    @Test("Processed command IDs survive storage reload")
    func processedCommandsSurviveRestart() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id1 = UUID()
        let id2 = UUID()

        // Write with one instance
        let storage1 = AppGroupStorage(containerURL: tempDir)
        try storage1.markCommandProcessed(id1)
        try storage1.markCommandProcessed(id2)

        // Read with a new instance (simulates app restart)
        let storage2 = AppGroupStorage(containerURL: tempDir)
        let ids = storage2.readProcessedCommandIDs()

        #expect(ids.contains(id1))
        #expect(ids.contains(id2))
        #expect(ids.count == 2)
    }

    // ==========================================================
    // #2: Duplicate command does not produce duplicate receipt
    // ==========================================================

    @Test("CommandProcessingResult.ignoredDuplicate does not post receipt")
    func duplicateCommandNoReceipt() {
        let result = CommandProcessingResult.ignoredDuplicate
        #expect(!result.shouldPostReceipt)
        #expect(result.receiptStatus == nil)
    }

    @Test("Applied command should post receipt")
    func appliedCommandPostsReceipt() {
        let result = CommandProcessingResult.applied
        #expect(result.shouldPostReceipt)
        #expect(result.receiptStatus == .applied)
    }

    // ==========================================================
    // #3: Expired command is ignored correctly
    // ==========================================================

    @Test("Expired command result is correct")
    func expiredCommandResult() {
        let result = CommandProcessingResult.ignoredExpired
        #expect(!result.shouldPostReceipt)
        #expect(result.receiptStatus == .expired)
        #expect(result.logReason.contains("expired"))
    }

    @Test("Failed validation records reason")
    func failedValidationReason() {
        let result = CommandProcessingResult.failedValidation(reason: "malformed action")
        #expect(result.shouldPostReceipt)
        #expect(result.receiptStatus == .failed)
        #expect(result.logReason.contains("malformed action"))
    }

    // ==========================================================
    // #4: Heartbeat failure increments failure state
    // ==========================================================

    @Test("Heartbeat failure increments consecutive failures")
    func heartbeatFailureIncrements() {
        let status = HeartbeatStatus.initial
        let failed1 = status.recordingFailure(reason: "network error")
        #expect(failed1.consecutiveFailures == 1)
        #expect(failed1.lastFailureReason == "network error")
        #expect(!failed1.isHealthy)

        let failed2 = failed1.recordingFailure(reason: "timeout")
        #expect(failed2.consecutiveFailures == 2)
        #expect(failed2.lastFailureReason == "timeout")
    }

    @Test("Heartbeat backoff increases with failures")
    func heartbeatBackoff() {
        let status = HeartbeatStatus.initial
        #expect(status.backoffSeconds() == 0)

        let failed1 = status.recordingFailure(reason: "error")
        #expect(failed1.backoffSeconds() == 20) // 10 * 2^1

        let failed3 = failed1
            .recordingFailure(reason: "error")
            .recordingFailure(reason: "error")
        #expect(failed3.backoffSeconds() == 80) // 10 * 2^3
    }

    // ==========================================================
    // #5: Heartbeat success clears failure streak
    // ==========================================================

    @Test("Heartbeat success clears failure count")
    func heartbeatSuccessClearsFailures() {
        let status = HeartbeatStatus.initial
            .recordingFailure(reason: "error1")
            .recordingFailure(reason: "error2")
            .recordingFailure(reason: "error3")

        #expect(status.consecutiveFailures == 3)

        let success = status.recordingSuccess()
        #expect(success.consecutiveFailures == 0)
        #expect(success.isHealthy)
        #expect(success.lastFailureReason == nil)
        #expect(success.lastSuccessAt != nil)
    }

    @Test("Heartbeat status persists through storage")
    func heartbeatStatusPersistence() throws {
        let storage = try makeStorage()
        let status = HeartbeatStatus.initial
            .recordingFailure(reason: "network")
            .recordingSuccess()

        try storage.writeHeartbeatStatus(status)
        let loaded = storage.readHeartbeatStatus()

        #expect(loaded != nil)
        #expect(loaded?.consecutiveFailures == 0)
        #expect(loaded?.isHealthy == true)
    }

    // ==========================================================
    // #6: Temporary unlock restores previous mode after relaunch
    // ==========================================================

    @Test("Temporary unlock state round-trips with previous mode")
    func tempUnlockPreviousMode() throws {
        let storage = try makeStorage()
        let unlock = TemporaryUnlockState(
            origin: .remoteCommand,
            previousMode: .dailyMode,
            startedAt: Date().addingTimeInterval(-600),
            expiresAt: Date().addingTimeInterval(-60),
            commandID: UUID()
        )

        try storage.writeTemporaryUnlockState(unlock)

        // Simulate relaunch — new storage pointing at same dir
        let loaded = storage.readTemporaryUnlockState()
        #expect(loaded != nil)
        #expect(loaded?.previousMode == .dailyMode)
        #expect(loaded?.origin == .remoteCommand)
        #expect(loaded?.isExpired == true)

        // Reconciler should detect the expiry
        let snapshot = PolicySnapshot(
            effectivePolicy: EffectivePolicy(resolvedMode: .unlocked, policyVersion: 1)
        )
        let action = PolicyReconciler.evaluate(
            currentSnapshot: snapshot,
            lastAppliedMode: .unlocked,
            authorizationHealth: AuthorizationHealth(currentState: .authorized),
            temporaryUnlockState: loaded,
            trigger: .appLaunch
        )
        #expect(action == .expireTemporaryUnlock(previousMode: .dailyMode))
    }

    @Test("Local PIN unlock stores origin correctly")
    func localPINUnlockOrigin() throws {
        let storage = try makeStorage()
        let unlock = TemporaryUnlockState(
            origin: .localPINUnlock,
            previousMode: .fullLockdown,
            expiresAt: Date().addingTimeInterval(1800)
        )

        try storage.writeTemporaryUnlockState(unlock)
        let loaded = storage.readTemporaryUnlockState()

        #expect(loaded?.origin == .localPINUnlock)
        #expect(loaded?.previousMode == .fullLockdown)
        #expect(loaded?.isActive == true)
    }

    @Test("Clearing temporary unlock state")
    func clearTempUnlock() throws {
        let storage = try makeStorage()
        let unlock = TemporaryUnlockState(
            origin: .remoteCommand,
            previousMode: .dailyMode,
            expiresAt: Date().addingTimeInterval(1800)
        )
        try storage.writeTemporaryUnlockState(unlock)
        #expect(storage.readTemporaryUnlockState() != nil)

        try storage.clearTemporaryUnlockState()
        #expect(storage.readTemporaryUnlockState() == nil)
    }

    // ==========================================================
    // #7: Authorization loss creates degraded state
    // ==========================================================

    @Test("Authorization loss records degraded state")
    func authorizationLossDegraded() throws {
        let storage = try makeStorage()
        let health = AuthorizationHealth(currentState: .authorized)
        let degraded = health.withTransition(to: .revoked)

        #expect(degraded.wasRevoked)
        #expect(degraded.enforcementDegraded)
        #expect(!degraded.isAuthorized)
        #expect(degraded.previousState == .authorized)

        try storage.writeAuthorizationHealth(degraded)
        let loaded = storage.readAuthorizationHealth()

        #expect(loaded?.currentState == .revoked)
        #expect(loaded?.enforcementDegraded == true)
        #expect(loaded?.wasRevoked == true)
    }

    @Test("Same state transition returns unchanged")
    func sameStateNoTransition() {
        let health = AuthorizationHealth(currentState: .authorized)
        let same = health.withTransition(to: .authorized)
        #expect(same == health)
    }

    // ==========================================================
    // #8: Authorization restoration triggers reconciliation path
    // ==========================================================

    @Test("Authorization restoration triggers reapply via reconciler")
    func authRestorationTriggersReconciliation() {
        let snapshot = PolicySnapshot(
            effectivePolicy: EffectivePolicy(resolvedMode: .fullLockdown, policyVersion: 1)
        )
        let action = PolicyReconciler.evaluate(
            currentSnapshot: snapshot,
            lastAppliedMode: .fullLockdown,
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

    @Test("AuthorizationHealth transition chain works correctly")
    func authTransitionChain() {
        let initial = AuthorizationHealth.unknown
        let authorized = initial.withTransition(to: .authorized)
        let revoked = authorized.withTransition(to: .revoked)
        let restored = revoked.withTransition(to: .authorized)

        #expect(authorized.isAuthorized)
        #expect(!revoked.isAuthorized)
        #expect(revoked.wasRevoked)
        #expect(restored.isAuthorized)
        #expect(restored.previousState == .revoked)
    }

    // ==========================================================
    // #9: Event queue preserves unsynced critical events
    // ==========================================================

    @Test("Unsynced events survive storage reload")
    func unsyncedEventsSurviveReload() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = AppGroupStorage(containerURL: tempDir)
        let criticalEvent = EventLogEntry(
            deviceID: deviceID,
            familyID: familyID,
            eventType: .localPINUnlock,
            details: "Emergency unlock by child"
        )
        try storage1.appendEventLog(criticalEvent)

        // New storage instance (simulates restart)
        let storage2 = AppGroupStorage(containerURL: tempDir)
        let loaded = storage2.readPendingEventLogs()

        #expect(loaded.count == 1)
        #expect(loaded[0].eventType == .localPINUnlock)
        #expect(loaded[0].uploadState == .pending)
        #expect(loaded[0].id == criticalEvent.id)
    }

    @Test("Event upload state can be updated")
    func eventUploadStateUpdate() throws {
        let storage = try makeStorage()

        let event1 = EventLogEntry(
            deviceID: deviceID, familyID: familyID, eventType: .heartbeatSent
        )
        let event2 = EventLogEntry(
            deviceID: deviceID, familyID: familyID, eventType: .modeChanged
        )
        try storage.appendEventLog(event1)
        try storage.appendEventLog(event2)

        // Mark first as uploading
        try storage.updateEventUploadState(ids: [event1.id], state: .uploading)
        var logs = storage.readPendingEventLogs()
        #expect(logs.first(where: { $0.id == event1.id })?.uploadState == .uploading)
        #expect(logs.first(where: { $0.id == event2.id })?.uploadState == .pending)

        // Mark first as uploaded
        try storage.updateEventUploadState(ids: [event1.id], state: .uploaded)
        logs = storage.readPendingEventLogs()
        #expect(logs.first(where: { $0.id == event1.id })?.uploadState == .uploaded)
        #expect(logs.first(where: { $0.id == event1.id })?.synced == true)
    }

    @Test("Event queue enforces max size")
    func eventQueueMaxSize() throws {
        let storage = try makeStorage()

        // Append more than max
        for i in 0..<(AppConstants.eventQueueMaxSize + 10) {
            let entry = EventLogEntry(
                deviceID: deviceID,
                familyID: familyID,
                eventType: .heartbeatSent,
                details: "Event \(i)"
            )
            try storage.appendEventLog(entry)
        }

        let logs = storage.readPendingEventLogs()
        #expect(logs.count == AppConstants.eventQueueMaxSize)
        // Oldest entries should have been pruned
        #expect(logs.first?.details == "Event 10")
    }

    // ==========================================================
    // #10: Shared App Group state round-trips for extension models
    // ==========================================================

    @Test("ExtensionSharedState round-trips through storage")
    func extensionSharedStateRoundTrip() throws {
        let storage = try makeStorage()
        let state = ExtensionSharedState(
            currentMode: .fullLockdown,
            isTemporaryUnlock: false,
            authorizationAvailable: true,
            enforcementDegraded: false,
            shieldConfig: ShieldConfig(
                title: "Locked",
                message: "Device is locked.",
                showRequestButton: true
            ),
            policyVersion: 42
        )

        try storage.writeExtensionSharedState(state)
        let loaded = storage.readExtensionSharedState()

        #expect(loaded == state)
        #expect(loaded?.currentMode == .fullLockdown)
        #expect(loaded?.shieldConfig.title == "Locked")
        #expect(loaded?.policyVersion == 42)
    }

    @Test("ExtensionSharedState.from builds correctly from backend state")
    func extensionStateFromBackend() {
        let snapshot = PolicySnapshot(
            effectivePolicy: EffectivePolicy(
                resolvedMode: .dailyMode,
                isTemporaryUnlock: false,
                policyVersion: 5
            )
        )
        let authHealth = AuthorizationHealth(currentState: .authorized)
        let shield = ShieldConfig(title: "Daily Mode", message: "Limited apps.")

        let state = ExtensionSharedState.from(
            snapshot: snapshot,
            authHealth: authHealth,
            shieldConfig: shield
        )

        #expect(state.currentMode == .dailyMode)
        #expect(state.authorizationAvailable)
        #expect(!state.enforcementDegraded)
        #expect(state.shieldConfig.title == "Daily Mode")
        #expect(state.policyVersion == 5)
    }

    @Test("ExtensionSharedState.from with no auth is degraded")
    func extensionStateDegraded() {
        let snapshot = PolicySnapshot(
            effectivePolicy: EffectivePolicy(resolvedMode: .fullLockdown, policyVersion: 1)
        )
        let authHealth = AuthorizationHealth(currentState: .denied)

        let state = ExtensionSharedState.from(
            snapshot: snapshot,
            authHealth: authHealth,
            shieldConfig: nil
        )

        #expect(!state.authorizationAvailable)
        #expect(state.enforcementDegraded)
    }

    // ==========================================================
    // #12: Local PIN emergency unlock is logged durably
    // ==========================================================

    @Test("Local PIN unlock event persists through storage")
    func localPINUnlockLoggedDurably() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = AppGroupStorage(containerURL: tempDir)

        // Log the PIN unlock event
        let unlockEvent = EventLogEntry(
            deviceID: deviceID,
            familyID: familyID,
            eventType: .localPINUnlock,
            details: "Parent entered PIN to temporarily unlock"
        )
        try storage1.appendEventLog(unlockEvent)

        // Also persist the temp unlock state
        let unlockState = TemporaryUnlockState(
            origin: .localPINUnlock,
            previousMode: .fullLockdown,
            expiresAt: Date().addingTimeInterval(1800)
        )
        try storage1.writeTemporaryUnlockState(unlockState)

        // Simulate restart
        let storage2 = AppGroupStorage(containerURL: tempDir)
        let events = storage2.readPendingEventLogs()
        let tempState = storage2.readTemporaryUnlockState()

        // Both the event and unlock state survive
        #expect(events.count == 1)
        #expect(events[0].eventType == .localPINUnlock)
        #expect(events[0].uploadState == .pending)
        #expect(tempState?.origin == .localPINUnlock)
        #expect(tempState?.previousMode == .fullLockdown)
    }

    // ==========================================================
    // Additional: Diagnostics
    // ==========================================================

    @Test("Diagnostic entries persist and filter by category")
    func diagnosticsLogPersistence() throws {
        let storage = try makeStorage()

        try storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .heartbeat, message: "Heartbeat sent"
        ))
        try storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement, message: "Mode applied"
        ))
        try storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .heartbeat, message: "Heartbeat failed"
        ))

        let all = storage.readDiagnosticEntries(category: nil)
        #expect(all.count == 3)

        let heartbeatOnly = storage.readDiagnosticEntries(category: .heartbeat)
        #expect(heartbeatOnly.count == 2)
    }

    @Test("Diagnostic entries prune by date")
    func diagnosticsPruning() throws {
        let storage = try makeStorage()

        try storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .command, message: "Old entry",
            timestamp: Date().addingTimeInterval(-7200)
        ))
        try storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .command, message: "Recent entry"
        ))

        try storage.pruneDiagnosticEntries(olderThan: Date().addingTimeInterval(-3600))

        let remaining = storage.readDiagnosticEntries(category: nil)
        #expect(remaining.count == 1)
        #expect(remaining[0].message == "Recent entry")
    }

    @Test("Diagnostics log enforces max entries")
    func diagnosticsMaxEntries() throws {
        let storage = try makeStorage()

        for i in 0..<(AppConstants.diagnosticsMaxEntries + 10) {
            try storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .storage, message: "Entry \(i)"
            ))
        }

        let all = storage.readDiagnosticEntries(category: nil)
        #expect(all.count == AppConstants.diagnosticsMaxEntries)
    }

    // ==========================================================
    // Additional: EnforcementStatus
    // ==========================================================

    @Test("EnforcementStatus.from builds correctly")
    func enforcementStatusFromState() {
        let snapshot = PolicySnapshot(
            effectivePolicy: EffectivePolicy(
                resolvedMode: .fullLockdown,
                warnings: [.someSystemAppsCannotBeBlocked],
                policyVersion: 3
            )
        )
        let authHealth = AuthorizationHealth(currentState: .authorized)
        let status = EnforcementStatus.from(
            snapshot: snapshot,
            authHealth: authHealth,
            temporaryUnlockState: nil,
            enforcementLastAppliedAt: Date()
        )

        #expect(status.authorizationAvailable)
        #expect(!status.isDegraded)
        #expect(status.currentMode == .fullLockdown)
        #expect(!status.temporaryUnlockActive)
    }

    @Test("EnforcementStatus degraded when auth missing")
    func enforcementStatusDegraded() {
        let snapshot = PolicySnapshot(
            effectivePolicy: EffectivePolicy(resolvedMode: .fullLockdown, policyVersion: 1)
        )
        let status = EnforcementStatus.from(
            snapshot: snapshot,
            authHealth: AuthorizationHealth(currentState: .denied),
            temporaryUnlockState: nil,
            enforcementLastAppliedAt: nil
        )

        #expect(!status.authorizationAvailable)
        #expect(status.isDegraded)
        #expect(status.currentModeIsBestEffort)
    }

    // ==========================================================
    // Additional: Heartbeat dedup
    // ==========================================================

    @Test("Heartbeat wasRecentlySent detects recent success")
    func heartbeatRecentlyDetection() {
        let now = Date()
        let status = HeartbeatStatus.initial
            .recordingSuccess(at: now.addingTimeInterval(-30))

        #expect(status.wasRecentlySent(within: 60, at: now))
        #expect(!status.wasRecentlySent(within: 10, at: now))
    }

    @Test("Heartbeat shouldRetry respects backoff")
    func heartbeatShouldRetryBackoff() {
        let now = Date()
        let status = HeartbeatStatus.initial
            .recordingFailure(reason: "error", at: now)

        // Backoff for 1 failure = 20 seconds
        #expect(!status.shouldRetry(at: now.addingTimeInterval(10)))
        #expect(status.shouldRetry(at: now.addingTimeInterval(25)))
    }

    // ==========================================================
    // Additional: EventLogEntry backward compat
    // ==========================================================

    @Test("EventLogEntry synced computed property works")
    func eventLogEntrySyncedCompat() {
        let entry = EventLogEntry(
            deviceID: deviceID,
            familyID: familyID,
            eventType: .heartbeatSent,
            uploadState: .uploaded
        )
        #expect(entry.synced == true)

        let pending = EventLogEntry(
            deviceID: deviceID,
            familyID: familyID,
            eventType: .heartbeatSent
        )
        #expect(pending.synced == false)
        #expect(pending.uploadState == .pending)
    }

    @Test("EventLogEntry decodes from old synced:true format")
    func eventLogEntryOldFormatDecode() throws {
        // Simulate old JSON with "synced": true instead of "uploadState"
        let oldJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "deviceID": "\(deviceID.rawValue)",
            "familyID": "\(familyID.rawValue)",
            "eventType": "heartbeatSent",
            "timestamp": 0,
            "synced": true
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let entry = try decoder.decode(EventLogEntry.self, from: oldJSON)
        #expect(entry.uploadState == .uploaded)
        #expect(entry.synced == true)
    }
}
