import Foundation
import CloudKit
import UIKit
import ManagedSettings
import FamilyControls
import DeviceActivity
import BigBrotherCore

/// Serializes access to command processing with a "needs reprocess" flag.
/// If a push arrives while processing is active, the flag is set so that
/// processing re-runs after the current batch completes (instead of dropping).
private actor ProcessingGate {
    private var active = false
    private var pendingReprocess = false

    func tryStart() -> Bool {
        guard !active else {
            // Signal that another run is needed after the current one finishes.
            pendingReprocess = true
            return false
        }
        active = true
        pendingReprocess = false
        return true
    }

    /// Returns true if another run was requested while we were processing.
    func finish() -> Bool {
        let needsRerun = pendingReprocess
        pendingReprocess = false
        active = false
        return needsRerun
    }
}

/// Internal errors thrown by command helpers to communicate failure back to the caller,
/// so the caller can return an accurate receipt status instead of false "applied".
private enum CommandError: Error {
    case permissionDeficiency
    case expiredBeforeDelivery
}

/// Concrete command processor for child devices.
///
/// Fetches pending commands, deduplicates against processed IDs,
/// routes each command through the canonical snapshot pipeline,
/// and uploads receipts.
///
/// Uses `ProcessingGate` to prevent concurrent execution of `processIncomingCommands()`
/// (which can happen when poll timer and push notification fire simultaneously).
final class CommandProcessorImpl: CommandProcessorProtocol, @unchecked Sendable {

    private let cloudKit: any CloudKitServiceProtocol
    private let storage: any SharedStorageProtocol
    private let keychain: any KeychainProtocol
    private let enforcement: (any EnforcementServiceProtocol)?
    private let eventLogger: any EventLoggerProtocol
    private let snapshotStore: PolicySnapshotStore

    /// Prevents concurrent execution of processIncomingCommands().
    private let processingGate = ProcessingGate()

    /// When true, mode change local notifications are suppressed because
    /// the alert push already displayed a banner. Reset after each processing cycle.
    var suppressModeNotifications = false

    /// Called on the main thread when a requestAppConfiguration command is received.
    var onRequestAppConfiguration: (() -> Void)?

    /// Called when a requestHeartbeat command is received, so the caller can
    /// trigger an immediate heartbeat send via HeartbeatService.
    var onRequestHeartbeat: (() -> Void)?

    /// Called when a requestAlwaysAllowedSetup command is received.
    var onRequestAlwaysAllowedSetup: (() -> Void)?

    /// Called when an unenroll command is received, so the app can clear
    /// enrollment state and reset to unconfigured.
    var onUnenroll: (() -> Void)?

    /// Called when a setLocationMode command is received.
    var onLocationModeChanged: ((LocationTrackingMode) -> Void)?

    /// Called when a requestLocation command is received (one-shot locate).
    var onRequestLocation: (() -> Void)?
    var onRequestPermissions: (() -> Void)?
    var onSyncNamedPlaces: (() -> Void)?
    var onRequestDiagnostics: (() -> Void)?
    var onRestartVPNTunnel: (() -> Void)?
    var onScheduleSyncNeeded: (() -> Void)?
    var onRequestTimeLimitSetup: (() -> Void)?
    var onRequestChildAppPick: (() -> Void)?

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
        // Prevent concurrent execution from poll timer + push notification firing together.
        guard await processingGate.tryStart() else {
            #if DEBUG
            print("[BigBrother] Command processing already in progress — queued for reprocess")
            #endif
            return
        }

