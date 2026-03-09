import Foundation
import DeviceActivity
import ManagedSettings
import BigBrotherCore

/// DeviceActivityMonitor extension.
///
/// Triggered by the system when registered DeviceActivitySchedule
/// intervals start or end. Guaranteed to run even if the main app
/// is not running.
///
/// Responsibilities:
/// - Read PolicySnapshot from App Group storage
/// - Apply/clear ManagedSettings restrictions on the "schedule" store
/// - Append event log entries to App Group storage
///
/// Constraints:
/// - Cannot make network calls
/// - Cannot present UI
/// - Very limited memory and execution time
/// - Must read all state from App Group shared storage
class BigBrotherMonitorExtension: DeviceActivityMonitor {

    private let storage = AppGroupStorage()
    private let store = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreSchedule))

    override func intervalDidStart(for activity: DeviceActivityName) {
        // Reconciliation schedule — verify enforcement matches snapshot.
        if activity.rawValue == "bigbrother.reconciliation" {
            reconcile()
            return
        }

        // Read the lightweight shared state first; fall back to full snapshot.
        let mode: LockMode
        let policy: EffectivePolicy?
        if let extState = storage.readExtensionSharedState() {
            mode = extState.currentMode
            policy = storage.readPolicySnapshot()?.effectivePolicy
        } else if let snapshot = storage.readPolicySnapshot() {
            mode = snapshot.effectivePolicy.resolvedMode
            policy = snapshot.effectivePolicy
        } else {
            return
        }

        applyShielding(mode: mode, policy: policy)
        logEvent(.scheduleTriggered, details: "Schedule started: \(activity.rawValue)")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        if activity.rawValue == "bigbrother.reconciliation" { return }

        // Clear the schedule store. The "base" store (set by the main app)
        // will still enforce the base policy.
        store.clearAllSettings()

        logEvent(.scheduleEnded, details: "Schedule ended: \(activity.rawValue)")
    }

    // MARK: - Reconciliation

    /// Verify enforcement matches the current policy snapshot.
    /// If the extension shared state indicates a mode that requires shielding,
    /// reapply it in case the schedule store was cleared unexpectedly.
    private func reconcile() {
        guard let extState = storage.readExtensionSharedState() else { return }

        // If temporary unlock is active and not expired, ensure store is clear.
        if extState.isTemporaryUnlock,
           let expires = extState.temporaryUnlockExpiresAt, expires > Date() {
            store.clearAllSettings()
            return
        }

        // If enforcement is degraded, nothing we can do from the extension.
        if extState.enforcementDegraded { return }

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShielding(mode: extState.currentMode, policy: policy)
        logEvent(.policyReconciled, details: "Reconciliation check from extension")
    }

    // MARK: - Shielding

    private func applyShielding(mode: LockMode, policy: EffectivePolicy?) {
        switch mode {
        case .unlocked:
            store.clearAllSettings()

        case .fullLockdown:
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()

        case .dailyMode, .essentialOnly:
            // If allowed app token data is available, decode and exempt those apps.
            // Otherwise, shield all (safe default).
            if let tokenData = policy?.allowedAppTokensData,
               let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: tokenData) {
                store.shield.applicationCategories = .all(except: tokens)
            } else {
                store.shield.applicationCategories = .all()
            }
            store.shield.webDomainCategories = .all()
        }
    }

    private func logEvent(_ type: EventType, details: String?) {
        // Read enrollment state to get deviceID and familyID.
        // If unavailable, skip logging (device may not be enrolled).
        let keychain = KeychainManager()
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        let entry = EventLogEntry(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            eventType: type,
            details: details
        )
        try? storage.appendEventLog(entry)
    }
}
