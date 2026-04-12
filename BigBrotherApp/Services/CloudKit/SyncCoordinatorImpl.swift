import Foundation
import BigBrotherCore

/// Orchestrates sync cycles between local state and CloudKit.
///
/// Full sync: commands → heartbeat → events → policy
/// Quick sync: commands → heartbeat (for background fetch with limited time)
///
/// Policy sync routes through the canonical snapshot pipeline
/// (PolicyPipelineCoordinator → PolicySnapshotStore) to ensure
/// consistent versioning and staleness rejection.
final class SyncCoordinatorImpl: SyncCoordinatorProtocol, @unchecked Sendable {

    private let cloudKit: any CloudKitServiceProtocol
    private let commandProcessor: any CommandProcessorProtocol
    private let heartbeat: any HeartbeatServiceProtocol
    private let eventLogger: any EventLoggerProtocol
    private let storage: any SharedStorageProtocol
    private let keychain: any KeychainProtocol
    private let enforcement: (any EnforcementServiceProtocol)?
    private let snapshotStore: PolicySnapshotStore

    /// Called when the device record is no longer found in CloudKit,
    /// indicating the parent has deleted this device. The app should
    /// clear enrollment and reset to unconfigured.
    var onUnenroll: (() -> Void)?

    // MARK: - Unenroll Strike Protection

    /// Requires 3 consecutive "device not found" results over at least 15 minutes
    /// before triggering self-unenrollment. Prevents a single transient CloudKit
    /// failure from wiping all parental controls.
    private let unenrollStrikeKey = "unenroll_strike_count"
    private let unenrollFirstStrikeKey = "unenroll_first_strike_at"

    init(
        cloudKit: any CloudKitServiceProtocol,
        commandProcessor: any CommandProcessorProtocol,
        heartbeat: any HeartbeatServiceProtocol,
        eventLogger: any EventLoggerProtocol,
        storage: any SharedStorageProtocol,
        keychain: any KeychainProtocol,
        enforcement: (any EnforcementServiceProtocol)?,
        snapshotStore: PolicySnapshotStore
    ) {
        self.cloudKit = cloudKit
        self.commandProcessor = commandProcessor
        self.heartbeat = heartbeat
        self.eventLogger = eventLogger
        self.storage = storage
        self.keychain = keychain
        self.enforcement = enforcement
        self.snapshotStore = snapshotStore
    }

    // MARK: - SyncCoordinatorProtocol

