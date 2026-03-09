import Foundation
import ManagedSettings
import FamilyControls
import BigBrotherCore

/// Concrete enforcement service bridging PolicyResolver output to ManagedSettings.
///
/// Uses three named ManagedSettingsStore instances:
///   - "base": primary enforcement from mode commands
///   - "schedule": managed by DeviceActivityMonitor extension
///   - "tempUnlock": clears restrictions during temporary unlock
///
/// ManagedSettingsStore state persists across app launches and reboots,
/// providing enforcement continuity even when the app is not running.
final class EnforcementServiceImpl: EnforcementServiceProtocol {

    private let baseStore: ManagedSettingsStore
    private let tempUnlockStore: ManagedSettingsStore
    private let storage: any SharedStorageProtocol
    private let fcManager: any FamilyControlsManagerProtocol

    init(
        storage: any SharedStorageProtocol = AppGroupStorage(),
        fcManager: any FamilyControlsManagerProtocol
    ) {
        self.baseStore = ManagedSettingsStore(
            named: ManagedSettingsStore.Name(rawValue: AppConstants.managedSettingsStoreBase)
        )
        self.tempUnlockStore = ManagedSettingsStore(
            named: ManagedSettingsStore.Name(rawValue: AppConstants.managedSettingsStoreTempUnlock)
        )
        self.storage = storage
        self.fcManager = fcManager
    }

    // MARK: - EnforcementServiceProtocol

    func apply(_ policy: EffectivePolicy) throws {
        // Handle temporary unlock: clear all stores so device is unlocked.
        if policy.isTemporaryUnlock {
            baseStore.clearAllSettings()
            tempUnlockStore.clearAllSettings()
            return
        }

        // Clear temp unlock store (in case a previous temp unlock was active).
        tempUnlockStore.clearAllSettings()

        switch policy.resolvedMode {
        case .unlocked:
            baseStore.clearAllSettings()

        case .fullLockdown:
            baseStore.shield.applicationCategories = .all()
            baseStore.shield.webDomainCategories = .all()

        case .dailyMode:
            // Decode allowed app tokens from the serialized FamilyActivitySelection.
            // If token data is available and decodable, exempt those apps from shielding.
            // Otherwise, shield all apps (safe default).
            if let tokenData = policy.allowedAppTokensData,
               let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: tokenData) {
                let appTokens = selection.applicationTokens
                if !appTokens.isEmpty {
                    baseStore.shield.applicationCategories = .all(except: appTokens)
                } else {
                    baseStore.shield.applicationCategories = .all()
                }
            } else {
                baseStore.shield.applicationCategories = .all()
            }
            baseStore.shield.webDomainCategories = .all()

        case .essentialOnly:
            // Shield all categories. Essential apps (Phone, Messages) are system-unblockable
            // and cannot be restricted by ManagedSettings.
            baseStore.shield.applicationCategories = .all()
            baseStore.shield.webDomainCategories = .all()
        }

        // Update shield config for the shield extension UI.
        let config = ShieldConfig(
            title: policy.resolvedMode.displayName,
            message: shieldMessage(for: policy),
            showRequestButton: false
        )
        try? storage.writeShieldConfiguration(config)
    }

    func clearAllRestrictions() throws {
        baseStore.clearAllSettings()
        tempUnlockStore.clearAllSettings()
    }

    func clearTemporaryUnlock() throws {
        tempUnlockStore.clearAllSettings()
    }

    var authorizationStatus: FCAuthorizationStatus {
        fcManager.status
    }

    func requestAuthorization() async throws {
        try await fcManager.requestAuthorization()
    }

    func reconcile(with snapshot: PolicySnapshot) throws {
        // Reapply the effective policy from the snapshot.
        // ManagedSettingsStore may already match, but reapplying is idempotent.
        try apply(snapshot.effectivePolicy)
    }

    // MARK: - Private

    private func shieldMessage(for policy: EffectivePolicy) -> String {
        switch policy.resolvedMode {
        case .unlocked:
            return "This app should be accessible."
        case .dailyMode:
            return "This app is not in your allowed list. Ask a parent to unlock it."
        case .fullLockdown:
            return "All apps are restricted right now."
        case .essentialOnly:
            return "Only essential apps are available right now."
        }
    }
}
