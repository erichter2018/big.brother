import Foundation
import BigBrotherCore

/// Handles app launch restoration.
///
/// On every launch (child device), this restorer:
/// 1. Reads enrollment state from Keychain
/// 2. Uses PolicyReconciler to evaluate what action is needed
/// 3. Handles temporary unlock expiry via TemporaryUnlockState
/// 4. Routes re-resolution through PolicyPipelineCoordinator
/// 5. Commits via PolicySnapshotStore for versioning consistency
/// 6. Reconciles enforcement state with ManagedSettingsStore
///
/// This ensures enforcement is correct even after reboot or force-quit.
struct AppLaunchRestorer {

    private let keychain: any KeychainProtocol
    private let storage: any SharedStorageProtocol
    private let enforcement: any EnforcementServiceProtocol
    private let eventLogger: any EventLoggerProtocol
    private let snapshotStore: PolicySnapshotStore

    init(
        keychain: any KeychainProtocol = KeychainManager(),
        storage: any SharedStorageProtocol = AppGroupStorage(),
        enforcement: any EnforcementServiceProtocol,
        eventLogger: any EventLoggerProtocol,
        snapshotStore: PolicySnapshotStore
    ) {
        self.keychain = keychain
        self.storage = storage
        self.enforcement = enforcement
        self.eventLogger = eventLogger
        self.snapshotStore = snapshotStore
    }

