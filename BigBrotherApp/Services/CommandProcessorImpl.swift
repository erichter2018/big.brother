import Foundation
import CloudKit
import ManagedSettings
import DeviceActivity
import BigBrotherCore

/// Serializes access to a boolean flag for async contexts.
private actor ProcessingGate {
    private var active = false

    func tryStart() -> Bool {
        guard !active else { return false }
        active = true
        return true
    }

    func finish() {
        active = false
    }
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
            print("[BigBrother] Command processing already in progress — skipping")
            #endif
            return
        }
        
        // Clear the gate when done. We use do/catch + explicit await instead of
        // defer { Task { ... } } which would clear the gate asynchronously and could
        // cause the next invocation to be skipped.
        do {
            try await _processIncomingCommandsBody()
        } catch {
            await processingGate.finish()
            throw error
        }
        await processingGate.finish()
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

        // Separate enforcement commands (lock/unlock) from config commands (budget, etc.).
        let enforcementCommands = unprocessed.filter { Self.isEnforcementCommand($0.action) }
        let configCommands = unprocessed.filter { !Self.isEnforcementCommand($0.action) }

        // For mode commands (setMode, temporaryUnlock, timedUnlock, lockUntil, returnToSchedule),
        // only the LATEST one matters — earlier ones are superseded. Per-app enforcement
        // commands (allowApp, blockManagedApp, etc.) still all execute.
        let modeCommands = enforcementCommands.filter { $0.action.isModeCommand }
        let perAppCommands = enforcementCommands.filter { !$0.action.isModeCommand }

        var effectiveModeCommands: [RemoteCommand] = []
        if let latestMode = modeCommands.max(by: { $0.issuedAt < $1.issuedAt }) {
            effectiveModeCommands = [latestMode]
            // Mark superseded mode commands as processed so they're never re-fetched.
            for cmd in modeCommands where cmd.id != latestMode.id {
                #if DEBUG
                print("[BigBrother] Superseded mode command: \(cmd.action.displayDescription) (id=\(cmd.id))")
                #endif
                try? storage.markCommandProcessed(cmd.id)
                // Post a receipt so the parent sees it was superseded, not stuck pending.
                let receipt = makeReceipt(
                    commandID: cmd.id,
                    deviceID: enrollment.deviceID,
                    familyID: enrollment.familyID,
                    status: .applied,
                    reason: "Superseded by newer mode command"
                )
                try? await cloudKit.saveReceipt(receipt)
            }
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
                    latestConfig[key] = cmd
                } else {
                    try? storage.markCommandProcessed(cmd.id)
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

            // Post receipt and try to update command record directly.
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
        // Check expiration.
        if let expiresAt = command.expiresAt, expiresAt < Date() {
            eventLogger.log(.commandFailed, details: "Command \(command.id) expired")
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
            }
            // If no public keys stored (pre-signing enrollment), accept with warning
        }

        do {
            switch command.action {
            case .setMode(let mode):
                try applyMode(mode, enrollment: enrollment, commandID: command.id)
                UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.set(false, forKey: "scheduleDrivenMode")
                eventLogger.log(.commandApplied, details: "Mode set to \(mode.rawValue)")
                ModeChangeNotifier.notify(newMode: mode)
                return .applied

            case .temporaryUnlock(let durationSeconds):
                let wasUnlocked = snapshotStore.loadCurrentSnapshot()?.effectivePolicy.resolvedMode == .unlocked
                try applyTemporaryUnlock(
                    durationSeconds: durationSeconds,
                    enrollment: enrollment,
                    commandID: command.id
                )
                let h = durationSeconds / 3600
                let m = (durationSeconds % 3600) / 60
                let dur = h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
                eventLogger.log(.commandApplied, details: "\(wasUnlocked ? "Extended" : "Temporary") unlock for \(dur)")
                ModeChangeNotifier.notifyTemporaryUnlock(durationSeconds: durationSeconds, isExtension: wasUnlocked)
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
                try? enforcement?.clearAllRestrictions()
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
                try applyTimedUnlock(
                    totalSeconds: totalSeconds,
                    penaltySeconds: penaltySeconds,
                    issuedAt: command.issuedAt,
                    enrollment: enrollment,
                    commandID: command.id
                )
                return .applied

            case .returnToSchedule:
                try applyReturnToSchedule(enrollment: enrollment, commandID: command.id)
                UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.set(true, forKey: "scheduleDrivenMode")
                eventLogger.log(.commandApplied, details: "Returned to schedule-driven mode")
                return .applied

            case .lockUntil(let date):
                UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.set(false, forKey: "scheduleDrivenMode")
                try applyLockUntil(date: date, enrollment: enrollment, commandID: command.id)
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                eventLogger.log(.commandApplied, details: "Locked until \(formatter.string(from: date))")
                ModeChangeNotifier.notify(newMode: .dailyMode)
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
            }

        } catch {
            eventLogger.log(.commandFailed, details: "Command \(command.id): \(error.localizedDescription)")
            return .failedExecution(reason: error.localizedDescription)
        }
    }

    /// Apply a mode change through the canonical snapshot pipeline.
    private func applyMode(_ mode: LockMode, enrollment: ChildEnrollmentState, commandID: UUID) throws {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("command", forKey: "lastShieldChangeReason")
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

        // Clear any active temporary/timed unlock on explicit mode change.
        try? storage.clearTemporaryUnlockState()
        try? storage.clearTimedUnlockInfo()
        cancelNonScheduleActivities()

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
    ///
    /// Also registers a DeviceActivitySchedule that fires at `expiresAt` so the
    /// monitor extension re-locks the device even if the main app is terminated.
    private func applyTemporaryUnlock(
        durationSeconds: Int,
        enrollment: ChildEnrollmentState,
        commandID: UUID
    ) throws {
        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let currentVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0
        let currentMode = currentSnapshot?.effectivePolicy.resolvedMode ?? .essentialOnly

        let now = Date()
        let expiresAt = now.addingTimeInterval(Double(durationSeconds))

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

            // Register a DeviceActivitySchedule so the monitor extension re-locks
            // when the unlock expires — works even if the main app is terminated.
            // This MUST succeed — without it, a force-close during unlock = permanent unlock.
            try registerTempUnlockExpirySchedule(commandID: commandID, start: now, end: expiresAt)

            // Also schedule a BGProcessingTask as a second safety net.
            AppDelegate.scheduleRelockTask(at: expiresAt)

            let durationStr = ModeChangeNotifier.formatDuration(durationSeconds)
            eventLogger.log(.temporaryUnlockStarted, details: "Unlocked for \(durationStr)")
        }
    }

    /// Register a one-shot DeviceActivitySchedule that fires `intervalDidEnd`
    /// at the temporary unlock expiry time. The monitor extension handles re-lock.
    /// Throws if registration fails — caller must not grant unlock without a re-lock guarantee.
    private func registerTempUnlockExpirySchedule(commandID: UUID, start: Date, end: Date) throws {
        let cal = Calendar.current
        let startComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let endComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)

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
        let currentMode = currentSnapshot?.effectivePolicy.resolvedMode ?? .dailyMode

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
            trigger: "selfUnlock(\(durationSeconds)s)"
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs,
            previousSnapshot: currentSnapshot
        )

        let result = try snapshotStore.commit(output.snapshot)
        if case .committed(let snapshot) = result {
            try enforcement?.apply(snapshot.effectivePolicy)
            try snapshotStore.markApplied()
            try registerTempUnlockExpirySchedule(commandID: unlockID, start: now, end: expiresAt)
            eventLogger.log(.temporaryUnlockStarted, details: "Self-unlock for \(ModeChangeNotifier.formatDuration(durationSeconds))")
        }
    }

    // MARK: - Timed Unlock (Penalty Offset)

    private func applyTimedUnlock(
        totalSeconds: Int,
        penaltySeconds: Int,
        issuedAt: Date,
        enrollment: ChildEnrollmentState,
        commandID: UUID
    ) throws {
        // Account for delivery delay.
        let elapsed = Int(Date().timeIntervalSince(issuedAt))
        let adjustedPenalty = max(0, penaltySeconds - elapsed)
        let adjustedTotal = max(0, totalSeconds - elapsed)

        guard adjustedTotal > 0 else {
            eventLogger.log(.commandFailed, details: "Timed unlock expired before delivery (elapsed \(elapsed)s)")
            // Notify parent that the command was dropped.
            let ck = cloudKit
            let receipt = CommandReceipt(
                commandID: commandID,
                deviceID: enrollment.deviceID,
                familyID: enrollment.familyID,
                status: .expired,
                failureReason: "Expired before delivery (elapsed \(elapsed)s)"
            )
            Task.detached { try? await ck.saveReceipt(receipt) }
            return
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
            ModeChangeNotifier.notifyTemporaryUnlock(durationSeconds: unlockDuration)
        } else if adjustedPenalty >= adjustedTotal {
            // Penalty exceeds or equals total window — no free time at all.
            // Device stays locked. Penalty timer (Firebase) ticks independently
            // and will decrease by adjustedTotal over the window duration.
            // No schedule needed — the device is already locked.
            eventLogger.log(.commandApplied, details: "Timed unlock: penalty \(ModeChangeNotifier.formatDuration(adjustedPenalty)) >= total \(ModeChangeNotifier.formatDuration(adjustedTotal)), no free time — penalty consumed")
            ModeChangeNotifier.notifyPenaltyStarted(penaltySeconds: adjustedTotal, unlockSeconds: 0)
        } else {
            // Penalty < total — lock during penalty, then unlock for remainder.
            let now = Date()
            let unlockAt = now.addingTimeInterval(Double(adjustedPenalty))
            let lockAt = now.addingTimeInterval(Double(adjustedTotal))
            let cal = Calendar.current

            let startComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: unlockAt)
            let endComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: lockAt)

            let activityName = DeviceActivityName(rawValue: "bigbrother.timedunlock.\(commandID.uuidString)")
            let schedule = DeviceActivitySchedule(
                intervalStart: startComps,
                intervalEnd: endComps,
                repeats: false
            )

            let center = DeviceActivityCenter()
            try center.startMonitoring(activityName, during: schedule)

            // Store timed unlock info so the monitor extension knows to unlock/lock.
            let info = TimedUnlockInfo(
                commandID: commandID,
                activityName: activityName.rawValue,
                unlockAt: unlockAt,
                lockAt: lockAt
            )
            try storage.writeTimedUnlockInfo(info)

            // Schedule BGProcessingTasks as safety nets for both phase transitions.
            AppDelegate.scheduleRelockTask(at: unlockAt)  // penalty → unlock
            AppDelegate.scheduleRelockTask(at: lockAt)    // unlock → re-lock

            // Explicitly enforce locked mode during penalty phase.
            // The device may have been in an ambiguous state; ensure shields are active.
            // NOTE: applyMode() clears timedUnlockInfo, so we must re-write it after.
            let currentMode = snapshotStore.loadCurrentSnapshot()?.effectivePolicy.resolvedMode ?? .dailyMode
            let lockedMode = currentMode == .unlocked ? .dailyMode : currentMode
            try applyMode(lockedMode, enrollment: enrollment, commandID: commandID)
            // Re-write timed unlock info because applyMode() clears it.
            try storage.writeTimedUnlockInfo(info)

            let penaltyStr = ModeChangeNotifier.formatDuration(adjustedPenalty)
            let unlockStr = ModeChangeNotifier.formatDuration(adjustedTotal - adjustedPenalty)
            eventLogger.log(.commandApplied, details: "Timed unlock: \(penaltyStr) penalty then \(unlockStr) free")
            ModeChangeNotifier.notifyPenaltyStarted(penaltySeconds: adjustedPenalty, unlockSeconds: adjustedTotal - adjustedPenalty)
        }
    }

    // MARK: - Return to Schedule

    /// Clear overrides and apply the mode dictated by the child's schedule profile.
    /// Falls back to dailyMode if no profile is assigned.
    private func applyReturnToSchedule(enrollment: ChildEnrollmentState, commandID: UUID) throws {
        // Clear any temporary unlock / timed unlock state.
        try? storage.clearTemporaryUnlockState()
        try? storage.clearTimedUnlockInfo()

        // Cancel any active temp/timed/lockuntil DeviceActivity schedules
        // so they don't interfere with the schedule-driven mode.
        cancelNonScheduleActivities()

        // Read the active schedule profile from App Group storage.
        let mode: LockMode
        if let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
        } else {
            mode = .dailyMode
        }

        try applyMode(mode, enrollment: enrollment, commandID: commandID)
        ModeChangeNotifier.notify(newMode: mode)
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
        // Apply dailyMode lock immediately.
        try applyMode(.dailyMode, enrollment: enrollment, commandID: commandID)

        // Register a one-shot DeviceActivitySchedule that fires at the target date.
        // When it fires, the monitor extension will call returnToSchedule.
        let now = Date()
        guard date > now else { return }

        let cal = Calendar.current
        let startComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let endComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

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

    /// Handle "revoke all apps" — clear all permanent and temporary allow lists.
    private func handleRevokeAllApps() -> CommandProcessingResult {
        // Clear permanent allowed tokens.
        try? storage.writeRawData(nil, forKey: StorageKeys.allowedAppTokens)
        try? storage.writeRawData(nil, forKey: "allowedBundleIDs")
        // Clear temporary allowed apps.
        try? storage.writeTemporaryAllowedApps([])
        reapplyCurrentEnforcement()
        eventLogger.log(.commandApplied, details: "All allowed apps revoked")
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

    /// Re-apply enforcement so ManagedSettingsStore picks up changes.
    /// Called after any change to allowed app lists or device restrictions.
    /// Always applies — device restrictions are active even in unlocked mode.
    private func reapplyCurrentEnforcement() {
        guard let snapshot = snapshotStore.loadCurrentSnapshot() else { return }
        try? enforcement?.apply(snapshot.effectivePolicy)
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
             .temporaryUnlockApp, .revokeAllApps, .requestAlwaysAllowedSetup, .unenroll:
            return true
        case .setSelfUnlockBudget, .setRestrictions, .nameApp, .syncPINHash,
             .setScheduleProfile, .clearScheduleProfile, .setHeartbeatProfile,
             .setPenaltyTimer, .requestHeartbeat, .requestAppConfiguration,
             .setAllowedWebDomains, .addTrustedSigningKey, .sendMessage,
             .setLocationMode, .requestLocation, .requestPermissions, .setHomeLocation,
             .syncNamedPlaces, .setDrivingSettings, .requestDiagnostics, .setSafeSearch:
            return false
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
            appliedAt: Date(),
            failureReason: reason
        )
    }
}
