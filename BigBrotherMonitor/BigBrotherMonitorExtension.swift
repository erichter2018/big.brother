import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import UserNotifications
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
    private let baseStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreBase))

    /// Prefix used by ScheduleRegistrar for free-window activities.
    private let scheduleProfilePrefix = "bigbrother.scheduleprofile."
    /// Prefix used for penalty-offset timed unlocks.
    private let timedUnlockPrefix = "bigbrother.timedunlock."
    /// Prefix used for temporary unlock expiry (auto-relock).
    private let tempUnlockPrefix = "bigbrother.tempunlock."
    /// Prefix used for timed lock (lockUntil) — auto-return to schedule.
    private let lockUntilPrefix = "bigbrother.lockuntil."

    override func intervalDidStart(for activity: DeviceActivityName) {
        // Reconciliation schedule — verify enforcement matches snapshot.
        if activity.rawValue == "bigbrother.reconciliation" {
            reconcile()
            return
        }

        // Schedule profile free window — unlock if today matches.
        if activity.rawValue.hasPrefix(scheduleProfilePrefix) {
            handleFreeWindowStart(activity)
            return
        }

        // Timed unlock (penalty offset) — penalty served, now unlock.
        if activity.rawValue.hasPrefix(timedUnlockPrefix) {
            handleTimedUnlockStart(activity)
            return
        }

        // Temporary unlock expiry schedule — no action needed on start (device is already unlocked).
        if activity.rawValue.hasPrefix(tempUnlockPrefix) {
            return
        }

        // Lock-until schedule — no action needed on start (device is already locked).
        if activity.rawValue.hasPrefix(lockUntilPrefix) {
            return
        }

        // Legacy / other schedule activity — apply current policy mode.
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

        // Schedule profile free window ended — re-lock.
        if activity.rawValue.hasPrefix(scheduleProfilePrefix) {
            handleFreeWindowEnd(activity)
            return
        }

        // Timed unlock ended — re-lock.
        if activity.rawValue.hasPrefix(timedUnlockPrefix) {
            handleTimedUnlockEnd(activity)
            return
        }

        // Temporary unlock expired — re-lock the device.
        if activity.rawValue.hasPrefix(tempUnlockPrefix) {
            handleTempUnlockExpired(activity)
            return
        }

        // Lock-until expired — return to schedule mode.
        if activity.rawValue.hasPrefix(lockUntilPrefix) {
            handleLockUntilExpired(activity)
            return
        }

        // Legacy / other schedule — clear schedule store.
        store.clearAllSettings()
        logEvent(.scheduleEnded, details: "Schedule ended: \(activity.rawValue)")
    }

    // MARK: - Schedule Profile Handling

    /// Free window started: check if today is a valid day, then unlock.
    private func handleFreeWindowStart(_ activity: DeviceActivityName) {
        guard let profile = storage.readActiveScheduleProfile() else { return }

        let windowID = String(activity.rawValue.dropFirst(scheduleProfilePrefix.count))
        guard let window = profile.freeWindows.first(where: { $0.id.uuidString == windowID }) else {
            return
        }

        // Check if today matches one of this window's active days.
        let today = Calendar.current.component(.weekday, from: Date())
        guard let day = DayOfWeek(rawValue: today), window.daysOfWeek.contains(day) else {
            // Not a matching day — keep locked.
            return
        }

        // Unlock: clear ALL shield stores (base + schedule + default).
        // ManagedSettings merges across stores with OR logic — clearing only
        // the schedule store leaves the base store shields active.
        clearAllShieldStores()
        logEvent(.scheduleTriggered, details: "Free window started: \(activity.rawValue)")
        sendModeNotification(title: "Free Time Started", body: "All apps are now accessible.")
    }

    /// Free window ended: re-apply the profile's locked mode.
    private func handleFreeWindowEnd(_ activity: DeviceActivityName) {
        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Check if we're currently inside another free window.
        // If so, don't lock — the device should stay free.
        if profile.isInFreeWindow(at: Date()) {
            return
        }

        // Re-lock using the profile's locked mode on ALL stores.
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: profile.lockedMode, policy: policy)
        logEvent(.scheduleEnded, details: "Free window ended, locked to \(profile.lockedMode.rawValue)")
        sendModeNotification(
            title: "Free Time Ended",
            body: "Device locked — \(profile.lockedMode.displayName) mode active."
        )
    }

    // MARK: - Timed Unlock (Penalty Offset)

    /// Penalty served — unlock the device.
    private func handleTimedUnlockStart(_ activity: DeviceActivityName) {
        clearAllShieldStores()
        logEvent(.scheduleTriggered, details: "Timed unlock: penalty served, device unlocked")
        sendModeNotification(title: "Penalty Complete", body: "All apps are now accessible.")
    }

    /// Timed unlock window ended — re-lock the device.
    private func handleTimedUnlockEnd(_ activity: DeviceActivityName) {
        let mode: LockMode
        if let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
        } else {
            mode = .dailyMode
        }
        if mode == .unlocked {
            clearAllShieldStores()
        } else {
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            applyShieldingToAllStores(mode: mode, policy: policy)
        }
        try? storage.clearTimedUnlockInfo()
        logEvent(.scheduleEnded, details: "Timed unlock ended, mode \(mode.rawValue)")
        sendModeNotification(title: "Free Time Ended", body: mode == .unlocked ? "Free window — all apps accessible." : "Device locked — \(mode.displayName) mode active.")
    }

    // MARK: - Temporary Unlock Expiry

    /// Temporary unlock timer expired — re-lock the device using the previous mode.
    private func handleTempUnlockExpired(_ activity: DeviceActivityName) {
        let unlockState = storage.readTemporaryUnlockState()
        let previousMode = unlockState?.previousMode ?? .dailyMode

        // Check schedule profile — if one is assigned, use its resolved mode instead.
        let mode: LockMode
        if let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
        } else {
            mode = previousMode
        }

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: mode, policy: policy)
        try? storage.clearTemporaryUnlockState()
        logEvent(.temporaryUnlockExpired, details: "Temp unlock expired, locked to \(mode.rawValue)")
        sendModeNotification(title: "Free Time Ended", body: "Device locked — \(mode.displayName) mode active.")
    }

    // MARK: - Lock Until Expiry

    /// Lock-until timer expired — return to schedule-driven mode.
    private func handleLockUntilExpired(_ activity: DeviceActivityName) {
        let mode: LockMode
        if let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
        } else {
            // No schedule — stay locked.
            mode = .dailyMode
        }

        if mode == .unlocked {
            clearAllShieldStores()
        } else {
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            applyShieldingToAllStores(mode: mode, policy: policy)
        }
        logEvent(.scheduleEnded, details: "Lock-until expired, mode: \(mode.rawValue)")
        sendModeNotification(
            title: mode == .unlocked ? "Free Time Started" : "Lock Period Ended",
            body: mode == .unlocked ? "All apps are now accessible." : "\(mode.displayName) mode active."
        )
    }

    // MARK: - Reconciliation

    /// Verify enforcement matches the current policy snapshot.
    /// Must work even if the main app was force-killed before writing ExtensionSharedState.
    /// Falls back to PolicySnapshot + ScheduleProfile when ExtensionSharedState is nil.
    private func reconcile() {
        let extState = storage.readExtensionSharedState()

        // --- Temporary unlock checks (only if ExtensionSharedState exists) ---

        if let extState {
            // If temporary unlock is active and not expired, ensure all stores are clear.
            if extState.isTemporaryUnlock,
               let expires = extState.temporaryUnlockExpiresAt, expires > Date() {
                clearAllShieldStores()
                return
            }

            // If temporary unlock has expired, re-lock using the previous mode.
            if extState.isTemporaryUnlock,
               let expires = extState.temporaryUnlockExpiresAt, expires <= Date() {
                let unlockState = storage.readTemporaryUnlockState()
                let previousMode = unlockState?.previousMode ?? .dailyMode
                let mode: LockMode
                if let profile = storage.readActiveScheduleProfile() {
                    mode = profile.resolvedMode(at: Date())
                } else {
                    mode = previousMode
                }
                let policy = storage.readPolicySnapshot()?.effectivePolicy
                applyShieldingToAllStores(mode: mode, policy: policy)
                try? storage.clearTemporaryUnlockState()
                logEvent(.temporaryUnlockExpired, details: "Reconciliation: temp unlock expired, locked to \(mode.rawValue)")
                sendModeNotification(title: "Free Time Ended", body: "Device locked — \(mode.displayName) mode active.")
                return
            }

            // If enforcement is degraded, nothing we can do from the extension.
            if extState.enforcementDegraded { return }
        }

        // --- Check TemporaryUnlockState directly (survives force-close) ---

        if let unlockState = storage.readTemporaryUnlockState() {
            if unlockState.expiresAt > Date() {
                // Active temp unlock — keep stores clear.
                clearAllShieldStores()
                return
            } else {
                // Expired temp unlock the monitor never caught — re-lock now.
                let mode: LockMode
                if let profile = storage.readActiveScheduleProfile() {
                    mode = profile.resolvedMode(at: Date())
                } else {
                    mode = unlockState.previousMode
                }
                let policy = storage.readPolicySnapshot()?.effectivePolicy
                applyShieldingToAllStores(mode: mode, policy: policy)
                try? storage.clearTemporaryUnlockState()
                logEvent(.temporaryUnlockExpired, details: "Reconciliation: stale temp unlock cleaned up, locked to \(mode.rawValue)")
                sendModeNotification(title: "Free Time Ended", body: "Device locked — \(mode.displayName) mode active.")
                return
            }
        }

        // --- Timed unlock check (penalty-offset unlocks survive force-close) ---

        if let timedInfo = storage.readTimedUnlockInfo() {
            let now = Date()
            if now < timedInfo.unlockAt {
                // Still in penalty phase — ensure device is locked.
                let penaltyMode: LockMode = storage.readActiveScheduleProfile()?.lockedMode ?? .dailyMode
                let policy = storage.readPolicySnapshot()?.effectivePolicy
                applyShieldingToAllStores(mode: penaltyMode, policy: policy)
                return
            } else if now >= timedInfo.unlockAt && now < timedInfo.lockAt {
                // In the free phase — device should be unlocked.
                clearAllShieldStores()
                return
            } else {
                // Past lockAt — the schedule should have re-locked, but clean up in case it didn't.
                let mode: LockMode
                if let profile = storage.readActiveScheduleProfile() {
                    mode = profile.resolvedMode(at: Date())
                } else {
                    mode = .dailyMode
                }
                if mode == .unlocked {
                    clearAllShieldStores()
                } else {
                    let policy = storage.readPolicySnapshot()?.effectivePolicy
                    applyShieldingToAllStores(mode: mode, policy: policy)
                }
                try? storage.clearTimedUnlockInfo()
                logEvent(.policyReconciled, details: "Reconciliation: stale timed unlock cleaned up, mode \(mode.rawValue)")
                return
            }
        }

        // --- Schedule profile free window check ---

        if let profile = storage.readActiveScheduleProfile(),
           profile.isInFreeWindow(at: Date()) {
            clearAllShieldStores()
            logEvent(.policyReconciled, details: "Reconciliation: in free window, stores cleared")
            return
        }

        // --- Default: apply the current mode from ExtensionSharedState or PolicySnapshot ---

        let resolvedMode: LockMode
        if let extState {
            resolvedMode = extState.currentMode
        } else if let snapshot = storage.readPolicySnapshot() {
            resolvedMode = snapshot.effectivePolicy.resolvedMode
        } else {
            // No state at all — nothing to enforce.
            return
        }

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: resolvedMode, policy: policy)
        logEvent(.policyReconciled, details: "Reconciliation check from extension")
    }

    // MARK: - All-Store Shield Management

    /// Clear shield properties on ALL named stores + default store.
    /// ManagedSettings merges across stores with OR logic — if any store blocks, it's blocked.
    private func clearAllShieldStores() {
        let tempUnlockStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreTempUnlock))
        for s in [baseStore, store, tempUnlockStore] {
            s.shield.applications = nil
            s.shield.applicationCategories = nil
            s.shield.webDomainCategories = nil
            s.shield.webDomains = nil
        }
        let defaultStore = ManagedSettingsStore()
        defaultStore.shield.applications = nil
        defaultStore.shield.applicationCategories = nil
        defaultStore.shield.webDomainCategories = nil
        defaultStore.shield.webDomains = nil
    }

    /// Apply shields to BOTH base and schedule stores using the hybrid per-app + category strategy.
    /// Mirrors EnforcementServiceImpl.applyShield() logic.
    private static let maxShieldApplications = 50

    private func applyShieldingToAllStores(mode: LockMode, policy: EffectivePolicy?) {
        switch mode {
        case .unlocked:
            clearAllShieldStores()

        case .dailyMode, .essentialOnly:
            let allowExemptions = mode == .dailyMode
            let allowedTokens = allowExemptions ? collectAllowedTokens() : []
            let pickerTokens = loadPickerTokens()

            if !pickerTokens.isEmpty && allowExemptions {
                let tokensToBlock = pickerTokens.subtracting(allowedTokens)
                let perAppTokens: Set<ApplicationToken>
                if tokensToBlock.count <= Self.maxShieldApplications {
                    perAppTokens = tokensToBlock
                } else {
                    perAppTokens = Set(tokensToBlock.prefix(Self.maxShieldApplications))
                }
                // Apply to both base and schedule stores for full coverage.
                for s in [baseStore, store] {
                    s.shield.applications = perAppTokens
                    s.shield.applicationCategories = .all(except: allowedTokens)
                    s.shield.webDomainCategories = .all()
                }
            } else {
                let apps: Set<ApplicationToken>? = allowExemptions ? nil : (pickerTokens.isEmpty ? nil : pickerTokens)
                for s in [baseStore, store] {
                    s.shield.applications = apps
                    if allowedTokens.isEmpty {
                        s.shield.applicationCategories = .all()
                    } else {
                        s.shield.applicationCategories = .all(except: allowedTokens)
                    }
                    s.shield.webDomainCategories = .all()
                }
            }
        }
    }

    /// Load app tokens from the saved FamilyActivitySelection.
    /// Mirrors EnforcementServiceImpl.loadPickerTokens().
    private func loadPickerTokens() -> Set<ApplicationToken> {
        guard let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection) else {
            return []
        }
        // FamilyActivitySelection is Codable — decode to get applicationTokens.
        // We decode a lightweight wrapper since we only need the tokens.
        guard let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return []
        }
        return selection.applicationTokens
    }

    // MARK: - Single-Store Shielding (legacy fallback)

    private func applyShielding(mode: LockMode, policy: EffectivePolicy?) {
        switch mode {
        case .unlocked:
            store.clearAllSettings()

        case .dailyMode, .essentialOnly:
            // Read allowed tokens from App Group (same source as main app).
            let allowedTokens = collectAllowedTokens()
            if allowedTokens.isEmpty {
                store.shield.applicationCategories = .all()
            } else {
                store.shield.applicationCategories = .all(except: allowedTokens)
            }
            store.shield.webDomainCategories = .all()
        }
    }

    /// Collect parent-approved tokens from App Group storage.
    /// Mirrors EnforcementServiceImpl.collectAllowedTokens().
    private func collectAllowedTokens() -> Set<ApplicationToken> {
        let decoder = JSONDecoder()
        var tokens = Set<ApplicationToken>()

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

    // MARK: - Notifications

    private func sendModeNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "SCHEDULE_CHANGE"

        let request = UNNotificationRequest(
            identifier: "schedule-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
