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
        let defaults = UserDefaults.appGroup

        // b439 (onboarding fix): Skip restoration entirely if guided setup is
        // active. Applying enforcement before the user has granted FC auth
        // would trigger the deep-rescue recovery path (verification fails →
        // recovery → probe → rescue → Step 4 AuthorizationCenter prompt),
        // firing Screen Time prompts ahead of the stepwise fixer flow.
        if defaults?.bool(forKey: AppGroupKeys.showPermissionFixerOnNextLaunch) == true {
            NSLog("[AppLaunchRestorer] Skipping — guided setup active, PermissionFixerView will handle enforcement after permissions are granted")
            return
        }

        // b434 (audit fix): Skip heavy restoration if AppDelegate.restoreEnforcementIfNeeded
        // just ran in the foreground branch. AppDelegate runs synchronously in
        // didFinishLaunching and writes "appDelegateRestorationAt" on successful
        // apply. Without this guard, the Main queue's performRestoration kicks
        // AppLaunchRestorer.restore() on a background queue shortly after, which
        // races with AppDelegate's writes to ManagedSettingsStore (multiple
        // concurrent writers). This skip still allows the safety-net 3s delayed
        // re-restoration to run fully (by which point AppDelegate's timestamp
        // will be > 2s old).
        let appDelegateRestoreAt = defaults?.double(forKey: AppGroupKeys.appDelegateRestorationAt) ?? 0
        let appDelegateRanRecently = appDelegateRestoreAt > 0 &&
            Date().timeIntervalSince1970 - appDelegateRestoreAt < 2.0
        if appDelegateRanRecently {
            NSLog("[AppLaunchRestorer] Skipping — AppDelegate.restoreEnforcementIfNeeded ran \(Int(Date().timeIntervalSince1970 - appDelegateRestoreAt))s ago (avoiding concurrent writer race)")
            // Still reset the throttle so the next launch has a fresh budget.
            enforcement.resetThrottle()
            return
        }

        // Reset enforcement throttle on every fresh launch so deploy-driven restarts
        // don't exhaust the nuclear reset budget across separate app launches.
        enforcement.resetThrottle()

        UserDefaults.appGroup?
            .set("launchRestore", forKey: AppGroupKeys.lastShieldChangeReason)

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

        // Cross-check with ModeStackResolver — the snapshot may be stale in EITHER direction:
        // 1. Snapshot says unlocked but device should be locked (temp unlock expired while app dead)
        // 2. Snapshot says locked/restricted but device should be unlocked (temp unlock active but
        //    something overwrote the snapshot, e.g., Monitor schedule transition)
        let resolution = ModeStackResolver.resolve(storage: storage)
        let snapshotMode = currentSnapshot?.effectivePolicy.resolvedMode
        if let snapshot = currentSnapshot, snapshotMode != resolution.mode {
            let correctMode = resolution.mode
            let currentVersion = snapshot.effectivePolicy.policyVersion
            let policy = Policy(
                targetDeviceID: enrollment.deviceID,
                mode: correctMode,
                temporaryUnlockUntil: resolution.expiresAt,
                version: currentVersion + 1
            )
            let capabilities = DeviceCapabilities(
                familyControlsAuthorized: enforcement.authorizationStatus == .authorized,
                isOnline: false
            )
            let source: SnapshotSource = resolution.mode == .unlocked ? .temporaryUnlockStarted : .temporaryUnlockExpired
            let inputs = PolicyPipelineCoordinator.Inputs(
                basePolicy: policy,
                alwaysAllowedTokensData: storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                capabilities: capabilities,
                temporaryUnlockState: temporaryUnlockState,
                authorizationHealth: authHealth,
                deviceID: enrollment.deviceID,
                source: source,
                trigger: "Stale snapshot on launch: was \(snapshotMode?.rawValue ?? "nil"), ModeStackResolver says \(correctMode.rawValue) (\(resolution.reason))"
            )
            let output = PolicyPipelineCoordinator.generateSnapshot(
                from: inputs, previousSnapshot: currentSnapshot
            )
            commitAndApply(output.snapshot)
            eventLogger.log(.policyReconciled, details: "Launch: snapshot corrected \(snapshotMode?.rawValue ?? "nil") → \(correctMode.rawValue) via ModeStackResolver")
            return
        }

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
            // No snapshot exists — check local state to determine the correct mode.
            // If any state files exist (temp unlock, timed unlock, ext state),
            // use ModeStackResolver to derive the mode. Otherwise, default to
            // .restricted (fail-safe) rather than .unlocked — an enrolled device
            // with no snapshot should lock down, not open up.
            let tempState = storage.readTemporaryUnlockState()
            let timedInfo = storage.readTimedUnlockInfo()
            let extState = storage.readExtensionSharedState()
            let hasLocalState = tempState != nil || timedInfo != nil || extState != nil

            let resolvedMode: LockMode
            if hasLocalState {
                let localResolution = ModeStackResolver.resolve(storage: storage)
                resolvedMode = localResolution.mode
            } else {
                // Truly blank slate post-enrollment — default to restricted (fail-safe).
                resolvedMode = .restricted
            }

            let policy = Policy(targetDeviceID: enrollment.deviceID, mode: resolvedMode)
            let capabilities = DeviceCapabilities(
                familyControlsAuthorized: enforcement.authorizationStatus == .authorized,
                isOnline: false
            )
            let inputs = PolicyPipelineCoordinator.Inputs(
                basePolicy: policy,
                alwaysAllowedTokensData: storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                capabilities: capabilities,
                authorizationHealth: authHealth,
                deviceID: enrollment.deviceID,
                source: .initial,
                trigger: hasLocalState
                    ? "First snapshot from local state: \(resolvedMode.rawValue)"
                    : "First launch after enrollment — fail-safe restricted"
            )
            let output = PolicyPipelineCoordinator.generateSnapshot(from: inputs, previousSnapshot: nil)
            commitAndApply(output.snapshot)
            eventLogger.log(.policyReconciled, details: "First launch: applied \(resolvedMode.rawValue) (localState: \(hasLocalState))")

        case .expireTemporaryUnlock(let previousMode):
            // Temp unlock expired while app was not running.
            // TemporaryUnlockState gives us the deterministic previous mode.
            do {
                try storage.clearTemporaryUnlockState()
            } catch {
                eventLogger.log(.commandFailed, details: "Failed to clear temp unlock state: \(error.localizedDescription)")
            }

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
                alwaysAllowedTokensData: storage.readRawData(forKey: StorageKeys.allowedAppTokens),
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
            if let tempState = temporaryUnlockState, tempState.expiresAt > Date() {
                do {
                    try enforcement.clearAllRestrictions()
                } catch {
                    eventLogger.log(.commandFailed, details: "Failed to clear restrictions for temp unlock: \(error.localizedDescription)")
                }
                eventLogger.log(.policyReconciled, details: "Launch reconciliation: \(reason) — but temp unlock active, shields cleared")
            } else if let snapshot = currentSnapshot {
                applyExisting(snapshot, logMessage: "Launch reconciliation: \(reason)")
            }

        case .applyDegradedEnforcement(let reason):
            if let tempState = temporaryUnlockState, tempState.expiresAt > Date() {
                do { try enforcement.clearAllRestrictions() } catch {
                    eventLogger.log(.commandFailed, details: "Degraded: failed to clear restrictions: \(error.localizedDescription)")
                }
                eventLogger.log(.policyReconciled, details: "Degraded: \(reason) — but temp unlock active, shields cleared")
            } else if let snapshot = currentSnapshot {
                applyExisting(snapshot, logMessage: "Degraded enforcement on launch: \(reason)")
                eventLogger.log(.enforcementDegraded, details: reason)
            }

        case .noChangeNeeded:
            // Check if a temporary unlock is active — if so, DON'T re-apply shields.
            // A subsequent command (e.g., setPenaltyTimer) may have created a new snapshot
            // that doesn't have isTemporaryUnlock=true, but the TemporaryUnlockState
            // in storage still says we should be unlocked.
            if let tempState = temporaryUnlockState, tempState.expiresAt > Date() {
                do { try enforcement.clearAllRestrictions() } catch {
                    eventLogger.log(.commandFailed, details: "Launch: failed to clear restrictions for temp unlock: \(error.localizedDescription)")
                }
                eventLogger.log(.policyReconciled, details: "Launch reconciliation: temp unlock active, shields cleared")
            } else if let snapshot = currentSnapshot {
                // Re-apply enforcement — the OS may have cleared ManagedSettingsStore
                // state during an app update even though our snapshot is unchanged.
                do { try enforcement.apply(snapshot.effectivePolicy) } catch {
                    eventLogger.log(.commandFailed, details: "Launch: failed to apply enforcement: \(error.localizedDescription)")
                }
                eventLogger.log(.policyReconciled, details: "Launch reconciliation: no change needed (restrictions refreshed)")
            }
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
        UserDefaults.appGroup?
            .set("launchRestore", forKey: AppGroupKeys.lastShieldChangeReason)

        // Don't override manual mode commands (parent sent setMode directly).
        let defaults = UserDefaults.appGroup ?? .standard
        if defaults.object(forKey: AppGroupKeys.scheduleDrivenMode) != nil && !defaults.bool(forKey: AppGroupKeys.scheduleDrivenMode) {
            return
        }

        let now = Date()
        let scheduleMode = profile.resolvedMode(at: now)
        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let currentMode = currentSnapshot?.effectivePolicy.resolvedMode

        // Don't override active temporary unlocks.
        if let tempState = storage.readTemporaryUnlockState(), tempState.expiresAt > now {
            return
        }

        // Don't override an active timed unlock in either phase. The
        // timed-unlock lifecycle (penalty → free → re-lock) has its own
        // DA-schedule + BGTask + resolver coverage; launch restoration
        // must defer to it. Without this guard, an app cold-launch during
        // penalty could clobber timed state back to schedule mode and
        // effectively cancel the parent's timed-unlock command.
        if let timed = storage.readTimedUnlockInfo(),
           timed.isInPenaltyPhase(at: now) || timed.isInFreePhase(at: now) {
            return
        }

        guard scheduleMode != currentMode else { return }

        // Build a corrected snapshot with the schedule-resolved mode
        // so all subsequent checks (60s loop, heartbeat, Monitor) agree.
        let basePolicy = currentSnapshot?.effectivePolicy
        let corrected = EffectivePolicy(
            resolvedMode: scheduleMode,
            // MUST pass controlAuthority = .schedule. Omitting this (previous
            // behavior) meant the EffectivePolicy was serialized with
            // controlAuthority = nil. ModeStackResolver coalesces nil →
            // `.parentManual` at step 4, so this restoration snapshot was
            // being misclassified as a parent manual override, hijacking the
            // resolver's decision chain. Every later lockUntil/temporaryUnlock
            // command then had to "win" against a phantom parent-manual
            // snapshot — and when its own commit produced the same mode, it
            // returned `.unchanged`, no transition logged, no visible effect.
            // Root cause of Simon's "commands not responding" tonight.
            controlAuthority: .schedule,
            isTemporaryUnlock: false,
            temporaryUnlockExpiresAt: nil,
            shieldedCategoriesData: basePolicy?.shieldedCategoriesData,
            allowedAppTokensData: basePolicy?.allowedAppTokensData,
            warnings: basePolicy?.warnings ?? [],
            policyVersion: (basePolicy?.policyVersion ?? 0) + 1
        )
        let correctedSnapshot = PolicySnapshot(
            source: .restoration,
            trigger: "Schedule reconciliation: \(currentMode?.rawValue ?? "nil") → \(scheduleMode.rawValue)",
            effectivePolicy: corrected
        )
        _ = try? storage.commitCorrectedSnapshot(correctedSnapshot)

        switch scheduleMode {
        case .unlocked:
            do { try enforcement.clearAllRestrictions() } catch {
                eventLogger.log(.commandFailed, details: "Schedule reconciliation: failed to clear restrictions: \(error.localizedDescription)")
            }
            eventLogger.log(.policyReconciled, details: "Schedule reconciliation: cleared shields for free window")
        case .locked, .restricted, .lockedDown:
            do { try enforcement.apply(corrected) } catch {
                eventLogger.log(.commandFailed, details: "Schedule reconciliation: failed to apply \(scheduleMode.rawValue): \(error.localizedDescription)")
            }
            eventLogger.log(.policyReconciled, details: "Schedule reconciliation: applied \(scheduleMode.rawValue)")
        }
    }

    // MARK: - Private

    /// Commit a new snapshot through the store and apply enforcement.
    private func commitAndApply(_ snapshot: PolicySnapshot) {
        do {
            let result = try snapshotStore.commit(snapshot)
            switch result {
            case .committed(let committed):
                try enforcement.apply(committed.effectivePolicy)
                try snapshotStore.markApplied()
            case .unchanged, .rejectedAsStale:
                // Still apply enforcement — the snapshot fingerprint may match but
                // ManagedSettingsStore could be out of sync (e.g., temp unlock expired).
                try enforcement.apply(snapshot.effectivePolicy)
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
