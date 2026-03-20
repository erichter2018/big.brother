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
    private let scheduleStore: ManagedSettingsStore
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
        self.scheduleStore = ManagedSettingsStore(
            named: ManagedSettingsStore.Name(rawValue: AppConstants.managedSettingsStoreSchedule)
        )
        self.tempUnlockStore = ManagedSettingsStore(
            named: ManagedSettingsStore.Name(rawValue: AppConstants.managedSettingsStoreTempUnlock)
        )
        self.storage = storage
        self.fcManager = fcManager
    }

    // MARK: - EnforcementServiceProtocol

    func apply(_ policy: EffectivePolicy) throws {
        // Device restrictions apply ALWAYS, regardless of lock/unlock state.
        applyRestrictions()

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
            // If schedule profile says we're in a free window, defer to the monitor extension.
            // The monitor manages all stores during free windows — don't re-shield here.
            if let profile = storage.readActiveScheduleProfile(),
               profile.isInFreeWindow(at: Date()) {
                clearAllShieldStores()
            } else {
                applyShield(allowExemptions: policy.resolvedMode == .dailyMode)
            }
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
    /// Global limit on shield.applications tokens (undocumented Apple constraint).
    /// Exceeding this silently fails — no apps are shielded and reads back nil.
    private static let maxShieldApplications = 50

    /// - Parameter allowExemptions: When false (essentialOnly), blocks ALL apps with no exemptions.
    private func applyShield(allowExemptions: Bool) {
        let allowedTokens = allowExemptions ? collectAllowedTokens() : []
        let pickerTokens = loadPickerTokens()

        if !pickerTokens.isEmpty && allowExemptions {
            // Per-app blocking for up to 50 apps (ShieldAction gets ApplicationToken).
            let tokensToBlock = pickerTokens.subtracting(allowedTokens)
            let perAppTokens: Set<ApplicationToken>
            if tokensToBlock.count <= Self.maxShieldApplications {
                perAppTokens = tokensToBlock
            } else {
                perAppTokens = Set(tokensToBlock.prefix(Self.maxShieldApplications))
            }
            baseStore.shield.applications = perAppTokens
            baseStore.shield.applicationCategories = .all(except: allowedTokens)
            #if DEBUG
            let overflow = tokensToBlock.count - perAppTokens.count
            print("[BigBrother] Shield applied — \(perAppTokens.count) apps via shield.applications\(overflow > 0 ? " (\(overflow) overflow to category)" : ""), category catch-all active")
            #endif
        } else {
            // No picker selection or essentialOnly — block everything.
            baseStore.shield.applications = allowExemptions ? nil : pickerTokens.isEmpty ? nil : pickerTokens
            if allowedTokens.isEmpty {
                baseStore.shield.applicationCategories = .all()
            } else {
                baseStore.shield.applicationCategories = .all(except: allowedTokens)
            }
            #if DEBUG
            print("[BigBrother] Shield applied — \(allowExemptions ? "category-only" : "essential") block with \(allowedTokens.count) exemptions")
            #endif
        }
        applyWebBlocking()
    }

    /// Apply web domain blocking based on the denyWebWhenLocked restriction.
    /// When the restriction is off, web stays open even when locked.
    /// When on, blocks all web categories unless the parent has configured allowed domains.
    private func applyWebBlocking() {
        let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
        guard restrictions.denyWebWhenLocked else {
            // Clear web blocking on ALL stores — ManagedSettings merges across stores,
            // so stale webDomainCategories on any store will keep blocking.
            for store in [baseStore, scheduleStore, tempUnlockStore] {
                store.shield.webDomainCategories = nil
            }
            ManagedSettingsStore().shield.webDomainCategories = nil
            #if DEBUG
            print("[BigBrother] Web blocking: disabled (denyWebWhenLocked=false) — cleared all stores")
            #endif
            return
        }

        if let data = storage.readRawData(forKey: StorageKeys.allowedWebDomains),
           let domains = try? JSONDecoder().decode([String].self, from: data),
           !domains.isEmpty {
            // Parent has allowed web access — don't block web categories.
            // Clear on all stores since Monitor may have set it on schedule store too.
            for store in [baseStore, scheduleStore, tempUnlockStore] {
                store.shield.webDomainCategories = nil
            }
            ManagedSettingsStore().shield.webDomainCategories = nil
            #if DEBUG
            print("[BigBrother] Web blocking: disabled (\(domains.count) allowed domains configured)")
            #endif
        } else {
            // Block on all stores to ensure coverage after schedule transitions.
            for store in [baseStore, scheduleStore] {
                store.shield.webDomainCategories = .all()
            }
            #if DEBUG
            print("[BigBrother] Web blocking: all domains blocked")
            #endif
        }
    }

    /// Load app tokens from the saved FamilyActivitySelection.
    private func loadPickerTokens() -> Set<ApplicationToken> {
        guard let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return []
        }
        return selection.applicationTokens
    }

    /// Clear shield properties on ALL named stores.
    /// ManagedSettings merges across stores — if any store blocks, it's blocked.
    private func clearAllShieldStores() {
        for store in [baseStore, scheduleStore, tempUnlockStore] {
            store.shield.applications = nil
            store.shield.applicationCategories = nil
            store.shield.webDomainCategories = nil
            store.shield.webDomains = nil
        }
        // Also clear the default (unnamed) store in case anything leaked there.
        let defaultStore = ManagedSettingsStore()
        defaultStore.shield.applications = nil
        defaultStore.shield.applicationCategories = nil
        defaultStore.shield.webDomainCategories = nil
        defaultStore.shield.webDomains = nil
    }

    /// Collect tokens for apps that should NOT be shielded (parent-approved).
    private func collectAllowedTokens() -> Set<ApplicationToken> {
        var tokens = Set<ApplicationToken>()
        let decoder = JSONDecoder()

        // Permanently allowed apps.
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens) {
            if let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
                tokens.formUnion(allowed)
                #if DEBUG
                print("[BigBrother] Allowed tokens loaded: \(allowed.count) permanent")
                #endif
            } else {
                #if DEBUG
                print("[BigBrother] Allowed tokens: decode FAILED (\(data.count) bytes)")
                #endif
            }
        } else {
            #if DEBUG
            print("[BigBrother] Allowed tokens: no data stored")
            #endif
        }

        // Temporarily allowed apps (non-expired only).
        let tempEntries = storage.readTemporaryAllowedApps()
        for entry in tempEntries where entry.isValid {
            if let token = try? decoder.decode(ApplicationToken.self, from: entry.tokenData) {
                tokens.insert(token)
            }
        }

        #if DEBUG
        print("[BigBrother] Total allowed tokens: \(tokens.count) (permanent + \(tempEntries.filter(\.isValid).count) temp)")
        #endif
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

    /// Apply device-level restrictions from parent settings.
    /// Clears stale restrictions from ALL stores first, then sets on default store.
    private func applyRestrictions() {
        let r = storage.readDeviceRestrictions() ?? DeviceRestrictions()

        // Clear restrictions from ALL named stores (stale values from earlier code).
        for store in [baseStore, scheduleStore, tempUnlockStore] {
            store.application.denyAppRemoval = nil
            store.media.denyExplicitContent = nil
            store.account.lockAccounts = nil
            store.dateAndTime.requireAutomaticDateAndTime = nil
        }

        // Apply on the default (unnamed) store.
        let store = ManagedSettingsStore()
        store.application.denyAppRemoval = r.denyAppRemoval ? true : nil
        store.media.denyExplicitContent = r.denyExplicitContent ? true : nil
        store.account.lockAccounts = r.lockAccounts ? true : nil
        store.dateAndTime.requireAutomaticDateAndTime = r.requireAutomaticDateAndTime ? true : nil

        #if DEBUG
        print("[BigBrother] Restrictions applied: removal=\(r.denyAppRemoval) explicit=\(r.denyExplicitContent) accounts=\(r.lockAccounts) dateTime=\(r.requireAutomaticDateAndTime)")
        print("[BigBrother] Restrictions readback: denyAppRemoval=\(String(describing: store.application.denyAppRemoval))")
        #endif
    }

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
