import Foundation
import ManagedSettings
import FamilyControls
import BigBrotherCore

/// Concrete enforcement service bridging PolicyResolver output to ManagedSettings.
///
/// Uses named ManagedSettingsStore instances:
///   - "base": primary enforcement via per-app blocking
///   - "schedule": managed by DeviceActivityMonitor extension
///   - "tempUnlock": clears restrictions during temporary unlock
///
/// Blocking strategy (hybrid):
///   1. `shield.applications` for per-app blocking from FamilyActivityPicker selection.
///      ShieldAction gets the ApplicationToken directly — enables per-app unlock.
///      Has a 50-token limit per store (silent failure above 50).
///   2. `shield.applicationCategories = .all(except:)` as catch-all for apps not in
///      the picker selection. ShieldAction only gets ActivityCategoryToken here.
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
            clearAllShieldStores()
            tempUnlockStore.clearAllSettings()
            return
        }

        // Clear temp unlock store (in case a previous temp unlock was active).
        tempUnlockStore.clearAllSettings()

        switch policy.resolvedMode {
        case .unlocked:
            clearAllShieldStores()

        case .dailyMode, .essentialOnly:
            applyShield()
        }

        // Update shield config for the shield extension UI.
        let config = ShieldConfig(
            title: policy.resolvedMode.displayName,
            message: shieldMessage(for: policy),
            showRequestButton: policy.resolvedMode != .unlocked
        )
        try? storage.writeShieldConfiguration(config)
    }

    /// Apply shields using per-app tokens from the picker selection.
    ///
    /// When a FamilyActivitySelection exists, uses `shield.applications` so
    /// ShieldAction receives the ApplicationToken directly (per-app unlock).
    /// Falls back to `.all(except:)` category blocking when no selection exists.
    private func applyShield() {
        let allowedTokens = collectAllowedTokens()
        let pickerTokens = loadPickerTokens()

        if !pickerTokens.isEmpty {
            // Per-app blocking: ShieldAction gets ApplicationToken directly.
            let tokensToBlock = pickerTokens.subtracting(allowedTokens)
            baseStore.shield.applications = tokensToBlock
            // Category catch-all for apps NOT in the picker selection.
            baseStore.shield.applicationCategories = .all(except: pickerTokens.union(allowedTokens))
            #if DEBUG
            print("[BigBrother] Shield applied — \(tokensToBlock.count) apps via shield.applications, category catch-all active")
            #endif
        } else {
            // No picker selection — block everything via categories.
            baseStore.shield.applications = nil
            if allowedTokens.isEmpty {
                baseStore.shield.applicationCategories = .all()
            } else {
                baseStore.shield.applicationCategories = .all(except: allowedTokens)
            }
            #if DEBUG
            print("[BigBrother] Shield applied — category-only block with \(allowedTokens.count) exemptions (no picker selection)")
            #endif
        }
        baseStore.shield.webDomainCategories = .all()
    }

    /// Load app tokens from the saved FamilyActivitySelection.
    private func loadPickerTokens() -> Set<ApplicationToken> {
        guard let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return []
        }
        return selection.applicationTokens
    }

    /// Clear the base store shield properties.
    private func clearAllShieldStores() {
        baseStore.shield.applications = nil
        baseStore.shield.applicationCategories = nil
        baseStore.shield.webDomainCategories = nil
        baseStore.shield.webDomains = nil
    }

    /// Collect tokens for apps that should NOT be shielded (parent-approved).
    private func collectAllowedTokens() -> Set<ApplicationToken> {
        var tokens = Set<ApplicationToken>()
        let decoder = JSONDecoder()

        // Permanently allowed apps.
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            tokens.formUnion(allowed)
        }

        // Temporarily allowed apps (non-expired only).
        let tempEntries = storage.readTemporaryAllowedApps()
        for entry in tempEntries where entry.isValid {
            if let token = try? decoder.decode(ApplicationToken.self, from: entry.tokenData) {
                tokens.insert(token)
            }
        }

        return tokens
    }

    func clearAllRestrictions() throws {
        clearAllShieldStores()
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
        clearAllShieldStores()
        try apply(snapshot.effectivePolicy)
    }

    // MARK: - Private

    private func shieldMessage(for policy: EffectivePolicy) -> String {
        switch policy.resolvedMode {
        case .unlocked:
            return "This app should be accessible."
        case .dailyMode:
            return "This app is not in your allowed list. Ask a parent to unlock it."
        case .essentialOnly:
            return "Only essential apps are available right now."
        }
    }
}