    func performFullSync() async throws {
        // Wrap entire sync in a 30-second timeout so a hung CloudKit call
        // doesn't block background refresh indefinitely.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
            group.addTask {
                try await self._performFullSyncBody()
            }
            // Wait for first completion (either timeout or sync).
            try await group.next()
            group.cancelAll()
        }
    }

    private func _performFullSyncBody() async throws {
        let syncStartedAt = Date()

        // 1. Process incoming commands (must complete before heartbeat
        //    so the heartbeat reflects the updated mode).
        do {
            try await commandProcessor.processIncomingCommands()
        } catch {
            eventLogger.log(.commandFailed, details: "Sync: command fetch failed: \(error.localizedDescription)")
        }
        let commandsProcessed = Self.didProcessCommands(since: syncStartedAt)

        // 2. Heartbeat, event sync, device check, and policy sync can run in parallel
        //    since they're independent operations.
        await withTaskGroup(of: Void.self) { group in
            if !commandsProcessed {
                group.addTask { try? await self.heartbeat.sendNow(force: false) }
            }
            group.addTask { try? await self.eventLogger.syncPendingEvents() }
            group.addTask { await self.checkDeviceExistence() }
            group.addTask { await self.syncPolicyFromCloud() }
        }
    }

    func performQuickSync() async throws {
        let syncStartedAt = Date()

        // Lightweight: commands, heartbeat, and event sync.
        try? await commandProcessor.processIncomingCommands()
        // If command processing changed state, CommandProcessor already requested
        // an immediate confirmation heartbeat. Otherwise send a normal heartbeat.
        if !Self.didProcessCommands(since: syncStartedAt) {
            try? await heartbeat.sendNow(force: false)
        }
        // Sync pending events so unlock requests reach CloudKit promptly.
        try? await eventLogger.syncPendingEvents()
    }

    // MARK: - Private

    /// Verify this device's record still exists in CloudKit.
    /// If the parent deleted the device, clear local enrollment and restrictions.
    ///
    /// Uses a 3-strike system: requires 3 consecutive "device not found" results
    /// over at least 15 minutes before triggering unenrollment. A single transient
    /// CloudKit empty result (network blip, index lag) must not wipe controls.
    private func checkDeviceExistence() async {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        let defaults = UserDefaults.appGroup

        do {
            let devices = try await cloudKit.fetchDevices(familyID: enrollment.familyID)
            let stillExists = devices.contains { $0.id == enrollment.deviceID }
            if !stillExists {
                // Device not found — record a strike.
                let strikes = (defaults?.integer(forKey: unenrollStrikeKey) ?? 0) + 1
                let firstStrike = defaults?.object(forKey: unenrollFirstStrikeKey) as? Date ?? Date()

                if strikes == 1 {
                    defaults?.set(Date(), forKey: unenrollFirstStrikeKey)
                }
                defaults?.set(strikes, forKey: unenrollStrikeKey)

                // Require 3 strikes over at least 15 minutes before unenrolling.
                let elapsed = Date().timeIntervalSince(firstStrike)
                if strikes >= 3 && elapsed >= 900 {
                    #if DEBUG
                    print("[BigBrother] Device record not found in CloudKit (3 strikes over \(Int(elapsed))s) — self-unenrolling")
                    #endif
                    defaults?.removeObject(forKey: unenrollStrikeKey)
                    defaults?.removeObject(forKey: unenrollFirstStrikeKey)
                    eventLogger.log(.enrollmentRevoked, details: "Device record deleted by parent — auto-unenrolling (3 strikes over \(Int(elapsed))s)")
                    do {
                        try enforcement?.clearAllRestrictions()
                    } catch {
                        try? storage.appendDiagnosticEntry(DiagnosticEntry(
                            category: .enforcement,
                            message: "Failed to clear restrictions during unenroll: \(error.localizedDescription)"
                        ))
                    }
                    Task { @MainActor [weak self] in
                        self?.onUnenroll?()
                    }
                } else {
                    #if DEBUG
                    print("[BigBrother] Device not found in CloudKit (strike \(strikes)/3, \(Int(elapsed))s elapsed). Not unenrolling yet.")
                    #endif
                }
            } else {
                // Device found — reset strikes.
                defaults?.removeObject(forKey: unenrollStrikeKey)
                defaults?.removeObject(forKey: unenrollFirstStrikeKey)
            }
        } catch {
            // Network error — don't unenroll on transient failures, don't count as a strike.
            #if DEBUG
            print("[BigBrother] Device existence check failed (non-fatal): \(error.localizedDescription)")
            #endif
        }
    }

    private func syncPolicyFromCloud() async {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        guard let remotePolicy = try? await cloudKit.fetchPolicy(
            deviceID: enrollment.deviceID
        ) else { return }

        // Compare with local version — only apply if remote is newer.
        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let localVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0

        guard remotePolicy.version > localVersion else { return }

        let capabilities = DeviceCapabilities(
            familyControlsAuthorized: enforcement?.authorizationStatus == .authorized,
            isOnline: true
        )

        let inputs = PolicyPipelineCoordinator.Inputs(
            basePolicy: remotePolicy,
            alwaysAllowedTokensData: storage.readRawData(forKey: StorageKeys.allowedAppTokens),
            capabilities: capabilities,
            temporaryUnlockState: storage.readTemporaryUnlockState(),
            authorizationHealth: storage.readAuthorizationHealth(),
            deviceID: enrollment.deviceID,
            source: .syncUpdate,
            trigger: "Synced policy v\(remotePolicy.version) from CloudKit"
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs,
            previousSnapshot: currentSnapshot
        )

        do {
            let result = try snapshotStore.commit(output.snapshot)
            if case .committed(let snapshot) = result {
                try? enforcement?.apply(snapshot.effectivePolicy)
                try? snapshotStore.markApplied()
                eventLogger.log(.modeChanged, details: "Synced policy v\(remotePolicy.version): \(remotePolicy.mode.rawValue)")
            }
        } catch {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Failed to commit synced policy",
                details: error.localizedDescription
            ))
        }
    }

    private static func didProcessCommands(since date: Date) -> Bool {
        let defaults = UserDefaults.appGroup ?? .standard
        let timestamp = defaults.double(forKey: "fr.bigbrother.lastCommandProcessedAt")
        guard timestamp > 0 else { return false }
        return Date(timeIntervalSince1970: timestamp) >= date
    }
}
