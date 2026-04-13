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
/// - Apply/clear ManagedSettings restrictions on the "enforcement" store
/// - Append event log entries to App Group storage
///
/// Constraints:
/// - Cannot make network calls
/// - Cannot present UI
/// - Very limited memory and execution time
/// - Must read all state from App Group shared storage
class BigBrotherMonitorExtension: DeviceActivityMonitor {

    private let storage = AppGroupStorage()
    /// Fresh ManagedSettingsStore instance on every access.
    /// Cached instances risk stale XPC connections — the same bug that broke enforcement in the main app.
    private var enforcementStore: ManagedSettingsStore {
        ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreEnforcement))
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

    /// One-time migration: clear legacy named stores (base, schedule, tempUnlock)
    /// so stale shields from the old multi-store layout don't linger.
    private func migrateLegacyStoresIfNeeded() {
        let defaults = UserDefaults.appGroup
        guard defaults?.bool(forKey: "migratedToSingleStore") != true else { return }
        for name in AppConstants.legacyStoreNames {
            ManagedSettingsStore(named: .init(name)).clearAllSettings()
        }
        defaults?.set(true, forKey: "migratedToSingleStore")
        NSLog("[Monitor] Migrated: cleared legacy stores")
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        // Record that the Monitor is alive (used by parent to detect force-close).
        let monitorDefaults = UserDefaults.appGroup
        monitorDefaults?.set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")
        monitorDefaults?.set(AppConstants.appBuildNumber, forKey: "monitorBuildNumber")

        // Migrate legacy multi-store layout to single enforcement store.
        migrateLegacyStoresIfNeeded()

        // Check if the main app needs to be launched after an update.
        checkAppLaunchNeeded()

        // R9 fix: Verify reconciliation registrations on EVERY callback.
        // App reinstalls kill extension processes, which can lose DeviceActivity
        // registrations. Without reconciliation, the Monitor stops firing and
        // enforcement drifts. This self-heals by re-registering if missing.
        ensureReconciliationRegistered()

        // Tunnel signals "enforcement dirty" when it handles grantExtraTime/blockAppForToday.
        // The tunnel can't write ManagedSettings — we must do it here on the next callback.
        checkEnforcementRefreshSignal()
        rearmEnforcementHeartbeat()

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
            NSLog("[Monitor] enforcementRefresh FIRED for \(activity.rawValue)")
            let resolution = ModeStackResolver.resolve(storage: storage)
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            NSLog("[Monitor] enforcementRefresh: mode=\(resolution.mode.rawValue) reason=\(resolution.reason)")
            if resolution.mode == .unlocked {
                clearAllShieldStores()
                NSLog("[Monitor] enforcementRefresh: cleared all shields (unlocked)")
            } else {
                applyShieldingToAllStores(mode: resolution.mode, policy: policy)
                NSLog("[Monitor] enforcementRefresh: applied shields for \(resolution.mode.rawValue)")
            }
            updateSharedState(mode: resolution.mode)
            // Confirm enforcement applied via UserDefaults — main app polls this.
            UserDefaults.appGroup?
                .set(Date().timeIntervalSince1970, forKey: "monitorEnforcementConfirmedAt")
            UserDefaults.appGroup?
                .set(Date().timeIntervalSince1970, forKey: "monitorNeedsHeartbeat")
            logEvent(.policyReconciled, details: "Monitor enforcement refresh: \(resolution.mode.rawValue) (\(resolution.reason))")
            // Clean up one-shot trigger activity
            DeviceActivityCenter().stopMonitoring([activity])
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
        let monitorDefaults = UserDefaults.appGroup
        monitorDefaults?.set(Date().timeIntervalSince1970, forKey: "monitorLastActiveAt")

        // R9 fix: self-heal reconciliation registrations on every callback.
        ensureReconciliationRegistered()

        checkEnforcementRefreshSignal()

        // Enforcement refresh trigger ended (1-minute window expired or was stopped).
        // Apply enforcement one more time as a safety net.
        if activity.rawValue.hasPrefix("bigbrother.enforcementRefresh") {
            NSLog("[Monitor] enforcementRefresh intervalDidEnd for \(activity.rawValue)")
            let resolution = ModeStackResolver.resolve(storage: storage)
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            if resolution.mode == .unlocked {
                clearAllShieldStores()
            } else {
                applyShieldingToAllStores(mode: resolution.mode, policy: policy)
            }
            updateSharedState(mode: resolution.mode)
            UserDefaults.appGroup?
                .set(Date().timeIntervalSince1970, forKey: "monitorEnforcementConfirmedAt")
            return
        }

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
            // Confirm enforcement applied via UserDefaults — main app polls this.
            UserDefaults.appGroup?
                .set(Date().timeIntervalSince1970, forKey: "monitorEnforcementConfirmedAt")
            logEvent(.policyReconciled, details: "On-demand enforcement: \(resolution.mode.rawValue) (\(resolution.reason))")
            // Signal tunnel to send a confirmation heartbeat — Monitor can't make network calls.
            // Parent sees the confirmed mode within 30s (tunnel's next liveness tick).
            UserDefaults.appGroup?
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

        // Legacy / other schedule — use ModeStackResolver for ground truth.
        // b513: was using profile.resolvedMode(at:) which reads raw schedule mode,
        // ignoring parent commands and temp unlocks. This caused locked shields
        // to be applied while a temp unlock was active.
        let resolution = ModeStackResolver.resolve(storage: storage)
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        if resolution.mode == .unlocked {
            clearAllShieldStores()
        } else {
            applyShieldingToAllStores(mode: resolution.mode, policy: policy)
        }
        updateSharedState(mode: resolution.mode)
        logEvent(.scheduleEnded, details: "Schedule ended: \(activity.rawValue) → \(resolution.mode.rawValue)")
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        checkEnforcementRefreshSignal()
        UserDefaults.appGroup?
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
        rearmEnforcementHeartbeat()

        if event.rawValue == "enforcement.heartbeat" {
            NSLog("[Monitor] Enforcement heartbeat fired — flag checked")
            return
        }

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

        // Per-app usage tracking for always-allowed apps.
        // Event name format: "appusage.<fingerprint8>.<minutes>"
        if activity.rawValue.hasPrefix("bigbrother.usagetracking"),
           event.rawValue.hasPrefix("appusage.") {
            handleAlwaysAllowedUsageMilestone(event: event)
            return
        }

        // Only handle global usage tracking events.
        guard activity.rawValue.hasPrefix("bigbrother.usagetracking"),
              event.rawValue.hasPrefix("usage.") else { return }

        // Parse the milestone minutes from the event name (e.g., "usage.120" -> 120).
        let minuteString = String(event.rawValue.dropFirst("usage.".count))
        guard let minutes = Int(minuteString) else { return }

        // b518: Monitor no longer writes screenTimeMinutes — tunnel is sole owner.
        // Store milestone separately for diagnostics only.
        let defaults = UserDefaults.appGroup
        let today = Self.todayDateString()
        let existingDate = defaults?.string(forKey: "monitorMilestoneDate")
        let existingMinutes = defaults?.integer(forKey: "monitorMilestoneMinutes") ?? 0
        if existingDate == today {
            if minutes > existingMinutes {
                defaults?.set(minutes, forKey: "monitorMilestoneMinutes")
            }
        } else {
            defaults?.set(today, forKey: "monitorMilestoneDate")
            defaults?.set(minutes, forKey: "monitorMilestoneMinutes")
        }

        // Record Monitor activity timestamp.
        let monitorDefaults = UserDefaults.appGroup
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

        UserDefaults.appGroup?
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

        UserDefaults.appGroup?
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

        // Use ModeStackResolver for ground truth — respects temp unlock, parent commands, etc.
        let resolution = ModeStackResolver.resolve(storage: storage)
        let mode = resolution.mode
        let policy = storage.readPolicySnapshot()?.effectivePolicy

        // Write snapshot FIRST so if extension is killed mid-operation,
        // the main app sees the intended state and won't undo it.
        writeCorrectedSnapshot(mode: mode, trigger: "Monitor: free window ended, mode → \(mode.rawValue) (\(resolution.reason))",
                               controlAuthority: resolution.controlAuthority)
        updateSharedState(mode: mode)

        if mode == .unlocked {
            clearAllShieldStores()
        } else {
            applyShieldingToAllStores(mode: mode, policy: policy)
        }
        if mode != .unlocked {
            UserDefaults.appGroup?
                .set(Date().timeIntervalSince1970, forKey: "lastNaturalRelockAt")
        }

        logEvent(.scheduleEnded, details: "Unlocked window ended, mode \(mode.rawValue) (\(resolution.reason))")
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

        // Temporary unlock or timed unlock active — don't override with schedule.
        if hasActiveTemporaryMode() { return }

        // Manual mode override — skip schedule-driven changes.
        if !AppConstants.isScheduleDriven() { return }

        UserDefaults.appGroup?
            .set("essentialStart", forKey: "lastShieldChangeReason")

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

        UserDefaults.appGroup?
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

        // Use ModeStackResolver for ground truth — respects temp unlock, parent commands, etc.
        let resolution = ModeStackResolver.resolve(storage: storage)
        let mode = resolution.mode

        // Write snapshot FIRST so if extension is killed mid-operation,
        // the main app sees the intended state and won't undo it.
        writeCorrectedSnapshot(mode: mode, trigger: "Monitor: locked window ended, mode → \(mode.rawValue) (\(resolution.reason))",
                               controlAuthority: resolution.controlAuthority)
        updateSharedState(mode: mode)

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        if mode == .unlocked {
            clearAllShieldStores()
        } else {
            applyShieldingToAllStores(mode: mode, policy: policy)
        }
        logEvent(.scheduleEnded, details: "Locked window ended, mode \(mode.rawValue) (\(resolution.reason))")
        sendModeNotification(
            title: "Locked Mode Ended",
            body: "Device returned to \(profile.lockedMode.displayName) mode."
        )
    }

    // MARK: - Timed Unlock (Penalty Offset)

    /// Penalty served — unlock the device.
    ///
    /// b459: must re-check the full mode stack before unlocking. A naive
    /// clearAllShieldStores at penalty end can unlock a device that was
    /// put into `.lockedDown` by the parent while the penalty timer was
    /// still running — the full resolver has to see the whole stack, not
    /// just the timed unlock bit. If resolver says we should still be
    /// locked, respect that and leave shields up.
    private func handleTimedUnlockStart(_ activity: DeviceActivityName) {
        let resolution = ModeStackResolver.resolve(storage: storage)
        if resolution.mode != .unlocked {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Timed unlock: penalty served but mode stack still resolves to \(resolution.mode.rawValue) — keeping shields UP",
                details: resolution.reason
            ))
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            applyShieldingToAllStores(mode: resolution.mode, policy: policy)
            updateSharedState(mode: resolution.mode)
            logEvent(.scheduleTriggered, details: "Timed unlock: penalty served but \(resolution.mode.rawValue) override — shields kept")
            return
        }
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
            UserDefaults.appGroup?
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
        let defaults = UserDefaults.appGroup

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
        let freshEnforcementStore = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreEnforcement))
        _ = freshEnforcementStore // Force init

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShieldingToAllStores(mode: mode, policy: policy)

        // Verify shields actually applied — .child FamilyControls auth can silently
        // reject ManagedSettings writes after temp unlock expiry. Retry with exponential
        // backoff up to ~30s total (Apple FC auth daemon can take 10-30s to re-validate).
        if mode != .unlocked && enforcementStore.shield.applicationCategories == nil {
            let retryDelays: [TimeInterval] = [2, 3, 5, 8, 13]
            for (i, delay) in retryDelays.enumerated() {
                logEvent(.enforcementDegraded, details: "Shield re-apply failed after temp unlock expiry — retry \(i + 1)/\(retryDelays.count) in \(Int(delay))s")
                Thread.sleep(forTimeInterval: delay)
                applyShieldingToAllStores(mode: mode, policy: policy)

                if enforcementStore.shield.applicationCategories != nil {
                    break // Shields applied successfully
                }
            }

            if enforcementStore.shield.applicationCategories == nil {
                logEvent(.enforcementDegraded, details: "Shield re-apply FAILED \(retryDelays.count)x after temp unlock expiry — scheduling fallback")
                // Write confirmed-down flag so tunnel can DNS-block immediately.
                // Companion timestamp marks this as fresh authoritative evidence.
                defaults?.set(false, forKey: "shieldsActiveAtLastHeartbeat")
                defaults?.set(Date().timeIntervalSince1970, forKey: "shieldsActiveAtLastHeartbeatAt")
                // Set refresh flag so the next Monitor callback retries immediately
                defaults?.set(true, forKey: "needsEnforcementRefresh")
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
    ///
    /// b459: clean up saved state FIRST so ModeStackResolver doesn't still
    /// see lockUntil as active on the next resolve, then use the full
    /// resolver (not just profile.resolvedMode) so any higher-priority
    /// state — parent lockedDown command, active temp unlock, etc. — is
    /// respected. The old path called `profile.resolvedMode(at: Date())`
    /// which knows only about the schedule and ignores parent overrides.
    /// That meant a parent who locked down the device while a lockUntil
    /// was active would have the device unlock when the lockUntil expired,
    /// because the profile thought it was in a free window.
    private func handleLockUntilExpired(_ activity: DeviceActivityName) {
        let defaults = UserDefaults.appGroup
        // Clean up saved state first so ModeStackResolver doesn't see
        // stale lockUntil bits when we call it below.
        defaults?.removeObject(forKey: "lockUntilPreviousMode")
        defaults?.removeObject(forKey: "lockUntilExpiresAt")

        let resolution = ModeStackResolver.resolve(storage: storage)
        let mode = resolution.mode

        // Write snapshot FIRST so if extension is killed mid-operation,
        // the main app sees the intended state and won't undo it.
        writeCorrectedSnapshot(
            mode: mode,
            trigger: "Monitor: lockUntil expired, mode → \(mode.rawValue) (\(resolution.reason))",
            controlAuthority: resolution.controlAuthority
        )
        updateSharedState(mode: mode)

        if mode == .unlocked {
            clearAllShieldStores()
        } else {
            let policy = storage.readPolicySnapshot()?.effectivePolicy
            applyShieldingToAllStores(mode: mode, policy: policy)
        }
        logEvent(.scheduleEnded, details: "Lock-until expired, mode: \(mode.rawValue) (\(resolution.reason))")
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

    /// Handle per-app usage milestone for always-allowed apps.
    /// Event name format: "appusage.<fingerprint8>.<minutes>"
    private func handleAlwaysAllowedUsageMilestone(event: DeviceActivityEvent.Name) {
        // Parse: "appusage.f042a04c.30" → fingerprint prefix "f042a04c", minutes 30
        let parts = event.rawValue.split(separator: ".")
        guard parts.count == 3,
              let minutes = Int(parts[2]) else { return }
        let fpPrefix = String(parts[1])

        // Find the full fingerprint — match by prefix from allowed tokens
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var matchedFingerprint: String?
        if let tokenData = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let tokens = try? decoder.decode(Set<ApplicationToken>.self, from: tokenData) {
            for token in tokens {
                if let encoded = try? encoder.encode(token) {
                    let fp = TokenFingerprint.fingerprint(for: encoded)
                    if fp.hasPrefix(fpPrefix) {
                        matchedFingerprint = fp
                        break
                    }
                }
            }
        }
        guard let fingerprint = matchedFingerprint else { return }

        // Update the usage snapshot
        let today = Self.todayDateString()
        var snapshot = storage.readAppUsageSnapshot() ?? AppUsageSnapshot(dateString: today)
        if snapshot.dateString != today {
            snapshot = AppUsageSnapshot(dateString: today)
        }

        let existing = snapshot.usageByFingerprint[fingerprint] ?? 0
        if minutes > existing {
            snapshot.usageByFingerprint[fingerprint] = minutes
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

        let tlContent = UNMutableNotificationContent()
        tlContent.title = "\(limit.appName) — Time's Up"
        tlContent.body = "Daily limit of \(limit.dailyLimitMinutes) minutes reached."
        tlContent.sound = .default
        let tlReq = UNNotificationRequest(
            identifier: "timelimit-\(limit.fingerprint)",
            content: tlContent, trigger: nil
        )
        UNUserNotificationCenter.current().add(tlReq)

        // Log event
        logEvent(.timeLimitExhausted, details: "\(limit.appName): \(limit.dailyLimitMinutes) min limit reached")

        UserDefaults.appGroup?
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

        UserDefaults.appGroup?
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
        // Check temp unlock file, then snapshot fallback (file reads can fail in extensions).
        let temp = storage.readTemporaryUnlockState()
            ?? storage.readPolicySnapshot()?.temporaryUnlockState
        if let temp, temp.expiresAt > now {
            return true
        }
        if let timed = storage.readTimedUnlockInfo(), now < timed.lockAt {
            return true
        }
        // Also check snapshot's isTemporaryUnlock flag as last resort.
        if let snapshot = storage.readPolicySnapshot(),
           snapshot.effectivePolicy.isTemporaryUnlock,
           let expiresAt = snapshot.effectivePolicy.temporaryUnlockExpiresAt,
           expiresAt > now {
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
        let defaults = UserDefaults.appGroup
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

        // Re-apply enforcement from current state.
        //
        // b459: when the refresh signal fires with resolver reporting
        // `.unlocked`, use applyWideOpenShields instead of destructively
        // clearing. This is a "refresh" — a best-effort sync — not a
        // definitive unlock event. If the resolver is wrong (stale temp
        // unlock file, race condition), a full clear here would drop
        // shields on a device that should still be locked. applyWideOpenShields
        // keeps the store populated with an `.all(except: everything)`
        // sentinel that functionally allows every app but leaves the
        // daemon's shield state non-nil, so the next real mode change can
        // apply shields without first rebuilding daemon context from
        // scratch. Matches the same decision we made for the main app's
        // forceDaemonRescue: only destructively clear when we're certain.
        let resolution = ModeStackResolver.resolve(storage: storage)
        let policy = storage.readPolicySnapshot()?.effectivePolicy

        if resolution.mode == .unlocked {
            applyWideOpenShields()
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

    // MARK: - Rolling Enforcement Heartbeat

    private func rearmEnforcementHeartbeat() {
        let center = DeviceActivityCenter()
        let activityName = DeviceActivityName(rawValue: "bigbrother.enforcementHeartbeat")

        let defaults = UserDefaults.appGroup
        let currentScreenMinutes = defaults?.integer(forKey: "screenTimeMinutes") ?? 0

        let nextThresholdSeconds = (currentScreenMinutes * 60) + 30
        let thresholdHours = nextThresholdSeconds / 3600
        let thresholdMinutes = (nextThresholdSeconds % 3600) / 60
        let thresholdSecs = nextThresholdSeconds % 60

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let event = DeviceActivityEvent(
            applications: [],
            categories: [],
            webDomains: [],
            threshold: DateComponents(hour: thresholdHours, minute: thresholdMinutes, second: thresholdSecs)
        )
        let eventName = DeviceActivityEvent.Name(rawValue: "enforcement.heartbeat")

        center.stopMonitoring([activityName])
        do {
            try center.startMonitoring(activityName, during: schedule, events: [eventName: event])
        } catch {
            NSLog("[Monitor] Failed to rearm enforcement heartbeat: \(error.localizedDescription)")
        }
    }

    // MARK: - Reconciliation

    /// Verify enforcement matches the mode stack.
    /// Uses ModeStackResolver for deterministic mode resolution from App Group files.
    /// Also cleans up expired temporary state as a side effect.
    private func reconcile() {
        let reconcileDefaults = UserDefaults.appGroup
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

        // Apply the resolved mode.
        //
        // b459: reconcile() is a PERIODIC safety net — not a definitive
        // mode-change event. When the resolver reports `.unlocked` here,
        // use `applyWideOpenShields` instead of `clearAllShieldStores`.
        // Reconciliation runs every few minutes on various Monitor
        // callbacks; if it ever misreads the current mode (stale temp
        // unlock file, race with main-app writes), a hard clear would
        // drop shields on a locked device. applyWideOpenShields leaves
        // the shield store populated so the daemon keeps context and
        // the next real mode change re-applies cleanly. Definitive
        // unlock events (handleUnlockedWindowStart, handleTimedUnlockStart)
        // still use clearAllShieldStores — those are explicit transitions.
        if resolution.mode == .unlocked {
            applyWideOpenShields()
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
        let defaults = UserDefaults.appGroup
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

    /// Apply "wide open" shields — allows everything but keeps the enforcement store non-nil.
    /// Avoids the clear-then-reapply race that silently breaks .child auth.
    private func applyWideOpenShields() {
        // Don't allow unlock if FamilyControls authorization is lost.
        let defaults = UserDefaults.appGroup
        let snapshot = storage.readPolicySnapshot()
        let fcRevoked = snapshot?.authorizationHealth?.isAuthorized == false
        // Use enforcement-critical flag (FC + location only), NOT allPermissionsGranted
        // which includes non-critical permissions (motion, VPN, notifications).
        // Missing notifications should NOT cause the device to be force-locked.
        let enforcementPermsMissing = defaults?.object(forKey: "enforcementPermissionsOK") as? Bool == false
        if fcRevoked || (enforcementPermsMissing && snapshot?.authorizationHealth == nil) {
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

        // Set .all(except: everything) on the enforcement store — keeps it non-nil
        enforcementStore.shield.applications = nil
        enforcementStore.shield.applicationCategories = allTokens.isEmpty ? nil : .all(except: allTokens)
        enforcementStore.shield.webDomainCategories = nil
        enforcementStore.shield.webDomains = nil

        // Clear the default store
        let defaultStore = ManagedSettingsStore()
        defaultStore.shield.applications = nil
        defaultStore.shield.applicationCategories = nil
        defaultStore.shield.webDomainCategories = nil
        defaultStore.shield.webDomains = nil

        // b459: set the shieldStoreWideOpen flag so the app-side
        // shieldDiagnostic() recognizes this populated-but-functionally-open
        // store as "not shielded". Without this, the main app's periodic
        // verifier would see `applicationCategories != nil` after the
        // Monitor wrote wide-open, decide shields were wrongly UP in
        // unlocked mode, and "fix" it with a destructive clear —
        // reintroducing the relock-failure race that applyWideOpenShields
        // existed to avoid in the first place. Keeping the flag in sync
        // across processes closes that cross-process divergence.
        defaults?.set(true, forKey: "shieldStoreWideOpen")

        // Clear DNS blocklists
        try? storage.writeEnforcementBlockedDomains([])
        try? storage.writeTimeLimitBlockedDomains([])
    }

    /// Clear shield properties on the enforcement store + default store.
    /// NOTE: This fully clears stores to nil. Only used when the intent is to immediately
    /// re-apply via applyShieldingToAllStores (which overwrites the enforcement store).
    ///
    /// b434 (audit fix): Added parity with main app's clearAllShieldStores —
    /// also clears the probe recovery store (enforcement.recovery) AND clears
    /// legacy stores (base, schedule, tempUnlock) on every call, not just
    /// during one-time migration. "Most-restrictive wins" merge means any
    /// stale data in any store will keep shields active even after our
    /// explicit clear of the primary enforcement store.
    private func clearAllShieldStores() {
        enforcementStore.shield.applications = nil
        enforcementStore.shield.applicationCategories = nil
        enforcementStore.shield.webDomainCategories = nil
        enforcementStore.shield.webDomains = nil
        enforcementStore.webContent.blockedByFilter = nil

        let defaultStore = ManagedSettingsStore()
        defaultStore.shield.applications = nil
        defaultStore.shield.applicationCategories = nil
        defaultStore.shield.webDomainCategories = nil
        defaultStore.shield.webDomains = nil

        // Defensive clear of the recovery probe store (see
        // EnforcementServiceImpl.clearAllShieldStores for full rationale).
        let recoveryStore = ManagedSettingsStore(named: .init("enforcement.recovery"))
        recoveryStore.shield.applications = nil
        recoveryStore.shield.applicationCategories = nil
        recoveryStore.shield.webDomainCategories = nil
        recoveryStore.shield.webDomains = nil

        // Clear legacy named stores on every call (not just during migration).
        for name in AppConstants.legacyStoreNames {
            let legacy = ManagedSettingsStore(named: .init(name))
            legacy.shield.applications = nil
            legacy.shield.applicationCategories = nil
            legacy.shield.webDomainCategories = nil
            legacy.shield.webDomains = nil
        }

        // Clear BOTH DNS blocklists — enforcement AND time-limit.
        try? storage.writeEnforcementBlockedDomains([])
        try? storage.writeTimeLimitBlockedDomains([])
    }

    /// Apply shields to the enforcement store using the hybrid per-app + category strategy.
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
        let defaults = UserDefaults.appGroup

        // b459: clear the shieldStoreWideOpen flag — real shields are about
        // to be applied. If Monitor previously wrote wide-open sentinel and
        // set the flag, leaving it set would make the main-app shieldDiagnostic
        // falsely report "no shields active" even after we've populated the
        // store with real category shields. Matches the main app's own
        // applyShield which also clears this flag on entry.
        defaults?.set(false, forKey: "shieldStoreWideOpen")

        // Force essential mode only if FamilyControls authorization is missing.
        // The enforcementPermissionsOK flag is now FC-only (post-b444 fix).
        // Location/motion/VPN/notifications are NOT enforcement-critical and
        // must NOT cause restricted-mode commands to silently promote to locked.
        let effectiveMode: LockMode
        if defaults?.object(forKey: "enforcementPermissionsOK") as? Bool == false && mode != .locked {
            effectiveMode = .locked
        } else {
            effectiveMode = mode
        }

        // Clear the default store to remove stale shields from other contexts.
        // The enforcement store is overwritten below in all code paths.
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
            let alwaysAllowedForShielding: Set<ApplicationToken> = allowExemptions ? [] : {
                guard let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                      let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data)
                else { return [] }
                return tokens
            }()

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
            let shouldBlockWeb = !allowExemptions || restrictions.denyWebWhenRestricted

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
                // Apply to the enforcement store. Empty set → nil for parity
                // with main app: Apple treats them equivalently in docs, but
                // nil is the canonical "no explicit apps" value and avoids
                // any implementation-defined cache behavior.
                enforcementStore.shield.applications = perAppTokens.isEmpty ? nil : perAppTokens
                enforcementStore.shield.applicationCategories = .all(except: allowedTokens)
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Monitor applyShieldingToAllStores WROTE: shield.applications=\(perAppTokens.count) + .all(except: \(allowedTokens.count))"
                ))
                if shouldBlockWeb {
                    enforcementStore.shield.webDomainCategories = .all()
                    enforcementStore.webContent.blockedByFilter = .all()
                } else {
                    enforcementStore.shield.webDomainCategories = nil
                    enforcementStore.webContent.blockedByFilter = nil
                }
            } else {
                var apps: Set<ApplicationToken>? = allowExemptions ? nil : (pickerTokens.isEmpty ? nil : pickerTokens)
                if !alwaysAllowedForShielding.isEmpty {
                    apps = (apps ?? Set()).union(alwaysAllowedForShielding)
                }
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
                enforcementStore.shield.applications = (apps?.isEmpty == true) ? nil : apps
                if allowedTokens.isEmpty {
                    enforcementStore.shield.applicationCategories = .all()
                } else {
                    enforcementStore.shield.applicationCategories = .all(except: allowedTokens)
                }
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Monitor applyShieldingToAllStores WROTE: shield.applications=\(apps?.count ?? 0) + \(allowedTokens.isEmpty ? ".all()" : ".all(except: \(allowedTokens.count))")"
                ))
                if shouldBlockWeb {
                    enforcementStore.shield.webDomainCategories = .all()
                    enforcementStore.webContent.blockedByFilter = .all()
                } else {
                    enforcementStore.shield.webDomainCategories = nil
                    enforcementStore.webContent.blockedByFilter = nil
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
        // b513: was overriding the caller's mode with profile.resolvedMode(at:),
        // which reads raw schedule mode and ignores parent commands/temp unlocks.
        // Now respects the mode passed in (should come from ModeStackResolver).
        if storage.readActiveScheduleProfile() != nil {
            applyShieldingToAllStores(mode: mode, policy: policy)
            return
        }

        switch mode {
        case .unlocked:
            enforcementStore.clearAllSettings()

        case .restricted, .locked, .lockedDown:
            let allowExemptions = mode == .restricted
            let allowedTokens = allowExemptions ? collectAllowedTokens() : []
            if allowedTokens.isEmpty {
                enforcementStore.shield.applicationCategories = .all()
            } else {
                enforcementStore.shield.applicationCategories = .all(except: allowedTokens)
            }
            let restrictions = storage.readDeviceRestrictions() ?? DeviceRestrictions()
            if restrictions.denyWebWhenRestricted {
                enforcementStore.shield.webDomainCategories = .all()
                // Note: per-domain exceptions require WebDomainTokens (picker-selected).
                // Domain allowlist is enforced at the VPN/DNS layer.
            } else {
                enforcementStore.shield.webDomainCategories = nil
            }
        }
    }

    /// Collect parent-approved tokens from App Group storage.
    /// Mirrors EnforcementServiceImpl.collectAllowedTokens().
    private func collectAllowedTokens() -> Set<ApplicationToken> {
        let decoder = JSONDecoder()
        var tokens = Set<ApplicationToken>()

        // Permanently allowed apps — try direct file first.
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            tokens.formUnion(allowed)
        }

        // Fallback: if file read returned empty, try the snapshot's embedded token data.
        // The snapshot is a single JSON file that the main app writes atomically.
        // This handles cases where App Group file reads are unreliable
        // (e.g., CFPrefsPlistSource detach after iCloud changes).
        if tokens.isEmpty,
           let snapshot = storage.readPolicySnapshot(),
           let tokenData = snapshot.effectivePolicy.allowedAppTokensData,
           !tokenData.isEmpty,
           let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: tokenData) {
            tokens.formUnion(allowed)
            NSLog("[Monitor] collectAllowedTokens: file read empty, loaded \(allowed.count) from snapshot fallback")
        }

        // Temporarily allowed apps (non-expired only).
        let tempEntries = storage.readTemporaryAllowedApps()
        for entry in tempEntries where entry.isValid {
            if let token = try? decoder.decode(ApplicationToken.self, from: entry.tokenData) {
                tokens.insert(token)
            }
        }

        NSLog("[Monitor] collectAllowedTokens: \(tokens.count) total (\(tokens.count) permanent + temp)")
        return tokens
    }

    // MARK: - Notifications

    /// Last mode we notified about — prevents repeated notifications for the same mode.
    /// Persisted in App Group so it survives Monitor process restarts.
    private var lastNotifiedMode: String? {
        get { UserDefaults.appGroup?.string(forKey: "monitorLastNotifiedMode") }
        set { UserDefaults.appGroup?.set(newValue, forKey: "monitorLastNotifiedMode") }
    }

    private func sendModeNotification(title: String, body: String) {
        // b518: Monitor no longer sends mode-change notifications.
        // The main app's ModeChangeNotifier handles all user-facing mode
        // notifications with persisted dedup. Monitor firing its own
        // caused guaranteed duplicates (different identifier).
        // Exception: time-limit "Time's Up" notifications still use
        // sendTimeLimitNotification() below.
    }

    /// Request an immediate heartbeat from the main app by writing a flag to App Group.
    /// The main app checks this every 30 seconds and sends a forced heartbeat if set.
    private func requestHeartbeat() {
        let defaults = UserDefaults.appGroup
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

        // Always reload allowed tokens from the file, not from the previous snapshot.
        // The previous snapshot may have been for unlocked mode where allowedAppTokensData
        // is nil. Using stale nil data causes the Monitor to lose token exemptions
        // when transitioning unlocked → restricted.
        let freshAllowedTokensData: Data? = {
            if mode == .unlocked { return nil } // no tokens needed for unlocked
            if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens), !data.isEmpty {
                return data
            }
            // Fall back to existing snapshot data if file read fails
            return basePolicy?.allowedAppTokensData
        }()

        // Preserve temp unlock state through snapshot writes.
        // Without this, ModeStackResolver's snapshot fallback loses the temp unlock
        // and resolves to restricted/locked instead of unlocked.
        //
        // b459: `isTemporaryUnlock` means "the resolved mode is currently
        // unlocked because of a temp unlock override". It MUST NOT be true
        // when `mode == .locked` / `.restricted` / `.lockedDown`. The old
        // code set it true purely based on the existence of a temp unlock
        // file, which is wrong when the Monitor is writing a corrected
        // snapshot for a locked-window transition: the file may still be
        // present but the caller is explicitly moving to a non-unlocked
        // mode. Setting the flag true then caused downstream readers (like
        // the old apply()'s isTemporaryUnlock early-return, now removed)
        // to clear shields on a locked device. That's one of the random
        // shield-drop paths the user reported.
        let currentTempUnlock: TemporaryUnlockState? = storage.readTemporaryUnlockState()
            ?? existing?.temporaryUnlockState
        let tempUnlockActive = currentTempUnlock != nil && currentTempUnlock!.expiresAt > Date()
        let isTempUnlock = tempUnlockActive && mode == .unlocked

        let corrected = EffectivePolicy(
            resolvedMode: mode,
            controlAuthority: controlAuthority,
            isTemporaryUnlock: isTempUnlock,
            temporaryUnlockExpiresAt: isTempUnlock ? currentTempUnlock?.expiresAt : nil,
            shieldedCategoriesData: basePolicy?.shieldedCategoriesData,
            allowedAppTokensData: freshAllowedTokensData,
            deviceRestrictions: basePolicy?.deviceRestrictions ?? storage.readDeviceRestrictions(),
            warnings: basePolicy?.warnings ?? [],
            policyVersion: (basePolicy?.policyVersion ?? 0) + 1
        )
        let snapshot = PolicySnapshot(
            source: .scheduleTransition,
            trigger: trigger,
            effectivePolicy: corrected,
            temporaryUnlockState: currentTempUnlock
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
        // Write shield state for tunnel's enforcement verifier.
        // The companion timestamp lets the tunnel distinguish "fresh evidence from
        // Monitor" from "stale flag during a transition" and suppress false
        // "shields down" alerts while Monitor is still applying the new mode.
        let auditDefaults = UserDefaults.appGroup
        auditDefaults?.set(mode != .unlocked, forKey: "shieldsActiveAtLastHeartbeat")
        auditDefaults?.set(Date().timeIntervalSince1970, forKey: "shieldsActiveAtLastHeartbeatAt")

        // Shield audit fingerprint — tracks that the Monitor applied shields and WHY.
        let auditSource: String
        if let reason = auditDefaults?.string(forKey: "lastShieldChangeReason") {
            auditSource = "monitor.\(reason)"
        } else {
            auditSource = "monitor"
        }
        let tokenCount = mode == .unlocked ? 0 : collectAllowedTokens().count
        let audit = "\(auditSource)|\(mode.rawValue)|\(mode != .unlocked ? "UP" : "DOWN")|\(tokenCount)tokens|\(Int(Date().timeIntervalSince1970))"
        auditDefaults?.set(audit, forKey: "lastShieldAudit")
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
        let defaults = UserDefaults.appGroup

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

        let defaults = UserDefaults.appGroup
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
        let defaults = UserDefaults.appGroup
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
    ///
    /// b462: two substantive changes after finding Olivia/Daphne/Juliet
    /// stuck in a 24-hour build-mismatch blackhole:
    ///   1. GRACE PERIOD. A fresh install+launch from `devicectl` leaves
    ///      a window where the Monitor extension is on the new binary but
    ///      the main app hasn't relaunched yet. Previously this fired
    ///      immediately and blackholed the device before the main app's
    ///      `setupOnLaunch` had a chance to update
    ///      `mainAppLastLaunchedBuild`. Now we only act on a mismatch
    ///      that's been detected for at least 10 minutes — that's way
    ///      more than any install→launch window, and it's short enough
    ///      that a kid who actually never opens BB for 10 min after an
    ///      update still gets the protection.
    ///   2. SHORTER TTL. The `internetBlockedUntil` was 24 h. That's
    ///      absurd — if the main app doesn't launch in 2 h after a build
    ///      push, either something's badly wrong (parent should look) or
    ///      the kid's asleep (fire again on next wake). Capping at 2 h
    ///      means even if every other safety path fails, the kid gets
    ///      internet back before the school day is over. Also now backed
    ///      by the 5 s `.parentCommand` invariant in the tunnel which
    ///      clears the in-memory reason if the flag is gone.
    private func checkAppLaunchNeeded() {
        let defaults = UserDefaults.appGroup
        let mainAppBuild = defaults?.integer(forKey: "mainAppLastLaunchedBuild") ?? 0
        let extensionBuild = AppConstants.appBuildNumber

        // Main app has launched with this build — clear any build-mismatch DNS block.
        guard mainAppBuild < extensionBuild else {
            // Mismatch resolved — remove the DNS block flag if we set it.
            if defaults?.bool(forKey: "buildMismatchDNSBlock") == true {
                defaults?.removeObject(forKey: "buildMismatchDNSBlock")
                defaults?.removeObject(forKey: "internetBlockedUntil")
                defaults?.removeObject(forKey: "monitorBuildMismatchFirstSeenAt")
            }
            return
        }

        // b462 grace period: require the mismatch to have been visible
        // for at least 10 minutes before we take any destructive action.
        // Use the monitor's own first-seen timestamp so we can reset it
        // when the mismatch clears.
        let now = Date().timeIntervalSince1970
        let firstSeen = defaults?.double(forKey: "monitorBuildMismatchFirstSeenAt") ?? 0
        if firstSeen <= 0 {
            defaults?.set(now, forKey: "monitorBuildMismatchFirstSeenAt")
            logEvent(.policyReconciled, details: "Post-update mismatch first-seen (main=\(mainAppBuild) ext=\(extensionBuild)) — starting 10 min grace")
            return
        }
        let mismatchAge = now - firstSeen
        if mismatchAge < 600 {
            // Still within grace. Don't blackhole yet.
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
        // checks this flag every 30 seconds. 2 h TTL (was 24 h) so even
        // if every clearance path fails, the kid gets internet back within
        // a school period instead of an entire day.
        if defaults?.bool(forKey: "buildMismatchDNSBlock") != true {
            defaults?.set(true, forKey: "buildMismatchDNSBlock")
            let blockUntil = Date().addingTimeInterval(2 * 3600).timeIntervalSince1970
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

    /// Check if reconciliation AND schedule window activities are registered.
    /// Re-register if missing. Called on every Monitor callback to self-heal
    /// after app installs which kill all DeviceActivity registrations (R9).
    private func ensureReconciliationRegistered() {
        let center = DeviceActivityCenter()
        let allActivities = center.activities

        // 1. Reconciliation quarters (4 expected)
        let reconciliationCount = allActivities.filter { $0.rawValue.hasPrefix("bigbrother.reconciliation.q") }.count
        if reconciliationCount < 4 {
            NSLog("[Monitor] Reconciliation incomplete (\(reconciliationCount)/4) — re-registering")
            reregisterReconciliationSchedule()
            reconcile()
        }

        // 2. Schedule window activities — re-register from stored profile if missing.
        // Without these, schedule transitions (free window start/end) never fire.
        let scheduleCount = allActivities.filter {
            $0.rawValue.hasPrefix("bigbrother.scheduleprofile.") || $0.rawValue.hasPrefix("bigbrother.essentialwindow.")
        }.count
        if scheduleCount == 0, let profile = storage.readActiveScheduleProfile() {
            NSLog("[Monitor] Schedule window activities MISSING — re-registering from \(profile.name)")
            reregisterScheduleWindows(profile: profile, center: center)
        }
    }

    /// Re-register schedule window DeviceActivity entries from a stored ScheduleProfile.
    /// Mirrors ScheduleRegistrar.register() logic but callable from the Monitor extension.
    private func reregisterScheduleWindows(profile: ScheduleProfile, center: DeviceActivityCenter) {
        let unlockPrefix = "bigbrother.scheduleprofile."
        let lockPrefix = "bigbrother.essentialwindow."

        for window in profile.unlockedWindows {
            registerScheduleWindow(window, prefix: unlockPrefix, center: center)
        }
        for window in profile.lockedWindows {
            registerScheduleWindow(window, prefix: lockPrefix, center: center)
        }

        let count = center.activities.filter {
            $0.rawValue.hasPrefix(unlockPrefix) || $0.rawValue.hasPrefix(lockPrefix)
        }.count
        NSLog("[Monitor] Re-registered \(count) schedule window activities")
    }

    private func registerScheduleWindow(_ window: ActiveWindow, prefix: String, center: DeviceActivityCenter) {
        if window.startTime < window.endTime {
            // Same-day window
            let name = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)")
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
                intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
                repeats: true
            )
            try? center.startMonitoring(name, during: schedule)
        } else {
            // Cross-midnight — split into evening + morning
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
