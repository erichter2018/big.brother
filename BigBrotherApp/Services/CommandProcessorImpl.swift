import Foundation
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
final class CommandProcessorImpl: CommandProcessorProtocol {

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
        
        // Ensure we clear the gate when done.
        defer {
            Task {
                await processingGate.finish()
            }
        }

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

            // Mark the command as applied/failed in CloudKit so it's not returned by
            // future fetchPendingCommands queries. This is the server-side dedup.
            let serverStatus: CommandStatus = (result == .applied) ? .applied : .failed
            try? await cloudKit.updateCommandStatus(command.id, status: serverStatus)

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
                ModeChangeNotifier.notify(newMode: mode)
                return .applied

            case .temporaryUnlock(let durationSeconds):
                try applyTemporaryUnlock(
                    durationSeconds: durationSeconds,
                    enrollment: enrollment,
                    commandID: command.id
                )
                let h = durationSeconds / 3600
                let m = (durationSeconds % 3600) / 60
                let dur = h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
                eventLogger.log(.commandApplied, details: "Temporary unlock for \(dur)")
                ModeChangeNotifier.notifyTemporaryUnlock(durationSeconds: durationSeconds)
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
                eventLogger.log(.commandApplied, details: "Returned to schedule-driven mode")
                return .applied

            case .lockUntil(let date):
                try applyLockUntil(date: date, enrollment: enrollment, commandID: command.id)
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                eventLogger.log(.commandApplied, details: "Locked until \(formatter.string(from: date))")
                ModeChangeNotifier.notify(newMode: .dailyMode)
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
            registerTempUnlockExpirySchedule(commandID: commandID, start: now, end: expiresAt)

            let hours = durationSeconds / 3600
            let mins = (durationSeconds % 3600) / 60
            let durationStr = hours > 0 ? (mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h") : "\(mins)m"
            eventLogger.log(.temporaryUnlockStarted, details: "Unlocked for \(durationStr)")
        }
    }

    /// Register a one-shot DeviceActivitySchedule that fires `intervalDidEnd`
    /// at the temporary unlock expiry time. The monitor extension handles re-lock.
    private func registerTempUnlockExpirySchedule(commandID: UUID, start: Date, end: Date) {
        let cal = Calendar.current
        let startComps = cal.dateComponents([.hour, .minute, .second], from: start)
        let endComps = cal.dateComponents([.hour, .minute, .second], from: end)

        let activityName = DeviceActivityName(rawValue: "bigbrother.tempunlock.\(commandID.uuidString)")
        let schedule = DeviceActivitySchedule(
            intervalStart: startComps,
            intervalEnd: endComps,
            repeats: false
        )

        let center = DeviceActivityCenter()
        try? center.startMonitoring(activityName, during: schedule)

        #if DEBUG
        print("[BigBrother] Registered temp unlock expiry schedule: \(activityName.rawValue), ends at \(end)")
        #endif
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
            registerTempUnlockExpirySchedule(commandID: unlockID, start: now, end: expiresAt)
            eventLogger.log(.temporaryUnlockStarted, details: "Self-unlock for \(durationSeconds / 60)m")
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
            eventLogger.log(.commandApplied, details: "Timed unlock expired before delivery (elapsed \(elapsed)s)")
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
            eventLogger.log(.commandApplied, details: "Timed unlock: no penalty remaining, unlocked for \(unlockDuration / 60)m")
            ModeChangeNotifier.notifyTemporaryUnlock(durationSeconds: unlockDuration)
        } else {
            // Register a DeviceActivitySchedule: locked now, unlock after penalty, lock after total.
            let now = Date()
            let unlockAt = now.addingTimeInterval(Double(adjustedPenalty))
            let lockAt = now.addingTimeInterval(Double(adjustedTotal))
            let cal = Calendar.current

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
            let info = TimedUnlockInfo(
                commandID: commandID,
                activityName: activityName.rawValue,
                unlockAt: unlockAt,
                lockAt: lockAt
            )
            try storage.writeTimedUnlockInfo(info)

            // Explicitly enforce locked mode during penalty phase.
            // The device may have been in an ambiguous state; ensure shields are active.
            let currentMode = snapshotStore.loadCurrentSnapshot()?.effectivePolicy.resolvedMode ?? .dailyMode
            let lockedMode = currentMode == .unlocked ? .dailyMode : currentMode
            try applyMode(lockedMode, enrollment: enrollment, commandID: commandID)

            let penaltyMin = adjustedPenalty / 60
            let unlockMin = (adjustedTotal - adjustedPenalty) / 60
            eventLogger.log(.commandApplied, details: "Timed unlock: \(penaltyMin)m penalty then \(unlockMin)m free")
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
        let startComps = cal.dateComponents([.hour, .minute, .second], from: now)
        let endComps = cal.dateComponents([.hour, .minute, .second], from: date)

        let activityName = DeviceActivityName(rawValue: "bigbrother.lockuntil.\(commandID.uuidString)")
        let schedule = DeviceActivitySchedule(
            intervalStart: startComps,
            intervalEnd: endComps,
            repeats: false
        )

        let center = DeviceActivityCenter()
        try? center.startMonitoring(activityName, during: schedule)

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
        var updated = false
        for (tokenBase64, _) in cache {
            // Compute fingerprint for this token
            if let data = Data(base64Encoded: tokenBase64) {
                let fp = Self.tokenFingerprint(for: data)
                if fp.hasPrefix(fingerprint) || fingerprint.hasPrefix(fp.prefix(fingerprint.count).description) {
                    storage.cacheAppName(name, forTokenKey: tokenBase64)
                    updated = true
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
        let keychain = KeychainManager()
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
