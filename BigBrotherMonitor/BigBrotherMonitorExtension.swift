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
    /// Prefix used by ScheduleRegistrar for essential-window activities.
    private let essentialWindowPrefix = "bigbrother.essentialwindow."

    /// Extract the window UUID from an activity name, stripping cross-midnight suffixes (.pm/.am).
    private func extractWindowID(from activity: DeviceActivityName, prefix: String) -> String {
        var windowID = String(activity.rawValue.dropFirst(prefix.count))
        if windowID.hasSuffix(".pm") { windowID = String(windowID.dropLast(3)) }
        if windowID.hasSuffix(".am") { windowID = String(windowID.dropLast(3)) }
        return windowID
    }
    /// Prefix used for penalty-offset timed unlocks.
    private let timedUnlockPrefix = "bigbrother.timedunlock."
    /// Prefix used for temporary unlock expiry (auto-relock).
    private let tempUnlockPrefix = "bigbrother.tempunlock."
    /// Prefix used for timed lock (lockUntil) — auto-return to schedule.
    private let lockUntilPrefix = "bigbrother.lockuntil."

    override func intervalDidStart(for activity: DeviceActivityName) {
        // Check if the main app needs to be launched after an update.
        checkAppLaunchNeeded()

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

        // Essential window — apply essential-only mode if today matches.
        if activity.rawValue.hasPrefix(essentialWindowPrefix) {
            handleEssentialWindowStart(activity)
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
        updateSharedState(mode: mode)
        logEvent(.scheduleTriggered, details: "Schedule started: \(activity.rawValue)")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        if activity.rawValue == "bigbrother.reconciliation" { return }

        // Schedule profile free window ended — re-lock.
        if activity.rawValue.hasPrefix(scheduleProfilePrefix) {
            handleFreeWindowEnd(activity)
            return
        }

        // Essential window ended — return to locked mode.
        if activity.rawValue.hasPrefix(essentialWindowPrefix) {
            handleEssentialWindowEnd(activity)
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

        // Legacy / other schedule — resolve schedule mode and apply.
        if let profile = storage.readActiveScheduleProfile() {
            let mode = profile.resolvedMode(at: Date())
            if mode == .unlocked {
                clearAllShieldStores()
            } else {
                let policy = storage.readPolicySnapshot()?.effectivePolicy
                applyShieldingToAllStores(mode: mode, policy: policy)
            }
            updateSharedState(mode: mode)
        } else {
            // No profile — original behavior: just clear the schedule store.
            store.clearAllSettings()
        }
        logEvent(.scheduleEnded, details: "Schedule ended: \(activity.rawValue)")
    }

    // MARK: - Schedule Profile Handling

    /// Free window started: check if today is a valid day, then unlock.
    private func handleFreeWindowStart(_ activity: DeviceActivityName) {
        guard let profile = storage.readActiveScheduleProfile() else { return }

        let windowID = extractWindowID(from: activity, prefix: scheduleProfilePrefix)
        guard let window = profile.freeWindows.first(where: { $0.id.uuidString == windowID }) else {
            return
        }

        // Check if the current date/time actually falls within this window.
        // Uses ActiveWindow.contains() which correctly handles cross-midnight
        // windows and yesterday's day-of-week for the morning portion.
        guard window.contains(Date()) else { return }

        // Unlock: clear ALL shield stores (base + schedule + default).
        // ManagedSettings merges across stores with OR logic — clearing only
        // the schedule store leaves the base store shields active.
        clearAllShieldStores()

        // Update shared state so the heartbeat reports .unlocked.
        updateSharedState(mode: .unlocked)

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

        // Resolve the current mode — an essential window may be active.
        let mode = profile.resolvedMode(at: Date())
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        if mode == .unlocked {
            clearAllShieldStores()
        } else {
            applyShieldingToAllStores(mode: mode, policy: policy)
        }
        updateSharedState(mode: mode)

        logEvent(.scheduleEnded, details: "Free window ended, mode \(mode.rawValue)")
        sendModeNotification(
            title: "Free Time Ended",
            body: mode == .unlocked ? "All apps are now accessible." : "Device locked — \(mode.displayName) mode active."
        )
    }

    // MARK: - Essential Window Handling

    /// Essential window started: apply essential-only mode if today matches.
    private func handleEssentialWindowStart(_ activity: DeviceActivityName) {
        guard let profile = storage.readActiveScheduleProfile() else { return }

        let windowID = extractWindowID(from: activity, prefix: essentialWindowPrefix)
        guard let window = profile.essentialWindows.first(where: { $0.id.uuidString == windowID }) else {
            return
        }

        // Check if the current date/time actually falls within this window.
        guard window.contains(Date()) else { return }

        // Don't override if currently in a free window (free > essential).
        if profile.isInFreeWindow(at: Date()) { return }

        // Apply essential-only mode on ALL stores.
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: .essentialOnly, policy: policy)
        updateSharedState(mode: .essentialOnly)
        logEvent(.scheduleTriggered, details: "Essential window started: \(activity.rawValue)")
        sendModeNotification(title: "Essential Mode", body: "Only essential apps are available.")
    }

    /// Essential window ended: return to the profile's locked mode.
    private func handleEssentialWindowEnd(_ activity: DeviceActivityName) {
        guard let profile = storage.readActiveScheduleProfile() else { return }

        // If in a free window, don't re-lock.
        if profile.isInFreeWindow(at: Date()) { return }
        // If in another essential window, stay essential.
        if profile.isInEssentialWindow(at: Date()) { return }

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: profile.lockedMode, policy: policy)
        updateSharedState(mode: profile.lockedMode)
        logEvent(.scheduleEnded, details: "Essential window ended, locked to \(profile.lockedMode.rawValue)")
        sendModeNotification(
            title: "Essential Mode Ended",
            body: "Device returned to \(profile.lockedMode.displayName) mode."
        )
    }

    // MARK: - Timed Unlock (Penalty Offset)

    /// Penalty served — unlock the device.
    private func handleTimedUnlockStart(_ activity: DeviceActivityName) {
        clearAllShieldStores()
        updateSharedState(mode: .unlocked)
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
        updateSharedState(mode: mode)
        try? storage.clearTimedUnlockInfo()
        logEvent(.scheduleEnded, details: "Timed unlock ended, mode \(mode.rawValue)")
        sendModeNotification(title: "Free Time Ended", body: mode == .unlocked ? "Free window — all apps accessible." : "Device locked — \(mode.displayName) mode active.")
    }

    // MARK: - Temporary Unlock Expiry

    /// Temporary unlock timer expired — re-lock the device using the previous mode.
    /// If a manual mode was set (scheduleDrivenMode=false), revert to previousMode.
    /// If schedule-driven, use the schedule's current resolved mode.
    private func handleTempUnlockExpired(_ activity: DeviceActivityName) {
        let unlockState = storage.readTemporaryUnlockState()
        let previousMode = unlockState?.previousMode ?? .dailyMode

        let mode: LockMode
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let isScheduleDriven = defaults?.object(forKey: "scheduleDrivenMode") == nil
            || (defaults?.bool(forKey: "scheduleDrivenMode") ?? true)

        if isScheduleDriven, let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
        } else {
            mode = previousMode
        }

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: mode, policy: policy)
        updateSharedState(mode: mode)
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
        updateSharedState(mode: mode)
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
                updateSharedState(mode: .unlocked, isTemporaryUnlock: true, temporaryUnlockExpiresAt: expires)
                return
            }

            // If temporary unlock has expired, re-lock using the previous mode.
            if extState.isTemporaryUnlock,
               let expires = extState.temporaryUnlockExpiresAt, expires <= Date() {
                let unlockState = storage.readTemporaryUnlockState()
                let previousMode = unlockState?.previousMode ?? .dailyMode
                let mode: LockMode
                let reconcileDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
                let reconcileScheduleDriven = reconcileDefaults?.object(forKey: "scheduleDrivenMode") == nil
                    || (reconcileDefaults?.bool(forKey: "scheduleDrivenMode") ?? true)
                if reconcileScheduleDriven, let profile = storage.readActiveScheduleProfile() {
                    mode = profile.resolvedMode(at: Date())
                } else {
                    mode = previousMode
                }
                let policy = storage.readPolicySnapshot()?.effectivePolicy
                applyShieldingToAllStores(mode: mode, policy: policy)
                updateSharedState(mode: mode)
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
                updateSharedState(mode: .unlocked, isTemporaryUnlock: true, temporaryUnlockExpiresAt: unlockState.expiresAt)
                return
            } else {
                // Expired temp unlock the monitor never caught — re-lock now.
                let mode: LockMode
                let staleDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
                let staleScheduleDriven = staleDefaults?.object(forKey: "scheduleDrivenMode") == nil
                    || (staleDefaults?.bool(forKey: "scheduleDrivenMode") ?? true)
                if staleScheduleDriven, let profile = storage.readActiveScheduleProfile() {
                    mode = profile.resolvedMode(at: Date())
                } else {
                    mode = unlockState.previousMode
                }
                let policy = storage.readPolicySnapshot()?.effectivePolicy
                applyShieldingToAllStores(mode: mode, policy: policy)
                updateSharedState(mode: mode)
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
                updateSharedState(mode: penaltyMode)
                return
            } else if now >= timedInfo.unlockAt && now < timedInfo.lockAt {
                // In the free phase — device should be unlocked.
                clearAllShieldStores()
                updateSharedState(mode: .unlocked)
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
                updateSharedState(mode: mode)
                try? storage.clearTimedUnlockInfo()
                logEvent(.policyReconciled, details: "Reconciliation: stale timed unlock cleaned up, mode \(mode.rawValue)")
                return
            }
        }

        // --- Schedule profile window check (free > essential > lockedMode) ---

        if let profile = storage.readActiveScheduleProfile() {
            let scheduleMode = profile.resolvedMode(at: Date())
            if scheduleMode == .unlocked {
                clearAllShieldStores()
                updateSharedState(mode: .unlocked)
                logEvent(.policyReconciled, details: "Reconciliation: in free window, stores cleared")
                return
            } else if scheduleMode == .essentialOnly {
                let policy = storage.readPolicySnapshot()?.effectivePolicy
                applyShieldingToAllStores(mode: .essentialOnly, policy: policy)
                updateSharedState(mode: .essentialOnly)
                logEvent(.policyReconciled, details: "Reconciliation: in essential window, essential mode applied")
                return
            }
            // lockedMode falls through to default enforcement below
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
        updateSharedState(mode: resolvedMode)
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
        // Always clear tempUnlock store shields — schedule transitions supersede temp unlocks.
        let tempUnlockStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreTempUnlock))
        tempUnlockStore.shield.applications = nil
        tempUnlockStore.shield.applicationCategories = nil
        tempUnlockStore.shield.webDomainCategories = nil
        tempUnlockStore.shield.webDomains = nil

        switch mode {
        case .unlocked:
            clearAllShieldStores()

        case .dailyMode, .essentialOnly:
            let allowExemptions = mode == .dailyMode
            let allowedTokens = allowExemptions ? collectAllowedTokens() : []
            let pickerTokens = loadPickerTokens()

            // Check if web blocking is enabled in device restrictions,
            // respecting parent-configured allowed web domains.
            let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            let hasAllowedWebDomains: Bool = {
                if let data = storage.readRawData(forKey: StorageKeys.allowedWebDomains),
                   let domains = try? JSONDecoder().decode([String].self, from: data),
                   !domains.isEmpty {
                    return true
                }
                return false
            }()
            let blockAllWeb = restrictions.denyWebWhenLocked && !hasAllowedWebDomains

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
                    s.shield.webDomainCategories = blockAllWeb ? .all() : nil
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
                    s.shield.webDomainCategories = blockAllWeb ? .all() : nil
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
            let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            let legacyHasAllowedWebDomains: Bool = {
                if let data = storage.readRawData(forKey: StorageKeys.allowedWebDomains),
                   let domains = try? JSONDecoder().decode([String].self, from: data),
                   !domains.isEmpty {
                    return true
                }
                return false
            }()
            store.shield.webDomainCategories = (restrictions.denyWebWhenLocked && !legacyHasAllowedWebDomains) ? .all() : nil
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

    /// Request an immediate heartbeat from the main app by writing a flag to App Group.
    /// The main app checks this every 30 seconds and sends a forced heartbeat if set.
    private func requestHeartbeat() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.set(Date().timeIntervalSince1970, forKey: "extensionHeartbeatRequestedAt")
    }

    /// Update ExtensionSharedState so the heartbeat reports the correct mode
    /// after schedule transitions (the Monitor doesn't write full PolicySnapshots).
    private func updateSharedState(mode: LockMode, isTemporaryUnlock: Bool = false, temporaryUnlockExpiresAt: Date? = nil) {
        let snapshot = storage.readPolicySnapshot()
        let authHealth = storage.readAuthorizationHealth()
        let shieldConfig = try? storage.readShieldConfiguration()
        let state = ExtensionSharedState(
            currentMode: mode,
            isTemporaryUnlock: isTemporaryUnlock,
            temporaryUnlockExpiresAt: temporaryUnlockExpiresAt,
            authorizationAvailable: authHealth?.isAuthorized ?? true,
            enforcementDegraded: !(authHealth?.isAuthorized ?? true) && mode != .unlocked,
            shieldConfig: shieldConfig ?? ShieldConfig(),
            policyVersion: snapshot?.effectivePolicy.policyVersion ?? 0
        )
        try? storage.writeExtensionSharedState(state)
        requestHeartbeat()
    }

    /// Check if the main app has been launched since the last update.
    /// If not, post a one-time notification to prompt the kid to open it.
    private func checkAppLaunchNeeded() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let mainAppBuild = defaults?.integer(forKey: "mainAppLastLaunchedBuild") ?? 0
        let extensionBuild = AppConstants.appBuildNumber

        // Main app has launched with this build — nothing to do.
        guard mainAppBuild < extensionBuild else { return }

        // Only notify once per build.
        let lastNotifiedBuild = defaults?.integer(forKey: "extensionLaunchNotifiedBuild") ?? 0
        guard lastNotifiedBuild < extensionBuild else { return }
        defaults?.set(extensionBuild, forKey: "extensionLaunchNotifiedBuild")

        let content = UNMutableNotificationContent()
        content.title = "Big Brother Updated"
        content.body = "Tap to finish setup and enable full monitoring."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "app-launch-needed",
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
