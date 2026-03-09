import Foundation
import BigBrotherCore

/// Concrete command processor for child devices.
///
/// Fetches pending commands, deduplicates against processed IDs,
/// routes each command through the canonical snapshot pipeline,
/// and uploads receipts.
final class CommandProcessorImpl: CommandProcessorProtocol {

    private let cloudKit: any CloudKitServiceProtocol
    private let storage: any SharedStorageProtocol
    private let keychain: any KeychainProtocol
    private let enforcement: (any EnforcementServiceProtocol)?
    private let eventLogger: any EventLoggerProtocol
    private let snapshotStore: PolicySnapshotStore

    init(
        cloudKit: any CloudKitServiceProtocol,
        storage: any SharedStorageProtocol,
        keychain: any KeychainProtocol,
        enforcement: (any EnforcementServiceProtocol)?,
        eventLogger: any EventLoggerProtocol,
        snapshotStore: PolicySnapshotStore
    ) {
        self.cloudKit = cloudKit
        self.storage = storage
        self.keychain = keychain
        self.enforcement = enforcement
        self.eventLogger = eventLogger
        self.snapshotStore = snapshotStore
    }

    // MARK: - CommandProcessorProtocol

    func processIncomingCommands() async throws {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        let commands = try await cloudKit.fetchPendingCommands(
            deviceID: enrollment.deviceID,
            childProfileID: enrollment.childProfileID,
            familyID: enrollment.familyID
        )

        let processedIDs = storage.readProcessedCommandIDs()

        #if DEBUG
        print("[BigBrother] Found \(commands.count) pending commands, \(processedIDs.count) already processed")
        #endif

        // Sort by issuedAt (oldest first) for correct ordering.
        let sorted = commands
            .filter { !processedIDs.contains($0.id) }
            .sorted { $0.issuedAt < $1.issuedAt }

        #if DEBUG
        if sorted.isEmpty && !commands.isEmpty {
            print("[BigBrother] All commands already processed (deduped)")
        }
        #endif

        for command in sorted {
            #if DEBUG
            print("[BigBrother] Processing command: \(command.action), id=\(command.id)")
            #endif
            let result = processCommand(command, enrollment: enrollment)
            #if DEBUG
            print("[BigBrother] Command result: \(result.logReason)")
            #endif

            // Post receipt if needed.
            if result.shouldPostReceipt, let receiptStatus = result.receiptStatus {
                let receipt = makeReceipt(
                    commandID: command.id,
                    deviceID: enrollment.deviceID,
                    familyID: enrollment.familyID,
                    status: receiptStatus,
                    reason: result == .applied ? nil : result.logReason
                )
                try? await cloudKit.saveReceipt(receipt)
            }

            try? storage.markCommandProcessed(command.id)

            // Log diagnostic.
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "\(command.action): \(result.logReason)",
                details: "Command ID: \(command.id)"
            ))
        }

        // Prune processed IDs older than retention window.
        let cutoff = Date().addingTimeInterval(-AppConstants.processedCommandRetentionSeconds)
        try? storage.pruneProcessedCommands(olderThan: cutoff)
    }

    func process(_ command: RemoteCommand) async throws -> CommandReceipt {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else {
            return makeReceipt(
                commandID: command.id,
                deviceID: DeviceID(rawValue: "unknown"),
                familyID: FamilyID(rawValue: "unknown"),
                status: .failed,
                reason: "Device not enrolled"
            )
        }

        let result = processCommand(command, enrollment: enrollment)

        return makeReceipt(
            commandID: command.id,
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            status: result.receiptStatus ?? .failed,
            reason: result == .applied ? nil : result.logReason
        )
    }

    // MARK: - Private

    private func processCommand(
        _ command: RemoteCommand,
        enrollment: ChildEnrollmentState
    ) -> CommandProcessingResult {
        // Check expiration.
        if let expiresAt = command.expiresAt, expiresAt < Date() {
            eventLogger.log(.commandFailed, details: "Command \(command.id) expired")
            return .ignoredExpired
        }

        do {
            switch command.action {
            case .setMode(let mode):
                try applyMode(mode, enrollment: enrollment, commandID: command.id)
                eventLogger.log(.commandApplied, details: "Mode set to \(mode.rawValue)")
                return .applied

            case .temporaryUnlock(let durationSeconds):
                try applyTemporaryUnlock(
                    durationSeconds: durationSeconds,
                    enrollment: enrollment,
                    commandID: command.id
                )
                eventLogger.log(.commandApplied, details: "Temporary unlock for \(durationSeconds)s")
                return .applied

            case .requestHeartbeat:
                eventLogger.log(.commandApplied, details: "Heartbeat requested")
                return .applied

            case .unenroll:
                eventLogger.log(.enrollmentRevoked, details: "Remote unenroll command")
                try? enforcement?.clearAllRestrictions()
                return .applied
            }

        } catch {
            eventLogger.log(.commandFailed, details: "Command \(command.id): \(error.localizedDescription)")
            return .failedExecution(reason: error.localizedDescription)
        }
    }

    /// Apply a mode change through the canonical snapshot pipeline.
    private func applyMode(_ mode: LockMode, enrollment: ChildEnrollmentState, commandID: UUID) throws {
        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let currentVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0

        let policy = Policy(
            targetDeviceID: enrollment.deviceID,
            mode: mode,
            version: currentVersion + 1
        )

        let capabilities = DeviceCapabilities(
            familyControlsAuthorized: enforcement?.authorizationStatus == .authorized,
            isOnline: true
        )

        // Clear any active temporary unlock on explicit mode change.
        try? storage.clearTemporaryUnlockState()

        let inputs = PolicyPipelineCoordinator.Inputs(
            basePolicy: policy,
            capabilities: capabilities,
            temporaryUnlockState: nil,
            authorizationHealth: storage.readAuthorizationHealth(),
            deviceID: enrollment.deviceID,
            source: .commandApplied,
            trigger: "setMode(\(mode.rawValue)) command \(commandID)"
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs,
            previousSnapshot: currentSnapshot
        )

        let result = try snapshotStore.commit(output.snapshot)
        if case .committed(let snapshot) = result {
            try enforcement?.apply(snapshot.effectivePolicy)
            try snapshotStore.markApplied()

            if output.modeChanged {
                eventLogger.log(.modeChanged, details: "Mode changed from \(output.previousMode?.rawValue ?? "none") to \(mode.rawValue)")
            }
        }
    }

    /// Apply a temporary unlock through the canonical snapshot pipeline.
    private func applyTemporaryUnlock(
        durationSeconds: Int,
        enrollment: ChildEnrollmentState,
        commandID: UUID
    ) throws {
        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let currentVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0
        let currentMode = currentSnapshot?.effectivePolicy.resolvedMode ?? .fullLockdown

        let expiresAt = Date().addingTimeInterval(Double(durationSeconds))

        // Create durable temp unlock state.
        let unlockState = TemporaryUnlockState(
            origin: .remoteCommand,
            previousMode: currentMode,
            expiresAt: expiresAt,
            commandID: commandID
        )
        try storage.writeTemporaryUnlockState(unlockState)

        let policy = Policy(
            targetDeviceID: enrollment.deviceID,
            mode: currentMode,
            temporaryUnlockUntil: expiresAt,
            version: currentVersion + 1
        )

        let capabilities = DeviceCapabilities(
            familyControlsAuthorized: enforcement?.authorizationStatus == .authorized,
            isOnline: true
        )

        let inputs = PolicyPipelineCoordinator.Inputs(
            basePolicy: policy,
            capabilities: capabilities,
            temporaryUnlockState: unlockState,
            authorizationHealth: storage.readAuthorizationHealth(),
            deviceID: enrollment.deviceID,
            source: .temporaryUnlockStarted,
            trigger: "temporaryUnlock(\(durationSeconds)s) command \(commandID)"
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs,
            previousSnapshot: currentSnapshot
        )

        let result = try snapshotStore.commit(output.snapshot)
        if case .committed(let snapshot) = result {
            try enforcement?.apply(snapshot.effectivePolicy)
            try snapshotStore.markApplied()
            eventLogger.log(.temporaryUnlockStarted, details: "Unlocked for \(durationSeconds)s until \(expiresAt)")
        }
    }

    private func makeReceipt(
        commandID: UUID,
        deviceID: DeviceID,
        familyID: FamilyID,
        status: CommandStatus,
        reason: String? = nil
    ) -> CommandReceipt {
        CommandReceipt(
            commandID: commandID,
            deviceID: deviceID,
            familyID: familyID,
            status: status,
            appliedAt: status == .applied ? Date() : nil,
            failureReason: reason
        )
    }
}
