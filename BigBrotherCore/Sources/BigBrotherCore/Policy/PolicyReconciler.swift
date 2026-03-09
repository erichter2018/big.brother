import Foundation

/// What triggered the reconciliation check.
public enum ReconciliationTrigger: String, Codable, Sendable {
    case appLaunch
    case syncCompleted
    case heartbeatCycle
    case authorizationRestored
    case temporaryUnlockExpired
    case manual
}

/// The action the reconciler recommends after evaluating state.
public enum ReconciliationAction: Sendable, Equatable {
    /// Current enforcement matches intended state. No action needed.
    case noChangeNeeded

    /// Enforcement needs to be (re)applied.
    case reapplyEnforcement(reason: String)

    /// Enforcement cannot fully match intent due to authorization.
    /// The system should record degraded state and do best-effort enforcement.
    case applyDegradedEnforcement(reason: String)

    /// No policy is available. Enforcement is impossible.
    case cannotEnforce(reason: String)

    /// A temporary unlock has expired. Revert to the previous mode.
    case expireTemporaryUnlock(previousMode: LockMode)
}

/// Pure reconciliation engine. No side effects, no framework dependencies.
///
/// Compares the currently intended policy state against what was last applied
/// and determines what corrective action, if any, is needed.
///
/// Usable from:
/// - App launch restoration
/// - Sync cycle completion
/// - Heartbeat cycle
/// - Authorization state change callbacks
public struct PolicyReconciler {

    /// Evaluate current state and determine the reconciliation action.
    ///
    /// - Parameters:
    ///   - currentSnapshot: The latest PolicySnapshot from App Group storage.
    ///   - lastAppliedMode: The lock mode that was last confirmed applied to ManagedSettingsStore.
    ///   - authorizationHealth: Current FamilyControls authorization health.
    ///   - temporaryUnlockState: Active temporary unlock metadata, if any.
    ///   - trigger: What caused this reconciliation check.
    ///   - currentTime: Injected for testability.
    ///
    /// - Returns: The recommended action.
    public static func evaluate(
        currentSnapshot: PolicySnapshot?,
        lastAppliedMode: LockMode?,
        authorizationHealth: AuthorizationHealth?,
        temporaryUnlockState: TemporaryUnlockState?,
        trigger: ReconciliationTrigger,
        currentTime: Date = Date()
    ) -> ReconciliationAction {

        // 1. No policy snapshot → nothing to enforce
        guard let snapshot = currentSnapshot else {
            return .cannotEnforce(reason: "No policy snapshot available")
        }

        // 2. Temporary unlock expired → revert to previous mode
        if let unlock = temporaryUnlockState, unlock.isExpired(at: currentTime) {
            return .expireTemporaryUnlock(previousMode: unlock.previousMode)
        }

        // 3. Authorization missing → degraded enforcement
        if let auth = authorizationHealth, !auth.isAuthorized {
            return .applyDegradedEnforcement(
                reason: "FamilyControls authorization \(auth.currentState.rawValue)"
            )
        }

        // 4. Mode mismatch between intended and applied → reapply
        let intendedMode = snapshot.effectivePolicy.resolvedMode
        if let applied = lastAppliedMode, applied != intendedMode {
            return .reapplyEnforcement(
                reason: "Mode drift: applied=\(applied.rawValue), intended=\(intendedMode.rawValue)"
            )
        }

        // 5. Trigger-specific logic
        switch trigger {
        case .authorizationRestored:
            return .reapplyEnforcement(reason: "Authorization restored")

        case .syncCompleted:
            return .reapplyEnforcement(reason: "Sync completed, ensuring enforcement matches latest policy")

        case .appLaunch:
            if lastAppliedMode == nil {
                return .reapplyEnforcement(reason: "First enforcement after launch")
            }
            return .noChangeNeeded

        case .temporaryUnlockExpired:
            // Should have been caught by step 2 if state was provided.
            // If temporaryUnlockState was nil but trigger says expired,
            // fall through to no change (state was already cleared).
            return .noChangeNeeded

        case .heartbeatCycle, .manual:
            return .noChangeNeeded
        }
    }
}
