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
    private lazy var keychain = KeychainManager()

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
        // Record that the Monitor is alive (used by parent to detect force-close).
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")

        // Check if the main app needs to be launched after an update.
        checkAppLaunchNeeded()

        // Reconciliation schedule (fires every 15 min) — verify enforcement matches snapshot.
        if activity.rawValue.hasPrefix("bigbrother.reconciliation") {
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
        if activity.rawValue.hasPrefix("bigbrother.reconciliation") { return }

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

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        // Only handle usage tracking events.
        guard activity.rawValue.hasPrefix("bigbrother.usagetracking"),
              event.rawValue.hasPrefix("usage.") else { return }

        // Parse the milestone minutes from the event name (e.g., "usage.120" -> 120).
        let minuteString = String(event.rawValue.dropFirst("usage.".count))
        guard let minutes = Int(minuteString) else { return }

        // Write the highest milestone reached to App Group so the heartbeat can relay it.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let today = Self.todayDateString()
        let dateKey = "screenTimeDate"
        let minutesKey = "screenTimeMinutes"

        let existingDate = defaults?.string(forKey: dateKey)
        let existingMinutes = defaults?.integer(forKey: minutesKey) ?? 0

        // Only update if today's date matches and the new milestone is higher.
        if existingDate == today {
            if minutes > existingMinutes {
                defaults?.set(minutes, forKey: minutesKey)
            }
        } else {
            // New day — reset.
            defaults?.set(today, forKey: dateKey)
            defaults?.set(minutes, forKey: minutesKey)
        }

        // Record Monitor activity timestamp.
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")

        #if DEBUG
        print("[BigBrother] Usage milestone: \(minutes) minutes")
        #endif
    }

    // MARK: - Schedule Profile Handling

    /// Free window started: check if today is a valid day, then unlock.
    private func handleFreeWindowStart(_ activity: DeviceActivityName) {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("freeWindowStart", forKey: "lastShieldChangeReason")

        // Manual mode override — skip schedule-driven changes.
        let freeStartDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let freeStartScheduleDriven = freeStartDefaults?.object(forKey: "scheduleDrivenMode") == nil
            || (freeStartDefaults?.bool(forKey: "scheduleDrivenMode") ?? true)
        if !freeStartScheduleDriven { return }

        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Exception date — schedule suspended, ensure device stays unlocked.
        if profile.isExceptionDate(Date()) {
            clearAllShieldStores()
            updateSharedState(mode: .unlocked)
            return
        }

        let windowID = extractWindowID(from: activity, prefix: scheduleProfilePrefix)
        guard let window = profile.freeWindows.first(where: { $0.id.uuidString == windowID }) else {
            return
        }

        // Check if the current date/time actually falls within this window.
        // Uses ActiveWindow.contains() which correctly handles cross-midnight
        // windows and yesterday's day-of-week for the morning portion.
        guard window.contains(Date()) else { return }

        // Block scheduled unlocks if the main app was force-closed.
        if shouldTreatMainAppAsUnavailable() {
            sendForceCloseNag()
            logEvent(.scheduleTriggered, details: "Free window blocked — app force-closed: \(activity.rawValue)")
            return
        }

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
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("freeWindowEnd", forKey: "lastShieldChangeReason")

        // Manual mode override — skip schedule-driven changes.
        let freeEndDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let freeEndScheduleDriven = freeEndDefaults?.object(forKey: "scheduleDrivenMode") == nil
            || (freeEndDefaults?.bool(forKey: "scheduleDrivenMode") ?? true)
        if !freeEndScheduleDriven { return }

        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Exception date — don't re-lock.
        if profile.isExceptionDate(Date()) { return }

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
        if mode != .unlocked {
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "lastNaturalRelockAt")
        }

        logEvent(.scheduleEnded, details: "Free window ended, mode \(mode.rawValue)")
        sendModeNotification(
            title: "Free Time Ended",
            body: mode == .unlocked ? "All apps are now accessible." : "Device locked — \(mode.displayName) mode active."
        )
    }

    // MARK: - Essential Window Handling

    /// Essential window started: apply essential-only mode if today matches.
    private func handleEssentialWindowStart(_ activity: DeviceActivityName) {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("essentialStart", forKey: "lastShieldChangeReason")

        // Manual mode override — skip schedule-driven changes.
        let essStartDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let essStartScheduleDriven = essStartDefaults?.object(forKey: "scheduleDrivenMode") == nil
            || (essStartDefaults?.bool(forKey: "scheduleDrivenMode") ?? true)
        if !essStartScheduleDriven { return }

        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Exception date — schedule suspended, ensure device stays unlocked.
        if profile.isExceptionDate(Date()) {
            clearAllShieldStores()
            updateSharedState(mode: .unlocked)
            return
        }

        let windowID = extractWindowID(from: activity, prefix: essentialWindowPrefix)
        guard let window = profile.essentialWindows.first(where: { $0.id.uuidString == windowID }) else {
            return
        }

        // Check if the current date/time actually falls within this window.
        guard window.contains(Date()) else { return }

        // Don't override if currently in a free window (free > essential).
        if profile.isInFreeWindow(at: Date()) { return }

        // Apply essential-only mode on ALL stores.
        // Never block tightening restrictions — essential mode should ALWAYS apply,
        // even if the main app is force-closed/suspended.
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: .essentialOnly, policy: policy)
        updateSharedState(mode: .essentialOnly)
        logEvent(.scheduleTriggered, details: "Essential window started: \(activity.rawValue)")
        sendModeNotification(title: "Essential Mode", body: "Only essential apps are available.")
    }

    /// Essential window ended: return to the profile's locked mode.
    private func handleEssentialWindowEnd(_ activity: DeviceActivityName) {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("essentialEnd", forKey: "lastShieldChangeReason")

        // Manual mode override — skip schedule-driven changes.
        let essEndDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let essEndScheduleDriven = essEndDefaults?.object(forKey: "scheduleDrivenMode") == nil
            || (essEndDefaults?.bool(forKey: "scheduleDrivenMode") ?? true)
        if !essEndScheduleDriven { return }

        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Exception date — don't re-lock.
        if profile.isExceptionDate(Date()) { return }

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
        if mode != .unlocked {
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "lastNaturalRelockAt")
        }
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
        // Record when the device naturally re-locked so force-close detection
        // gives extra grace time (the app may be suspended from a game).
        defaults?.set(Date().timeIntervalSince1970, forKey: "lastNaturalRelockAt")
        logEvent(.temporaryUnlockExpired, details: "Temp unlock expired, locked to \(mode.rawValue)")
        sendModeNotification(title: "Free Time Ended", body: "Device locked — \(mode.displayName) mode active.")
    }

    // MARK: - Lock Until Expiry

    /// Lock-until timer expired — return to schedule-driven mode.
    private func handleLockUntilExpired(_ activity: DeviceActivityName) {
        // Manual mode override — skip schedule-driven changes.
        let lockUntilDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let lockUntilScheduleDriven = lockUntilDefaults?.object(forKey: "scheduleDrivenMode") == nil
            || (lockUntilDefaults?.bool(forKey: "scheduleDrivenMode") ?? true)
        if !lockUntilScheduleDriven { return }

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
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("reconcile", forKey: "lastShieldChangeReason")
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

        // --- Check if parent overrode the schedule with a manual mode command ---

        let reconcileDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let isScheduleDriven = reconcileDefaults?.object(forKey: "scheduleDrivenMode") == nil
            || (reconcileDefaults?.bool(forKey: "scheduleDrivenMode") ?? true)

        // --- Schedule profile window check (free > essential > lockedMode) ---
        // Only apply schedule-driven modes if scheduleDrivenMode is true.
        // When a parent sends a manual setMode command, scheduleDrivenMode is set to false
        // and the manual mode should persist until the parent sends returnToSchedule.

        if isScheduleDriven, let profile = storage.readActiveScheduleProfile() {
            let scheduleMode = profile.resolvedMode(at: Date())
            if scheduleMode == .unlocked || scheduleMode == .essentialOnly {
                // Block scheduled UNLOCKS if the main app was force-closed (security).
                // But NEVER block essential mode — tightening restrictions is always safe
                // and should happen regardless of app state.
                if scheduleMode == .unlocked && shouldTreatMainAppAsUnavailable() {
                    sendForceCloseNag()
                    logEvent(.policyReconciled, details: "Reconciliation: unlock blocked — app dead, essential mode")
                    return
                } else if scheduleMode == .unlocked {
                    clearAllShieldStores()
                    updateSharedState(mode: .unlocked)
                    logEvent(.policyReconciled, details: "Reconciliation: in free window, stores cleared")
                    return
                } else {
                    let policy = storage.readPolicySnapshot()?.effectivePolicy
                    applyShieldingToAllStores(mode: .essentialOnly, policy: policy)
                    updateSharedState(mode: .essentialOnly)
                    logEvent(.policyReconciled, details: "Reconciliation: in essential window, essential mode applied")
                    return
                }
            }
            // lockedMode falls through to default enforcement below
        }

        // --- Force-close check (regardless of schedule profile) ---

        if shouldTreatMainAppAsUnavailable() {
            sendForceCloseNag()
            logEvent(.policyReconciled, details: "Reconciliation: app dead — essential mode until BB reopened")
            return
        }

        // --- Final temp unlock safety check ---
        // If a temp unlock is active in storage, always clear shields regardless of
        // what the snapshot or shared state says. This catches cases where the snapshot
        // was overwritten by a non-unlock command but the unlock is still active.
        if let tempState = storage.readTemporaryUnlockState(), tempState.expiresAt > Date() {
            clearAllShieldStores()
            updateSharedState(mode: .unlocked, isTemporaryUnlock: true, temporaryUnlockExpiresAt: tempState.expiresAt)
            logEvent(.policyReconciled, details: "Reconciliation: temp unlock active, shields cleared")
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
        updateSharedState(mode: resolvedMode)
        logEvent(.policyReconciled, details: "Reconciliation check from extension")
    }

    // MARK: - All-Store Shield Management

    /// Clear shield properties on ALL named stores + default store.
    /// ManagedSettings merges across stores with OR logic — if any store blocks, it's blocked.
    private func clearAllShieldStores() {
        // Don't allow unlock if permissions are missing — stay in essential mode.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if defaults?.bool(forKey: "allPermissionsGranted") == false {
            // Apply essential-only shielding instead of clearing
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            applyShieldingToAllStores(mode: .essentialOnly, policy: policy)
            return
        }

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
        // Force essential mode if permissions are missing.
        let effectiveMode: LockMode
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if defaults?.bool(forKey: "allPermissionsGranted") == false && mode != .essentialOnly {
            effectiveMode = .essentialOnly
        } else {
            effectiveMode = mode
        }

        // Always clear tempUnlock store shields — schedule transitions supersede temp unlocks.
        let tempUnlockStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreTempUnlock))
        tempUnlockStore.shield.applications = nil
        tempUnlockStore.shield.applicationCategories = nil
        tempUnlockStore.shield.webDomainCategories = nil
        tempUnlockStore.shield.webDomains = nil

        switch effectiveMode {
        case .unlocked:
            clearAllShieldStores()

        case .dailyMode, .essentialOnly, .lockedDown:
            let allowExemptions = effectiveMode == .dailyMode
            let allowedTokens = allowExemptions ? collectAllowedTokens() : []
            let pickerTokens = loadPickerTokens()

            // Check if web blocking is enabled in device restrictions,
            // respecting parent-configured allowed web domains.
            let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            let shouldBlockWeb = restrictions.denyWebWhenLocked

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
                    if shouldBlockWeb {
                        s.shield.webDomainCategories = .all()
                        // Note: per-domain exceptions require WebDomainTokens (picker-selected),
                        // not WebDomain strings. Domain allowlist is enforced at the VPN/DNS layer.
                    } else {
                        s.shield.webDomainCategories = nil
                    }
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
                    if shouldBlockWeb {
                        s.shield.webDomainCategories = .all()
                        // Note: per-domain exceptions require WebDomainTokens (picker-selected),
                        // not WebDomain strings. Domain allowlist is enforced at the VPN/DNS layer.
                    } else {
                        s.shield.webDomainCategories = nil
                    }
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
        // Prefer the multi-store path when possible — the legacy single-store path
        // doesn't handle essential mode correctly. Resolve schedule profile mode first.
        if let profile = storage.readActiveScheduleProfile() {
            let resolvedMode = profile.resolvedMode(at: Date())
            applyShieldingToAllStores(mode: resolvedMode, policy: policy)
            return
        }

        switch mode {
        case .unlocked:
            store.clearAllSettings()

        case .dailyMode, .essentialOnly, .lockedDown:
            let allowExemptions = mode == .dailyMode
            let allowedTokens = allowExemptions ? collectAllowedTokens() : []
            if allowedTokens.isEmpty {
                store.shield.applicationCategories = .all()
            } else {
                store.shield.applicationCategories = .all(except: allowedTokens)
            }
            let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            if restrictions.denyWebWhenLocked {
                store.shield.webDomainCategories = .all()
                // Note: per-domain exceptions require WebDomainTokens (picker-selected).
                // Domain allowlist is enforced at the VPN/DNS layer.
            } else {
                store.shield.webDomainCategories = nil
            }
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
        let requestToken = defaults?.string(forKey: "extensionHeartbeatRequestToken")
        let ackToken = defaults?.string(forKey: "extensionHeartbeatAcknowledgedToken")

        // Keep a single unresolved liveness request outstanding until the main
        // app positively acknowledges it. Rewriting the timestamp every
        // reconciliation cycle prevents the request from ever going stale.
        if let requestToken, !requestToken.isEmpty, ackToken != requestToken {
            return
        }

        defaults?.set(UUID().uuidString, forKey: "extensionHeartbeatRequestToken")
        defaults?.set(Date().timeIntervalSince1970, forKey: "extensionHeartbeatRequestedAt")
    }

    /// Update ExtensionSharedState so the heartbeat reports the correct mode
    /// after schedule transitions (the Monitor doesn't write full PolicySnapshots).
    private func updateSharedState(mode: LockMode, isTemporaryUnlock: Bool = false, temporaryUnlockExpiresAt: Date? = nil) {
        let snapshot = storage.readPolicySnapshot()
        let authHealth = storage.readAuthorizationHealth()
        let shieldConfig = storage.readShieldConfiguration()
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

    /// Detect if the main app was force-closed by the user (not just suspended by iOS).
    ///
    /// Two-signal detection to distinguish force-close from iOS suspension:
    /// 1. extensionHeartbeatRequestedAt flag is stale (>16 min) — means the main app
    ///    never cleared it, so the app process is not running
    /// 2. Heartbeat age exceeds threshold (20 min locked / 45 min unlocked)
    ///
    /// If BOTH signals are present, the app is force-closed.
    /// If only heartbeat is stale but the flag was cleared, the app is alive but
    /// having CloudKit issues — do NOT treat as force-close.
    private func isAppForceClosed() -> Bool {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)

        // Signal 0: Build mismatch — the app was updated but hasn't launched yet.
        // After an update, the ack token still matches the request token (from the
        // old binary), so the normal flag-based detection fails. Treat this as
        // equivalent to force-close once heartbeats are stale.
        let mainAppBuild = defaults?.integer(forKey: "mainAppLastLaunchedBuild") ?? 0
        let buildMismatch = mainAppBuild > 0 && mainAppBuild < AppConstants.appBuildNumber

        // Signal 1: Check if the extension heartbeat request flag is stale.
        // The main app must explicitly acknowledge the current request token.
        // If the outstanding request ages past one reconciliation cycle, the
        // process is no longer servicing extension liveness checks.
        let flagIsStale: Bool
        let requestToken = defaults?.string(forKey: "extensionHeartbeatRequestToken")
        let ackToken = defaults?.string(forKey: "extensionHeartbeatAcknowledgedToken")
        let requestedAt = defaults?.double(forKey: "extensionHeartbeatRequestedAt") ?? 0
        if let requestToken, !requestToken.isEmpty, requestToken != ackToken, requestedAt > 0 {
            let flagAge = Date().timeIntervalSince1970 - requestedAt
            flagIsStale = flagAge > AppConstants.forceCloseFlagStaleness
        } else {
            // No unresolved request — can't confirm force-close via this signal.
            flagIsStale = false
        }

        // Signal 2: Check heartbeat staleness.
        let lastHeartbeatAt = defaults?.double(forKey: "lastHeartbeatSentAt") ?? 0
        guard lastHeartbeatAt > 0 else {
            // No heartbeat ever sent — app may not have finished initial setup.
            return false
        }
        let heartbeatAge = Date().timeIntervalSince1970 - lastHeartbeatAt

        let currentMode = storage.readExtensionSharedState()?.currentMode ?? .dailyMode
        let threshold = currentMode == .unlocked
            ? AppConstants.forceCloseThresholdUnlocked
            : AppConstants.forceCloseThresholdLocked

        let heartbeatIsStale = heartbeatAge > threshold

        // Build mismatch + stale heartbeat = app updated but never re-launched.
        // Flag + stale heartbeat = app was force-closed or killed.
        // Either combination is sufficient for force-close detection.
        return heartbeatIsStale && (flagIsStale || buildMismatch)
    }

    /// Once fail-safe mode is active, keep it latched until the main app
    /// explicitly clears it after proving liveness.
    /// Exception: during a parent-sanctioned temporary unlock, the app being
    /// killed is expected (games use memory) — don't lock the device.
    private func shouldTreatMainAppAsUnavailable() -> Bool {
        // During an active temp unlock, the kid is supposed to be using the device.
        // iOS may kill the main app due to memory pressure from games — that's fine.
        if let tempState = storage.readTemporaryUnlockState(), tempState.expiresAt > Date() {
            return false
        }
        // Also check timed unlock (penalty-offset unlocks)
        if let timedInfo = storage.readTimedUnlockInfo() {
            let now = Date()
            if now >= timedInfo.unlockAt && now < timedInfo.lockAt {
                return false  // In the free phase of a timed unlock
            }
        }

        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if defaults?.bool(forKey: "forceCloseWebBlocked") == true {
            // But clear the latch if a temp unlock started AFTER the latch was set
            if let tempState = storage.readTemporaryUnlockState(), tempState.expiresAt > Date() {
                defaults?.removeObject(forKey: "forceCloseWebBlocked")
                return false
            }
            return true
        }
        return isAppForceClosed()
    }

    /// Apply essential-only mode and nag the kid to open Big Brother.
    /// Essential mode blocks most apps but allows phone, messages, and other
    /// essentials — less aggressive than blocking everything, but still enforced.
    /// When the main app launches, it clears the forceCloseWebBlocked flag and
    /// re-applies normal enforcement with proper exemptions via performRestoration().
    private func sendForceCloseNag() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.set("appClosed", forKey: "lastShieldChangeReason")

        // Apply essential-only mode on all stores — no exemptions.
        if defaults?.bool(forKey: "forceCloseWebBlocked") != true {
            defaults?.set(true, forKey: "forceCloseWebBlocked")
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            applyShieldingToAllStores(mode: .essentialOnly, policy: policy)
        }
        updateSharedState(mode: .essentialOnly)

        // Throttle notification: don't nag more than once per 15 minutes.
        // Every reconciliation cycle re-triggers this, so throttle prevents spam.
        let lastNagAt = defaults?.double(forKey: "forceCloseLastNagAt") ?? 0
        let nagAge = Date().timeIntervalSince1970 - lastNagAt
        guard nagAge > 900 else { return }  // 15 minutes
        defaults?.set(Date().timeIntervalSince1970, forKey: "forceCloseLastNagAt")

        let content = UNMutableNotificationContent()
        content.title = "Essential Mode"
        content.body = "Open Big Brother to restore your full app access."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "force-close-nag",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Check if the main app has been launched since the last update.
    /// If not, apply enforcement immediately and notify the kid to open the app.
    ///
    /// After an app update the main app doesn't auto-launch, and DeviceActivity
    /// schedule registrations may be lost. Without this, the device can stay
    /// unlocked indefinitely until someone manually opens the app.
    private func checkAppLaunchNeeded() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let mainAppBuild = defaults?.integer(forKey: "mainAppLastLaunchedBuild") ?? 0
        let extensionBuild = AppConstants.appBuildNumber

        // Main app has launched with this build — nothing to do.
        guard mainAppBuild < extensionBuild else { return }

        // Don't lock during an active temp unlock — the kid is supposed to be using the device.
        if let tempState = storage.readTemporaryUnlockState(), tempState.expiresAt > Date() {
            logEvent(.policyReconciled, details: "Post-update: skipping essential mode — temp unlock active")
            return
        }

        // Apply essential-only mode immediately — the app isn't running so we
        // can't trust the full enforcement pipeline.
        defaults?.set("appClosed", forKey: "lastShieldChangeReason")
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: .essentialOnly, policy: policy)
        updateSharedState(mode: .essentialOnly)
        logEvent(.policyReconciled, details: "Post-update essential mode (main app build \(mainAppBuild) < extension build \(extensionBuild))")

        // Re-register reconciliation schedule — DeviceActivity registrations
        // may have been lost during the update. This ensures the Monitor keeps
        // firing even if the main app is never opened.
        reregisterReconciliationSchedule()

        // Only notify once per build.
        let lastNotifiedBuild = defaults?.integer(forKey: "extensionLaunchNotifiedBuild") ?? 0
        guard lastNotifiedBuild < extensionBuild else { return }
        defaults?.set(extensionBuild, forKey: "extensionLaunchNotifiedBuild")

        let content = UNMutableNotificationContent()
        content.title = "Big Brother Updated"
        content.body = "Tap to finish setup and enable full monitoring."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "app-launch-needed",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Re-register the 15-minute reconciliation schedule from the Monitor extension.
    /// Called after an app update to ensure the Monitor keeps firing.
    private func reregisterReconciliationSchedule() {
        let center = DeviceActivityCenter()
        let quarters: [(name: String, minute: Int)] = [
            ("bigbrother.reconciliation", 0),
            ("bigbrother.reconciliation.q2", 15),
            ("bigbrother.reconciliation.q3", 30),
            ("bigbrother.reconciliation.q4", 45),
        ]
        for q in quarters {
            let activityName = DeviceActivityName(rawValue: q.name)
            let start = DateComponents(minute: q.minute)
            let end = DateComponents(minute: q.minute + 1)
            let schedule = DeviceActivitySchedule(
                intervalStart: start,
                intervalEnd: end,
                repeats: true
            )
            try? center.startMonitoring(activityName, during: schedule)
        }
    }

    private static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func logEvent(_ type: EventType, details: String?) {
        // Read enrollment state to get deviceID and familyID.
        // If unavailable, skip logging (device may not be enrolled).
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