        // CRITICAL: Begin a background task so iOS doesn't suspend us mid-enforcement.
        // Without this, ManagedSettingsStore writes from a backgrounded app don't commit
        // before iOS suspends the process — shields stay in the wrong state until the
        // user manually opens the app.
        let bgTaskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "commandProcessing") { }
        }

        // Process commands, then re-run if a push arrived during processing.
        var shouldRerun = true
        while shouldRerun {
            do {
                try await _processIncomingCommandsBody()
            } catch {
                let _ = await processingGate.finish()
                await MainActor.run {
                    if bgTaskID != .invalid { UIApplication.shared.endBackgroundTask(bgTaskID) }
                }
                throw error
            }
            shouldRerun = await processingGate.finish()
            if shouldRerun {
                #if DEBUG
                print("[BigBrother] Reprocessing commands (push arrived during previous batch)")
                #endif
                guard await processingGate.tryStart() else { break }
            }
        }

        // Brief pause for ManagedSettingsStore writes to commit, then release
        try? await Task.sleep(for: .milliseconds(500))
        await MainActor.run {
            if bgTaskID != .invalid { UIApplication.shared.endBackgroundTask(bgTaskID) }
        }
    }

    private func _processIncomingCommandsBody() async throws {

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

        // Filter out already-processed commands.
        let unprocessed = commands.filter { !processedIDs.contains($0.id) }

        // Drop commands past their explicit expiry (default 24 hours from issuedAt).
        // Do NOT use an arbitrary shorter cutoff — devices can be offline for hours
        // and must still process legitimate commands when connectivity returns.
        let now = Date()
        let fresh = unprocessed.filter { cmd in
            if let expiresAt = cmd.expiresAt, expiresAt < now { return false }
            return true
        }
        let expiredCount = unprocessed.count - fresh.count
        if expiredCount > 0 {
            #if DEBUG
            print("[BigBrother] Skipping \(expiredCount) expired commands")
            #endif
            for cmd in unprocessed where cmd.expiresAt != nil && cmd.expiresAt! < now {
                // Always send explicit .expired status to CloudKit so parent dashboard shows it.
                try? await cloudKit.updateCommandStatus(cmd.id, status: .expired)
                do {
                    try storage.markCommandProcessed(cmd.id)
                } catch {
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .command,
                        message: "Failed to mark expired command \(cmd.id) as processed: \(error.localizedDescription)"
                    ))
                }
                eventLogger.log(.commandFailed, details: "Command \(cmd.id) expired before processing (issued: \(cmd.issuedAt), expired: \(cmd.expiresAt!))")
            }
        }

        // Separate enforcement commands (lock/unlock) from config commands (budget, etc.).
        let enforcementCommands = fresh.filter { Self.isEnforcementCommand($0.action) }
        let configCommands = fresh.filter { !Self.isEnforcementCommand($0.action) }

        // For mode commands (setMode, temporaryUnlock, timedUnlock, lockUntil, returnToSchedule),
        // only the LATEST one matters — earlier ones are superseded. Per-app enforcement
        // commands (allowApp, blockManagedApp, etc.) still all execute.
        let modeCommands = enforcementCommands.filter { $0.action.isModeCommand }
        let perAppCommands = enforcementCommands.filter { !$0.action.isModeCommand }

        // Select the latest mode command. Older ones are superseded AFTER the winner
        // is successfully processed — this ensures we don't discard fallback commands
        // if the winner fails (bad signature, expired, registration failure).
        var effectiveModeCommands: [RemoteCommand] = []
        var supersededModeCommands: [RemoteCommand] = []
        if let latestMode = modeCommands.max(by: { $0.issuedAt < $1.issuedAt }) {
            effectiveModeCommands = [latestMode]
            supersededModeCommands = modeCommands.filter { $0.id != latestMode.id }
        }
        let skippedMode = modeCommands.count - effectiveModeCommands.count

        // For config commands, only process the LATEST of each type — older duplicates
        // are stale and just waste time. Group by stable deduplication key.
        var latestConfig: [String: RemoteCommand] = [:]
        for cmd in configCommands {
            let key = cmd.action.deduplicationKey
            if let existing = latestConfig[key] {
                // Keep the newer one, mark the older as processed to skip next time.
                if cmd.issuedAt > existing.issuedAt {
                    try? storage.markCommandProcessed(existing.id)
                    try? await cloudKit.updateCommandStatus(existing.id, status: .applied)
                    latestConfig[key] = cmd
                } else {
                    try? storage.markCommandProcessed(cmd.id)
                    try? await cloudKit.updateCommandStatus(cmd.id, status: .applied)
                }
            } else {
                latestConfig[key] = cmd
            }
        }

        // Process: latest mode command first, then per-app enforcement, then latest config.
        let sorted = effectiveModeCommands
            + perAppCommands.sorted { $0.issuedAt < $1.issuedAt }
            + latestConfig.values.sorted { $0.issuedAt < $1.issuedAt }

        let skippedConfig = configCommands.count - latestConfig.count
        #if DEBUG
        if sorted.isEmpty && !commands.isEmpty {
            print("[BigBrother] All commands already processed (deduped)")
        } else {
            print("[BigBrother] \(effectiveModeCommands.count) mode + \(perAppCommands.count) per-app + \(latestConfig.count) config to process (\(skippedMode) mode + \(skippedConfig) config skipped)")
        }
        #endif

        for command in sorted {
            #if DEBUG
            print("[BigBrother] Processing command: \(command.action), id=\(command.id)")
            #endif
            let result = await processCommand(command, enrollment: enrollment)
            #if DEBUG
            print("[BigBrother] Command result: \(result.logReason)")
            #endif

            // Post receipt and update the command's CloudKit status so it's no longer
            // returned by fetchPendingCommands on subsequent polls.
            if result.shouldPostReceipt, let receiptStatus = result.receiptStatus {
                let receipt = makeReceipt(
                    commandID: command.id,
                    deviceID: enrollment.deviceID,
                    familyID: enrollment.familyID,
                    status: receiptStatus,
                    reason: result == .applied ? nil : result.logReason
                )
                // Retry receipt upload — parent needs confirmation the command was processed.
                for attempt in 1...3 {
                    do {
                        try await cloudKit.saveReceipt(receipt)
                        try await cloudKit.updateCommandStatus(command.id, status: receiptStatus)
                        break
                    } catch {
                        if attempt == 3 {
                            eventLogger.log(.commandFailed, details: "Receipt upload failed after 3 attempts for \(command.id): \(error.localizedDescription)")
                        } else {
                            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                        }
                    }
                }
            }

            do {
                try storage.markCommandProcessed(command.id)
            } catch {
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .command,
                    message: "Failed to mark command \(command.id) as processed: \(error.localizedDescription)"
                ))
            }

            // Log diagnostic.
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "\(command.action): \(result.logReason)",
                details: "Command ID: \(command.id)"
            ))
        }

        // Now that the winning mode command has been processed, mark superseded ones.
        // Deferred from earlier so that if the winner fails, we could fall back (not yet
        // implemented, but this ordering is safer than pre-emptive superseding).
        for cmd in supersededModeCommands {
            #if DEBUG
            print("[BigBrother] Superseded mode command: \(cmd.action.displayDescription) (id=\(cmd.id))")
            #endif
            do {
                try storage.markCommandProcessed(cmd.id)
            } catch {
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .command,
                    message: "Failed to mark superseded command \(cmd.id) as processed: \(error.localizedDescription)"
                ))
            }
            try? await cloudKit.updateCommandStatus(cmd.id, status: .expired)
        }

        // Prune processed IDs older than retention window.
        let cutoff = Date().addingTimeInterval(-AppConstants.processedCommandRetentionSeconds)
        try? storage.pruneProcessedCommands(olderThan: cutoff)

        // Record last command processing time for heartbeat reporting.
        if !sorted.isEmpty {
            let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
            defaults.set(Date().timeIntervalSince1970, forKey: "fr.bigbrother.lastCommandProcessedAt")

            // Send heartbeat immediately so parent sees the confirmed mode change.
            onRequestHeartbeat?()
        }
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

        let result = await processCommand(command, enrollment: enrollment)

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
    ) async -> CommandProcessingResult {
        // Check expiration. Send explicit .expired status to CloudKit so the parent
        // dashboard reflects it (ignoredExpired normally skips receipt posting).
        if let expiresAt = command.expiresAt, expiresAt < Date() {
            try? await cloudKit.updateCommandStatus(command.id, status: .expired)
            eventLogger.log(.commandFailed, details: "Command \(command.id) expired before processing (issued: \(command.issuedAt), expired: \(expiresAt))")
            return .ignoredExpired
        }

        // Verify command signature for mode commands.
        // Children trust multiple parent public keys (one per parent device).
        if command.action.isModeCommand {
            let trustedKeys: [Data] = {
                guard let data = try? keychain.getData(forKey: StorageKeys.commandSigningPublicKey) else { return [] }
                // Try multi-key format (JSON array of base64 strings) first.
                if let keys = try? JSONDecoder().decode([String].self, from: data) {
                    return keys.compactMap { Data(base64Encoded: $0) }
                }
                // Fall back to single raw key (pre-multi-key format).
                return [data]
            }()

            if !trustedKeys.isEmpty {
                if let sig = command.signatureBase64 {
                    let verified = trustedKeys.contains { pubKeyData in
                        CommandSigner.verify(command: command, signatureBase64: sig, publicKeyData: pubKeyData)
                    }
                    guard verified else {
                        eventLogger.log(.commandFailed, details: "Invalid signature for command \(command.id)")
                        // Receipt handles status propagation to parent.
                        return .rejectedSignature
                    }
                } else {
                    // We have trusted keys but the command has no signature — reject
                    eventLogger.log(.commandFailed, details: "Unsigned mode command rejected: \(command.id)")
                    try? await cloudKit.updateCommandStatus(command.id, status: .failed)
                    return .rejectedSignature
                }
            } else {
                // Device is enrolled but has no trusted keys — Keychain may have been wiped
                // (e.g., MDM removal clears Keychain entries). Accept command with warning.
                // Rejecting here bricks the device — parent can't send ANY commands.
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .command,
                    message: "WARNING: No trusted public keys in Keychain — accepting command \(command.id) unsigned. Re-enroll to restore key verification."
                ))
            }
        }

        do {
            switch command.action {
            case .setMode(let mode):
                // Indefinite mode command: clears the entire stack.
                // Last parent command always wins — if parent says Lock,
                // any active temp unlock, timed unlock, or schedule is overridden.
                // CRITICAL: If clear fails, retry with brute force. The 60-second
                // enforcement check uses ModeStackResolver which reads these files.
                // A leftover temp unlock file will override this setMode command.
                do {
                    try storage.clearTemporaryUnlockState()
                } catch {
                    // Retry once — file might be locked by another process
                    try? storage.clearTemporaryUnlockState()
                    // Nuclear: overwrite with nil data to ensure the file is gone
                    try? storage.writeRawData(nil, forKey: "temporaryUnlockState.json")
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .command,
                        message: "Failed to clear temp unlock during setMode (retried): \(error.localizedDescription)"
                    ))
                }
                do {
                    try storage.clearTimedUnlockInfo()
                } catch {
                    try? storage.clearTimedUnlockInfo()
                    try? storage.writeRawData(nil, forKey: "timedUnlockInfo.json")
                }
                clearLockUntilState()
                cancelNonScheduleActivities()
                // scheduleDrivenMode is now derived from controlAuthority in the snapshot commit.
                try applyMode(mode, enrollment: enrollment, commandID: command.id)
                eventLogger.log(.commandApplied, details: "Mode set to \(mode.rawValue)")
                if !suppressModeNotifications { ModeChangeNotifier.notify(newMode: mode) }
                return .applied

            case .temporaryUnlock(let durationSeconds):
                let wasUnlocked = snapshotStore.loadCurrentSnapshot()?.effectivePolicy.resolvedMode == .unlocked
                do {
                    try applyTemporaryUnlock(
                        durationSeconds: durationSeconds,
                        enrollment: enrollment,
                        commandID: command.id,
                        issuedAt: command.issuedAt
                    )
                } catch CommandError.permissionDeficiency {
                    return .failedExecution(reason: "Temporary unlock blocked: permissions missing")
                } catch CommandError.expiredBeforeDelivery {
                    return .failedExecution(reason: "Temporary unlock expired before delivery")
                }
                let h = durationSeconds / 3600
                let m = (durationSeconds % 3600) / 60
                let dur = h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
                eventLogger.log(.commandApplied, details: "\(wasUnlocked ? "Extended" : "Temporary") unlock for \(dur)")
                if !suppressModeNotifications { ModeChangeNotifier.notifyTemporaryUnlock(durationSeconds: durationSeconds, isExtension: wasUnlocked) }
                return .applied

            case .requestHeartbeat:
                eventLogger.log(.commandApplied, details: "Heartbeat requested")
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestHeartbeat?()
                }
                return .applied

            case .requestAppConfiguration:
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestAppConfiguration?()
                }
                eventLogger.log(.commandApplied, details: "App configuration requested by parent")
                return .applied

            case .unenroll:
                eventLogger.log(.enrollmentRevoked, details: "Remote unenroll command")
                do {
                    try enforcement?.clearAllRestrictions()
                } catch {
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .enforcement,
                        message: "Failed to clear restrictions during unenroll: \(error.localizedDescription)"
                    ))
                }
                // Clear enrollment state and reset to unconfigured.
                DispatchQueue.main.async { [weak self] in
                    self?.onUnenroll?()
                }
                return .applied

            case .allowApp(let requestID):
                let result = handleAllowApp(requestID: requestID)
                if case .applied = result {
                    eventLogger.log(.commandApplied, details: "App permanently allowed (request \(requestID))")
                }
                return result

            case .allowManagedApp(let appName):
                let result = handleAllowManagedApp(appName: appName)
                if case .applied = result {
                    eventLogger.log(.commandApplied, details: "App permanently allowed (\(appName))")
                }
                return result

            case .revokeApp(let requestID):
                let result = handleRevokeApp(requestID: requestID)
                if case .applied = result {
                    eventLogger.log(.commandApplied, details: "App access revoked (request \(requestID))")
                }
                return result

            case .blockManagedApp(let appName):
                let result = handleBlockManagedApp(appName: appName)
                if case .applied = result {
                    eventLogger.log(.commandApplied, details: "App access revoked (\(appName))")
                }
                return result

            case .temporaryUnlockApp(let requestID, let durationSeconds):
                return handleTemporaryUnlockApp(
                    requestID: requestID,
                    durationSeconds: durationSeconds
                )

            case .nameApp(let fingerprint, let name):
                return handleNameApp(fingerprint: fingerprint, name: name)

            case .setRestrictions(let restrictions):
                return handleSetRestrictions(restrictions)

            case .revokeAllApps:
                return handleRevokeAllApps()

            case .requestAlwaysAllowedSetup:
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestAlwaysAllowedSetup?()
                }
                eventLogger.log(.commandApplied, details: "Always-allowed setup requested by parent")
                return .applied

            case .timedUnlock(let totalSeconds, let penaltySeconds):
                do {
                    try applyTimedUnlock(
                        totalSeconds: totalSeconds,
                        penaltySeconds: penaltySeconds,
                        issuedAt: command.issuedAt,
                        enrollment: enrollment,
                        commandID: command.id
                    )
                } catch CommandError.expiredBeforeDelivery {
                    return .failedExecution(reason: "Timed unlock expired before delivery")
                }
                return .applied

            case .returnToSchedule:
                try applyReturnToSchedule(enrollment: enrollment, commandID: command.id)
                // scheduleDrivenMode is now derived from controlAuthority in the snapshot commit.
                eventLogger.log(.commandApplied, details: "Returned to schedule-driven mode")
                // Trigger immediate schedule sync from CloudKit — the child may have
                // a stale schedule. After sync completes, re-apply enforcement.
                DispatchQueue.main.async { [weak self] in
                    self?.onScheduleSyncNeeded?()
                }
                return .applied

            case .lockUntil(let date):
                // scheduleDrivenMode is now derived from controlAuthority in the snapshot commit.
                try applyLockUntil(date: date, enrollment: enrollment, commandID: command.id)
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                eventLogger.log(.commandApplied, details: "Locked until \(formatter.string(from: date))")
                if !suppressModeNotifications { ModeChangeNotifier.notify(newMode: .restricted) }
                return .applied

            case .syncPINHash(let base64):
                // Try to decrypt (new encrypted format) then fall back to raw (old format).
                // Uses the first parent's raw public key as enrollment secret.
                // Parent stores raw key bytes; child stores JSON array of base64 strings.
                // Extract the first raw key from whichever format is stored.
                let enrollmentSecret: Data? = {
                    guard let stored = try? keychain.getData(forKey: StorageKeys.commandSigningPublicKey) else { return nil }
                    // Try JSON array format (child) first
                    if let keys = try? JSONDecoder().decode([String].self, from: stored),
                       let first = keys.first,
                       let raw = Data(base64Encoded: first) {
                        return raw
                    }
                    // Fall back to raw key bytes (parent or legacy single-key)
                    return stored
                }()
                if let encryptedData = Data(base64Encoded: base64) {
                    if let decrypted = try? FamilyDerivedKey.decrypt(encryptedData, familyID: enrollment.familyID, enrollmentSecret: enrollmentSecret, purpose: "pin-sync") {
                        // New encrypted format — validate and store decrypted hash
                        guard PINHasher.PINHash(combined: decrypted) != nil else {
                            return .failedExecution(reason: "Invalid decrypted PIN hash format (expected \(64) bytes, got \(decrypted.count))")
                        }
                        try keychain.setData(decrypted, forKey: StorageKeys.parentPINHash)
                    } else {
                        // Old format (raw hash) — store directly
                        guard PINHasher.PINHash(combined: encryptedData) != nil else {
                            return .failedExecution(reason: "Invalid PIN hash format (expected \(64) bytes, got \(encryptedData.count))")
                        }
                        try keychain.setData(encryptedData, forKey: StorageKeys.parentPINHash)
                    }
                } else {
                    return .failedExecution(reason: "Invalid PIN hash base64")
                }
                eventLogger.log(.commandApplied, details: "Parent PIN synced to device")
                return .applied

            case .setScheduleProfile(let profileID, let versionDate):
                try await cloudKit.updateDeviceFields(
                    deviceID: enrollment.deviceID,
                    fields: [
                        CKFieldName.scheduleProfileID: profileID.uuidString as CKRecordValue,
                        CKFieldName.scheduleProfileVersion: versionDate as CKRecordValue
                    ]
                )
                eventLogger.log(.commandApplied, details: "Schedule profile set: \(profileID.uuidString.prefix(8))")
                return .applied

            case .clearScheduleProfile:
                try await cloudKit.updateDeviceFields(
                    deviceID: enrollment.deviceID,
                    fields: [
                        CKFieldName.scheduleProfileID: nil,
                        CKFieldName.scheduleProfileVersion: nil
                    ]
                )
                eventLogger.log(.commandApplied, details: "Schedule profile cleared")
                return .applied

            case .setSelfUnlockBudget(let count):
                let value: CKRecordValue? = count > 0 ? count as NSNumber : nil
                try await cloudKit.updateDeviceFields(
                    deviceID: enrollment.deviceID,
                    fields: [CKFieldName.selfUnlocksPerDay: value]
                )
                eventLogger.log(.commandApplied, details: "Self-unlock budget set to \(count)")
                return .applied

            case .setPenaltyTimer(let seconds, let endTime):
                try await cloudKit.updateDeviceFields(
                    deviceID: enrollment.deviceID,
                    fields: [
                        CKFieldName.penaltySeconds: seconds.map { $0 as NSNumber } as CKRecordValue?,
                        CKFieldName.penaltyTimerEndTime: endTime.map { $0 as NSDate } as CKRecordValue?
                    ]
                )
                eventLogger.log(.commandApplied, details: "Penalty timer updated")
                return .applied

            case .setHeartbeatProfile(let profileID):
                let value: CKRecordValue? = profileID?.uuidString as CKRecordValue?
                try await cloudKit.updateDeviceFields(
                    deviceID: enrollment.deviceID,
                    fields: [CKFieldName.heartbeatProfileID: value]
                )
                eventLogger.log(.commandApplied, details: "Heartbeat profile set: \(profileID?.uuidString.prefix(8) ?? "cleared")")
                return .applied

            case .setAllowedWebDomains(let domains):
                let data = try JSONEncoder().encode(domains)
                try storage.writeRawData(data, forKey: StorageKeys.allowedWebDomains)
                reapplyCurrentEnforcement()
                eventLogger.log(.commandApplied, details: "Web domains: \(domains.isEmpty ? "all blocked" : domains.joined(separator: ", "))")
                return .applied

            case .sendMessage(let text):
                let msg = ParentMessage(id: command.id, text: text, sentAt: command.issuedAt, sentBy: command.issuedBy)
                var existing = storage.readParentMessages()
                existing.append(msg)
                if existing.count > 20 { existing = Array(existing.suffix(20)) }
                try storage.writeParentMessages(existing)
                ModeChangeNotifier.notifyParentMessage(text: text, from: command.issuedBy)
                eventLogger.log(.commandApplied, details: "Message from \(command.issuedBy): \(String(text.prefix(50)))")
                return .applied

            case .addTrustedSigningKey(let publicKeyBase64):
                // Append new parent's public key to the trusted keys list.
                guard Data(base64Encoded: publicKeyBase64) != nil else {
                    return .failedValidation(reason: "Invalid base64 public key")
                }
                var existingKeys: [String] = {
                    guard let data = try? keychain.getData(forKey: StorageKeys.commandSigningPublicKey),
                          let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
                    return keys
                }()
                if !existingKeys.contains(publicKeyBase64) {
                    existingKeys.append(publicKeyBase64)
                    let encoded = try JSONEncoder().encode(existingKeys)
                    try keychain.setData(encoded, forKey: StorageKeys.commandSigningPublicKey)
                    eventLogger.log(.commandApplied, details: "Added trusted signing key (\(existingKeys.count) total)")
                } else {
                    eventLogger.log(.commandApplied, details: "Signing key already trusted")
                }
                return .applied

            case .setLocationMode(let mode):
                UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                    .set(mode.rawValue, forKey: "locationTrackingMode")
                DispatchQueue.main.async { [weak self] in
                    self?.onLocationModeChanged?(mode)
                }
                eventLogger.log(.commandApplied, details: "Location mode set to \(mode.rawValue)")
                return .applied

            case .requestLocation:
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestLocation?()
                }
                eventLogger.log(.commandApplied, details: "Location requested")
                return .applied

            case .requestPermissions:
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestPermissions?()
                }
                eventLogger.log(.commandApplied, details: "Permissions re-request triggered")
                return .applied

            case .setHomeLocation(let latitude, let longitude):
                let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
                defaults?.set(latitude, forKey: "homeLatitude")
                defaults?.set(longitude, forKey: "homeLongitude")
                // Trigger LocationService to register the geofence immediately.
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestLocation?() // Reuses location callback to refresh
                }
                eventLogger.log(.commandApplied, details: "Home geofence set at (\(latitude), \(longitude))")
                return .applied

            case .syncNamedPlaces:
                DispatchQueue.main.async { [weak self] in
                    self?.onSyncNamedPlaces?()
                }
                eventLogger.log(.commandApplied, details: "Named places sync requested")
                return .applied

            case .setDrivingSettings(let settings):
                if let data = try? JSONEncoder().encode(settings) {
                    UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                        .set(data, forKey: "drivingSettings")
                }
                eventLogger.log(.commandApplied, details: "Driving settings updated: speed limit \(Int(settings.speedThresholdMPH)) mph")
                return .applied

            case .requestDiagnostics:
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestDiagnostics?()
                }
                eventLogger.log(.commandApplied, details: "Diagnostic report requested")
                return .applied

            case .setSafeSearch(let enabled):
                UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                    .set(enabled, forKey: "safeSearchEnabled")
                // Restart the VPN tunnel to pick up the new DNS settings
                DispatchQueue.main.async { [weak self] in
                    self?.onRestartVPNTunnel?()
                }
                eventLogger.log(.commandApplied, details: "Safe search \(enabled ? "enabled" : "disabled")")
                return .applied

            case .blockInternet:
                // Legacy: internet blocking is now inherent to .lockedDown mode.
                // The tunnel reads mode from App Group and applies DNS blackhole automatically.
                // Just restart the tunnel to re-evaluate.
                DispatchQueue.main.async { [weak self] in
                    self?.onRestartVPNTunnel?()
                }
                eventLogger.log(.commandApplied, details: "Internet block state synced (mode-driven)")
                return .applied

            case .requestTimeLimitSetup:
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestTimeLimitSetup?()
                }
                eventLogger.log(.commandApplied, details: "Time limit setup requested by parent (Mode 1)")
                return .applied

            case .requestChildAppPick:
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestChildAppPick?()
                }
                eventLogger.log(.commandApplied, details: "App pick requested by parent (Mode 2)")
                return .applied

            case .reviewApp(let fingerprint, let disposition, let minutes):
                return handleReviewApp(fingerprint: fingerprint, disposition: disposition, minutes: minutes)

            case .reviewApps(let decisions):
                var lastResult: CommandProcessingResult = .applied
                for decision in decisions {
                    lastResult = handleReviewApp(fingerprint: decision.fingerprint, disposition: decision.disposition, minutes: decision.minutes)
                }
                reapplyCurrentEnforcement()
                return lastResult

            case .grantExtraTime(let fingerprint, let extraMinutes):
                return handleGrantExtraTime(fingerprint: fingerprint, extraMinutes: extraMinutes)

            case .removeTimeLimit(let fingerprint):
                return handleRemoveTimeLimit(fingerprint: fingerprint)

            case .blockAppForToday(let fingerprint):
                return handleBlockAppForToday(fingerprint: fingerprint)
            }

        } catch {
            eventLogger.log(.commandFailed, details: "Command \(command.id): \(error.localizedDescription)")
            return .failedExecution(reason: error.localizedDescription)
        }
    }

    /// Apply a mode change through the canonical snapshot pipeline.
    private func applyMode(_ mode: LockMode, enrollment: ChildEnrollmentState, commandID: UUID, controlAuthority: ControlAuthority = .parentManual) throws {
        // If permissions are missing, force essential mode regardless of requested mode.
        let effectiveMode: LockMode
        if hasPermissionDeficiency() && mode != .locked {
            effectiveMode = .locked
            eventLogger.log(.enforcementDegraded, details: "Permissions missing — forced essential mode (requested: \(mode.rawValue))")
        } else {
            effectiveMode = mode
        }

        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("command", forKey: "lastShieldChangeReason")
        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let currentVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0

        let policy = Policy(
            targetDeviceID: enrollment.deviceID,
            mode: effectiveMode,
            version: currentVersion + 1
        )

        let capabilities = DeviceCapabilities(
            familyControlsAuthorized: enforcement?.authorizationStatus == .authorized,
            isOnline: true
        )

        // NOTE: Stack clearing (clearTemporaryUnlockState, clearTimedUnlockInfo,
        // cancelNonScheduleActivities) is handled by the CALLER (setMode, returnToSchedule),
        // NOT here. applyMode() is also called by lockUntil and timedUnlock which should
        // NOT clear the stack — they're pushing onto it.

        let inputs = PolicyPipelineCoordinator.Inputs(
            basePolicy: policy,
            capabilities: capabilities,
            temporaryUnlockState: nil,
            authorizationHealth: storage.readAuthorizationHealth(),
            deviceID: enrollment.deviceID,
            source: .commandApplied,
            trigger: "setMode(\(effectiveMode.rawValue)) command \(commandID)",
            controlAuthority: controlAuthority,
            deviceRestrictions: storage.readDeviceRestrictions()
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs,
            previousSnapshot: currentSnapshot
        )

        let result = try snapshotStore.commit(output.snapshot)
        NSLog("[CommandProcessor] applyMode(\(effectiveMode.rawValue)): snapshot committed, calling enforcement.apply()")
        switch result {
        case .committed(let snapshot):
            try enforcement?.apply(snapshot.effectivePolicy)
            NSLog("[CommandProcessor] applyMode(\(effectiveMode.rawValue)): enforcement.apply() completed, triggering Monitor")
            try snapshotStore.markApplied()

            // Trigger the Monitor extension to apply enforcement from its privileged context.
            // The main app's enforcement.apply() above is best-effort (works in foreground).
            triggerMonitorEnforcementRefresh()

            if output.modeChanged {
                eventLogger.log(.modeChanged, details: "Mode changed from \(output.previousMode?.rawValue ?? "none") to \(effectiveMode.rawValue)")

                // If transitioning to/from .lockedDown, restart VPN tunnel to apply/remove DNS blackhole.
                let wasLockedDown = output.previousMode == .lockedDown
                let isLockedDown = effectiveMode == .lockedDown
                if wasLockedDown != isLockedDown {
                    DispatchQueue.main.async { [weak self] in
                        self?.onRestartVPNTunnel?()
                    }
                }
            }
        case .unchanged:
            // Policy fingerprint identical — still apply enforcement to ensure stores are correct.
            if let snapshot = snapshotStore.loadCurrentSnapshot() {
                try enforcement?.apply(snapshot.effectivePolicy)
            }
        case .rejectedAsStale:
            // Another process wrote a newer snapshot — apply THAT instead.
            if let snapshot = snapshotStore.loadCurrentSnapshot() {
                try enforcement?.apply(snapshot.effectivePolicy)
            }
        }
    }

    /// Apply a temporary unlock through the canonical snapshot pipeline.
    ///
    /// Also registers a DeviceActivitySchedule that fires at `expiresAt` so the
    /// monitor extension re-locks the device even if the main app is terminated.
    private func applyTemporaryUnlock(
        durationSeconds: Int,
        enrollment: ChildEnrollmentState,
        commandID: UUID,
        issuedAt: Date = Date()
    ) throws {
        // Block unlock if permissions are missing
        if hasPermissionDeficiency() {
            eventLogger.log(.enforcementDegraded, details: "Temporary unlock blocked: permissions missing")
            throw CommandError.permissionDeficiency
        }

        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let currentVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0
        let currentMode = currentSnapshot?.effectivePolicy.resolvedMode ?? .locked

        // Expiry is anchored to when the parent SENT the command, not when the child processes it.
        // This ensures the unlock window is the same regardless of delivery delay.
        let now = Date()
        let expiresAt = issuedAt.addingTimeInterval(Double(durationSeconds))

        // If the unlock has already expired by the time we process it, reject.
        guard expiresAt > now else {
            eventLogger.log(.commandFailed, details: "Temporary unlock expired before delivery (issued \(Int(Date().timeIntervalSince(issuedAt)))s ago)")
            throw CommandError.expiredBeforeDelivery
        }

        // Clear any existing timed unlock / lockUntil to prevent conflicts.
        try? storage.clearTimedUnlockInfo()
        try? storage.writeRawData(nil, forKey: "timedUnlockInfo.json")
        clearLockUntilState()

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
            trigger: "temporaryUnlock(\(durationSeconds)s) command \(commandID)",
            controlAuthority: .temporaryUnlock,
            deviceRestrictions: storage.readDeviceRestrictions()
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs,
            previousSnapshot: currentSnapshot
        )

        // Register the re-lock schedule BEFORE applying enforcement.
        // Try to register DeviceActivity schedule for expiry callback.
        // If this fails (e.g., after MDM removal disrupted DeviceActivity),
        // proceed with the unlock anyway — BGTask and ModeStackResolver provide
        // safety nets for re-locking. Aborting here blocks ALL unlocks when
        // DeviceActivity is temporarily broken.
        do {
            try registerTempUnlockExpirySchedule(commandID: commandID, start: now, end: expiresAt)
        } catch {
            eventLogger.log(.commandFailed, details: "DeviceActivity schedule registration failed (\(error.localizedDescription)) — proceeding with BGTask safety net")
        }

        // BGProcessingTask as safety net for re-lock (works even if DeviceActivity is broken).
        AppDelegate.scheduleRelockTask(at: expiresAt)

        let result = try snapshotStore.commit(output.snapshot)
        switch result {
        case .committed(let snapshot):
            try enforcement?.apply(snapshot.effectivePolicy)
            try snapshotStore.markApplied()
        case .unchanged, .rejectedAsStale:
            // Snapshot collision — still must apply enforcement so the unlock takes effect.
            if let snapshot = snapshotStore.loadCurrentSnapshot() {
                try enforcement?.apply(snapshot.effectivePolicy)
            }
        }

        let durationStr = ModeChangeNotifier.formatDuration(durationSeconds)
        eventLogger.log(.temporaryUnlockStarted, details: "Unlocked for \(durationStr)")
    }

    /// Register a one-shot DeviceActivitySchedule that fires `intervalDidEnd`
    /// at the temporary unlock expiry time. The monitor extension handles re-lock.
    /// Throws if registration fails — caller must not grant unlock without a re-lock guarantee.
    private func registerTempUnlockExpirySchedule(commandID: UUID, start: Date, end: Date) throws {
        let cal = Calendar.current
        // Use ONLY hour/minute/second — NOT year/month/day.
        // Including date components causes "invalid schedule" failures on iOS 17+.
        let startComps = cal.dateComponents([.hour, .minute, .second], from: start)
        let endComps = cal.dateComponents([.hour, .minute, .second], from: end)

        let activityName = DeviceActivityName(rawValue: "bigbrother.tempunlock.\(commandID.uuidString)")
        let schedule = DeviceActivitySchedule(
            intervalStart: startComps,
            intervalEnd: endComps,
            repeats: false
        )

        let center = DeviceActivityCenter()
        try center.startMonitoring(activityName, during: schedule)

        #if DEBUG
        print("[BigBrother] Registered temp unlock expiry schedule: \(activityName.rawValue), ends at \(end)")
        #endif
    }

    // MARK: - Direct Enforcement (called from main app for timed unlock transitions)

    /// Apply a temporary unlock directly (no command needed).
    func applyTemporaryUnlockDirect(durationSeconds: Int, enrollment: ChildEnrollmentState) throws {
        try applyTemporaryUnlock(
            durationSeconds: durationSeconds,
            enrollment: enrollment,
            commandID: UUID()
        )
    }

    /// Apply a mode change directly (no command needed).
    func applyModeDirect(_ mode: LockMode, enrollment: ChildEnrollmentState) throws {
        try applyMode(mode, enrollment: enrollment, commandID: UUID())
    }

    // MARK: - Self Unlock (child-initiated)

    /// Apply a self-unlock (child-initiated, 15 minutes).
    /// Uses the same temporary unlock infrastructure as remote commands.
    func applySelfUnlock(durationSeconds: Int) throws {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let currentVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0
        let currentMode = currentSnapshot?.effectivePolicy.resolvedMode ?? .restricted

        // Don't self-unlock if already unlocked.
        guard currentMode != .unlocked else { return }

        let now = Date()
        let expiresAt = now.addingTimeInterval(Double(durationSeconds))
        let unlockID = UUID()

        let unlockState = TemporaryUnlockState(
            unlockID: unlockID,
            origin: .selfUnlock,
            previousMode: currentMode,
            startedAt: now,
            expiresAt: expiresAt,
            commandID: nil
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
            trigger: "selfUnlock(\(durationSeconds)s)",
            controlAuthority: .selfUnlock,
            deviceRestrictions: storage.readDeviceRestrictions()
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs,
            previousSnapshot: currentSnapshot
        )

        // Register the re-lock schedule BEFORE applying enforcement.
        // If this fails, we must NOT unlock — matches applyTemporaryUnlock() pattern.
        do {
            try registerTempUnlockExpirySchedule(commandID: unlockID, start: now, end: expiresAt)
        } catch {
            eventLogger.log(.commandFailed, details: "Self-unlock ABORTED: schedule registration failed: \(error.localizedDescription)")
            try? storage.clearTemporaryUnlockState()
            return
        }

        // Also schedule a BGProcessingTask as a second safety net.
        AppDelegate.scheduleRelockTask(at: expiresAt)

        let result = try snapshotStore.commit(output.snapshot)
        switch result {
        case .committed(let snapshot):
            try enforcement?.apply(snapshot.effectivePolicy)
            try snapshotStore.markApplied()
        case .unchanged, .rejectedAsStale:
            if let snapshot = snapshotStore.loadCurrentSnapshot() {
                try enforcement?.apply(snapshot.effectivePolicy)
            }
        }
        eventLogger.log(.temporaryUnlockStarted, details: "Self-unlock for \(ModeChangeNotifier.formatDuration(durationSeconds))")
    }

    // MARK: - Timed Unlock (Penalty Offset)

    private func applyTimedUnlock(
        totalSeconds: Int,
        penaltySeconds: Int,
        issuedAt: Date,
        enrollment: ChildEnrollmentState,
        commandID: UUID
    ) throws {
        // Clear all competing state — timedUnlock overrides everything.
        try? storage.clearTemporaryUnlockState()
        try? storage.writeRawData(nil, forKey: "temporaryUnlockState.json")
        clearLockUntilState()

        // Account for delivery delay.
        let elapsed = Int(Date().timeIntervalSince(issuedAt))
        let adjustedPenalty = max(0, penaltySeconds - elapsed)
        let adjustedTotal = max(0, totalSeconds - elapsed)

        guard adjustedTotal > 0 else {
            eventLogger.log(.commandFailed, details: "Timed unlock expired before delivery (elapsed \(elapsed)s)")
            throw CommandError.expiredBeforeDelivery
        }

        if adjustedPenalty <= 0 {
            // Penalty already served — immediate unlock for remaining time.
            let unlockDuration = adjustedTotal
            try applyTemporaryUnlock(
                durationSeconds: unlockDuration,
                enrollment: enrollment,
                commandID: commandID
            )
            eventLogger.log(.commandApplied, details: "Timed unlock: no penalty remaining, unlocked for \(ModeChangeNotifier.formatDuration(unlockDuration))")
            if !suppressModeNotifications { ModeChangeNotifier.notifyTemporaryUnlock(durationSeconds: unlockDuration) }
        } else if adjustedPenalty >= adjustedTotal {
            // Penalty exceeds or equals total window — no free time at all.
            // Device must be actively locked for the entire duration.
            // Penalty timer (Firebase) ticks independently and will decrease
            // by adjustedTotal over the window duration.
            // Actively enforce locked mode in case the device is in an ambiguous
            // state (e.g., temp unlock was active before this command).
            let currentMode = snapshotStore.loadCurrentSnapshot()?.effectivePolicy.resolvedMode ?? .restricted
            let lockedMode: LockMode = currentMode == .unlocked ? .restricted : currentMode
            try applyMode(lockedMode, enrollment: enrollment, commandID: commandID, controlAuthority: .timedUnlock)
            eventLogger.log(.commandApplied, details: "Timed unlock: penalty \(ModeChangeNotifier.formatDuration(adjustedPenalty)) >= total \(ModeChangeNotifier.formatDuration(adjustedTotal)), no free time — device locked")
            if !suppressModeNotifications { ModeChangeNotifier.notifyPenaltyStarted(penaltySeconds: adjustedTotal, unlockSeconds: 0) }
        } else {
            // Penalty < total — lock during penalty, then unlock for remainder.
            let now = Date()
            let unlockAt = now.addingTimeInterval(Double(adjustedPenalty))
            let lockAt = now.addingTimeInterval(Double(adjustedTotal))
            let cal = Calendar.current

            // Use ONLY hour/minute/second — date components cause registration failures on iOS 17+.
            let startComps = cal.dateComponents([.hour, .minute, .second], from: unlockAt)
            let endComps = cal.dateComponents([.hour, .minute, .second], from: lockAt)

            let activityName = DeviceActivityName(rawValue: "bigbrother.timedunlock.\(commandID.uuidString)")
            let schedule = DeviceActivitySchedule(
                intervalStart: startComps,
                intervalEnd: endComps,
                repeats: false
            )

            let center = DeviceActivityCenter()
            try center.startMonitoring(activityName, during: schedule)

            // Store timed unlock info so the monitor extension knows to unlock/lock.
            let priorMode = snapshotStore.loadCurrentSnapshot()?.effectivePolicy.resolvedMode ?? .restricted
            let info = TimedUnlockInfo(
                commandID: commandID,
                activityName: activityName.rawValue,
                unlockAt: unlockAt,
                lockAt: lockAt,
                previousMode: priorMode
            )
            try storage.writeTimedUnlockInfo(info)

            // Schedule BGProcessingTasks as safety nets for both phase transitions.
            AppDelegate.scheduleRelockTask(at: unlockAt)  // penalty → unlock
            AppDelegate.scheduleRelockTask(at: lockAt)    // unlock → re-lock

            // Explicitly enforce locked mode during penalty phase.
            // The device may have been in an ambiguous state; ensure shields are active.
            // NOTE: applyMode() clears timedUnlockInfo, so we must re-write it after.
            let currentMode = snapshotStore.loadCurrentSnapshot()?.effectivePolicy.resolvedMode ?? .restricted
            let lockedMode = currentMode == .unlocked ? .restricted : currentMode
            try applyMode(lockedMode, enrollment: enrollment, commandID: commandID, controlAuthority: .timedUnlock)
            // Re-write timed unlock info because applyMode() clears it.
            try storage.writeTimedUnlockInfo(info)

            let penaltyStr = ModeChangeNotifier.formatDuration(adjustedPenalty)
            let unlockStr = ModeChangeNotifier.formatDuration(adjustedTotal - adjustedPenalty)
            eventLogger.log(.commandApplied, details: "Timed unlock: \(penaltyStr) penalty then \(unlockStr) free")
            if !suppressModeNotifications { ModeChangeNotifier.notifyPenaltyStarted(penaltySeconds: adjustedPenalty, unlockSeconds: adjustedTotal - adjustedPenalty) }
        }
    }

    // MARK: - Return to Schedule

    /// Clear overrides and apply the mode dictated by the child's schedule profile.
    /// Falls back to dailyMode if no profile is assigned.
    private func applyReturnToSchedule(enrollment: ChildEnrollmentState, commandID: UUID) throws {
        // Clear any temporary unlock / timed unlock / lockUntil state.
        // Retry + nuclear fallback to handle file lock contention.
        try? storage.clearTemporaryUnlockState()
        try? storage.writeRawData(nil, forKey: "temporaryUnlockState.json")
        try? storage.clearTimedUnlockInfo()
        try? storage.writeRawData(nil, forKey: "timedUnlockInfo.json")
        clearLockUntilState()

        // Cancel any active temp/timed/lockuntil DeviceActivity schedules
        // so they don't interfere with the schedule-driven mode.
        cancelNonScheduleActivities()

        // Invalidate cached schedule version so the next sync cycle (every 60s)
        // forces a re-fetch from CloudKit. This catches stale schedules when
        // the parent edited the profile but the child hasn't synced yet.
        let versionKey = "scheduleProfileVersion.\(enrollment.deviceID.rawValue)"
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.removeObject(forKey: versionKey)

        // Read the active schedule profile and re-register DeviceActivity intervals
        // so upcoming transitions (e.g., restricted → locked at bedtime) fire correctly.
        let mode: LockMode
        if let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
            // Re-register the schedule so the Monitor fires for the next transition.
            ScheduleRegistrar.register(profile, storage: storage)
        } else {
            mode = .restricted
        }

        try applyMode(mode, enrollment: enrollment, commandID: commandID, controlAuthority: .schedule)
        if !suppressModeNotifications { ModeChangeNotifier.notify(newMode: mode) }
    }

    /// Wake the DeviceActivityMonitor extension to apply enforcement from its privileged context.
    /// Fires intervalDidEnd in the Monitor by stopping the currently-active reconciliation quarter.
    /// The Monitor re-applies enforcement from its privileged context, then re-registers the quarter.
    private func triggerMonitorEnforcementRefresh() {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "needsEnforcementRefresh")

        let center = DeviceActivityCenter()
        let activeReconciliation = center.activities.filter { $0.rawValue.hasPrefix("bigbrother.reconciliation") }
        let hour = Calendar.current.component(.hour, from: Date())
        let quarter = hour / 6
        let quarterName = DeviceActivityName(rawValue: "bigbrother.reconciliation.q\(quarter)")
        NSLog("[CommandProcessor] triggerMonitorRefresh: \(activeReconciliation.count) reconciliation activities, stopping q\(quarter)")
        center.stopMonitoring([quarterName])
    }

    /// Clear lockUntil state from UserDefaults. Must be called by any command that
    /// overrides the lockUntil (setMode, returnToSchedule, temporaryUnlock, timedUnlock).
    private func clearLockUntilState() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.removeObject(forKey: "lockUntilPreviousMode")
        defaults?.removeObject(forKey: "lockUntilExpiresAt")
    }

    /// Cancel all non-schedule DeviceActivity monitors (temp unlock, timed unlock, lock-until).
    private func cancelNonScheduleActivities() {
        let center = DeviceActivityCenter()
        let prefixes = ["bigbrother.tempunlock.", "bigbrother.timedunlock.", "bigbrother.lockuntil."]
        for activity in center.activities {
            if prefixes.contains(where: { activity.rawValue.hasPrefix($0) }) {
                center.stopMonitoring([activity])
            }
        }
    }

    // MARK: - Lock Until

    /// Lock the device immediately and register a DeviceActivitySchedule to
    /// return to schedule at the target date.
    private func applyLockUntil(date: Date, enrollment: ChildEnrollmentState, commandID: UUID) throws {
        let now = Date()

        // If the lockUntil date is already in the past (late delivery / bad signal),
        // skip the lock entirely — don't over-lock the device with no expiry mechanism.
        guard date > now else {
            eventLogger.log(.commandApplied, details: "lockUntil skipped: target \(date) already past")
            return
        }

        // lockUntil is temporary — it pushes onto the stack and restores prior mode at expiry.
        // Clear any active temp/timed unlock — lockUntil overrides them.
        try? storage.clearTemporaryUnlockState()
        try? storage.writeRawData(nil, forKey: "temporaryUnlockState.json")
        try? storage.clearTimedUnlockInfo()
        try? storage.writeRawData(nil, forKey: "timedUnlockInfo.json")
        cancelNonScheduleActivities()

        // Save prior mode and expiry for restoration + self-healing.
        let priorMode = snapshotStore.loadCurrentSnapshot()?.effectivePolicy.resolvedMode ?? .restricted
        let lockDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        lockDefaults?.set(priorMode.rawValue, forKey: "lockUntilPreviousMode")
        lockDefaults?.set(date.timeIntervalSince1970, forKey: "lockUntilExpiresAt")

        // Apply lock immediately.
        try applyMode(.restricted, enrollment: enrollment, commandID: commandID, controlAuthority: .lockUntil)

        // Schedule BGTask safety net (in case Monitor misses the callback).
        AppDelegate.scheduleRelockTask(at: date)

        let cal = Calendar.current
        // Use ONLY hour/minute/second — date components cause registration failures on iOS 17+.
        let startComps = cal.dateComponents([.hour, .minute, .second], from: now)
        let endComps = cal.dateComponents([.hour, .minute, .second], from: date)

        let activityName = DeviceActivityName(rawValue: "bigbrother.lockuntil.\(commandID.uuidString)")
        let schedule = DeviceActivitySchedule(
            intervalStart: startComps,
            intervalEnd: endComps,
            repeats: false
        )

        let center = DeviceActivityCenter()
        try center.startMonitoring(activityName, during: schedule)

        #if DEBUG
        print("[BigBrother] Registered lockUntil schedule: \(activityName.rawValue), ends at \(date)")
        #endif
    }

    // MARK: - Token Lookup
    //
    // The token data is embedded in the event log entry's details field
    // (format: "Requesting access to AppName\nTOKEN:base64data").
    // This is the ONLY reliable cross-extension channel — file writes
    // from extensions silently fail on real iOS devices.
    //
    // Falls back to the pending requests file (best-effort backup).

    /// Look up token data and app name for a request, checking the event log first.
    private func findTokenForRequest(_ requestID: UUID) -> (tokenData: Data, appName: String)? {
        // Primary: check the event log queue (written by ShieldAction, proven to work).
        let events = storage.readPendingEventLogs()
        if let event = events.first(where: { $0.id == requestID && $0.eventType == .unlockRequested }),
           let details = event.details {
            if let result = extractTokenFromDetails(details) {
                #if DEBUG
                print("[BigBrother] Found token in event log for request \(requestID)")
                #endif
                return result
            }

            if let appName = extractAppNameFromRequestDetails(details) {
                let matches = findTokensForAppName(appName)
                if matches.count == 1, let match = matches.first {
                    #if DEBUG
                    print("[BigBrother] Resolved token by app name for request \(requestID): \(appName)")
                    #endif
                    return match
                }
            }
        }

        // Fallback: check the pending requests file (may work if main app wrote it).
        let requests = storage.readPendingUnlockRequests()
        if let request = requests.first(where: { $0.id == requestID }) {
            #if DEBUG
            print("[BigBrother] Found token in pending requests file for request \(requestID)")
            #endif
            return (request.tokenData, request.appName)
        }

        #if DEBUG
        let unlockEvents = events.filter { $0.eventType == .unlockRequested }
        print("[BigBrother] Token not found for request \(requestID) — checked \(unlockEvents.count) unlock events and \(requests.count) pending requests")
        for e in unlockEvents {
            let hasToken = e.details?.contains("\nTOKEN:") ?? false
            print("[BigBrother]   event \(e.id) hasToken=\(hasToken) uploaded=\(e.uploadState) details=\(e.details?.prefix(80) ?? "nil")")
        }
        #endif
        return nil
    }

    /// Extract app name and base64-encoded token from event details.
    /// Format: "Requesting access to AppName\nBUNDLE:id\nTOKEN:base64data"
    private func extractTokenFromDetails(_ details: String) -> (tokenData: Data, appName: String)? {
        let parts = details.components(separatedBy: "\nTOKEN:")
        guard parts.count == 2,
              let tokenData = Data(base64Encoded: parts[1]) else {
            return nil
        }
        
        let head = parts[0]
        let nameParts = head.components(separatedBy: "\nBUNDLE:")
        let appName: String
        if nameParts[0].hasPrefix("Requesting access to ") {
            appName = String(nameParts[0].dropFirst("Requesting access to ".count))
        } else {
            appName = "an app"
        }
        return (tokenData, appName)
    }

    private func extractBundleIDFromDetails(_ details: String) -> String? {
        guard let bundleRange = details.range(of: "\nBUNDLE:") else { return nil }
        let afterBundle = details[bundleRange.upperBound...]
        let endOfLine = afterBundle.range(of: "\n")?.lowerBound ?? afterBundle.endIndex
        return String(afterBundle[..<endOfLine])
    }

    private func findIdentityForRequest(_ requestID: UUID) -> (tokenData: Data?, bundleID: String?, appName: String)? {
        let events = storage.readPendingEventLogs()
        if let event = events.first(where: { $0.id == requestID && $0.eventType == .unlockRequested }),
           let details = event.details {
            let tokenData = extractTokenFromDetails(details)?.tokenData
            let bundleID = extractBundleIDFromDetails(details)
            let appName = extractAppNameFromRequestDetails(details) ?? "an app"
            return (tokenData, bundleID, appName)
        }
        return nil
    }

    private func extractAppNameFromRequestDetails(_ details: String) -> String? {
        let head: String
        if let tokenRange = details.range(of: "\nTOKEN:") {
            head = String(details[..<tokenRange.lowerBound])
        } else {
            head = details
        }

        guard head.hasPrefix("Requesting access to ") else {
            return nil
        }

        let appName = String(head.dropFirst("Requesting access to ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty else { return nil }
        return appName
    }

    /// Handle "allow app permanently" — look up token, add to allowed set.
    private func handleAllowApp(requestID: UUID) -> CommandProcessingResult {
        guard let identity = findIdentityForRequest(requestID) else {
            return .failedValidation(reason: "Identity for request \(requestID) not found")
        }

        // 1. Update permanent allowed tokens (if available).
        if let tokenData = identity.tokenData,
           let token = try? JSONDecoder().decode(ApplicationToken.self, from: tokenData) {
            var allowedTokens = loadAllowedTokens()
            allowedTokens.insert(token)
            if let data = try? JSONEncoder().encode(allowedTokens) {
                try? storage.writeRawData(data, forKey: StorageKeys.allowedAppTokens)
            }
        }

        // 2. Update permanent allowed bundle IDs.
        if let bundleID = identity.bundleID {
            var allowedBundles = loadAllowedBundleIDs()
            allowedBundles.insert(bundleID)
            if let data = try? JSONEncoder().encode(allowedBundles) {
                try? storage.writeRawData(data, forKey: "allowedBundleIDs")
            }
        }

        try? storage.removePendingUnlockRequest(id: requestID)
        reapplyCurrentEnforcement()

        return .applied
    }

    /// Handle "allow managed app" — resolve cached token(s) by app name and add them
    /// to the permanent allow list for this device.
    private func handleAllowManagedApp(appName: String) -> CommandProcessingResult {
        guard Self.isUsefulAppName(appName) else {
            return .failedValidation(reason: "Refusing to allow unusable app name: \(appName)")
        }
        let matches = findTokensForAppName(appName)
        guard !matches.isEmpty else {
            return .failedValidation(reason: "Token for app \(appName) not found on device")
        }

        var allowedTokens = loadAllowedTokens()
        let decoder = JSONDecoder()

        for match in matches {
            guard let token = try? decoder.decode(ApplicationToken.self, from: match.tokenData) else {
                return .failedExecution(reason: "Failed to decode app token for \(appName)")
            }
            allowedTokens.insert(token)
        }

        guard let data = try? JSONEncoder().encode(allowedTokens) else {
            return .failedExecution(reason: "Failed to encode allowed tokens")
        }

        try? storage.writeRawData(data, forKey: StorageKeys.allowedAppTokens)
        reapplyCurrentEnforcement()
        return .applied
    }

    /// Handle "revoke app" — find the token by request ID and remove from allowed set.
    private func handleRevokeApp(requestID: UUID) -> CommandProcessingResult {
        let identity = findIdentityForRequest(requestID)
        
        // Revoke token.
        if let tokenData = identity?.tokenData,
           let token = try? JSONDecoder().decode(ApplicationToken.self, from: tokenData) {
            var allowedTokens = loadAllowedTokens()
            allowedTokens.remove(token)
            if let data = try? JSONEncoder().encode(allowedTokens) {
                try? storage.writeRawData(data, forKey: StorageKeys.allowedAppTokens)
            }
        }

        // Revoke bundle ID.
        if let bundleID = identity?.bundleID {
            var allowedBundles = loadAllowedBundleIDs()
            allowedBundles.remove(bundleID)
            if let data = try? JSONEncoder().encode(allowedBundles) {
                try? storage.writeRawData(data, forKey: "allowedBundleIDs")
            }
        }

        reapplyCurrentEnforcement()
        return .applied
    }

    /// Handle "block managed app" — resolve cached token(s) by app name and remove them
    /// from both the permanent and temporary allow lists.
    private func handleBlockManagedApp(appName: String) -> CommandProcessingResult {
        guard Self.isUsefulAppName(appName) else {
            return .failedValidation(reason: "Refusing to block unusable app name: \(appName)")
        }
        let matches = findTokensForAppName(appName)
        guard !matches.isEmpty else {
            return .failedValidation(reason: "Token for app \(appName) not found for revocation")
        }

        let decoder = JSONDecoder()
        var allowedTokens = loadAllowedTokens()

        for match in matches {
            guard let token = try? decoder.decode(ApplicationToken.self, from: match.tokenData) else {
                return .failedExecution(reason: "Failed to decode app token for \(appName)")
            }
            allowedTokens.remove(token)
        }

        if let data = try? JSONEncoder().encode(allowedTokens) {
            try? storage.writeRawData(data, forKey: StorageKeys.allowedAppTokens)
        }

        let normalizedName = Self.normalizeAppName(appName)
        let tokenKeys = Set(matches.map { $0.tokenData.base64EncodedString() })
        let tempEntries = storage.readTemporaryAllowedApps()
        let filteredEntries = tempEntries.filter { entry in
            let entryKey = entry.tokenData.base64EncodedString()
            let matchesName = Self.normalizeAppName(entry.appName) == normalizedName
            let matchesToken = tokenKeys.contains(entryKey)
            return entry.isValid && !matchesName && !matchesToken
        }

        if filteredEntries.count != tempEntries.count {
            try? storage.writeTemporaryAllowedApps(filteredEntries)
        }

        reapplyCurrentEnforcement()
        return .applied
    }

    /// Handle "temporarily unlock a specific app" — look up the token, add to
    /// the temporary-allowed list with an expiry timestamp.
    private func handleTemporaryUnlockApp(requestID: UUID, durationSeconds: Int) -> CommandProcessingResult {
        guard let identity = findIdentityForRequest(requestID) else {
            return .failedValidation(reason: "Identity for request \(requestID) not found")
        }

        let expiresAt = Date().addingTimeInterval(Double(durationSeconds))
        let entry = TemporaryAllowedAppEntry(
            requestID: requestID,
            tokenData: identity.tokenData ?? Data(), // Handle empty token for bundle-only
            appName: identity.appName,
            bundleID: identity.bundleID,
            expiresAt: expiresAt
        )

        var entries = storage.readTemporaryAllowedApps()
        entries.removeAll { $0.expiresAt < Date() }
        entries.removeAll { $0.requestID == requestID }
        entries.append(entry)

        do {
            try storage.writeTemporaryAllowedApps(entries)
        } catch {
            return .failedExecution(reason: "Failed to write temporary allowed apps")
        }

        reapplyCurrentEnforcement()
        eventLogger.log(.commandApplied, details: "App \(identity.appName) unlocked temporarily")
        return .applied
    }

    /// Handle "name app" — update the local name cache so ShieldAction uses the correct name.
    private func handleNameApp(fingerprint: String, name: String) -> CommandProcessingResult {
        // Find all cached tokens whose fingerprint matches and update their names.
        let cache = storage.readAllCachedAppNames()
        for (tokenBase64, _) in cache {
            // Compute fingerprint for this token
            if let data = Data(base64Encoded: tokenBase64) {
                let fp = Self.tokenFingerprint(for: data)
                if fp.hasPrefix(fingerprint) || fingerprint.hasPrefix(fp.prefix(fingerprint.count).description) {
                    storage.cacheAppName(name, forTokenKey: tokenBase64)
                }
            }
        }

        // Also store in UserDefaults for extension access
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        var nameMap = defaults?.dictionary(forKey: "tokenToAppName") as? [String: String] ?? [:]
        // Store with fingerprint as key (extension can look up by fingerprint too)
        nameMap["fp:\(fingerprint)"] = name
        defaults?.set(nameMap, forKey: "tokenToAppName")

        eventLogger.log(.commandApplied, details: "App named: \(name) (fingerprint \(fingerprint))")
        return .applied
    }

    /// Handle "revoke all apps" — clear all permanent and temporary allow lists,
    /// plus pending app review probes (unreviewed 1-minute limits).
    private func handleRevokeAllApps() -> CommandProcessingResult {
        // Nuclear: clear everything app-related.
        try? storage.writeRawData(nil, forKey: StorageKeys.allowedAppTokens)
        try? storage.writeRawData(nil, forKey: "allowedBundleIDs")
        try? storage.writeTemporaryAllowedApps([])
        try? storage.writeAppTimeLimits([])
        try? storage.writeTimeLimitExhaustedApps([])
        ScheduleRegistrar.registerTimeLimitEvents(limits: [])
        reapplyCurrentEnforcement()
        eventLogger.log(.commandApplied, details: "All apps and time limits revoked")
        return .applied
    }

    /// Handle "set restrictions" — store and apply device restrictions.
    private func handleSetRestrictions(_ restrictions: DeviceRestrictions) -> CommandProcessingResult {
        do {
            try storage.writeDeviceRestrictions(restrictions)
        } catch {
            return .failedExecution(reason: "Failed to write restrictions: \(error.localizedDescription)")
        }
        reapplyCurrentEnforcement()
        eventLogger.log(.commandApplied, details: "Restrictions updated: removal=\(restrictions.denyAppRemoval) explicit=\(restrictions.denyExplicitContent) accounts=\(restrictions.lockAccounts) dateTime=\(restrictions.requireAutomaticDateAndTime)")
        return .applied
    }

    private static func tokenFingerprint(for data: Data) -> String {
        TokenFingerprint.fingerprint(for: data)
    }

    // MARK: - App Review (Mode 2)

    /// Handle app review/transition. Supports ALL state changes:
    /// pending→allowed, pending→timeLimited, pending→blocked,
    /// allowed→timeLimited, timeLimited→allowed, any→blocked (delete).
    private func handleReviewApp(fingerprint: String, disposition: AppDisposition, minutes: Int?) -> CommandProcessingResult {
        var limits = storage.readAppTimeLimits()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        // Load allowed tokens
        var allowedTokens = Set<ApplicationToken>()
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let existing = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            allowedTokens = existing
        }

        // Find the token for this fingerprint from any source
        let token: ApplicationToken? = {
            // From time limits
            if let limit = limits.first(where: { $0.fingerprint == fingerprint }),
               let t = try? decoder.decode(ApplicationToken.self, from: limit.tokenData) {
                return t
            }
            // From allowed list (check each token's fingerprint)
            for t in allowedTokens {
                if let data = try? encoder.encode(t),
                   TokenFingerprint.fingerprint(for: data) == fingerprint {
                    return t
                }
            }
            // From picker selection
            if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
               let sel = try? decoder.decode(FamilyActivitySelection.self, from: data) {
                for t in sel.applicationTokens {
                    if let data = try? encoder.encode(t),
                       TokenFingerprint.fingerprint(for: data) == fingerprint {
                        return t
                    }
                }
            }
            return nil
        }()

        // Clean up: remove from ALL lists first (clean transition)
        if let token {
            allowedTokens.remove(token)
        }
        limits.removeAll { $0.fingerprint == fingerprint }
        var exhausted = storage.readTimeLimitExhaustedApps()
        exhausted.removeAll { $0.fingerprint == fingerprint }

        switch disposition {
        case .allowAlways:
            if let token {
                allowedTokens.insert(token)
            }

        case .timeLimit:
            let dailyMinutes = minutes ?? 60
            if let token, let tokenData = try? encoder.encode(token) {
                let appName = storage.readAllCachedAppNames()[tokenData.base64EncodedString()] ?? "App"
                let limit = AppTimeLimit(
                    appName: appName,
                    tokenData: tokenData,
                    fingerprint: fingerprint,
                    dailyLimitMinutes: dailyMinutes,
                    wasAlreadyAllowed: false
                )
                limits.append(limit)
                // Also add to allowed so app is usable until limit reached
                allowedTokens.insert(token)
            }

        case .keepBlocked:
            // Remove from picker selection too (fully block)
            if let token,
               let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
               var sel = try? decoder.decode(FamilyActivitySelection.self, from: data) {
                sel.applicationTokens.remove(token)
                if let encoded = try? encoder.encode(sel) {
                    try? storage.writeRawData(encoded, forKey: StorageKeys.familyActivitySelection)
                }
            }
        }

        // Persist all changes
        if let encoded = try? encoder.encode(allowedTokens) {
            try? storage.writeRawData(encoded, forKey: StorageKeys.allowedAppTokens)
        }
        try? storage.writeAppTimeLimits(limits)

        // Check if any time-limited app already exceeds its limit (retroactive enforcement).
        // This handles: parent converts always-allowed to 30 min, kid already used 45 min.
        if disposition == .timeLimit, let mins = minutes, let token {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let today = f.string(from: Date())
            // Check screen time milestones for approximate usage
            let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
            let _ = defaults?.integer(forKey: "screenTimeMinutes") ?? 0
            // If we can't determine exact per-app usage, check if the app was previously
            // in the exhausted list (re-adding after grant extra time).
            // Conservative: if we just set a limit, register events and let them fire naturally.
            // But also check app-specific usage from the tunnel DNS tracker.
            if let tokenData = try? encoder.encode(token) {
                let appUsageKey = "appUsage.\(TokenFingerprint.fingerprint(for: tokenData)).\(today)"
                let appMinutes = defaults?.integer(forKey: appUsageKey) ?? 0
                if appMinutes >= mins {
                    // Already exceeded — immediately exhaust
                    let limitID = limits.first(where: { $0.fingerprint == fingerprint })?.id ?? UUID()
                    let entry = TimeLimitExhaustedApp(
                        timeLimitID: limitID,
                        appName: limits.first(where: { $0.fingerprint == fingerprint })?.appName ?? "App",
                        tokenData: tokenData,
                        fingerprint: fingerprint
                    )
                    exhausted.append(entry)
                }
            }
        }

        try? storage.writeTimeLimitExhaustedApps(exhausted)
        ScheduleRegistrar.registerTimeLimitEvents(limits: limits)
        reapplyCurrentEnforcement()
        eventLogger.log(.commandApplied, details: "App \(disposition.rawValue): fp \(fingerprint.prefix(8))\(minutes.map { " \($0)m" } ?? "")")
        return .applied
    }

    // MARK: - App Time Limits

    private func handleGrantExtraTime(fingerprint: String, extraMinutes: Int) -> CommandProcessingResult {
        let limits = storage.readAppTimeLimits()
        guard let idx = limits.firstIndex(where: { $0.fingerprint == fingerprint }) else {
            return .failedExecution(reason: "No time limit found for fingerprint \(fingerprint)")
        }

        // Remove from exhausted list
        var exhausted = storage.readTimeLimitExhaustedApps()
        exhausted.removeAll { $0.fingerprint == fingerprint }
        try? storage.writeTimeLimitExhaustedApps(exhausted)

        // Store extra time separately (date-keyed so it resets at midnight).
        // Do NOT modify limits[idx].dailyLimitMinutes — that's the permanent base limit.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let todayKey = "extraTime.\(fingerprint).\(f.string(from: Date()))"
        let existing = defaults?.integer(forKey: todayKey) ?? 0
        defaults?.set(existing + extraMinutes, forKey: todayKey)

        // Re-register DeviceActivityEvent with effective threshold (base + extra)
        var adjustedLimits = limits
        adjustedLimits[idx].dailyLimitMinutes += existing + extraMinutes
        ScheduleRegistrar.registerTimeLimitEvents(limits: adjustedLimits)

        reapplyCurrentEnforcement()
        eventLogger.log(.timeLimitExtended, details: "\(limits[idx].appName): +\(extraMinutes) min today (base \(limits[idx].dailyLimitMinutes) + \(existing + extraMinutes) extra)")
        return .applied
    }

    private func handleRemoveTimeLimit(fingerprint: String) -> CommandProcessingResult {
        var limits = storage.readAppTimeLimits()
        let removed = limits.first(where: { $0.fingerprint == fingerprint })
        limits.removeAll { $0.fingerprint == fingerprint }
        try? storage.writeAppTimeLimits(limits)

        // Persist name + token for future re-add.
        if let removed {
            let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
            var nameMap = (defaults?.dictionary(forKey: "harvestedAppNames") as? [String: String]) ?? [:]
            nameMap[removed.fingerprint] = removed.appName
            defaults?.set(nameMap, forKey: "harvestedAppNames")
            storage.cacheAppName(removed.appName, forTokenKey: removed.tokenData.base64EncodedString())
        }

        // Remove from exhausted list
        var exhausted = storage.readTimeLimitExhaustedApps()
        exhausted.removeAll { $0.fingerprint == fingerprint }
        try? storage.writeTimeLimitExhaustedApps(exhausted)

        // Remove from allowed tokens so the app gets blocked by category shield.
        // Only remove if the app wasn't already allowed before the time limit was added.
        if let removed {
            let center = DeviceActivityCenter()
            let activityName = DeviceActivityName(rawValue: "bigbrother.timelimit.\(removed.id.uuidString)")
            center.stopMonitoring([activityName])

            if !removed.wasAlreadyAllowed,
               let token = try? JSONDecoder().decode(ApplicationToken.self, from: removed.tokenData) {
                var allowed: Set<ApplicationToken>
                if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                   let existing = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
                    allowed = existing
                } else {
                    allowed = []
                }
                allowed.remove(token)
                if let encoded = try? JSONEncoder().encode(allowed) {
                    try? storage.writeRawData(encoded, forKey: StorageKeys.allowedAppTokens)
                }
            }
        }

        // Re-register remaining limits
        ScheduleRegistrar.registerTimeLimitEvents(limits: limits)

        reapplyCurrentEnforcement()
        eventLogger.log(.commandApplied, details: "Time limit removed: \(removed?.appName ?? fingerprint)")
        return .applied
    }

    private func handleBlockAppForToday(fingerprint: String) -> CommandProcessingResult {
        let limits = storage.readAppTimeLimits()
        guard let limit = limits.first(where: { $0.fingerprint == fingerprint }) else {
            return .failedExecution(reason: "No time limit found for fingerprint \(fingerprint)")
        }

        var exhausted = storage.readTimeLimitExhaustedApps()
        let today: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: Date())
        }()

        // Already exhausted today — no-op
        guard !exhausted.contains(where: { $0.fingerprint == fingerprint && $0.dateString == today }) else {
            return .applied
        }

        let entry = TimeLimitExhaustedApp(
            id: UUID(),
            timeLimitID: limit.id,
            appName: limit.appName,
            tokenData: limit.tokenData,
            fingerprint: limit.fingerprint,
            exhaustedAt: Date(),
            dateString: today
        )
        exhausted.append(entry)
        try? storage.writeTimeLimitExhaustedApps(exhausted)

        reapplyCurrentEnforcement()
        eventLogger.log(.timeLimitExhausted, details: "\(limit.appName) blocked for today by parent")
        return .applied
    }

    /// Re-apply enforcement so ManagedSettingsStore picks up changes.
    /// Called after any change to allowed app lists or device restrictions.
    /// Always applies — device restrictions are active even in unlocked mode.
    /// Returns false if enforcement fails (caller should report failure).
    @discardableResult
    private func reapplyCurrentEnforcement() -> Bool {
        guard let snapshot = snapshotStore.loadCurrentSnapshot() else { return false }
        // Use ModeStackResolver as ground truth — the snapshot may have stale
        // isTemporaryUnlock or mode from a previous command. Without this,
        // revokeAllApps can trigger applyWideOpenShields() via a stale snapshot.
        let resolution = ModeStackResolver.resolve(storage: storage)
        var policy = snapshot.effectivePolicy
        if resolution.mode != policy.resolvedMode || (!policy.isTemporaryUnlock && storage.readTemporaryUnlockState() == nil) {
            policy = EffectivePolicy(
                resolvedMode: resolution.mode,
                controlAuthority: resolution.controlAuthority,
                isTemporaryUnlock: storage.readTemporaryUnlockState() != nil,
                temporaryUnlockExpiresAt: storage.readTemporaryUnlockState()?.expiresAt,
                shieldedCategoriesData: policy.shieldedCategoriesData,
                allowedAppTokensData: policy.allowedAppTokensData,
                deviceRestrictions: policy.deviceRestrictions,
                warnings: policy.warnings,
                policyVersion: policy.policyVersion
            )
        }
        do {
            try enforcement?.apply(policy)
            return true
        } catch {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "reapplyCurrentEnforcement failed",
                details: error.localizedDescription
            ))
            return false
        }
    }

    private func loadAllowedTokens() -> Set<ApplicationToken> {
        guard let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens) else {
            return []
        }
        return (try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data)) ?? []
    }

    /// Resolve all known token payloads for an app name using the shared cache first,
    /// then pending requests and unsynced events as fallbacks.
    private func findTokensForAppName(_ appName: String) -> [(tokenData: Data, appName: String)] {
        let normalizedName = Self.normalizeAppName(appName)
        guard !normalizedName.isEmpty else { return [] }

        var results: [(tokenData: Data, appName: String)] = []
        var seenTokenKeys = Set<String>()

        func append(tokenData: Data, appName: String) {
            let key = tokenData.base64EncodedString()
            guard seenTokenKeys.insert(key).inserted else { return }
            results.append((tokenData: tokenData, appName: appName))
        }

        for (tokenKey, cachedName) in storage.readAllCachedAppNames()
        where Self.isUsefulAppName(cachedName) &&
              Self.normalizeAppName(cachedName) == normalizedName {
            guard let tokenData = Data(base64Encoded: tokenKey) else { continue }
            append(tokenData: tokenData, appName: cachedName)
        }

        for request in storage.readPendingUnlockRequests()
        where Self.normalizeAppName(request.appName) == normalizedName {
            append(tokenData: request.tokenData, appName: request.appName)
        }

        for event in storage.readPendingEventLogs() where event.eventType == .unlockRequested {
            guard let details = event.details,
                  let found = extractTokenFromDetails(details),
                  Self.normalizeAppName(found.appName) == normalizedName else {
                continue
            }
            append(tokenData: found.tokenData, appName: found.appName)
        }

        return results
    }

    private static func normalizeAppName(_ appName: String) -> String {
        appName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUsefulAppName(_ appName: String) -> Bool {
        let normalized = normalizeAppName(appName).lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.contains("token(") &&
            !normalized.contains("data:") &&
            !normalized.contains("bytes)")
    }

    private func findBundleIDForRequest(_ requestID: UUID) -> String? {
        // Try to find the bundle ID in the keychain cache from the last shield event.
        let keychain = self.keychain
        if let cached = try? keychain.get(LastShieldedAppKeychain.self, forKey: StorageKeys.lastShieldedAppKeychain),
           cached.timestamp > Date().addingTimeInterval(-3600).timeIntervalSince1970 {
            return cached.bundleID
        }
        
        // Fallback: check shared defaults.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        return defaults?.string(forKey: "lastShielded.bundleID")
    }

    private func loadAllowedBundleIDs() -> Set<String> {
        guard let data = storage.readRawData(forKey: "allowedBundleIDs") else {
            return []
        }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    /// Returns true for commands that affect device lock state and should be processed first.
    private static func isEnforcementCommand(_ action: CommandAction) -> Bool {
        switch action {
        case .setMode, .temporaryUnlock, .timedUnlock, .lockUntil, .returnToSchedule,
             .allowApp, .revokeApp, .allowManagedApp, .blockManagedApp,
             .temporaryUnlockApp, .revokeAllApps, .requestAlwaysAllowedSetup, .unenroll,
             .requestTimeLimitSetup, .requestChildAppPick,
             .reviewApp, .reviewApps,
             .grantExtraTime, .removeTimeLimit, .blockAppForToday:
            return true
        case .setSelfUnlockBudget, .setRestrictions, .nameApp, .syncPINHash,
             .setScheduleProfile, .clearScheduleProfile, .setHeartbeatProfile,
             .setPenaltyTimer, .requestHeartbeat, .requestAppConfiguration,
             .setAllowedWebDomains, .addTrustedSigningKey, .sendMessage,
             .setLocationMode, .requestLocation, .requestPermissions, .setHomeLocation,
             .syncNamedPlaces, .setDrivingSettings, .requestDiagnostics, .setSafeSearch,
             .blockInternet:
            return false
        }
    }

    /// Returns true if critical permissions are missing (FamilyControls or location not "Always").
    /// Used to block unlock and force essential mode until the child grants permissions.
    private func hasPermissionDeficiency() -> Bool {
        // FamilyControls must be authorized
        if let enforcement, enforcement.authorizationStatus != .authorized {
            return true
        }
        // Location must be "Always" (not denied, not whenInUse, not notDetermined)
        let locStatus = CLLocationManager().authorizationStatus
        if locStatus != .authorizedAlways {
            return true
        }
        return false
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
            appliedAt: Date(),
            failureReason: reason
        )
    }
}
