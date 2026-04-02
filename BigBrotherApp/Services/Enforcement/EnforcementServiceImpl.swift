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

    /// Throttle nuclear resets to prevent infinite clear/re-apply loops.
    private var nuclearResetCount = 0
    private var nuclearResetWindowStart = Date()

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
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.set("apply", forKey: "lastShieldChangeReason")
        defaults?.set(Date().timeIntervalSince1970, forKey: "mainAppEnforcementAt")

        // Device restrictions apply ALWAYS, regardless of lock/unlock state.
        applyRestrictions(policy.deviceRestrictions)

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

        case .restricted, .locked, .lockedDown:
            // The resolvedMode in the EffectivePolicy already reflects the schedule
            // (set by the producer: CommandProcessor, Monitor, or ModeStackResolver).
            // Enforcement just applies what the policy says — no re-checking.
            applyShield(allowExemptions: policy.resolvedMode == .restricted, policyRestrictions: policy.deviceRestrictions)
        }

        // Update shield config for the shield extension UI.
        let config = ShieldConfig(
            title: policy.resolvedMode.displayName,
            message: shieldMessage(for: policy),
            showRequestButton: policy.resolvedMode != .unlocked
        )
        do {
            try storage.writeShieldConfiguration(config)
        } catch {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Failed to write shield config: \(error.localizedDescription)",
                details: "source=app"
            ))
        }

        // Verify enforcement took effect — read back the store state.
        // Checks both shield presence AND mode-specific details (exemptions, web blocking).
        let diag = shieldDiagnostic()
        let expectedShielded = policy.resolvedMode != .unlocked && !policy.isTemporaryUnlock
        // Mode-aware check: lockedDown should have zero exemptions (no per-app tokens).
        // restricted should have per-app tokens. locked should have category-only blocking.
        let modeInconsistent: Bool = {
            guard expectedShielded else { return false }
            switch policy.resolvedMode {
            case .lockedDown:
                // lockedDown = no exemptions, category blocking, web blocked
                return diag.appCount > 0 // Should be 0 (no per-app, just category)
            case .locked:
                // locked = category blocking active, no exemptions
                return !diag.categoryActive
            case .restricted:
                // restricted = shields active (either per-app or category)
                return false // Any shield type is fine
            default:
                return false
            }
        }()
        if expectedShielded != diag.shieldsActive || modeInconsistent {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Enforcement verification FAILED — attempting reset",
                details: "Expected shields \(expectedShielded ? "UP" : "DOWN") but got \(diag.shieldsActive ? "UP" : "DOWN") (mode: \(policy.resolvedMode.rawValue))"
            ))

            // Throttle nuclear resets to prevent infinite clear/re-apply loops.
            let now = Date()
            if now.timeIntervalSince(nuclearResetWindowStart) > 3600 {
                nuclearResetCount = 0
                nuclearResetWindowStart = now
            }
            nuclearResetCount += 1
            if nuclearResetCount > 3 {
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "THROTTLED: Nuclear reset exceeded 3x in 1 hour. Skipping to prevent loop.",
                    details: "source=app"
                ))
                return
            }

            // Nuclear option: clear everything, recreate stores, re-apply
            clearAllShieldStores()
            baseStore.clearAllSettings()
            scheduleStore.clearAllSettings()
            tempUnlockStore.clearAllSettings()

            // Re-apply from scratch
            if expectedShielded {
                applyShield(allowExemptions: policy.resolvedMode == .restricted, policyRestrictions: policy.deviceRestrictions)
                applyWebBlocking(policy.deviceRestrictions)
            }
            // Always re-apply device restrictions (denyAppRemoval etc.) after nuclear reset.
            applyRestrictions(policy.deviceRestrictions)

            let retryDiag = shieldDiagnostic()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: retryDiag.shieldsActive == expectedShielded
                    ? "Enforcement recovery SUCCEEDED after reset"
                    : "Enforcement recovery FAILED — ManagedSettings may need App & Website Activity toggle",
                details: "After reset: shields=\(retryDiag.shieldsActive), apps=\(retryDiag.appCount), cat=\(retryDiag.categoryActive)"
            ))
        }
    }

    /// Apply shields using per-app tokens from the picker selection.
    ///
    /// When a FamilyActivitySelection exists, uses `shield.applications` so
    /// ShieldAction receives the ApplicationToken directly (per-app unlock).
    /// Falls back to `.all(except:)` category blocking when no selection exists.
    /// Global limit on shield.applications tokens (undocumented Apple constraint).
    /// Exceeding this silently fails — no apps are shielded and reads back nil.
    private static let maxShieldApplications = 50

    /// - Parameters:
    ///   - allowExemptions: When false (essentialOnly), blocks ALL apps with no exemptions.
    ///   - policyRestrictions: Device restrictions from the policy, if available.
    private func applyShield(allowExemptions: Bool, policyRestrictions: DeviceRestrictions? = nil) {
        var allowedTokens = allowExemptions ? collectAllowedTokens() : Set<ApplicationToken>()
        let pickerTokens = loadPickerTokens()

        // Remove time-exhausted apps from the allowed set and collect their tokens
        // for shield.applications (enables "Request More Time" on the shield).
        let decoder = JSONDecoder()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        let exhaustedApps = storage.readTimeLimitExhaustedApps().filter { $0.dateString == today }
        var exhaustedTokens = Set<ApplicationToken>()
        for app in exhaustedApps {
            if let token = try? decoder.decode(ApplicationToken.self, from: app.tokenData) {
                allowedTokens.remove(token)
                exhaustedTokens.insert(token)
            }
        }

        if !pickerTokens.isEmpty && allowExemptions {
            // Per-app blocking for up to 50 apps (ShieldAction gets ApplicationToken).
            let tokensToBlock = pickerTokens.subtracting(allowedTokens)
            var perAppTokens: Set<ApplicationToken>
            if tokensToBlock.count <= Self.maxShieldApplications {
                perAppTokens = tokensToBlock
            } else {
                perAppTokens = Set(tokensToBlock.prefix(Self.maxShieldApplications))
            }
            // Add exhausted tokens to shield.applications for "Request More Time".
            // Re-enforce the 50-token cap after union — exceeding it causes Apple to
            // silently fail, dropping ALL shields.
            // Priority: exhausted tokens (time-limited apps that MUST be shielded) always
            // kept; picker tokens fill remaining slots. hashValue sort was non-deterministic
            // across process restarts and could drop exhausted tokens entirely.
            perAppTokens.formUnion(exhaustedTokens)
            if perAppTokens.count > Self.maxShieldApplications {
                let exhaustedCount = min(exhaustedTokens.count, Self.maxShieldApplications)
                let remainingSlots = Self.maxShieldApplications - exhaustedCount
                let pickerOnly = perAppTokens.subtracting(exhaustedTokens)
                let keptPicker = Set(pickerOnly.prefix(remainingSlots))
                perAppTokens = Set(exhaustedTokens.prefix(exhaustedCount)).union(keptPicker)
                let dropped = pickerOnly.count + exhaustedTokens.count - perAppTokens.count
                if dropped > 0 {
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .enforcement,
                        message: "Token cap: \(dropped) apps dropped from shield.applications (50 limit). \(exhaustedTokens.count) exhausted kept.",
                        details: "source=app"
                    ))
                }
            }
            baseStore.shield.applications = perAppTokens
            baseStore.shield.applicationCategories = .all(except: allowedTokens)
            recordShieldedAppCount(perAppTokens.count)
            #if DEBUG
            let overflow = tokensToBlock.count - perAppTokens.count
            print("[BigBrother] Shield applied — \(perAppTokens.count) apps via shield.applications\(overflow > 0 ? " (\(overflow) overflow to category)" : ""), category catch-all active, \(exhaustedTokens.count) time-exhausted")
            #endif
        } else {
            // No picker selection or essentialOnly — block everything.
            var explicitApps: Set<ApplicationToken>? = allowExemptions ? nil : pickerTokens.isEmpty ? nil : pickerTokens
            // Add exhausted tokens
            if !exhaustedTokens.isEmpty {
                explicitApps = (explicitApps ?? Set()).union(exhaustedTokens)
            }
            // Enforce 50-token cap — exceeding it silently drops ALL shields.
            // Priority: exhausted tokens always kept, picker tokens fill remaining slots.
            if let apps = explicitApps, apps.count > Self.maxShieldApplications {
                let exhaustedCount = min(exhaustedTokens.count, Self.maxShieldApplications)
                let remainingSlots = Self.maxShieldApplications - exhaustedCount
                let nonExhausted = apps.subtracting(exhaustedTokens)
                let keptNonExhausted = Set(nonExhausted.prefix(remainingSlots))
                explicitApps = Set(exhaustedTokens.prefix(exhaustedCount)).union(keptNonExhausted)
            }
            baseStore.shield.applications = explicitApps
            if allowedTokens.isEmpty {
                baseStore.shield.applicationCategories = .all()
            } else {
                baseStore.shield.applicationCategories = .all(except: allowedTokens)
            }
            recordShieldedAppCount(explicitApps?.count ?? 0)
            #if DEBUG
            print("[BigBrother] Shield applied — \(allowExemptions ? "category-only" : "essential") block with \(allowedTokens.count) exemptions")
            #endif
        }
        applyWebBlocking(policyRestrictions)
        updateEnforcementBlockedDomains(allowedTokens: allowedTokens, policyRestrictions: policyRestrictions)
    }

    /// Compute and write DNS-blocked domains for web app bypass prevention.
    /// Only blocks web domains of apps that are ACTIVELY SHIELDED (in the picker
    /// selection), not the entire app catalog. This prevents overbroad DNS blocking
    /// that breaks legitimate websites sharing domains with cataloged apps.
    private func updateEnforcementBlockedDomains(allowedTokens: Set<ApplicationToken>, policyRestrictions: DeviceRestrictions? = nil) {
        let encoder = JSONEncoder()
        let cache = storage.readAllCachedAppNames()

        // Resolve names of SHIELDED apps (picker selection minus allowed).
        // Only these apps' web domains need DNS blocking.
        let pickerTokens = loadPickerTokens()
        let shieldedTokens = pickerTokens.subtracting(allowedTokens)
        var shieldedNames = Set<String>()
        for token in shieldedTokens {
            if let data = try? encoder.encode(token) {
                let key = data.base64EncodedString()
                if let name = cache[key], !name.hasPrefix("App ") {
                    shieldedNames.insert(name)
                }
            }
        }

        // Block ONLY the web domains of shielded apps — not the entire catalog.
        var blocked = Set<String>()
        for name in shieldedNames {
            blocked.formUnion(DomainCategorizer.domainsForApp(name))
        }

        // Always block DoH resolvers when enforcement is active — prevents DNS bypass.
        blocked.formUnion(DomainCategorizer.dohResolverDomains)

        // If web games are denied, also block browser gaming sites.
        let restrictions = policyRestrictions ?? storage.readDeviceRestrictions() ?? DeviceRestrictions()
        if restrictions.denyWebGamesWhenRestricted {
            blocked.formUnion(DomainCategorizer.webGamingDomains)
        }

        do {
            try storage.writeEnforcementBlockedDomains(blocked)
        } catch {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Failed to write enforcement blocked domains: \(error.localizedDescription)",
                details: "source=app"
            ))
        }

        #if DEBUG
        print("[BigBrother] Enforcement DNS blocking: \(blocked.count) domains blocked (\(shieldedNames.count) shielded apps)\(restrictions.denyWebGamesWhenRestricted ? " +gaming" : "")")
        #endif
    }

    /// Apply web domain blocking based on the denyWebWhenLocked restriction.
    /// When the restriction is off, web stays open even when locked.
    /// When on, blocks all web categories unless the parent has configured allowed domains.
    /// Uses the provided restrictions when available, falling back to storage read.
    private func applyWebBlocking(_ policyRestrictions: DeviceRestrictions? = nil) {
        let restrictions = policyRestrictions ?? storage.readDeviceRestrictions() ?? DeviceRestrictions()
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

        // Block web on ALL stores to ensure coverage after schedule/unlock transitions.
        // ManagedSettings merges across stores — a stale nil on any store won't
        // override .all() on another, but consistency prevents confusion.
        let allStores = [baseStore, scheduleStore, tempUnlockStore]
        for store in allStores {
            store.shield.webDomainCategories = .all()
        }
    }

    /// Load app tokens from the saved FamilyActivitySelection.
    private func loadPickerTokens() -> Set<ApplicationToken> {
        guard let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection) else {
            return []
        }
        do {
            let selection = try JSONDecoder().decode(FamilyActivitySelection.self, from: data)
            return selection.applicationTokens
        } catch {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Failed to decode FamilyActivitySelection (\(data.count) bytes): \(error.localizedDescription)",
                details: "source=app"
            ))
            return []
        }
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

        // Clear BOTH DNS blocklists — enforcement AND time-limit.
        // Both must be cleared on unlock; the tunnel reads them with OR logic.
        do {
            try storage.writeEnforcementBlockedDomains([])
        } catch {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Failed to clear enforcement blocked domains: \(error.localizedDescription)",
                details: "source=app"
            ))
        }
        do {
            try storage.writeTimeLimitBlockedDomains([])
        } catch {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Failed to clear time-limit blocked domains: \(error.localizedDescription)",
                details: "source=app"
            ))
        }
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
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("clearAll", forKey: "lastShieldChangeReason")
        clearAllShieldStores()
        recordShieldedAppCount(0)
        tempUnlockStore.clearAllSettings()
        // Re-apply device-level restrictions (denyAppRemoval, lockAccounts, etc.)
        // that should persist even when shields are cleared during unlocked mode.
        applyRestrictions()
    }

    func clearTemporaryUnlock() throws {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("tempUnlockClear", forKey: "lastShieldChangeReason")
        tempUnlockStore.clearAllSettings()
    }

    func applyEssentialOnly() throws {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("vpnDenied", forKey: "lastShieldChangeReason")
        applyRestrictions()
        applyShield(allowExemptions: false)
    }

    // MARK: - Shield Diagnostic

    /// Track shielded app count ourselves because ManagedSettingsStore.shield.applications
    /// doesn't reliably return the tokens that were written to it.
    private func recordShieldedAppCount(_ count: Int) {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(count, forKey: "shieldedAppCount")
    }

    func shieldDiagnostic() -> ShieldDiagnostic {
        let baseCat = baseStore.shield.applicationCategories
        let schedCat = scheduleStore.shield.applicationCategories

        let appCount = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .integer(forKey: "shieldedAppCount") ?? 0
        let categoryActive = baseCat != nil || schedCat != nil
        let shieldsActive = appCount > 0 || categoryActive

        // Also check web blocking and device restrictions for mode-aware verification.
        let webBlocking = baseStore.shield.webDomainCategories != nil
            || scheduleStore.shield.webDomainCategories != nil
        let denyAppRemoval = ManagedSettingsStore().application.denyAppRemoval == true

        return ShieldDiagnostic(
            shieldsActive: shieldsActive,
            appCount: appCount,
            categoryActive: categoryActive,
            webBlockingActive: webBlocking,
            denyAppRemoval: denyAppRemoval
        )
    }

    var authorizationStatus: FCAuthorizationStatus {
        fcManager.status
    }

    func requestAuthorization() async throws {
        try await fcManager.requestAuthorization()
    }

    func reconcile(with snapshot: PolicySnapshot) throws {
        // Don't clear stores first — apply() already handles unlocked (clears)
        // and locked (overwrites). Clearing first creates a vulnerability window
        // where shields are down if apply() throws.
        try apply(snapshot.effectivePolicy)
    }

    // MARK: - Private

    /// Apply device-level restrictions from parent settings.
    /// Clears stale restrictions from ALL stores first, then sets on default store.
    /// Uses the provided restrictions when available, falling back to storage read.
    private func applyRestrictions(_ policyRestrictions: DeviceRestrictions? = nil) {
        let r = policyRestrictions ?? storage.readDeviceRestrictions() ?? DeviceRestrictions()

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
        case .restricted:
            return "This app is not in your allowed list. Ask a parent to unlock it."
        case .locked:
            return "Only essential apps are available right now."
        case .lockedDown:
            return "Device is locked down. Only essential apps, no internet."
        }
    }
}
