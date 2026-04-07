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
    /// Fresh ManagedSettingsStore instances on every access.
    /// Cached instances risk stale XPC connections — the same bug that broke enforcement in the main app.
    private var store: ManagedSettingsStore {
        ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreSchedule))
    }
    private var baseStore: ManagedSettingsStore {
        ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreBase))
    }
    private lazy var keychain = KeychainManager()

    /// Prefix used by ScheduleRegistrar for unlocked-window activities.
    private let scheduleProfilePrefix = "bigbrother.scheduleprofile."
    /// Prefix used by ScheduleRegistrar for locked-window activities.
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
        let monitorDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        monitorDefaults?.set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")

        // Check if the main app needs to be launched after an update.
        checkAppLaunchNeeded()

        // Tunnel signals "enforcement dirty" when it handles grantExtraTime/blockAppForToday.
        // The tunnel can't write ManagedSettings — we must do it here on the next callback.
        checkEnforcementRefreshSignal()

        // Reconciliation quarter window started — verify enforcement matches snapshot.
        if activity.rawValue.hasPrefix("bigbrother.reconciliation.q") {
            NSLog("[Monitor] intervalDidStart FIRED for \(activity.rawValue)")
            reconcile()
            return
        }

        // Enforcement refresh trigger — main app processed a command and needs the Monitor
        // to apply ManagedSettings from its privileged context (background writes from
        // the main app are unreliable).
        if activity.rawValue.hasPrefix("bigbrother.enforcementRefresh") {
            let resolution = ModeStackResolver.resolve(storage: storage)
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            if resolution.mode == .unlocked {
                clearAllShieldStores()
            } else {
                applyShieldingToAllStores(mode: resolution.mode, policy: policy)
            }
            updateSharedState(mode: resolution.mode)
            logEvent(.policyReconciled, details: "Monitor enforcement refresh: \(resolution.mode.rawValue) (\(resolution.reason))")
            return
        }

        // Per-app time limit daily reset — new day, clear exhausted status.
        if activity.rawValue.hasPrefix("bigbrother.timelimit.") {
            handleTimeLimitDayReset(activity: activity)
            return
        }

        // Schedule profile unlocked window — unlock if today matches.
        if activity.rawValue.hasPrefix(scheduleProfilePrefix) {
            handleUnlockedWindowStart(activity)
            return
        }

        // Locked window — apply essential-only mode if today matches.
        if activity.rawValue.hasPrefix(essentialWindowPrefix) {
            handleLockedWindowStart(activity)
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

        // Legacy / other schedule activity — use ModeStackResolver for ground truth.
        let resolution = ModeStackResolver.resolve(storage: storage)
        let mode = resolution.mode
        let policy = storage.readPolicySnapshot()?.effectivePolicy

        applyShielding(mode: mode, policy: policy)
        updateSharedState(mode: mode)
        logEvent(.scheduleTriggered, details: "Schedule started: \(activity.rawValue)")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        checkEnforcementRefreshSignal()

        // Reconciliation quarter ended — triggered by natural end OR by stopMonitoring from tunnel/main app.
        // This is the ON-DEMAND enforcement trigger. Apply shields from our privileged context.
        if activity.rawValue.hasPrefix("bigbrother.reconciliation.q") {
            NSLog("[Monitor] intervalDidEnd FIRED for \(activity.rawValue)")
            let resolution = ModeStackResolver.resolve(storage: storage)
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            NSLog("[Monitor] On-demand enforcement: mode=\(resolution.mode.rawValue) reason=\(resolution.reason)")
            if resolution.mode == .unlocked {
                clearAllShieldStores()
                NSLog("[Monitor] Cleared all shield stores (unlocked)")
            } else {
                applyShieldingToAllStores(mode: resolution.mode, policy: policy)
                NSLog("[Monitor] Applied shields for \(resolution.mode.rawValue)")
            }
            updateSharedState(mode: resolution.mode)
            logEvent(.policyReconciled, details: "On-demand enforcement: \(resolution.mode.rawValue) (\(resolution.reason))")
            // Signal tunnel to send a confirmation heartbeat — Monitor can't make network calls.
            // Parent sees the confirmed mode within 30s (tunnel's next liveness tick).
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "monitorNeedsHeartbeat")
            reregisterReconciliationQuarter(activity)
            return
        }

        // Schedule profile unlocked window ended — re-lock.
        if activity.rawValue.hasPrefix(scheduleProfilePrefix) {
            handleUnlockedWindowEnd(activity)
            return
        }

        // Locked window ended — return to locked mode.
        if activity.rawValue.hasPrefix(essentialWindowPrefix) {
            handleLockedWindowEnd(activity)
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
            // No profile — clear the schedule store and default to restricted.
            store.clearAllSettings()
            updateSharedState(mode: .restricted)
        }
        logEvent(.scheduleEnded, details: "Schedule ended: \(activity.rawValue)")
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        checkEnforcementRefreshSignal()
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")

        // Reconciliation quarter warning — 3 hours before end = mid-quarter enforcement check.
        if activity.rawValue.hasPrefix("bigbrother.reconciliation.q") {
            NSLog("[Monitor] intervalWillEndWarning for \(activity.rawValue) — reconciling")
            reconcile()
            return
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        checkEnforcementRefreshSignal()
        // Handle per-app time limit events.
        if activity.rawValue.hasPrefix("bigbrother.timelimit.") {
            if event.rawValue.hasPrefix("timelimit.exhausted") {
                handleTimeLimitExhausted(activity: activity)
                return
            }
            if event.rawValue.hasPrefix("timelimit.usage.") {
                handleTimeLimitUsageMilestone(event: event, activity: activity)
                return
            }
        }

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
        let monitorDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        monitorDefaults?.set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")

        // Piggyback enforcement reconciliation on usage tracking callbacks.
        // These fire every ~5 minutes of active device use — exactly when enforcement matters most.
        // Throttle to once per 60 seconds to avoid excessive work.
        let lastReconcile = monitorDefaults?.double(forKey: "monitorLastReconcileAt") ?? 0
        let now = Date().timeIntervalSince1970
        if now - lastReconcile > 60 {
            monitorDefaults?.set(now, forKey: "monitorLastReconcileAt")
            reconcile()
        }
    }

    // MARK: - Schedule Profile Handling

    /// Unlocked window started: check if today is a valid day, then unlock.
    private func handleUnlockedWindowStart(_ activity: DeviceActivityName) {
        // Clear expired temporary unlock state to prevent stale restorer re-unlock on next app launch.
        if let tempState = storage.readTemporaryUnlockState(),
           tempState.expiresAt <= Date() {
            try? storage.clearTemporaryUnlockState()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Cleared expired temporary unlock state during unlocked window start"
            ))
        }

        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("freeWindowStart", forKey: "lastShieldChangeReason")

        // Temporary unlock or timed unlock active — don't override with schedule.
        if hasActiveTemporaryMode() { return }

        // Manual mode override — skip schedule-driven changes.
        if !AppConstants.isScheduleDriven() { return }

        // lockedDown is parent-enforced maximum restriction — schedule must never override it.
        if storage.readPolicySnapshot()?.effectivePolicy.resolvedMode == .lockedDown { return }

        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Exception date — schedule suspended, ensure device stays unlocked.
        if profile.isExceptionDate(Date()) {
            clearAllShieldStores()
            updateSharedState(mode: .unlocked)
            return
        }

        let windowID = extractWindowID(from: activity, prefix: scheduleProfilePrefix)
        guard let window = profile.unlockedWindows.first(where: { $0.id.uuidString == windowID }) else {
            return
        }

        // Check if the current date/time actually falls within this window.
        // Uses ActiveWindow.contains() which correctly handles cross-midnight
        // windows and yesterday's day-of-week for the morning portion.
        // Allow 30-second tolerance for late DeviceActivity callbacks.
        guard window.contains(Date()) || window.contains(Date().addingTimeInterval(-30)) else { return }

        // Block scheduled unlocks if the main app was force-closed.
        // This is the ONE case where we nag — the kid's free time is being blocked.
        if shouldTreatMainAppAsUnavailable() {
            sendForceCloseEnforcement(nagNotification: true)
            logEvent(.scheduleTriggered, details: "Unlocked window blocked — app force-closed: \(activity.rawValue)")
            return
        }

        // Write corrected PolicySnapshot FIRST so if extension is killed mid-operation,
        // the main app sees the intended state and won't undo it on foreground.
        writeCorrectedSnapshot(mode: .unlocked, trigger: "Monitor: free window started (\(activity.rawValue))")
        updateSharedState(mode: .unlocked)

        // Set wide-open shields instead of clearing — avoids .child auth re-validation race.
        applyWideOpenShields()

        logEvent(.scheduleTriggered, details: "Unlocked window started: \(activity.rawValue)")
        sendModeNotification(title: "Free Time Started", body: "All apps are now accessible.")
    }

    /// Unlocked window ended: re-apply the profile's locked mode.
    private func handleUnlockedWindowEnd(_ activity: DeviceActivityName) {
        // Don't override an active temporary unlock — parent command takes precedence.
        if let tempState = storage.readTemporaryUnlockState(),
           tempState.expiresAt > Date() {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Skipping window-end lock — temporary unlock active until \(tempState.expiresAt)"
            ))
            return
        }

        // Don't override an active timed unlock free phase.
        if let timedInfo = storage.readTimedUnlockInfo() {
            let now = Date()
            if now >= timedInfo.unlockAt && now < timedInfo.lockAt {
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Skipping window-end lock — timed unlock free phase active until \(timedInfo.lockAt)"
                ))
                return
            }
        }

        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("freeWindowEnd", forKey: "lastShieldChangeReason")

        // Temporary unlock or timed unlock active — don't override with schedule.
        if hasActiveTemporaryMode() { return }

        // Manual mode override — skip schedule-driven changes.
        if !AppConstants.isScheduleDriven() { return }

        // lockedDown is parent-enforced maximum restriction — schedule must never override it.
        if storage.readPolicySnapshot()?.effectivePolicy.resolvedMode == .lockedDown { return }

        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Exception date — don't re-lock.
        if profile.isExceptionDate(Date()) { return }

        // Check if we're currently inside another unlocked window.
        // If so, don't lock — the device should stay unlocked.
        if profile.isInUnlockedWindow(at: Date()) {
            return
        }

        // Resolve the current mode — an essential window may be active.
        let mode = profile.resolvedMode(at: Date())
        let policy = storage.readPolicySnapshot()?.effectivePolicy

        // Write snapshot FIRST so if extension is killed mid-operation,
        // the main app sees the intended state and won't undo it.
        writeCorrectedSnapshot(mode: mode, trigger: "Monitor: free window ended, mode → \(mode.rawValue)")
        updateSharedState(mode: mode)

        if mode == .unlocked {
            clearAllShieldStores()
        } else {
            applyShieldingToAllStores(mode: mode, policy: policy)
        }
        if mode != .unlocked {
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "lastNaturalRelockAt")
        }

        logEvent(.scheduleEnded, details: "Unlocked window ended, mode \(mode.rawValue)")
        sendModeNotification(
            title: "Free Time Ended",
            body: mode == .unlocked ? "All apps are now accessible." : "Device locked — \(mode.displayName) mode active."
        )
    }

    // MARK: - Locked Window Handling

    /// Locked window started: apply essential-only mode if today matches.
    private func handleLockedWindowStart(_ activity: DeviceActivityName) {
        // Clear expired temporary unlock state to prevent stale restorer re-unlock on next app launch.
        if let tempState = storage.readTemporaryUnlockState(),
           tempState.expiresAt <= Date() {
            try? storage.clearTemporaryUnlockState()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Cleared expired temporary unlock state during locked window start"
            ))
        }

        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("essentialStart", forKey: "lastShieldChangeReason")

        // Temporary unlock or timed unlock active — don't override with schedule.
        if hasActiveTemporaryMode() { return }

        // Manual mode override — skip schedule-driven changes.
        if !AppConstants.isScheduleDriven() { return }

        // lockedDown is parent-enforced maximum restriction — schedule must never weaken it.
        if storage.readPolicySnapshot()?.effectivePolicy.resolvedMode == .lockedDown { return }

        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Exception date — schedule suspended, ensure device stays unlocked.
        if profile.isExceptionDate(Date()) {
            clearAllShieldStores()
            updateSharedState(mode: .unlocked)
            return
        }

        let windowID = extractWindowID(from: activity, prefix: essentialWindowPrefix)
        guard let window = profile.lockedWindows.first(where: { $0.id.uuidString == windowID }) else {
            return
        }

        // Check if the current date/time actually falls within this window.
        // Allow 30-second tolerance for late DeviceActivity callbacks.
        guard window.contains(Date()) || window.contains(Date().addingTimeInterval(-30)) else { return }

        // Don't override if currently in an unlocked window (unlocked > locked).
        if profile.isInUnlockedWindow(at: Date()) { return }

        // Write snapshot FIRST so if extension is killed mid-operation,
        // the main app sees the intended state and won't undo it.
        writeCorrectedSnapshot(mode: .locked, trigger: "Monitor: locked window started (\(activity.rawValue))")
        updateSharedState(mode: .locked)

        // Then apply essential-only mode on ALL stores.
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: .locked, policy: policy)
        logEvent(.scheduleTriggered, details: "Locked window started: \(activity.rawValue)")
        sendModeNotification(title: "Locked Mode", body: "Only essential apps are available.")
    }

    /// Locked window ended: return to the profile's locked mode.
    private func handleLockedWindowEnd(_ activity: DeviceActivityName) {
        // Clear expired temporary unlock state to prevent stale restorer re-unlock on next app launch.
        if let tempState = storage.readTemporaryUnlockState(),
           tempState.expiresAt <= Date() {
            try? storage.clearTemporaryUnlockState()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Cleared expired temporary unlock state during locked window end"
            ))
        }

        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set("essentialEnd", forKey: "lastShieldChangeReason")

        // Temporary unlock or timed unlock active — don't override with schedule.
        if hasActiveTemporaryMode() { return }

        // Manual mode override — skip schedule-driven changes.
        if !AppConstants.isScheduleDriven() { return }

        // lockedDown is parent-enforced maximum restriction — schedule must never weaken it.
        if storage.readPolicySnapshot()?.effectivePolicy.resolvedMode == .lockedDown { return }

        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Exception date — don't re-lock.
        if profile.isExceptionDate(Date()) { return }

        // If in an unlocked window, don't re-lock.
        if profile.isInUnlockedWindow(at: Date()) { return }
        // If in another locked window, stay locked.
        if profile.isInLockedWindow(at: Date()) { return }

        // Write snapshot FIRST so if extension is killed mid-operation,
        // the main app sees the intended state and won't undo it.
        writeCorrectedSnapshot(mode: profile.lockedMode, trigger: "Monitor: locked window ended, mode → \(profile.lockedMode.rawValue)")
        updateSharedState(mode: profile.lockedMode)

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: profile.lockedMode, policy: policy)
        logEvent(.scheduleEnded, details: "Locked window ended, locked to \(profile.lockedMode.rawValue)")
        sendModeNotification(
            title: "Locked Mode Ended",
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

    /// Timed unlock window ended — re-lock the device using saved previousMode.
    /// Falls back to schedule or .restricted if previousMode not available.
    private func handleTimedUnlockEnd(_ activity: DeviceActivityName) {
        let timedInfo = storage.readTimedUnlockInfo()

        let mode: LockMode
        if AppConstants.isScheduleDriven(), let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
        } else if let saved = timedInfo?.previousMode {
            mode = saved
        } else {
            mode = .restricted
        }

        // Update PolicySnapshot so all processes see the correct post-unlock mode.
        if let existingSnapshot = storage.readPolicySnapshot() {
            let existingPolicy = existingSnapshot.effectivePolicy
            let correctedPolicy = EffectivePolicy(
                resolvedMode: mode,
                controlAuthority: .schedule,
                isTemporaryUnlock: false,
                temporaryUnlockExpiresAt: nil,
                shieldedCategoriesData: existingPolicy.shieldedCategoriesData,
                allowedAppTokensData: existingPolicy.allowedAppTokensData,
                deviceRestrictions: existingPolicy.deviceRestrictions,
                warnings: existingPolicy.warnings,
                policyVersion: existingPolicy.policyVersion + 1
            )
            let correctedSnapshot = PolicySnapshot(
                source: .temporaryUnlockExpired,
                trigger: "Monitor: timed unlock ended, reverted to \(mode.rawValue)",
                effectivePolicy: correctedPolicy
            )
            _ = try? storage.commitCorrectedSnapshot(correctedSnapshot)
        }

        if mode == .unlocked {
            clearAllShieldStores()
        } else {
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            applyShieldingToAllStores(mode: mode, policy: policy)
        }
        updateSharedState(mode: mode)
        try? storage.clearTimedUnlockInfo()
        try? storage.clearTemporaryUnlockState()
        if mode != .unlocked {
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "lastNaturalRelockAt")
        }
        logEvent(.scheduleEnded, details: "Timed unlock ended, mode \(mode.rawValue)")
        sendModeNotification(title: "Free Time Ended", body: mode == .unlocked ? "Unlocked window — all apps accessible." : "Device locked — \(mode.displayName) mode active.")
    }

    // MARK: - Temporary Unlock Expiry

    /// Temporary unlock timer expired — re-lock the device using the previous mode.
    /// If a manual mode was set (scheduleDrivenMode=false), revert to previousMode.
    /// If schedule-driven, use the schedule's current resolved mode.
    private func handleTempUnlockExpired(_ activity: DeviceActivityName) {
        let unlockState = storage.readTemporaryUnlockState()
        let previousMode = unlockState?.previousMode ?? .restricted

        let mode: LockMode
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)

        if AppConstants.isScheduleDriven(), let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
        } else {
            mode = previousMode
        }

        // CRITICAL: Update the PolicySnapshot so the main app sees the correct mode.
        // Without this, the snapshot remains stale with isTemporaryUnlock=true and
        // resolvedMode=.unlocked, causing the app to think shields should be down.
        if let existingSnapshot = storage.readPolicySnapshot() {
            let existingPolicy = existingSnapshot.effectivePolicy
            let authority: ControlAuthority = AppConstants.isScheduleDriven() ? .schedule : (existingPolicy.controlAuthority ?? .schedule)
            let correctedPolicy = EffectivePolicy(
                resolvedMode: mode,
                controlAuthority: authority,
                isTemporaryUnlock: false,
                temporaryUnlockExpiresAt: nil,
                shieldedCategoriesData: existingPolicy.shieldedCategoriesData,
                allowedAppTokensData: existingPolicy.allowedAppTokensData,
                deviceRestrictions: existingPolicy.deviceRestrictions,
                warnings: existingPolicy.warnings,
                policyVersion: existingPolicy.policyVersion + 1
            )
            let correctedSnapshot = PolicySnapshot(
                source: .temporaryUnlockExpired,
                trigger: "Monitor: temp unlock expired, reverted to \(mode.rawValue)",
                effectivePolicy: correctedPolicy
            )
            _ = try? storage.commitCorrectedSnapshot(correctedSnapshot)
        }

        // Brief delay before re-applying — gives the .child auth daemon time to
        // process the wide-open-to-restricted transition. Without this, the daemon
        // may still be processing the temp unlock state and silently reject writes.
        Thread.sleep(forTimeInterval: 1.0)

        // Use a fresh ManagedSettingsStore instance — the cached one may have stale auth state.
        let freshBaseStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreBase))
        let freshScheduleStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreSchedule))
        _ = freshBaseStore; _ = freshScheduleStore // Force init

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: mode, policy: policy)

        // Verify shields actually applied — .child FamilyControls auth can silently
        // reject ManagedSettings writes after temp unlock expiry. Retry with delay
        // to give iOS's auth daemon time to re-validate.
        if mode != .unlocked && baseStore.shield.applicationCategories == nil {
            logEvent(.enforcementDegraded, details: "Shield re-apply failed after temp unlock expiry — retrying in 2s")
            Thread.sleep(forTimeInterval: 2.0)
            applyShieldingToAllStores(mode: mode, policy: policy)

            if baseStore.shield.applicationCategories == nil {
                logEvent(.enforcementDegraded, details: "Shield re-apply failed on 2nd attempt — retrying in 5s")
                Thread.sleep(forTimeInterval: 5.0)
                applyShieldingToAllStores(mode: mode, policy: policy)

                if baseStore.shield.applicationCategories == nil {
                    logEvent(.enforcementDegraded, details: "Shield re-apply FAILED 3x after temp unlock expiry — shields may be down")
                    // Write confirmed-down flag so tunnel can DNS-block immediately
                    defaults?.set(false, forKey: "shieldsActiveAtLastHeartbeat")
                }
            }
        }

        updateSharedState(mode: mode)
        try? storage.clearTemporaryUnlockState()
        // Also clear any lingering timed unlock info to prevent conflicts.
        try? storage.clearTimedUnlockInfo()
        // Record when the device naturally re-locked so force-close detection
        // gives extra grace time (the app may be suspended from a game).
        defaults?.set(Date().timeIntervalSince1970, forKey: "lastNaturalRelockAt")
        logEvent(.temporaryUnlockExpired, details: "Temp unlock expired, locked to \(mode.rawValue)")
        sendModeNotification(title: "Free Time Ended", body: "Device locked — \(mode.displayName) mode active.")
    }

    // MARK: - Lock Until Expiry

    /// Lock-until timer expired — restore prior mode from stack.
    /// Uses schedule if schedule-driven, saved previousMode if manual, or .restricted as fallback.
    private func handleLockUntilExpired(_ activity: DeviceActivityName) {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let mode: LockMode
        if AppConstants.isScheduleDriven(), let profile = storage.readActiveScheduleProfile() {
            mode = profile.resolvedMode(at: Date())
        } else if let savedRaw = defaults?.string(forKey: "lockUntilPreviousMode"),
                  let saved = LockMode(rawValue: savedRaw) {
            mode = saved
        } else {
            mode = .restricted
        }

        // Clean up saved state
        defaults?.removeObject(forKey: "lockUntilPreviousMode")
        defaults?.removeObject(forKey: "lockUntilExpiresAt")

        // Write snapshot FIRST so if extension is killed mid-operation,
        // the main app sees the intended state and won't undo it.
        writeCorrectedSnapshot(mode: mode, trigger: "Monitor: lockUntil expired, mode → \(mode.rawValue)")
        updateSharedState(mode: mode)

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

    // MARK: - Per-App Time Limits

    /// A time-limited app's usage milestone was reached (every 5 minutes).
    /// Writes precise foreground time to App Group for the parent to read.
    private func handleTimeLimitUsageMilestone(event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        // Parse minutes from event name: "timelimit.usage.30" → 30
        let minuteStr = String(event.rawValue.dropFirst("timelimit.usage.".count))
        guard let minutes = Int(minuteStr) else { return }

        // Parse app ID from activity name
        let idString = String(activity.rawValue.dropFirst("bigbrother.timelimit.".count))
        let limits = storage.readAppTimeLimits()
        guard let limit = limits.first(where: { $0.id.uuidString == idString }) else { return }

        // Update the usage snapshot
        let today = Self.todayDateString()
        var snapshot = storage.readAppUsageSnapshot() ?? AppUsageSnapshot(dateString: today)
        if snapshot.dateString != today {
            snapshot = AppUsageSnapshot(dateString: today)
        }

        let existing = snapshot.usageByFingerprint[limit.fingerprint] ?? 0
        if minutes > existing {
            snapshot.usageByFingerprint[limit.fingerprint] = minutes
            try? storage.writeAppUsageSnapshot(snapshot)
        }
    }

    /// An app's daily time limit was reached. Block it via shield.applications
    /// so the shield shows the app name and "Request More Time" button.
    private func handleTimeLimitExhausted(activity: DeviceActivityName) {
        let idString = String(activity.rawValue.dropFirst("bigbrother.timelimit.".count))
        let limits = storage.readAppTimeLimits()
        guard let limit = limits.first(where: { $0.id.uuidString == idString }) else { return }

        // Write exhausted entry
        var exhausted = storage.readTimeLimitExhaustedApps()
        let today = Self.todayDateString()
        // Don't duplicate
        guard !exhausted.contains(where: { $0.timeLimitID == limit.id && $0.dateString == today }) else { return }

        let entry = TimeLimitExhaustedApp(
            timeLimitID: limit.id,
            appName: limit.appName,
            tokenData: limit.tokenData,
            fingerprint: limit.fingerprint,
            dateString: today
        )
        exhausted.append(entry)
        try? storage.writeTimeLimitExhaustedApps(exhausted)

        // Block the app's web domains at the DNS level (prevents Safari bypass).
        updateTimeLimitBlockedDomains()

        // Re-apply enforcement (adds to shield.applications, removes from allowed)
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: policy?.resolvedMode ?? .restricted, policy: policy)

        // Notify kid
        sendModeNotification(
            title: "\(limit.appName) — Time's Up",
            body: "Daily limit of \(limit.dailyLimitMinutes) minutes reached."
        )

        // Log event
        logEvent(.timeLimitExhausted, details: "\(limit.appName): \(limit.dailyLimitMinutes) min limit reached")

        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")
    }

    /// Daily reset: a time limit schedule restarted (midnight). Clear exhausted status
    /// for this app so it's usable again today.
    private func handleTimeLimitDayReset(activity: DeviceActivityName) {
        let idString = String(activity.rawValue.dropFirst("bigbrother.timelimit.".count))

        var exhausted = storage.readTimeLimitExhaustedApps()
        let before = exhausted.count
        exhausted.removeAll { $0.timeLimitID.uuidString == idString }
        guard exhausted.count != before else { return }

        try? storage.writeTimeLimitExhaustedApps(exhausted)

        // Update DNS blocklist (removes cleared app's domains).
        updateTimeLimitBlockedDomains()

        // Re-apply enforcement to unblock the app
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: policy?.resolvedMode ?? .restricted, policy: policy)

        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")
    }

    /// Update the DNS blocklist with domains of all currently-exhausted apps.
    /// The VPN tunnel reads this and blocks DNS queries for these domains.
    private func updateTimeLimitBlockedDomains() {
        let today = Self.todayDateString()
        let exhausted = storage.readTimeLimitExhaustedApps().filter { $0.dateString == today }
        var blockedDomains = Set<String>()
        for app in exhausted {
            let domains = DomainCategorizer.domainsForApp(app.appName)
            blockedDomains.formUnion(domains)
        }
        try? storage.writeTimeLimitBlockedDomains(blockedDomains)
    }

    // MARK: - Temporary Mode Guard

    /// Check if a temporary mode (temp unlock, timed unlock) is currently active.
    /// Schedule window transitions should NOT override active temporary modes —
    /// the parent's explicit command takes priority over the schedule.
    private func hasActiveTemporaryMode() -> Bool {
        let now = Date()
        if let temp = storage.readTemporaryUnlockState(), temp.expiresAt > now {
            return true
        }
        if let timed = storage.readTimedUnlockInfo(), now < timed.lockAt {
            return true
        }
        return false
    }

    // MARK: - Reconciliation Re-registration

    /// Re-register a reconciliation quarter after it was stopped by stopMonitoring (on-demand trigger).
    /// Re-registers the same 6-hour window so it fires again at the next natural boundary.
    private func reregisterReconciliationQuarter(_ activity: DeviceActivityName) {
        guard activity.rawValue.hasPrefix("bigbrother.reconciliation.q"),
              let quarterChar = activity.rawValue.last,
              let quarter = Int(String(quarterChar)) else { return }

        let startHour = quarter * 6
        let endHour = startHour + 5
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: startHour, minute: 0),
            intervalEnd: DateComponents(hour: endHour, minute: 59),
            repeats: true,
            warningTime: DateComponents(hour: 3)
        )
        let center = DeviceActivityCenter()
        do {
            try center.startMonitoring(activity, during: schedule)
            NSLog("[Monitor] Re-registered \(activity.rawValue)")
        } catch {
            NSLog("[Monitor] Failed to re-register \(activity.rawValue): \(error)")
        }
    }

    // MARK: - Enforcement Refresh Signal

    /// Check if the tunnel signaled that enforcement needs immediate refresh.
    /// The tunnel handles grantExtraTime/blockAppForToday but can't write ManagedSettings.
    /// It sets this flag so the Monitor re-applies on its next callback (any callback).
    private func checkEnforcementRefreshSignal() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard let signalTime = defaults?.double(forKey: "needsEnforcementRefresh"),
              signalTime > 0 else { return }

        // Only act on recent signals (within 5 minutes)
        let age = Date().timeIntervalSince1970 - signalTime
        guard age < 300 else {
            defaults?.removeObject(forKey: "needsEnforcementRefresh")
            return
        }

        // Clear the flag FIRST to prevent re-entrancy
        defaults?.removeObject(forKey: "needsEnforcementRefresh")

        // Process pending token removals from the tunnel (tunnel can't import ManagedSettings).
        let pendingRemovals = defaults?.stringArray(forKey: "pendingTokenRemovals") ?? []
        if !pendingRemovals.isEmpty {
            defaults?.removeObject(forKey: "pendingTokenRemovals")
            if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
               var allowed = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
                let beforeCount = allowed.count
                for base64 in pendingRemovals {
                    if let tokenData = Data(base64Encoded: base64),
                       let token = try? JSONDecoder().decode(ApplicationToken.self, from: tokenData) {
                        allowed.remove(token)
                    }
                }
                if allowed.count != beforeCount, let encoded = try? JSONEncoder().encode(allowed) {
                    try? storage.writeRawData(encoded, forKey: StorageKeys.allowedAppTokens)
                }
            }
        }

        // Re-apply enforcement from current state
        let resolution = ModeStackResolver.resolve(storage: storage)
        let policy = storage.readPolicySnapshot()?.effectivePolicy

        if resolution.mode == .unlocked {
            clearAllShieldStores()
            updateSharedState(mode: .unlocked)
        } else {
            applyShieldingToAllStores(mode: resolution.mode, policy: policy)
            updateSharedState(mode: resolution.mode)
        }

        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "Enforcement refresh from tunnel signal (age \(Int(age))s) → \(resolution.mode.rawValue)"
        ))
    }

    // MARK: - Reconciliation

    /// Verify enforcement matches the mode stack.
    /// Uses ModeStackResolver for deterministic mode resolution from App Group files.
    /// Also cleans up expired temporary state as a side effect.
    private func reconcile() {
        let reconcileDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        reconcileDefaults?.set("reconcile", forKey: "lastShieldChangeReason")
        // Update Monitor heartbeat so the tunnel knows we're alive.
        // Without this, the tunnel's 1-hour "Monitor dead" threshold triggers
        // false emergency blackhole activation during quiet periods.
        reconcileDefaults?.set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")

        // Check VPN tunnel health — if the child deleted the VPN profile,
        // DNS enforcement stops silently. Log it so it appears in heartbeat/diagnostics.
        let tunnelLastActive = reconcileDefaults?.double(forKey: "tunnelLastActiveAt") ?? 0
        if tunnelLastActive > 0 {
            let tunnelAge = Date().timeIntervalSince1970 - tunnelLastActive
            if tunnelAge > 600 { // Tunnel dead for 10+ minutes
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "WARNING: VPN tunnel inactive for \(Int(tunnelAge))s — may have been removed"
                ))
                // If device should be restricted/locked, note the DNS fallback is gone.
                if let snapshot = storage.readPolicySnapshot(),
                   snapshot.effectivePolicy.resolvedMode != .unlocked {
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .enforcement,
                        message: "Tunnel dead during enforced mode — maintaining shields (DNS fallback unavailable)"
                    ))
                }
            }
        }

        let resolution = ModeStackResolver.resolve(storage: storage)
        let policy = storage.readPolicySnapshot()?.effectivePolicy

        // Re-register DeviceActivity schedules if the schedule's expected mode
        // doesn't match what's currently enforced. This catches missed transitions
        // where the system failed to fire intervalDidStart/End.
        reregisterScheduleIfDrifted(expectedMode: resolution.mode)

        // Security: block scheduled unlocks if main app is force-closed.
        // Tightening restrictions is always safe, but loosening when app is dead is risky.
        if resolution.mode == .unlocked && shouldTreatMainAppAsUnavailable() {
            sendForceCloseEnforcement(nagNotification: true)
            logEvent(.policyReconciled, details: "Reconciliation: unlock blocked — app dead (\(resolution.reason))")
            return
        }

        // Apply the resolved mode
        if resolution.mode == .unlocked {
            clearAllShieldStores()
            updateSharedState(
                mode: .unlocked,
                isTemporaryUnlock: resolution.isTemporary,
                temporaryUnlockExpiresAt: resolution.expiresAt
            )
        } else {
            applyShieldingToAllStores(mode: resolution.mode, policy: policy)
            updateSharedState(mode: resolution.mode)
        }

        logEvent(.policyReconciled, details: "Reconciliation: \(resolution.reason)")
    }

    /// If the schedule's expected mode drifted from what's enforced (a missed transition),
    /// re-register the DeviceActivity schedules. Throttled to once per 30 minutes to avoid
    /// churning registrations on every reconciliation tick.
    private func reregisterScheduleIfDrifted(expectedMode: LockMode) {
        guard let profile = storage.readActiveScheduleProfile() else { return }
        let extState = storage.readExtensionSharedState()
        let currentMode = extState?.currentMode ?? .unlocked

        // If expected mode matches enforced mode, no drift
        guard expectedMode != currentMode else { return }

        // Throttle: re-register at most once per 30 minutes
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let lastReregAt = defaults?.double(forKey: "lastScheduleReregisteredAt") ?? 0
        let elapsed = Date().timeIntervalSince1970 - lastReregAt
        guard elapsed > 1800 else { return }

        // Re-register the DeviceActivity schedules
        let center = DeviceActivityCenter()

        // Clear existing schedule activities
        for activity in center.activities {
            if activity.rawValue.hasPrefix("bigbrother.scheduleprofile.")
                || activity.rawValue.hasPrefix("bigbrother.essentialwindow.") {
                center.stopMonitoring([activity])
            }
        }

        // Re-register unlocked windows
        for window in profile.unlockedWindows {
            registerWindowFromReconciliation(window, prefix: scheduleProfilePrefix, center: center)
        }
        // Re-register locked windows
        for window in profile.lockedWindows {
            registerWindowFromReconciliation(window, prefix: essentialWindowPrefix, center: center)
        }

        defaults?.set(Date().timeIntervalSince1970, forKey: "lastScheduleReregisteredAt")

        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "Schedule drift detected (\(currentMode.rawValue)→\(expectedMode.rawValue)) — re-registered DeviceActivity schedules"
        ))
    }

    /// Register a single window's DeviceActivity schedule (called from reconciliation).
    private func registerWindowFromReconciliation(_ window: ActiveWindow, prefix: String, center: DeviceActivityCenter) {
        if window.startTime < window.endTime {
            let name = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)")
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
                intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
                repeats: true
            )
            try? center.startMonitoring(name, during: schedule)
        } else {
            // Cross-midnight: evening + morning
            let eveningName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString).pm")
            let eveningSchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true
            )
            try? center.startMonitoring(eveningName, during: eveningSchedule)

            let morningName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString).am")
            let morningSchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
                repeats: true
            )
            try? center.startMonitoring(morningName, during: morningSchedule)
        }
    }

    // MARK: - All-Store Shield Management

    /// Clear shield properties on ALL named stores + default store.
    /// Apply "wide open" shields — allows everything but keeps stores non-nil.
    /// Avoids the clear-then-reapply race that silently breaks .child auth.
    private func applyWideOpenShields() {
        // Don't allow unlock if FamilyControls authorization is lost.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let snapshot = storage.readPolicySnapshot()
        let fcRevoked = snapshot?.authorizationHealth?.isAuthorized == false
        let flagSaysMissing = defaults?.bool(forKey: "allPermissionsGranted") == false
        if fcRevoked || (flagSaysMissing && snapshot?.authorizationHealth == nil) {
            let policy = snapshot?.effectivePolicy
            applyShieldingToAllStores(mode: .locked, policy: policy)
            return
        }

        // Collect every known token
        var allTokens = collectAllowedTokens()
        allTokens.formUnion(loadPickerTokens())
        let decoder = JSONDecoder()
        for limit in storage.readAppTimeLimits() {
            if let token = try? decoder.decode(ApplicationToken.self, from: limit.tokenData) {
                allTokens.insert(token)
            }
        }

        // Set .all(except: everything) on base and schedule — keeps stores non-nil
        for s in [baseStore, store] {
            s.shield.applications = nil
            s.shield.applicationCategories = allTokens.isEmpty ? nil : .all(except: allTokens)
            s.shield.webDomainCategories = nil
            s.shield.webDomains = nil
        }

        // Clear supplementary stores normally
        let tempUnlockStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreTempUnlock))
        for s in [tempUnlockStore] {
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

        // Clear DNS blocklists
        try? storage.writeEnforcementBlockedDomains([])
        try? storage.writeTimeLimitBlockedDomains([])
    }

    /// ManagedSettings merges across stores with OR logic — if any store blocks, it's blocked.
    /// NOTE: This fully clears stores to nil. Only used when the intent is to immediately
    /// re-apply via applyShieldingToAllStores (which overwrites base/schedule without clearing).
    private func clearAllShieldStores() {
        let tempUnlockStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreTempUnlock))
        for s in [tempUnlockStore] {
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

        // Clear BOTH DNS blocklists — enforcement AND time-limit.
        try? storage.writeEnforcementBlockedDomains([])
        try? storage.writeTimeLimitBlockedDomains([])
    }

    /// Apply shields to BOTH base and schedule stores using the hybrid per-app + category strategy.
    /// Mirrors EnforcementServiceImpl.applyShield() logic.
    private static let maxShieldApplications = 50

    /// Sort tokens deterministically by encoded data instead of hash order.
    private static func stableSorted(_ tokens: Set<ApplicationToken>) -> [ApplicationToken] {
        let encoder = JSONEncoder()
        return tokens.sorted { a, b in
            let da = (try? encoder.encode(a))?.base64EncodedString() ?? ""
            let db = (try? encoder.encode(b))?.base64EncodedString() ?? ""
            return da < db
        }
    }

    private func applyShieldingToAllStores(mode: LockMode, policy: EffectivePolicy?) {
        // Check if main app enforced very recently (within 2s) to avoid stomping on it.
        // ManagedSettings OR-merges so both writing is safe, but we skip unnecessary work.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)

        // Force essential mode if permissions are missing.
        let effectiveMode: LockMode
        if defaults?.bool(forKey: "allPermissionsGranted") == false && mode != .locked {
            effectiveMode = .locked
        } else {
            effectiveMode = mode
        }

        // Clear tempUnlock + default stores to remove stale shields from other contexts.
        // Do NOT clear base/schedule stores here — we overwrite them below in all code paths,
        // and clearing first creates a window where shields are down if the extension is killed.
        let tempUnlockStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreTempUnlock))
        tempUnlockStore.shield.applications = nil
        tempUnlockStore.shield.applicationCategories = nil
        tempUnlockStore.shield.webDomainCategories = nil
        tempUnlockStore.shield.webDomains = nil
        let defaultStore = ManagedSettingsStore()
        defaultStore.shield.applications = nil
        defaultStore.shield.applicationCategories = nil
        defaultStore.shield.webDomainCategories = nil
        defaultStore.shield.webDomains = nil

        switch effectiveMode {
        case .unlocked:
            clearAllShieldStores()

        case .restricted, .locked, .lockedDown:
            let allowExemptions = effectiveMode == .restricted
            var allowedTokens = allowExemptions ? collectAllowedTokens() : []
            let pickerTokens = loadPickerTokens()

            // Remove time-exhausted apps from the allowed set and collect their tokens
            // for shield.applications (enables "Request More Time" on the shield).
            let decoder = JSONDecoder()
            let today = Self.todayDateString()
            let exhaustedApps = storage.readTimeLimitExhaustedApps().filter { $0.dateString == today }
            var exhaustedTokens = Set<ApplicationToken>()
            for app in exhaustedApps {
                if let token = try? decoder.decode(ApplicationToken.self, from: app.tokenData) {
                    allowedTokens.remove(token)
                    exhaustedTokens.insert(token)
                }
            }

            // Web blocking: locked/lockedDown ALWAYS block web, restricted respects flag.
            let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            let shouldBlockWeb = !allowExemptions || restrictions.denyWebWhenLocked

            if !pickerTokens.isEmpty && allowExemptions {
                let tokensToBlock = pickerTokens.subtracting(allowedTokens)
                var perAppTokens: Set<ApplicationToken>
                if tokensToBlock.count <= Self.maxShieldApplications {
                    perAppTokens = tokensToBlock
                } else {
                    perAppTokens = Set(Self.stableSorted(tokensToBlock).prefix(Self.maxShieldApplications))
                }
                // Add exhausted tokens to shield.applications for "Request More Time".
                // Re-enforce 50-token cap — exceeding it silently drops ALL shields.
                // Priority: exhausted tokens always kept; picker tokens fill remaining
                // slots sorted deterministically (encoded data, not hash).
                perAppTokens.formUnion(exhaustedTokens)
                if perAppTokens.count > Self.maxShieldApplications {
                    let exhaustedCount = min(exhaustedTokens.count, Self.maxShieldApplications)
                    let remainingSlots = Self.maxShieldApplications - exhaustedCount
                    let pickerOnly = perAppTokens.subtracting(exhaustedTokens)
                    let keptPicker = Set(Self.stableSorted(pickerOnly).prefix(remainingSlots))
                    perAppTokens = Set(Self.stableSorted(exhaustedTokens).prefix(exhaustedCount)).union(keptPicker)
                    let dropped = pickerOnly.count + exhaustedTokens.count - perAppTokens.count
                    if dropped > 0 {
                        try? storage.appendDiagnosticEntry(DiagnosticEntry(
                            category: .enforcement,
                            message: "Monitor token cap: \(dropped) apps dropped from shield.applications (50 limit). \(exhaustedTokens.count) exhausted kept."
                        ))
                    }
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
                var apps: Set<ApplicationToken>? = allowExemptions ? nil : (pickerTokens.isEmpty ? nil : pickerTokens)
                // Add exhausted tokens to shield.applications
                if !exhaustedTokens.isEmpty {
                    apps = (apps ?? Set()).union(exhaustedTokens)
                }
                // Enforce 50-token cap — exceeding it silently drops ALL shields.
                // Priority: exhausted tokens always kept, picker tokens fill remaining slots.
                if let currentApps = apps, currentApps.count > Self.maxShieldApplications {
                    let exhaustedCount = min(exhaustedTokens.count, Self.maxShieldApplications)
                    let remainingSlots = Self.maxShieldApplications - exhaustedCount
                    let nonExhausted = currentApps.subtracting(exhaustedTokens)
                    let keptNonExhausted = Set(Self.stableSorted(nonExhausted).prefix(remainingSlots))
                    apps = Set(Self.stableSorted(exhaustedTokens).prefix(exhaustedCount)).union(keptNonExhausted)
                }
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

            // DNS-block web versions of shielded apps (prevents Safari web app bypass).
            updateEnforcementBlockedDomains(allowedTokens: allowedTokens)
        }
    }

    /// Compute and write DNS-blocked domains when shields are up.
    /// Only blocks web domains of apps that are actively shielded (picker minus allowed).
    /// Mirrors EnforcementServiceImpl.updateEnforcementBlockedDomains().
    private func updateEnforcementBlockedDomains(allowedTokens: Set<ApplicationToken>) {
        let encoder = JSONEncoder()
        let cache = storage.readAllCachedAppNames()

        // Only block domains for apps that are actually shielded.
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

        var blocked = Set<String>()
        for name in shieldedNames {
            blocked.formUnion(DomainCategorizer.domainsForApp(name))
        }

        // Always block DoH resolvers when enforcement is active.
        blocked.formUnion(DomainCategorizer.dohResolverDomains)

        // If web games are denied, also block browser gaming sites.
        let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
        if restrictions.denyWebGamesWhenRestricted {
            blocked.formUnion(DomainCategorizer.webGamingDomains)
        }

        // If we have shielded tokens but resolved zero names (cache miss), preserve
        // the existing blocklist rather than overwriting it with just DoH resolvers.
        // The main app will write the correct list on next foreground.
        if !shieldedTokens.isEmpty && shieldedNames.isEmpty {
            let existing = storage.readEnforcementBlockedDomains()
            if !existing.isEmpty {
                return  // Keep existing blocklist — name cache not available in extension
            }
        }

        try? storage.writeEnforcementBlockedDomains(blocked)
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

        case .restricted, .locked, .lockedDown:
            let allowExemptions = mode == .restricted
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

        // Don't issue a new request if one is already outstanding and unacked.
        if let requestToken, !requestToken.isEmpty, ackToken != requestToken {
            return
        }

        // Debounce: don't issue a new request within 60 seconds of the last one.
        // This prevents the race where Monitor sets a new token before the app
        // finishes acking the old one, which looks like force-close.
        let lastRequestAt = defaults?.double(forKey: "extensionHeartbeatRequestedAt") ?? 0
        if lastRequestAt > 0 && Date().timeIntervalSince1970 - lastRequestAt < 60 {
            return
        }

        defaults?.set(UUID().uuidString, forKey: "extensionHeartbeatRequestToken")
        defaults?.set(Date().timeIntervalSince1970, forKey: "extensionHeartbeatRequestedAt")
    }

    /// Write a corrected PolicySnapshot so the main app, tunnel, and heartbeat
    /// all agree on the current mode after a schedule transition.
    private func writeCorrectedSnapshot(mode: LockMode, trigger: String, controlAuthority: ControlAuthority = .schedule) {
        let existing = storage.readPolicySnapshot()
        let basePolicy = existing?.effectivePolicy
        let corrected = EffectivePolicy(
            resolvedMode: mode,
            controlAuthority: controlAuthority,
            isTemporaryUnlock: false,
            temporaryUnlockExpiresAt: nil,
            shieldedCategoriesData: basePolicy?.shieldedCategoriesData,
            allowedAppTokensData: basePolicy?.allowedAppTokensData,
            deviceRestrictions: basePolicy?.deviceRestrictions,
            warnings: basePolicy?.warnings ?? [],
            policyVersion: (basePolicy?.policyVersion ?? 0) + 1
        )
        let snapshot = PolicySnapshot(
            source: .scheduleTransition,
            trigger: trigger,
            effectivePolicy: corrected
        )
        do {
            try storage.commitCorrectedSnapshot(snapshot)
        } catch {
            // Critical: snapshot write failed — main app may see stale state and undo enforcement.
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Monitor: PolicySnapshot write FAILED",
                details: "Mode: \(mode.rawValue), error: \(error.localizedDescription)"
            ))
        }
    }

    /// Update ExtensionSharedState so the heartbeat reports the correct mode
    /// after schedule transitions. Also writes PolicySnapshot for consistency.
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

        // Use ModeStackResolver for ground truth — ExtensionSharedState can be stale.
        let currentMode = ModeStackResolver.resolve(storage: storage).mode
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
    /// Locked mode blocks most apps but allows phone, messages, and other
    /// essentials — less aggressive than blocking everything, but still enforced.
    /// When the main app launches, it clears the forceCloseWebBlocked flag and
    /// re-applies normal enforcement with proper exemptions via performRestoration().
    /// Apply essential-only enforcement. Only sends a notification when `nagNotification`
    /// is true (unlocked window blocked). Silent when the device is already locked down.
    private func sendForceCloseEnforcement(nagNotification: Bool) {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.set("appClosed", forKey: "lastShieldChangeReason")

        // Apply essential-only mode on all stores — no exemptions.
        if defaults?.bool(forKey: "forceCloseWebBlocked") != true {
            defaults?.set(true, forKey: "forceCloseWebBlocked")
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            applyShieldingToAllStores(mode: .locked, policy: policy)
        }
        updateSharedState(mode: .locked)

        guard nagNotification else { return }

        // Throttle notification: don't nag more than once per hour.
        let lastNagAt = defaults?.double(forKey: "forceCloseLastNagAt") ?? 0
        let nagAge = Date().timeIntervalSince1970 - lastNagAt
        guard nagAge > 3600 else { return }  // 1 hour
        defaults?.set(Date().timeIntervalSince1970, forKey: "forceCloseLastNagAt")

        let content = UNMutableNotificationContent()
        content.title = "Free Time Blocked"
        content.body = "Open Big Brother to start your free time."
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

        // Main app has launched with this build — clear any build-mismatch DNS block.
        guard mainAppBuild < extensionBuild else {
            // Mismatch resolved — remove the DNS block flag if we set it.
            if defaults?.bool(forKey: "buildMismatchDNSBlock") == true {
                defaults?.removeObject(forKey: "buildMismatchDNSBlock")
                defaults?.removeObject(forKey: "internetBlockedUntil")
            }
            return
        }

        // Don't lock during an active temp unlock — the kid is supposed to be using the device.
        if let tempState = storage.readTemporaryUnlockState(), tempState.expiresAt > Date() {
            logEvent(.policyReconciled, details: "Post-update: skipping essential mode — temp unlock active")
            return
        }

        // Apply essential-only mode immediately — the app isn't running so we
        // can't trust the full enforcement pipeline.
        defaults?.set("appClosed", forKey: "lastShieldChangeReason")
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: .locked, policy: policy)
        updateSharedState(mode: .locked)

        // Block DNS via the tunnel's legacy internetBlockedUntil flag.
        // This works even if the tunnel is still running OLD code — it already
        // checks this flag every 30 seconds. Set expiry far in the future;
        // it's cleared when the app launches and the mismatch resolves.
        if defaults?.bool(forKey: "buildMismatchDNSBlock") != true {
            defaults?.set(true, forKey: "buildMismatchDNSBlock")
            // Block for 24 hours — cleared when app launches (guard clause above).
            let blockUntil = Date().addingTimeInterval(86400).timeIntervalSince1970
            defaults?.set(blockUntil, forKey: "internetBlockedUntil")
        }

        logEvent(.policyReconciled, details: "Post-update essential mode + DNS block (main app build \(mainAppBuild) < extension build \(extensionBuild))")

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

    /// Re-register the 4 quarter-day reconciliation windows from the Monitor extension.
    /// Matches ScheduleManagerImpl.registerReconciliationSchedule().
    private func reregisterReconciliationSchedule() {
        let center = DeviceActivityCenter()
        let quarters: [(name: String, startHour: Int, endHour: Int)] = [
            ("bigbrother.reconciliation.q0", 0, 5),
            ("bigbrother.reconciliation.q1", 6, 11),
            ("bigbrother.reconciliation.q2", 12, 17),
            ("bigbrother.reconciliation.q3", 18, 23),
        ]
        for q in quarters {
            let activityName = DeviceActivityName(rawValue: q.name)
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: q.startHour, minute: 0),
                intervalEnd: DateComponents(hour: q.endHour, minute: 59),
                repeats: true,
                warningTime: nil
            )
            do {
                try center.startMonitoring(activityName, during: schedule)
            } catch {
                NSLog("[Monitor] Failed to register \(q.name): \(error)")
            }
        }
        let count = center.activities.filter { $0.rawValue.hasPrefix("bigbrother.reconciliation") }.count
        NSLog("[Monitor] Re-registered reconciliation: \(count) quarters")
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
