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
final class SyncCoordinatorImpl: SyncCoordinatorProtocol {

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
        // 1. Process incoming commands.
        do {
            try await commandProcessor.processIncomingCommands()
        } catch {
            eventLogger.log(.commandFailed, details: "Sync: command fetch failed: \(error.localizedDescription)")
        }

        // 2. Send heartbeat.
        do {
            try await heartbeat.sendNow(force: false)
        } catch {
            // Heartbeat failure is non-fatal.
        }

        // 3. Sync event logs.
        do {
            try await eventLogger.syncPendingEvents()
        } catch {
            // Event sync failure is non-fatal.
        }

        // 4. Check if this device still exists in CloudKit.
        //    If the parent deleted the device record, self-unenroll.
        await checkDeviceExistence()

        // 5. Fetch latest policy from CloudKit (for child devices).
        await syncPolicyFromCloud()
    }

    func performQuickSync() async throws {
        // Lightweight: commands, heartbeat, and event sync.
        try? await commandProcessor.processIncomingCommands()
        try? await heartbeat.sendNow(force: false)
        // Sync pending events so unlock requests reach CloudKit promptly.
        try? await eventLogger.syncPendingEvents()
    }

    // MARK: - Private

    /// Verify this device's record still exists in CloudKit.
    /// If the parent deleted the device, clear local enrollment and restrictions.
    private func checkDeviceExistence() async {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        do {
            let devices = try await cloudKit.fetchDevices(familyID: enrollment.familyID)
            let stillExists = devices.contains { $0.id == enrollment.deviceID }
            if !stillExists {
                #if DEBUG
                print("[BigBrother] Device record not found in CloudKit — self-unenrolling")
                #endif
                eventLogger.log(.enrollmentRevoked, details: "Device record deleted by parent — auto-unenrolling")
                try? enforcement?.clearAllRestrictions()
                DispatchQueue.main.async { [weak self] in
                    self?.onUnenroll?()
                }
            }
        } catch {
            // Network error — don't unenroll on transient failures.
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
}