    /// Run the full restoration flow. Should be called on app launch for child devices.
    func restore() {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else {
            // Not enrolled — nothing to restore.
            return
        }

        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let temporaryUnlockState = storage.readTemporaryUnlockState()
        let authHealth = storage.readAuthorizationHealth()

        // Determine last applied mode from snapshot (appliedAt set = was applied).
        let lastAppliedMode = currentSnapshot?.appliedAt != nil
            ? currentSnapshot?.effectivePolicy.resolvedMode
            : nil

        // Use PolicyReconciler to decide what action to take.
        let action = PolicyReconciler.evaluate(
            currentSnapshot: currentSnapshot,
            lastAppliedMode: lastAppliedMode,
            authorizationHealth: authHealth,
            temporaryUnlockState: temporaryUnlockState,
            trigger: .appLaunch
        )

        switch action {
        case .cannotEnforce:
            // No snapshot exists — first run after enrollment.
            let policy = Policy(targetDeviceID: enrollment.deviceID, mode: .unlocked)
            let capabilities = DeviceCapabilities(
                familyControlsAuthorized: enforcement.authorizationStatus == .authorized,
                isOnline: false
            )
            let inputs = PolicyPipelineCoordinator.Inputs(
                basePolicy: policy,
                capabilities: capabilities,
                authorizationHealth: authHealth,
                deviceID: enrollment.deviceID,
                source: .initial,
                trigger: "First launch after enrollment"
            )
            let output = PolicyPipelineCoordinator.generateSnapshot(from: inputs, previousSnapshot: nil)
            commitAndApply(output.snapshot)
            eventLogger.log(.policyReconciled, details: "First launch: applied default unlocked policy")

        case .expireTemporaryUnlock(let previousMode):
            // Temp unlock expired while app was not running.
            // TemporaryUnlockState gives us the deterministic previous mode.
            try? storage.clearTemporaryUnlockState()

            let currentVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0
            let policy = Policy(
                targetDeviceID: enrollment.deviceID,
                mode: previousMode,
                version: currentVersion + 1
            )
            let capabilities = DeviceCapabilities(
                familyControlsAuthorized: enforcement.authorizationStatus == .authorized,
                isOnline: false
            )
            let inputs = PolicyPipelineCoordinator.Inputs(
                basePolicy: policy,
                capabilities: capabilities,
                authorizationHealth: authHealth,
                deviceID: enrollment.deviceID,
                source: .temporaryUnlockExpired,
                trigger: "Temporary unlock expired during app suspension"
            )
            let output = PolicyPipelineCoordinator.generateSnapshot(
                from: inputs, previousSnapshot: currentSnapshot
            )
            commitAndApply(output.snapshot)
            eventLogger.log(.temporaryUnlockExpired, details: "Expired during suspension, reverted to \(previousMode.rawValue)")

        case .reapplyEnforcement(let reason):
            if let snapshot = currentSnapshot {
                applyExisting(snapshot, logMessage: "Launch reconciliation: \(reason)")
            }

        case .applyDegradedEnforcement(let reason):
            if let snapshot = currentSnapshot {
                applyExisting(snapshot, logMessage: "Degraded enforcement on launch: \(reason)")
                eventLogger.log(.enforcementDegraded, details: reason)
            }

        case .noChangeNeeded:
            eventLogger.log(.policyReconciled, details: "Launch reconciliation: no change needed")
        }

        // Schedule-aware reconciliation: if a schedule profile is active,
        // verify enforcement matches the current window state. The Monitor
        // extension handles transitions, but if it crashed mid-transition
        // enforcement could be wrong.
        reconcileScheduleState()

        // Log diagnostic.
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .restoration,
            message: "App launch restoration completed",
            details: "Action: \(action)"
        ))
    }

    /// Verify enforcement matches the current schedule window state.
    /// Catches cases where the Monitor extension crashed during a transition.
    private func reconcileScheduleState() {
        guard let profile = storage.readActiveScheduleProfile() else { return }
        let now = Date()
        let inFreeWindow = profile.isInFreeWindow(at: now)
        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let currentMode = currentSnapshot?.effectivePolicy.resolvedMode

        // If we're in a free window but enforcement shows locked (or vice versa),
        // re-apply the correct state.
        if inFreeWindow && currentMode != .unlocked {
            // Should be unlocked but isn't — extension missed the start.
            #if DEBUG
            print("[BigBrother] Schedule reconciliation: in free window but mode=\(currentMode?.rawValue ?? "nil"), clearing shields")
            #endif
            try? enforcement.clearAllRestrictions()
            // Re-apply restrictions (they should always be on).
            if let snapshot = currentSnapshot {
                try? enforcement.apply(snapshot.effectivePolicy)
            }
            eventLogger.log(.policyReconciled, details: "Schedule reconciliation: cleared shields for active free window")
        } else if !inFreeWindow && currentMode == .unlocked {
            // Check if there's a temporary unlock active — don't override that.
            if let tempState = storage.readTemporaryUnlockState(), tempState.expiresAt > now {
                return // Active temp unlock, don't re-lock.
            }
            // Should be locked but isn't — extension missed the end.
            #if DEBUG
            print("[BigBrother] Schedule reconciliation: outside free window but unlocked, re-locking")
            #endif
            if let snapshot = currentSnapshot {
                try? enforcement.reconcile(with: snapshot)
            }
            eventLogger.log(.policyReconciled, details: "Schedule reconciliation: re-locked after missed free window end")
        }
    }

    // MARK: - Private

    /// Commit a new snapshot through the store and apply enforcement.
    private func commitAndApply(_ snapshot: PolicySnapshot) {
        do {
            let result = try snapshotStore.commit(snapshot)
            if case .committed(let committed) = result {
                try enforcement.apply(committed.effectivePolicy)
                try snapshotStore.markApplied()
            }
        } catch {
            eventLogger.log(.commandFailed, details: "Commit/apply failed: \(error.localizedDescription)")
        }
    }

    /// Re-apply an existing snapshot's policy to enforcement.
    private func applyExisting(_ snapshot: PolicySnapshot, logMessage: String) {
        do {
            try enforcement.apply(snapshot.effectivePolicy)
            try snapshotStore.markApplied()
            eventLogger.log(.policyReconciled, details: logMessage)
        } catch {
            eventLogger.log(.commandFailed, details: "Reconciliation failed: \(error.localizedDescription)")
        }
    }
}
