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
///
/// ## Thread safety
///
/// `@unchecked Sendable` because:
///   1. Most instance fields are immutable `let`s set in `init`.
///   2. `ProcessingGate` serializes `processIncomingCommands()` — the only
///      entry point that mutates per-invocation state.
///   3. Callback closures (`onRequestHeartbeat`, `onRequestLocation`, etc.)
///      are set once at wiring time by `AppState` and dispatched back to
///      MainActor via `Task { @MainActor in ... }` before firing.
///   4. CloudKit / storage / keychain / enforcement dependencies manage
///      their own thread safety (documented on their respective types).
///
/// Actor conversion would require every caller (including synchronous
/// heartbeat paths from timers that can't await) to hop through an async
/// boundary, and the `onXxx` callback pattern wouldn't compose cleanly.
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
    /// Called when a startLiveTracking command is received.
    var onStartLiveTracking: ((Int) -> Void)?
    /// Called when a stopLiveTracking command is received.
    var onStopLiveTracking: (() -> Void)?

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

    #if DEBUG
    /// Debug-only entry point for the automated shield test harness.
    /// Bypasses CloudKit fetch and runs a single already-constructed command
    /// through the same processing code path real parent commands use
    /// (snapshot commit → enforcement.apply → shield write → heartbeat).
    /// Called by TestCommandReceiver when a Darwin notification arrives
    /// from `xcrun devicectl device notification post`.
    func processTestCommand(_ command: RemoteCommand) async {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else {
            NSLog("[TestCommandReceiver] No enrollment — dropping test command \(command.id)")
            return
        }
        beginEnforcementBatch()
        defer { endEnforcementBatch() }
        let result = await processCommand(command, enrollment: enrollment)
        NSLog("[TestCommandReceiver] Processed \(command.action): \(result.logReason)")
    }
    #endif

    private func _processIncomingCommandsBody() async throws {

        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        // The tunnel processes CK commands but cannot apply ManagedSettings
        // (no family-controls entitlement). It writes this flag so the main
        // app can schedule a Monitor wake. The main app HAS the entitlement,
        // so its DeviceActivity schedule registrations work (unlike the
        // tunnel's). The Monitor then applies enforcement from its
        // privileged context. We don't call enforcement.apply() directly
        // because ManagedSettings writes silently fail from backgrounded apps.
        let enforcementDefaults = UserDefaults.appGroup
        let refreshEpoch = enforcementDefaults?.double(forKey: AppGroupKeys.needsEnforcementRefresh) ?? 0
        if refreshEpoch > 0 {
            NSLog("[BigBrother] needsEnforcementRefresh flag set (epoch=\(refreshEpoch)) — applying enforcement")
            // Layer 1: Try direct apply (works if app was recently foreground,
            // silently fails if XPC connection is stale from background).
            if let policy = snapshotStore.loadCurrentSnapshot()?.effectivePolicy {
                try? enforcement?.apply(policy)
            }
            // Layer 2: Schedule Monitor wake at 65s. The main app HAS the
            // family-controls entitlement so the registration works even from
            // background. 65s ensures the minute component is in the future
            // (DeviceActivity has minute-level granularity). The Monitor
            // applies enforcement from its privileged context — guaranteed.
            scheduleEnforcementRefreshActivity(source: "tunnelFlag", delaySeconds: 65)
        }

        let commands = try await cloudKit.fetchPendingCommands(
            deviceID: enrollment.deviceID,
            childProfileID: enrollment.childProfileID,
            familyID: enrollment.familyID
        )

        let processedIDs = storage.readProcessedCommandIDs()
        // Also check tunnel's processed command IDs — tunnel processes mode commands
        // from CloudKit polling when the main app is dead. Without this check, the
        // main app would re-process commands the tunnel already applied.
        // The tunnel writes the FULL recordName ("BBRemoteCommand_<UUID>") which
        // would never match the bare UUID string we compare against. Strip the
        // prefix here so dedup actually works — without this, every mode command
        // the tunnel processed got re-applied by the app on next poll, inflating
        // policyVersion by thousands and burning the daemon.
        let tunnelDefaults = UserDefaults.appGroup
        let rawTunnelProcessed = tunnelDefaults?.stringArray(forKey: "tunnelAppliedCommandIDs") ?? []
        let tunnelProcessed = Set(rawTunnelProcessed.map { entry in
            entry.hasPrefix("BBRemoteCommand_")
                ? String(entry.dropFirst("BBRemoteCommand_".count))
                : entry
        })

        #if DEBUG
        print("[BigBrother] Found \(commands.count) pending commands, \(processedIDs.count) app + \(tunnelProcessed.count) tunnel already processed")
        #endif

        // Filter out already-processed commands (by app OR tunnel).
        let unprocessed = commands.filter {
            !processedIDs.contains($0.id) && !tunnelProcessed.contains($0.id.uuidString)
        }

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
        // If the tunnel processed mode commands, the snapshot is correct but
        // ManagedSettings shields were never applied (tunnel lacks the
        // family-controls entitlement). Re-apply enforcement for the current
        // resolved mode so shields match the snapshot the tunnel wrote.
        let tunnelHandledModeCommands = commands.filter { cmd in
            tunnelProcessed.contains(cmd.id.uuidString) && cmd.action.isModeCommand
        }

        #if DEBUG
        if sorted.isEmpty && !commands.isEmpty {
            print("[BigBrother] All commands already processed (deduped)")
        } else {
            print("[BigBrother] \(effectiveModeCommands.count) mode + \(perAppCommands.count) per-app + \(latestConfig.count) config to process (\(skippedMode) mode + \(skippedConfig) config skipped)")
        }
        if !tunnelHandledModeCommands.isEmpty {
            print("[BigBrother] \(tunnelHandledModeCommands.count) tunnel-processed mode commands — re-applying enforcement")
        }
        #endif

        var modeCommandResult: CommandProcessingResult?
        // Open an enforcement batch around the whole command loop. Per-handler
        // calls to reapplyCurrentEnforcement() are coalesced inside the batch
        // and a single apply runs at the end. Prevents the burst-write daemon
        // corruption pattern that breaks ManagedSettings under rapid command
        // processing (~30 reviewApp calls in ~5 minutes degraded the agent).
        beginEnforcementBatch()
        defer { endEnforcementBatch() }

        if !tunnelHandledModeCommands.isEmpty {
            reapplyCurrentEnforcement()
        }

        // Poison-pill: if the same command UUID has been processed >3 times in
        // the recent history (e.g. tunnel/app dedup mismatch, CK status update
        // perpetually failing), force-mark it processed locally and skip. Stops
        // runaway loops that inflate policyVersion and exhaust the FC daemon.
        //
        // UserDefaults round-trips Int values as NSNumber, so we map through
        // NSNumber on read — the naive `as? [String: Int]` cast fails silently
        // and the counter never accumulates.
        let poisonKey = "fr.bigbrother.commandProcessCounts"
        let poisonDefaults = UserDefaults.appGroup
        var processCounts: [String: Int] = {
            guard let raw = poisonDefaults?.dictionary(forKey: poisonKey) else { return [:] }
            var out: [String: Int] = [:]
            for (k, v) in raw {
                if let n = v as? NSNumber { out[k] = n.intValue }
                else if let i = v as? Int { out[k] = i }
            }
            return out
        }()
        defer {
            // Trim the counter map to last 100 entries to prevent unbounded growth.
            if processCounts.count > 100 {
                let trimmed = processCounts.sorted { $0.value > $1.value }.prefix(100)
                processCounts = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
            }
            poisonDefaults?.set(processCounts, forKey: poisonKey)
        }

        for command in sorted {
            #if DEBUG
            print("[BigBrother] Processing command: \(command.action), id=\(command.id)")
            #endif
            // Increment the counter and check the threshold BEFORE processing.
            let pkey = command.id.uuidString
            let count = (processCounts[pkey] ?? 0) + 1
            processCounts[pkey] = count
            if count > 3 {
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .command,
                    message: "POISON-PILL: command \(command.id.uuidString.prefix(8)) processed \(count)x — force-marking and skipping",
                    details: "Action: \(command.action). Likely cause: tunnel/app dedup mismatch or CK status update failing repeatedly."
                ))
                try? storage.markCommandProcessed(command.id)
                try? await cloudKit.updateCommandStatus(command.id, status: .applied)
                continue
            }
            let result = await processCommand(command, enrollment: enrollment)
            if command.action.isModeCommand { modeCommandResult = result }
            #if DEBUG
            print("[BigBrother] Command result: \(result.logReason)")
            #endif

            // Mark processed IMMEDIATELY after applying — before receipt upload.
            // If the app is killed between apply and mark, the command would be
            // re-processed on next sync (double-granting time, resetting timers).
            do {
                try storage.markCommandProcessed(command.id)
            } catch {
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .command,
                    message: "Failed to mark command \(command.id) as processed: \(error.localizedDescription)"
                ))
            }

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
                // Save the receipt (child-owned record type). Retry up to 3x
                // on transient errors. The receipt is the authoritative signal
                // to the parent that this command was processed — the parent
                // reads receipts to update its own dashboard state.
                var receiptSaved = false
                for attempt in 1...3 {
                    do {
                        try await cloudKit.saveReceipt(receipt)
                        receiptSaved = true
                        break
                    } catch {
                        if attempt == 3 {
                            eventLogger.log(.commandFailed, details: "Receipt upload failed after 3 attempts for \(command.id): \(error.localizedDescription)")
                        } else {
                            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                        }
                    }
                }

                // Separately attempt the command-status update. This is a
                // convenience for the parent dashboard (so the command record
                // flips from "pending" to "applied"), but it's NOT the
                // authoritative path — the receipt is. On multi-iCloud-account
                // families, the child does NOT own the BBRemoteCommand record
                // (the parent created it), so this write throws "WRITE operation
                // not permitted". We silently swallow that error instead of
                // retrying — the parent will still see the correct state via
                // the receipt (saved above).
                if receiptSaved {
                    do {
                        try await cloudKit.updateCommandStatus(command.id, status: receiptStatus)
                    } catch {
                        let desc = error.localizedDescription.lowercased()
                        if desc.contains("permission") || desc.contains("not permitted") {
                            // Expected on multi-account families. Receipt is the
                            // authoritative signal — nothing else to do.
                        } else {
                            eventLogger.log(.commandFailed, details: "updateCommandStatus failed for \(command.id): \(error.localizedDescription)")
                        }
                    }
                }
            }

            // Log diagnostic.
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "\(command.action): \(result.logReason)",
                details: "Command ID: \(command.id)"
            ))
        }

        // Only supersede older mode commands if the winner was durably applied.
        // If the winner failed (bad signature, execution failure), keep the older
        // commands available for reprocessing on the next sync cycle.
        let shouldSupersede = modeCommandResult == .applied || modeCommandResult == .ignoredDuplicate || modeCommandResult == nil
        if !shouldSupersede && !supersededModeCommands.isEmpty {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "Mode command failed (\(modeCommandResult?.logReason ?? "unknown")) — keeping \(supersededModeCommands.count) superseded commands for fallback"
            ))
        }
        for cmd in supersededModeCommands where shouldSupersede {
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
            let defaults = UserDefaults.appGroup ?? .standard
            defaults.set(Date().timeIntervalSince1970, forKey: "fr.bigbrother.lastCommandProcessedAt")

            // Send heartbeat immediately so parent sees the confirmed mode change.
            onRequestHeartbeat?()
        }

        // DO NOT call trimUnusedSelectionTokens here. The trim was based on a
        // backwards assumption: it dropped any picker token NOT in allowedTokens
        // / appTimeLimits / pending. But the picker selection IS the universe of
        // "apps to block" — picker tokens that aren't in the allowed list are
        // exactly the apps that SHOULD be shielded. Running trim on every command
        // batch nuked the entire picker selection in locked mode (where allowed
        // is always empty), leaving Apps: 0 and triggering the verification
        // false-failure loop. Revoke-side cleanup (handleBlockManagedApp removing
        // matching tokens from selection) is sufficient and correct.
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
                // (e.g., MDM removal clears Keychain entries). Accept with warning for now.
                // TODO: Once all devices have signing keys re-enrolled, switch to rejecting
                // unsigned mode commands here (S3 in AUDIT_TODO.md).
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
                    // Nuclear: delete via typed API (correct filename)
                    try? storage.clearTemporaryUnlockState()
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .command,
                        message: "Failed to clear temp unlock during setMode (retried): \(error.localizedDescription)"
                    ))
                }
                do {
                    try storage.clearTimedUnlockInfo()
                } catch {
                    try? storage.clearTimedUnlockInfo()
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
                Task { @MainActor [weak self] in
                    self?.onRequestHeartbeat?()
                }
                return .applied

            case .requestAppConfiguration:
                Task { @MainActor [weak self] in
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
                Task { @MainActor [weak self] in
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
                Task { @MainActor [weak self] in
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
                Task { @MainActor [weak self] in
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
                // 1. Update CloudKit device record so other syncs see the new assignment.
                try await cloudKit.updateDeviceFields(
                    deviceID: enrollment.deviceID,
                    fields: [
                        CKFieldName.scheduleProfileID: profileID.uuidString as CKRecordValue,
                        CKFieldName.scheduleProfileVersion: versionDate as CKRecordValue
                    ]
                )

                // 2. Fetch and register the profile LOCALLY so it takes effect immediately.
                //    Without this, the 60s sync might read a stale CK cache and revert
                //    to the old schedule before the new assignment propagates.
                do {
                    let profiles = try await cloudKit.fetchScheduleProfiles(familyID: enrollment.familyID)
                    if let profile = profiles.first(where: { $0.id == profileID }) {
                        ScheduleRegistrar.register(profile, storage: storage)
                        eventLogger.log(.commandApplied, details: "Schedule profile set + registered: \(profile.name) (\(profileID.uuidString.prefix(8)))")
                    } else {
                        // Profile not found in CK — trigger async sync to retry later.
                        eventLogger.log(.commandApplied, details: "Schedule profile set (CK field updated, profile fetch pending): \(profileID.uuidString.prefix(8))")
                        DispatchQueue.main.async { [weak self] in
                            self?.onScheduleSyncNeeded?()
                        }
                    }
                } catch {
                    // CK fetch failed — the 60s sync will pick it up eventually.
                    eventLogger.log(.commandApplied, details: "Schedule profile set (profile fetch failed, will retry): \(profileID.uuidString.prefix(8))")
                    DispatchQueue.main.async { [weak self] in
                        self?.onScheduleSyncNeeded?()
                    }
                }
                return .applied

            case .clearScheduleProfile:
                try await cloudKit.updateDeviceFields(
                    deviceID: enrollment.deviceID,
                    fields: [
                        CKFieldName.scheduleProfileID: nil,
                        CKFieldName.scheduleProfileVersion: nil
                    ]
                )
                // Clear locally immediately so DeviceActivity schedules are removed.
                ScheduleRegistrar.clearAll(storage: storage)
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
                UserDefaults.appGroup?
                    .set(mode.rawValue, forKey: "locationTrackingMode")
                Task { @MainActor [weak self] in
                    self?.onLocationModeChanged?(mode)
                }
                eventLogger.log(.commandApplied, details: "Location mode set to \(mode.rawValue)")
                return .applied

            case .requestLocation:
                Task { @MainActor [weak self] in
                    self?.onRequestLocation?()
                }
                eventLogger.log(.commandApplied, details: "Location requested")
                return .applied

            case .requestPermissions:
                Task { @MainActor [weak self] in
                    self?.onRequestPermissions?()
                }
                eventLogger.log(.commandApplied, details: "Permissions re-request triggered")
                return .applied

            case .setHomeLocation(let latitude, let longitude):
                let defaults = UserDefaults.appGroup
                defaults?.set(latitude, forKey: "homeLatitude")
                defaults?.set(longitude, forKey: "homeLongitude")
                // Trigger LocationService to register the geofence immediately.
                Task { @MainActor [weak self] in
                    self?.onRequestLocation?() // Reuses location callback to refresh
                }
                eventLogger.log(.commandApplied, details: "Home geofence set at (\(latitude), \(longitude))")
                return .applied

            case .syncNamedPlaces:
                Task { @MainActor [weak self] in
                    self?.onSyncNamedPlaces?()
                }
                eventLogger.log(.commandApplied, details: "Named places sync requested")
                return .applied

            case .setDrivingSettings(let settings):
                if let data = try? JSONEncoder().encode(settings) {
                    UserDefaults.appGroup?
                        .set(data, forKey: "drivingSettings")
                }
                eventLogger.log(.commandApplied, details: "Driving settings updated: speed limit \(Int(settings.speedThresholdMPH)) mph")
                return .applied

            case .requestDiagnostics:
                Task { @MainActor [weak self] in
                    self?.onRequestDiagnostics?()
                }
                eventLogger.log(.commandApplied, details: "Diagnostic report requested")
                return .applied

            case .setSafeSearch(let enabled):
                UserDefaults.appGroup?
                    .set(enabled, forKey: "safeSearchEnabled")
                // Restart the VPN tunnel to pick up the new DNS settings
                Task { @MainActor [weak self] in
                    self?.onRestartVPNTunnel?()
                }
                eventLogger.log(.commandApplied, details: "Safe search \(enabled ? "enabled" : "disabled")")
                return .applied

            case .blockInternet:
                // Legacy: internet blocking is now inherent to .lockedDown mode.
                // The tunnel reads mode from App Group and applies DNS blackhole automatically.
                // Just restart the tunnel to re-evaluate.
                Task { @MainActor [weak self] in
                    self?.onRestartVPNTunnel?()
                }
                eventLogger.log(.commandApplied, details: "Internet block state synced (mode-driven)")
                return .applied

            case .requestTimeLimitSetup:
                Task { @MainActor [weak self] in
                    self?.onRequestTimeLimitSetup?()
                }
                eventLogger.log(.commandApplied, details: "Time limit setup requested by parent (Mode 1)")
                return .applied

            case .requestChildAppPick:
                Task { @MainActor [weak self] in
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

            // Live tracking handled automatically by LocationService when moving
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

        UserDefaults.appGroup?
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

        // Pass the raw always-allowed tokens data through the pipeline so the
        // snapshot's effectivePolicy.allowedAppTokensData is populated. The
        // Monitor extension uses this as a fallback when its App Group file
        // read returns empty (extension context file coordination quirks).
        // Without this, Monitor's fallback was always nil and its second-pass
        // writes collapsed restricted → locked by losing the exception set.
        let allowedAppTokensData = storage.readRawData(forKey: StorageKeys.allowedAppTokens)
        let inputs = PolicyPipelineCoordinator.Inputs(
            basePolicy: policy,
            alwaysAllowedTokensData: allowedAppTokensData,
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
            NSLog("[CommandProcessor] applyMode(\(effectiveMode.rawValue)): enforcement.apply() completed")
            try snapshotStore.markApplied()

            // Verify write stuck — moved off main thread to avoid UI freeze.
            // The Monitor trigger below is the real safety net for background writes.
            //
            // IMPORTANT: both retry loops re-read the CURRENT snapshot instead
            // of applying the captured one. If a newer command was committed
            // while this task was sleeping, our captured snapshot is stale and
            // re-applying it would stomp the newer state. Re-reading ensures
            // we only ever apply the authoritative latest state — if it
            // matches ours, great; if it's been superseded, the newer
            // command's own retry loop is responsible for it and we exit.
            let verifyEnforcement = enforcement
            let verifySnapshotStore = snapshotStore
            let committedVersion = snapshot.effectivePolicy.policyVersion
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                guard let currentSnap = verifySnapshotStore.loadCurrentSnapshot(),
                      currentSnap.effectivePolicy.policyVersion == committedVersion else {
                    NSLog("[CommandProcessor] Post-write verify SKIPPED — newer snapshot superseded v\(committedVersion)")
                    return
                }
                let verifyDiag = verifyEnforcement?.shieldDiagnostic()
                let shouldBeShielded = currentSnap.effectivePolicy.resolvedMode != .unlocked
                let isShielded = verifyDiag?.shieldsActive == true || verifyDiag?.categoryActive == true
                if shouldBeShielded != isShielded {
                    NSLog("[CommandProcessor] POST-WRITE VERIFY FAILED — retrying (shields=\(isShielded), expected=\(shouldBeShielded))")
                    try? await Task.sleep(for: .seconds(0.5))
                    // Re-read again — another command may have landed in the 0.5s sleep.
                    guard let stillCurrent = verifySnapshotStore.loadCurrentSnapshot(),
                          stillCurrent.effectivePolicy.policyVersion == committedVersion else {
                        NSLog("[CommandProcessor] Post-write verify retry SKIPPED — newer snapshot superseded v\(committedVersion)")
                        return
                    }
                    try? verifyEnforcement?.apply(stillCurrent.effectivePolicy)
                    let retryDiag = verifyEnforcement?.shieldDiagnostic()
                    let retryOK = (retryDiag?.shieldsActive == true || retryDiag?.categoryActive == true) == shouldBeShielded
                    NSLog("[CommandProcessor] Retry result: \(retryOK ? "OK" : "STILL FAILED")")
                } else {
                    NSLog("[CommandProcessor] Post-write verify OK")
                }
            }

            // Trigger the Monitor extension to apply enforcement from its privileged context.
            // The main app's enforcement.apply() above is best-effort (works in foreground).
            let triggerTime = Date().timeIntervalSince1970
            triggerMonitorEnforcementRefresh()

            // Verify the Monitor actually applied enforcement within the
            // background-task window (~20s of polling). The scheduled
            // enforcementRefresh activity fires ~90s from now, so if the main
            // app gets suspended during the wait, the Monitor still wakes
            // itself and applies shields — we don't need to hold the process
            // alive to wait for it. Inside the window, retry the main-app
            // write every 3s as a best-effort backstop in case FC auth / XPC
            // recovers during the wait. Retries re-read the current snapshot
            // so we never stomp a newer command with this task's stale one.
            let maxAttempts = 20
            Task.detached {
                let defaults = UserDefaults.appGroup
                var confirmed = false
                for attempt in 1...maxAttempts {
                    try? await Task.sleep(for: .seconds(1))
                    let confirmedAt = defaults?.double(forKey: "monitorEnforcementConfirmedAt") ?? 0
                    if confirmedAt >= triggerTime {
                        NSLog("[CommandProcessor] Monitor confirmed enforcement after \(attempt)s")
                        confirmed = true
                        break
                    }
                    // Exit the loop early if a newer snapshot superseded ours —
                    // that command's own retry loop now owns recovery.
                    guard let currentSnap = verifySnapshotStore.loadCurrentSnapshot(),
                          currentSnap.effectivePolicy.policyVersion == committedVersion else {
                        NSLog("[CommandProcessor] Monitor confirm loop exiting — newer snapshot superseded v\(committedVersion)")
                        return
                    }
                    if attempt % 3 == 0 {
                        let isUnlockRetry = currentSnap.effectivePolicy.resolvedMode == .unlocked
                        NSLog("[CommandProcessor] \(isUnlockRetry ? "Unlock" : "Lock") not confirmed after \(attempt)s — retrying main-app apply")
                        try? verifyEnforcement?.apply(currentSnap.effectivePolicy)
                    }
                }
                if !confirmed {
                    NSLog("[CommandProcessor] Monitor not confirmed within main-app window; scheduled refresh (~90s) will handle it")
                    defaults?.set(Date().timeIntervalSince1970, forKey: "needsEnforcementRefresh")
                }
            }

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
            alwaysAllowedTokensData: storage.readRawData(forKey: StorageKeys.allowedAppTokens),
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

        // Trigger Monitor to clear shields from its privileged context.
        // Same confirmation handshake as applyMode — without this, stale shields
        // can remain after the unlock is "applied" from the main app.
        let triggerTime = Date().timeIntervalSince1970
        triggerMonitorEnforcementRefresh()

        Task.detached { [weak self] in
            let defaults = UserDefaults.appGroup
            var confirmed = false
            for attempt in 1...10 {
                try? await Task.sleep(for: .seconds(1))
                let confirmedAt = defaults?.double(forKey: "monitorEnforcementConfirmedAt") ?? 0
                if confirmedAt >= triggerTime {
                    NSLog("[CommandProcessor] Monitor confirmed temp unlock enforcement after \(attempt)s")
                    confirmed = true
                    break
                }
                // Retry clear from app every 3s as backup
                if attempt % 3 == 0 {
                    NSLog("[CommandProcessor] Temp unlock not confirmed after \(attempt)s — retrying clear")
                    if let snap = self?.snapshotStore.loadCurrentSnapshot() {
                        try? self?.enforcement?.apply(snap.effectivePolicy)
                    }
                }
                if attempt % 5 == 0 {
                    self?.triggerMonitorEnforcementRefresh()
                }
            }
            if !confirmed {
                NSLog("[CommandProcessor] Monitor did NOT confirm temp unlock after 10s — flag set")
                defaults?.set(Date().timeIntervalSince1970, forKey: "needsEnforcementRefresh")
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
            alwaysAllowedTokensData: storage.readRawData(forKey: StorageKeys.allowedAppTokens),
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
        try? storage.clearTemporaryUnlockState()
        try? storage.clearTimedUnlockInfo()
        clearLockUntilState()

        // Cancel any active temp/timed/lockuntil DeviceActivity schedules
        // so they don't interfere with the schedule-driven mode.
        cancelNonScheduleActivities()

        // Invalidate cached schedule version so the next sync cycle (every 60s)
        // forces a re-fetch from CloudKit. This catches stale schedules when
        // the parent edited the profile but the child hasn't synced yet.
        let versionKey = "scheduleProfileVersion.\(enrollment.deviceID.rawValue)"
        UserDefaults.appGroup?.removeObject(forKey: versionKey)

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
        // Schedule a near-future one-shot DeviceActivity that fires intervalDidStart
        // in the Monitor extension, which applies enforcement from its privileged
        // context. This replaces the old stopMonitoring/re-register-quarter trick
        // which was silently a no-op on iOS 17+ (stopMonitoring doesn't fire
        // intervalDidEnd; re-registering a schedule whose start is in the past
        // doesn't fire intervalDidStart). See scheduleEnforcementRefreshActivity.
        scheduleEnforcementRefreshActivity(source: "cmdProc.trigger")

        // Self-heal: make sure all 4 reconciliation quarters are registered so
        // the natural 6-hour fallback keeps working. Registering an activity that
        // already exists is a no-op.
        let center = DeviceActivityCenter()
        let existing = center.activities
        let quarters: [(name: String, startHour: Int, endHour: Int)] = [
            ("bigbrother.reconciliation.q0", 0, 5),
            ("bigbrother.reconciliation.q1", 6, 11),
            ("bigbrother.reconciliation.q2", 12, 17),
            ("bigbrother.reconciliation.q3", 18, 23),
        ]
        for q in quarters {
            let activityName = DeviceActivityName(rawValue: q.name)
            if existing.contains(activityName) { continue }
            let qSchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: q.startHour, minute: 0),
                intervalEnd: DateComponents(hour: q.endHour, minute: 59),
                repeats: true
            )
            try? center.startMonitoring(activityName, during: qSchedule)
        }
    }

    /// Clear lockUntil state from UserDefaults. Must be called by any command that
    /// overrides the lockUntil (setMode, returnToSchedule, temporaryUnlock, timedUnlock).
    private func clearLockUntilState() {
        let defaults = UserDefaults.appGroup
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
        try? storage.clearTimedUnlockInfo()
        cancelNonScheduleActivities()

        // Save prior mode and expiry for restoration + self-healing.
        let priorMode = snapshotStore.loadCurrentSnapshot()?.effectivePolicy.resolvedMode ?? .restricted
        let lockDefaults = UserDefaults.appGroup
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
    /// to the permanent allow list for this device. Also removes stale tokens for the
    /// same app name (token rotation cleanup).
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
        let encoder = JSONEncoder()

        // Garbage collect: remove stale tokens that resolve to nil Application
        // (token rotation aftermath — old tokens that no longer reference any app).
        let cache = storage.readAllCachedAppNames()
        let normalizedTarget = Self.normalizeAppName(appName)
        var staleRemoved = 0
        allowedTokens = allowedTokens.filter { token in
            guard let data = try? encoder.encode(token) else { return false }
            let key = data.base64EncodedString()
            // If the cached name for this token matches the target app, and we have
            // a fresh match below, drop the stale entry.
            if let cachedName = cache[key], Self.normalizeAppName(cachedName) == normalizedTarget {
                staleRemoved += 1
                return false
            }
            return true
        }

        for match in matches {
            guard let token = try? decoder.decode(ApplicationToken.self, from: match.tokenData) else {
                return .failedExecution(reason: "Failed to decode app token for \(appName)")
            }
            allowedTokens.insert(token)
        }

        guard let data = try? encoder.encode(allowedTokens) else {
            return .failedExecution(reason: "Failed to encode allowed tokens")
        }

        try? storage.writeRawData(data, forKey: StorageKeys.allowedAppTokens)
        if staleRemoved > 0 {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "Allowed \(appName): added \(matches.count) fresh token(s), dropped \(staleRemoved) stale"
            ))
        }
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

        // Also remove the matching tokens from familyActivitySelection. Without
        // this, the picker thinks the app is "still configured" and refuses to
        // let the child re-pick it later — leaving stale tokens that bloat the
        // selection forever.
        if let selData = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
           var selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: selData) {
            let encoder = JSONEncoder()
            let beforeCount = selection.applicationTokens.count
            selection.applicationTokens = selection.applicationTokens.filter { token in
                guard let data = try? encoder.encode(token) else { return true }
                return !tokenKeys.contains(data.base64EncodedString())
            }
            if selection.applicationTokens.count != beforeCount,
               let encoded = try? encoder.encode(selection) {
                try? storage.writeRawData(encoded, forKey: StorageKeys.familyActivitySelection)
            }
        }

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
        let defaults = UserDefaults.appGroup
        var nameMap = defaults?.dictionary(forKey: "tokenToAppName") as? [String: String] ?? [:]
        // Store with fingerprint as key (extension can look up by fingerprint too)
        nameMap["fp:\(fingerprint)"] = name
        defaults?.set(nameMap, forKey: "tokenToAppName")

        var harvestedNames = defaults?.dictionary(forKey: AppGroupKeys.harvestedAppNames) as? [String: String] ?? [:]
        harvestedNames[fingerprint] = name
        defaults?.set(harvestedNames, forKey: AppGroupKeys.harvestedAppNames)

        eventLogger.log(.commandApplied, details: "App named: \(name) (fingerprint \(fingerprint))")
        return .applied
    }

    private func authoritativeAppName(fingerprint: String, tokenData: Data? = nil) -> String? {
        let defaults = UserDefaults.appGroup
        if let fingerprintName = (defaults?.dictionary(forKey: AppGroupKeys.tokenToAppName) as? [String: String])?["fp:\(fingerprint)"],
           Self.isUsefulAppName(fingerprintName) {
            return fingerprintName
        }
        if let harvestedName = (defaults?.dictionary(forKey: AppGroupKeys.harvestedAppNames) as? [String: String])?[fingerprint],
           Self.isUsefulAppName(harvestedName) {
            return harvestedName
        }
        if let tokenData,
           let cachedName = storage.readAllCachedAppNames()[tokenData.base64EncodedString()],
           Self.isUsefulAppName(cachedName) {
            return cachedName
        }
        return nil
    }

    private func removePendingAppReviewsLocally(fingerprint: String) {
        if let data = storage.readRawData(forKey: "pending_review_local.json"),
           var pending = try? JSONDecoder().decode([PendingAppReview].self, from: data) {
            let before = pending.count
            pending.removeAll { $0.appFingerprint == fingerprint }
            if pending.count != before, let encoded = try? JSONEncoder().encode(pending) {
                try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
            }
        }
    }

    private func reviewDispositionLabel(_ disposition: AppDisposition) -> String {
        switch disposition {
        case .allowAlways: return "allowed"
        case .timeLimit: return "limited"
        case .keepBlocked: return "rejected"
        }
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
        requestRegisterTimeLimitEvents([])
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

        // Find the token for this fingerprint from any source.
        // Token rotation breaks fingerprint match — fall back to fresh tokens
        // from event log + pending unlock requests + name cache via app name lookup.
        let appNameForLookup: String = {
            if let authoritativeName = authoritativeAppName(fingerprint: fingerprint) {
                return authoritativeName
            }
            // Try to find a known app name for this fingerprint to use as fallback
            if let limit = limits.first(where: { $0.fingerprint == fingerprint }) {
                return limit.appName
            }
            for event in storage.readPendingEventLogs() where event.eventType == .unlockRequested {
                guard let details = event.details, let found = extractTokenFromDetails(details) else { continue }
                if TokenFingerprint.fingerprint(for: found.tokenData) == fingerprint {
                    return found.appName
                }
            }
            for req in storage.readPendingUnlockRequests() {
                if TokenFingerprint.fingerprint(for: req.tokenData) == fingerprint {
                    return req.appName
                }
            }
            return ""
        }()

        let token: ApplicationToken? = {
            // 1. Time limits (old token, may match)
            if let limit = limits.first(where: { $0.fingerprint == fingerprint }),
               let t = try? decoder.decode(ApplicationToken.self, from: limit.tokenData) {
                return t
            }
            // 2. Allowed list (old token, may match)
            for t in allowedTokens {
                if let data = try? encoder.encode(t),
                   TokenFingerprint.fingerprint(for: data) == fingerprint {
                    return t
                }
            }
            // 3. Picker selection (old token, may match)
            if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
               let sel = try? decoder.decode(FamilyActivitySelection.self, from: data) {
                for t in sel.applicationTokens {
                    if let data = try? encoder.encode(t),
                       TokenFingerprint.fingerprint(for: data) == fingerprint {
                        return t
                    }
                }
            }
            // 4. FRESH token via event log direct fingerprint match
            for event in storage.readPendingEventLogs() where event.eventType == .unlockRequested {
                guard let details = event.details, let found = extractTokenFromDetails(details) else { continue }
                if TokenFingerprint.fingerprint(for: found.tokenData) == fingerprint,
                   let t = try? decoder.decode(ApplicationToken.self, from: found.tokenData) {
                    return t
                }
            }
            // 5. FRESH token via PendingUnlockRequest direct fingerprint match
            for req in storage.readPendingUnlockRequests() {
                if TokenFingerprint.fingerprint(for: req.tokenData) == fingerprint,
                   let t = try? decoder.decode(ApplicationToken.self, from: req.tokenData) {
                    return t
                }
            }
            // 6. Last resort: name-based lookup (handles token rotation across app updates).
            // findTokensForAppName searches name cache + pending requests + event logs.
            if !appNameForLookup.isEmpty {
                let matches = findTokensForAppName(appNameForLookup)
                if let firstMatch = matches.first,
                   let t = try? decoder.decode(ApplicationToken.self, from: firstMatch.tokenData) {
                    return t
                }
            }
            return nil
        }()

        // Surface the silent-failure case explicitly. Without this, a stale
        // fingerprint (post-reinstall token rotation) returns .applied with no
        // visible side effects — the parent thinks the command worked, the
        // shield never drops, and there's no log line to debug from.
        if token == nil && disposition == .keepBlocked {
            limits.removeAll { $0.fingerprint == fingerprint }
            var exhausted = storage.readTimeLimitExhaustedApps()
            exhausted.removeAll { $0.fingerprint == fingerprint }
            try? storage.writeAppTimeLimits(limits)
            try? storage.writeTimeLimitExhaustedApps(exhausted)
            removePendingAppReviewsLocally(fingerprint: fingerprint)
            reapplyCurrentEnforcement()
            eventLogger.log(
                .commandApplied,
                details: "App rejected: fp \(fingerprint.prefix(8)) (no local token binding)"
            )
            return .applied
        }

        if token == nil {
            return .failedValidation(
                reason: "reviewApp: no token bound to fingerprint \(fingerprint.prefix(8)) " +
                        "(stale fingerprint? token rotation after reinstall?) — " +
                        "name fallback was: '\(appNameForLookup)'"
            )
        }

        // Clean up: remove from ALL lists first (clean transition)
        if let token {
            allowedTokens.remove(token)
            if let tokenData = try? encoder.encode(token),
               let authoritativeName = authoritativeAppName(
                   fingerprint: fingerprint,
                   tokenData: tokenData
               ) {
                storage.cacheAppName(authoritativeName, forTokenKey: tokenData.base64EncodedString())
            }
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
                let appName = authoritativeAppName(fingerprint: fingerprint, tokenData: tokenData)
                    ?? storage.readAllCachedAppNames()[tokenData.base64EncodedString()]
                    ?? appNameForLookup
                let limit = AppTimeLimit(
                    appName: appName,
                    tokenData: tokenData,
                    bundleID: Application(token: token).bundleIdentifier,
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
            let defaults = UserDefaults.appGroup
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
        requestRegisterTimeLimitEvents(limits)

        // Remove the matching pending review from the kid's local file so the
        // "Pending Parent Approval" card stops showing this app the moment the
        // parent decides. Without this, the card stays stale until the next
        // foreground sync wipes the entire file (which has its own bugs).
        // Match by fingerprint — the parent acted on this exact fingerprint.
        removePendingAppReviewsLocally(fingerprint: fingerprint)

        reapplyCurrentEnforcement()
        eventLogger.log(
            .commandApplied,
            details: "App \(reviewDispositionLabel(disposition)): fp \(fingerprint.prefix(8))\(minutes.map { " \($0)m" } ?? "")"
        )
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
        let defaults = UserDefaults.appGroup
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let todayKey = "extraTime.\(fingerprint).\(f.string(from: Date()))"
        let existing = defaults?.integer(forKey: todayKey) ?? 0
        defaults?.set(existing + extraMinutes, forKey: todayKey)

        // Re-register DeviceActivityEvent with effective threshold (base + extra)
        var adjustedLimits = limits
        adjustedLimits[idx].dailyLimitMinutes += existing + extraMinutes
        requestRegisterTimeLimitEvents(adjustedLimits)

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
            let defaults = UserDefaults.appGroup
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
        requestRegisterTimeLimitEvents(limits)

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
    /// Set to true while we're processing a batch of commands. Per-handler calls
    /// to reapplyCurrentEnforcement() during this window are coalesced into a
    /// single deferred apply at end of batch. Each ManagedSettings write goes
    /// through one XPC pipe to ManagedSettingsAgent — under burst load, repeated
    /// writes degrade the daemon and shields silently stop applying. Coalescing
    /// to ONE write per batch eliminates the burst pattern entirely.
    private var batchInProgress = false
    private var batchNeedsReapply = false
    private var batchPendingTimeLimits: [AppTimeLimit]?

    private func beginEnforcementBatch() {
        batchInProgress = true
        batchNeedsReapply = false
        batchPendingTimeLimits = nil
    }

    private func endEnforcementBatch() {
        let needs = batchNeedsReapply
        let pendingLimits = batchPendingTimeLimits
        batchInProgress = false
        batchNeedsReapply = false
        batchPendingTimeLimits = nil
        if let pendingLimits {
            ScheduleRegistrar.registerTimeLimitEvents(limits: pendingLimits)
        }
        if needs {
            _ = performReapplyNow()
        }
    }

    /// Coalesce DeviceActivityCenter.startMonitoring across a command batch.
    /// Each call to startMonitoring on an already-monitored activity internally
    /// fires stopMonitoring → intervalDidEnd → Monitor extension writes the
    /// SAME enforcement store from a different process → cross-process write
    /// race that degrades the ManagedSettings agent. Defer to one call per batch.
    private func requestRegisterTimeLimitEvents(_ limits: [AppTimeLimit]) {
        if batchInProgress {
            batchPendingTimeLimits = limits
            return
        }
        ScheduleRegistrar.registerTimeLimitEvents(limits: limits)
    }

    @discardableResult
    private func reapplyCurrentEnforcement() -> Bool {
        if batchInProgress {
            batchNeedsReapply = true
            return true
        }
        return performReapplyNow()
    }

    private func performReapplyNow() -> Bool {
        guard let snapshot = snapshotStore.loadCurrentSnapshot() else { return false }
        // Use ModeStackResolver as ground truth — the snapshot may have stale
        // isTemporaryUnlock or mode from a previous command. Without this,
        // revokeAllApps can trigger applyWideOpenShields() via a stale snapshot.
        let resolution = ModeStackResolver.resolve(storage: storage)
        // Derive temp unlock from ModeStackResolver (checks expiry), NOT file existence.
        // A stale temp-unlock file (failed delete) must not cause shields to clear.
        let activeTempUnlock = resolution.isTemporary ? storage.readTemporaryUnlockState() : nil
        let isTempUnlock = activeTempUnlock != nil && resolution.controlAuthority == .temporaryUnlock
        var policy = snapshot.effectivePolicy
        if resolution.mode != policy.resolvedMode || policy.isTemporaryUnlock != isTempUnlock {
            policy = EffectivePolicy(
                resolvedMode: resolution.mode,
                controlAuthority: resolution.controlAuthority,
                isTemporaryUnlock: isTempUnlock,
                temporaryUnlockExpiresAt: activeTempUnlock?.expiresAt,
                shieldedCategoriesData: policy.shieldedCategoriesData,
                allowedAppTokensData: policy.allowedAppTokensData,
                deviceRestrictions: policy.deviceRestrictions,
                warnings: policy.warnings,
                policyVersion: policy.policyVersion
            )
        }
        do {
            try enforcement?.apply(policy, force: true)
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

        // Fallback: cross-reference pending_review_local.json (which has appFingerprint
        // + appName but no raw tokenData) against the picker's familyActivitySelection
        // (which has tokens but no names). Compute fingerprint per token, match to a
        // pending review by name, recover the tokenData. This rescues apps that were
        // added via submitSingleApp before we started caching names there.
        if results.isEmpty,
           let reviewData = storage.readRawData(forKey: "pending_review_local.json"),
           let reviews = try? JSONDecoder().decode([PendingAppReview].self, from: reviewData) {
            let matchingFingerprints = Set(
                reviews
                    .filter { Self.normalizeAppName($0.appName) == normalizedName }
                    .map(\.appFingerprint)
            )
            if !matchingFingerprints.isEmpty,
               let selData = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
               let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: selData) {
                let encoder = JSONEncoder()
                for token in selection.applicationTokens {
                    guard let tokenData = try? encoder.encode(token) else { continue }
                    let fp = TokenFingerprint.fingerprint(for: tokenData)
                    if matchingFingerprints.contains(fp) {
                        // Cache it now so subsequent lookups skip this fallback path.
                        storage.cacheAppName(appName, forTokenKey: tokenData.base64EncodedString())
                        append(tokenData: tokenData, appName: appName)
                    }
                }
            }
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
        let defaults = UserDefaults.appGroup
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

    /// Returns true if FamilyControls authorization is missing.
    /// Used to block temporary unlock commands and force essential mode until
    /// the child grants FC. Location is NOT included — it's for breadcrumbs
    /// and geofencing, not shield enforcement, and was previously causing
    /// every parent-issued .restricted command to silently force-convert to
    /// .locked when the kid had Location set to "While Using" (b445 bug).
    private func hasPermissionDeficiency() -> Bool {
        if let enforcement, enforcement.authorizationStatus != .authorized {
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
