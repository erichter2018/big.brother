import Foundation
import ManagedSettings
import FamilyControls
import DeviceActivity
import UserNotifications
import BigBrotherCore

/// Concrete enforcement service bridging PolicyResolver output to ManagedSettings.
///
/// Uses a single named ManagedSettingsStore ("enforcement") for all shield writes.
/// Legacy stores (base, schedule, tempUnlock) are cleared on first launch via migration.
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

    /// b436 (audit fix): Class-level lock serializing all enforcement writes
    /// within the main app process. apply(), clearAllRestrictions(),
    /// clearTemporaryUnlock(), applyEssentialOnly(), and forceDaemonRescue()
    /// all acquire this lock for the duration of their work.
    ///
    /// **Why static:** Multiple EnforcementServiceImpl instances can exist in
    /// the process simultaneously (e.g., AppDelegate creates its own, AppState
    /// holds another, AppLaunchRestorer receives one). All of them write to
    /// the same underlying ManagedSettingsStore (same name), so concurrent
    /// writes from different instances still race. A static lock is shared
    /// across all instances in the process.
    ///
    /// **Cross-process note:** The Monitor extension is a SEPARATE PROCESS
    /// with its own lock instance. This lock does NOT synchronize main-app
    /// writes with Monitor writes — that would require file-based locking
    /// (NSFileCoordinator) which is out of scope for this fix.
    ///
    /// **Deep rescue note:** attemptDeepDaemonRescue has Thread.sleep calls
    /// totaling ~6 seconds. While rescue is running, other apply() calls on
    /// other threads will wait. That's acceptable — shields take priority,
    /// and rescue is rare. To avoid blocking the main thread for 6 seconds,
    /// callers should dispatch rescue to a background queue (forceDaemonRescue
    /// already does this via Task.detached).
    private static let applyLock = NSLock()
    private static var lastApplyMode: LockMode?
    static private(set) var lastApplyTime: Date?

    /// FRESH store instance created on every access — never cached.
    /// ManagedSettingsStore communicates with the system daemon via XPC.
    /// Cached instances have stale XPC connections after the app is backgrounded,
    /// causing writes to silently fail. Fresh instances establish fresh connections.
    private var enforcementStore: ManagedSettingsStore {
        ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreEnforcement))
    }

    /// Clear legacy named stores (base, schedule, tempUnlock) on first launch.
    /// ManagedSettings merges across stores, so stale data in any legacy store
    /// would override the new single-store enforcement.
    private func migrateLegacyStoresIfNeeded() {
        let defaults = UserDefaults.appGroup
        guard defaults?.bool(forKey: "migratedToSingleStore") != true else { return }
        for name in AppConstants.legacyStoreNames {
            ManagedSettingsStore(named: .init(name)).clearAllSettings()
        }
        defaults?.set(true, forKey: "migratedToSingleStore")
        NSLog("[Enforcement] Migrated: cleared legacy stores (base, schedule, tempUnlock)")
    }
    private let storage: any SharedStorageProtocol
    private let fcManager: any FamilyControlsManagerProtocol

    /// Throttle nuclear resets to prevent infinite clear/re-apply loops.
    /// Reset on each fresh app launch (resetThrottle()) so deploy restarts get a clean slate.
    private var nuclearResetCount = 0
    private var nuclearResetWindowStart = Date()

    /// Reset the nuclear throttle counter. Call on each fresh app launch.
    func resetThrottle() {
        nuclearResetCount = 0
        nuclearResetWindowStart = Date()
    }

    /// Gated daemon rescue. Called from AppState.performForegroundSync on
    /// every foreground wake. Previously ran unconditionally on every
    /// foreground — the comment literally said "running daemon rescue
    /// unconditionally" — which was responsible for the user-reported
    /// "shields randomly get dropped" issue. The rescue sequence is
    /// destructive (clearAllShieldStores + clearAllSettings, then re-apply),
    /// so running it every foreground on a perfectly healthy daemon opened
    /// a small window where shields were momentarily DOWN. If the re-apply
    /// silently failed for any reason (background-vs-foreground timing,
    /// transient FC daemon busy state, XPC hiccup), shields stayed DOWN
    /// until the next mode change — forcing manual intervention.
    ///
    /// b459 rewrite:
    ///   1. Read current shield state FIRST (cheap, non-destructive).
    ///   2. If shields already match what the policy says they should be,
    ///      return early. The daemon is healthy; don't touch it.
    ///   3. Only if there's a real mismatch do we run the destructive
    ///      rescue sequence.
    ///   4. Use policy.resolvedMode as the ground truth. Do NOT use
    ///      policy.isTemporaryUnlock — that flag is set by several writer
    ///      paths (Monitor, heartbeat reconcile, verifyAndFixEnforcement)
    ///      that mistakenly copy `resolution.isTemporary` from
    ///      ModeStackResolver even for lockUntil/timedUnlock states where
    ///      `mode == .restricted`. Trusting it would compute
    ///      expectedShielded=false for a locked-down device and then
    ///      happily clear shields.
    func forceDaemonRescue() {
        Self.applyLock.lock()
        defer { Self.applyLock.unlock() }
        guard let snapshot = storage.readPolicySnapshot() else {
            NSLog("[Enforcement] forceDaemonRescue: no snapshot, skipping")
            return
        }
        let policy = snapshot.effectivePolicy
        // Ground truth: derive expectedShielded from resolvedMode ALONE.
        // See class comment above for why we don't read isTemporaryUnlock.
        let expectedShielded = policy.resolvedMode != .unlocked

        // Non-destructive pre-check: is the daemon actually wedged?
        let preDiag = shieldDiagnostic()
        let isShielded = preDiag.shieldsActive || preDiag.categoryActive
        if isShielded == expectedShielded {
            // Healthy: state matches policy. Don't touch the daemon.
            // Just refresh the audit flag so the next heartbeat sees fresh.
            let shieldDefaults = UserDefaults.appGroup
            shieldDefaults?.set(isShielded, forKey: "shieldsActiveAtLastHeartbeat")
            shieldDefaults?.set(Date().timeIntervalSince1970, forKey: "shieldsActiveAtLastHeartbeatAt")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Foreground rescue SKIPPED — healthy",
                details: "mode=\(policy.resolvedMode.rawValue), shields=\(isShielded ? "UP" : "DOWN") already matches expected=\(expectedShielded ? "UP" : "DOWN"). Not touching the daemon."
            ))
            return
        }

        // Mismatch — the daemon really is wedged. Rescue is justified.
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "Foreground rescue triggered — real mismatch",
            details: "mode=\(policy.resolvedMode.rawValue), shields=\(isShielded ? "UP" : "DOWN") does NOT match expected=\(expectedShielded ? "UP" : "DOWN"). Running attemptDeepDaemonRescue."
        ))
        let rescueSucceeded = attemptDeepDaemonRescue(expectedShielded: expectedShielded, policy: policy)

        // Regardless of whether rescue "succeeded" per the verifier, write the
        // current actual shield state to the audit flags so the next heartbeat
        // reflects reality. Without this, a stale pre-rescue audit would
        // continue to report until the next normal apply() call.
        let postDiag = shieldDiagnostic()
        let postIsShielded = postDiag.shieldsActive || postDiag.categoryActive
        let shieldDefaults = UserDefaults.appGroup
        shieldDefaults?.set(postIsShielded, forKey: "shieldsActiveAtLastHeartbeat")
        shieldDefaults?.set(Date().timeIntervalSince1970, forKey: "shieldsActiveAtLastHeartbeatAt")
        let audit = "app.rescue|\(policy.resolvedMode.rawValue)|\(postIsShielded ? "UP" : "DOWN")|\(postDiag.appCount)apps|\(Int(Date().timeIntervalSince1970))"
        shieldDefaults?.set(audit, forKey: "lastShieldAudit")
        shieldDefaults?.set("rescue", forKey: "lastShieldChangeReason")

        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "Foreground rescue complete — \(rescueSucceeded ? "SUCCEEDED" : "FAILED")",
            details: "Post-rescue: shields=\(postDiag.shieldsActive), cat=\(postDiag.categoryActive), apps=\(postDiag.appCount), expected=\(expectedShielded ? "UP" : "DOWN")"
        ))
    }

    init(
        storage: any SharedStorageProtocol = AppGroupStorage(),
        fcManager: any FamilyControlsManagerProtocol
    ) {
        self.storage = storage
        self.fcManager = fcManager
    }

    // MARK: - EnforcementServiceProtocol

    func apply(_ policy: EffectivePolicy) throws {
        Self.applyLock.lock()
        defer { Self.applyLock.unlock() }

        let now = Date()
        if let lastMode = Self.lastApplyMode,
           let lastTime = Self.lastApplyTime,
           lastMode == policy.resolvedMode,
           now.timeIntervalSince(lastTime) < 10.0 {
            return
        }

        NSLog("[Enforcement] apply() START — mode=\(policy.resolvedMode.rawValue) isTemp=\(policy.isTemporaryUnlock)")

        // Timing: record the exact instants around the ManagedSettings write
        // so the automated test harness can separate apply latency from
        // CloudKit delivery latency. The paired `applyFinishedAt` write lives
        // at the end of this method.
        let applyStartedAt = Date()
        let applyDefaults = UserDefaults.appGroup
        applyDefaults?.set(applyStartedAt.timeIntervalSince1970, forKey: "enforcementApplyStartedAt")

        migrateLegacyStoresIfNeeded()

        // Auth warm-up: touch authorizationStatus to wake the FamilyControls XPC daemon.
        let authStatus = authorizationStatus
        NSLog("[Enforcement] authStatus=\(authStatus) — XPC warmup (no sleep)")

        let defaults = UserDefaults.appGroup
        defaults?.set("apply", forKey: "lastShieldChangeReason")
        defaults?.set(Date().timeIntervalSince1970, forKey: "mainAppEnforcementAt")
        defer {
            // Written unconditionally at return — covers both the temp-unlock
            // early return and the regular end-of-method path.
            applyDefaults?.set(Date().timeIntervalSince1970, forKey: "enforcementApplyFinishedAt")
        }

        applyRestrictions(policy.deviceRestrictions)

        // b459: removed the `if policy.isTemporaryUnlock` early-return that
        // used to live here. It was conflated with the `resolvedMode == .unlocked`
        // case but READ the wrong field: if a caller constructed an
        // EffectivePolicy with `isTemporaryUnlock=true, resolvedMode=.restricted`
        // (which happens in Monitor/heartbeatReconcile/verifyAndFixEnforcement
        // paths that naively map ModeStackResolver.Resolution.isTemporary),
        // apply() would clearAllShieldStores even though mode is restricted.
        // That is one of the shield-drop paths the user reported.
        //
        // The switch below is the canonical source of truth: clear iff mode
        // is actually unlocked, apply shields iff mode is anything else.
        // The verify/audit/config paths that follow the switch now run
        // unconditionally regardless of isTemporaryUnlock, which also means
        // shield diagnostics get updated correctly on every apply() call.

        switch policy.resolvedMode {
        case .unlocked:
            NSLog("[Enforcement] clearing all shields (unlocked)")
            clearAllShieldStores()
            recordShieldedAppCount(0)

        case .restricted, .locked, .lockedDown:
            NSLog("[Enforcement] applying shields for \(policy.resolvedMode.rawValue)")
            applyShield(allowExemptions: policy.resolvedMode == .restricted, policyRestrictions: policy.deviceRestrictions)
        }

        Self.lastApplyMode = policy.resolvedMode
        Self.lastApplyTime = Date()

        // Verify the write actually stuck
        let diagResult = shieldDiagnostic()
        let shouldBeShielded = policy.resolvedMode != .unlocked
        let isShielded = diagResult.shieldsActive || diagResult.categoryActive
        NSLog("[Enforcement] apply() DONE — shields=\(diagResult.shieldsActive) cat=\(diagResult.categoryActive) shouldBeShielded=\(shouldBeShielded) match=\(shouldBeShielded == isShielded)")

        // Write actual shield state so the tunnel can verify enforcement consistency.
        // Companion timestamp lets the tunnel distinguish fresh Monitor/app writes
        // from stale flags during a mode transition.
        let shieldDefaults = UserDefaults.appGroup
        shieldDefaults?.set(isShielded, forKey: "shieldsActiveAtLastHeartbeat")
        shieldDefaults?.set(Date().timeIntervalSince1970, forKey: "shieldsActiveAtLastHeartbeatAt")

        // Shield audit fingerprint — tracks WHO applied shields and WHY.
        let audit = "app|\(policy.resolvedMode.rawValue)|\(isShielded ? "UP" : "DOWN")|\(diagResult.appCount)apps|\(Int(Date().timeIntervalSince1970))"
        shieldDefaults?.set(audit, forKey: "lastShieldAudit")

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
        // b459: derive expectedShielded from resolvedMode ALONE. Trusting
        // `policy.isTemporaryUnlock` would compute the wrong expected
        // state for lockUntil / timedUnlock-penalty snapshots where the
        // flag was historically set true even though the resolved mode
        // was .restricted. (Same root cause as the forceDaemonRescue fix
        // above — see class-level comment on forceDaemonRescue.)
        let diag = shieldDiagnostic()
        let expectedShielded = policy.resolvedMode != .unlocked
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
        if expectedShielded == diag.shieldsActive && !modeInconsistent {
            // Verification passed — clear any degraded flag from a previous episode.
            let degradedDefaults = UserDefaults.appGroup
            if degradedDefaults?.bool(forKey: "fcAuthDegraded") == true {
                degradedDefaults?.removeObject(forKey: "fcAuthDegraded")
                degradedDefaults?.removeObject(forKey: "fcAuthDegradedAt")
                degradedDefaults?.removeObject(forKey: "fcAuthDegradedNotificationSent")
                NSLog("[Enforcement] FC auth recovered — ManagedSettings writes working again")
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .auth,
                    message: "FC auth recovered — ManagedSettings writes working again"
                ))
            }
        }

        // b459: double-check with a small delay before declaring failure.
        // ManagedSettings reads go through XPC to ScreenTimeAgent. A read
        // immediately after a write often returns stale data — not because
        // the write failed, but because the agent hasn't published the
        // change yet. The old code treated that stale read as a real
        // failure, ran the destructive clearAllSettings+reset recovery
        // path, and left shields down if the subsequent reapply hit any
        // hiccup. Spending ~200ms on a confirming read is MUCH cheaper
        // than the nuclear reset, and eliminates the false-positive
        // recovery path that was a major shield-drop vector.
        var doubleCheckedFailure = false
        if expectedShielded != diag.shieldsActive || modeInconsistent {
            Thread.sleep(forTimeInterval: 0.2)
            let retryDiag = shieldDiagnostic()
            let retryInconsistent: Bool = {
                guard expectedShielded else { return false }
                switch policy.resolvedMode {
                case .lockedDown: return retryDiag.appCount > 0
                case .locked:    return !retryDiag.categoryActive
                default:         return false
                }
            }()
            if expectedShielded == retryDiag.shieldsActive && !retryInconsistent {
                NSLog("[Enforcement] apply() verify: first read was stale (XPC latency), retry PASSED")
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Verify retry PASSED — first read was stale (XPC latency)",
                    details: "first=shields:\(diag.shieldsActive) retry=shields:\(retryDiag.shieldsActive) mode=\(policy.resolvedMode.rawValue)"
                ))
            } else {
                doubleCheckedFailure = true
            }
        }

        if doubleCheckedFailure {
            // Check if app is in foreground — ManagedSettings writes silently fail
            // from background. Nuclear reset from background DESTROYS shields the
            // Monitor wrote (clearAllSettings succeeds) but re-apply fails (silent).
            // Net result: shields go DOWN. Instead, flag the Monitor to handle it.
            let appInForeground: Bool = {
                let defaults = UserDefaults.appGroup
                let lastForegroundAt = defaults?.double(forKey: "mainAppLastForegroundAt") ?? 0
                // Consider "foreground" if the app was active within the last 5 seconds
                return Date().timeIntervalSince1970 - lastForegroundAt < 5
            }()

            if !appInForeground {
                // Background: DON'T nuclear reset — it will clear Monitor's work.
                // Schedule a near-future DeviceActivity so the Monitor can re-apply
                // enforcement from its privileged context. stopMonitoring-as-trigger
                // was unreliable; see scheduleEnforcementRefreshActivity.
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Enforcement verification FAILED (background) — scheduling Monitor refresh",
                    details: "Expected shields \(expectedShielded ? "UP" : "DOWN") but got \(diag.shieldsActive ? "UP" : "DOWN") (mode: \(policy.resolvedMode.rawValue))."
                ))
                scheduleEnforcementRefreshActivity(source: "apply.bgVerify")
            } else {
                // Foreground: nuclear reset is safe — ManagedSettings writes work.
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Enforcement verification FAILED — attempting reset",
                    details: "Expected shields \(expectedShielded ? "UP" : "DOWN") but got \(diag.shieldsActive ? "UP" : "DOWN") (mode: \(policy.resolvedMode.rawValue))"
                ))

                clearAllShieldStores()
                enforcementStore.clearAllSettings()

                if expectedShielded {
                    applyShield(allowExemptions: policy.resolvedMode == .restricted, policyRestrictions: policy.deviceRestrictions)
                    applyWebBlocking(policy.deviceRestrictions, forceBlock: policy.resolvedMode != .restricted)
                }
                applyRestrictions(policy.deviceRestrictions)

                let retryDiag = shieldDiagnostic()
                if retryDiag.shieldsActive == expectedShielded {
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .enforcement,
                        message: "Enforcement recovery SUCCEEDED after reset",
                        details: "After reset: shields=\(retryDiag.shieldsActive), apps=\(retryDiag.appCount), cat=\(retryDiag.categoryActive)"
                    ))
                } else {
                    // Primary store recovery failed. PROBE a fresh store name to
                    // distinguish "primary store corrupt" from "FC daemon dead".
                    //
                    // b432: This is a probe ONLY. Previously, on probe success
                    // we tried to "switch" to enforcement.recovery by writing
                    // .all() to it. But the rest of the codebase still uses the
                    // canonical "enforcement" store, so the recovery store
                    // became a permanent additional writer that "most-restrictive
                    // wins" merged forever — leaving the kid with ghost shields
                    // blocking everything until manual intervention. The probe
                    // store is now fully cleared after the test write, and the
                    // deep daemon rescue handles the actual recovery in BOTH
                    // cases (corrupt store AND dead daemon).
                    let recoveryStore = ManagedSettingsStore(named: .init("enforcement.recovery"))
                    recoveryStore.shield.applicationCategories = .all()
                    let recoveryCheck = recoveryStore.shield.applicationCategories != nil
                    // Always clear the probe store immediately — it must NEVER
                    // contribute to the merged daemon state.
                    recoveryStore.clearAllSettings()
                    recoveryStore.shield.applications = nil
                    recoveryStore.shield.applicationCategories = nil
                    recoveryStore.shield.webDomainCategories = nil
                    recoveryStore.shield.webDomains = nil
                    // b432 (audit fix): Readback verify that the clear stuck.
                    // If any property is still non-nil, the daemon dropped our
                    // clear and the probe store has leaked state. Log it so the
                    // parent dashboard sees it; clearAllShieldStores will keep
                    // trying on every subsequent call.
                    let probeLeakedApps = recoveryStore.shield.applications != nil
                    let probeLeakedCats = recoveryStore.shield.applicationCategories != nil
                    let probeLeakedWebCat = recoveryStore.shield.webDomainCategories != nil
                    let probeLeakedWebDom = recoveryStore.shield.webDomains != nil
                    if probeLeakedApps || probeLeakedCats || probeLeakedWebCat || probeLeakedWebDom {
                        NSLog("[Enforcement] CRITICAL: enforcement.recovery probe clear FAILED — daemon dropped writes, state leaked")
                        try? storage.appendDiagnosticEntry(DiagnosticEntry(
                            category: .enforcement,
                            message: "enforcement.recovery probe clear FAILED — daemon wedged",
                            details: "apps=\(probeLeakedApps) cats=\(probeLeakedCats) webCat=\(probeLeakedWebCat) webDom=\(probeLeakedWebDom). clearAllShieldStores will retry on next call."
                        ))
                    }

                    if recoveryCheck {
                        NSLog("[Enforcement] Recovery probe succeeded — primary store corrupt, daemon alive. Running deep rescue.")
                        try? storage.appendDiagnosticEntry(DiagnosticEntry(
                            category: .enforcement,
                            message: "Primary store corrupt (recovery probe accepted writes) — running deep rescue",
                            details: "Recovery store fully cleared so it can't merge ghost shields."
                        ))
                    } else {
                        NSLog("[Enforcement] Recovery probe failed — FC daemon may be dead. Running deep rescue as last resort.")
                        try? storage.appendDiagnosticEntry(DiagnosticEntry(
                            category: .enforcement,
                            message: "FC daemon may be dead (recovery probe rejected writes) — running deep rescue",
                            details: "Last-resort attempt before notifying parent of FC_AUTH_DEGRADED."
                        ))
                    }

                    // Run deep rescue in BOTH cases — it's our last chance to
                    // recover programmatically. (DeviceActivity kick + state
                    // machine flush + broad clearAllSettings + auth XPC poke.)
                    let rescueWorked = attemptDeepDaemonRescue(
                        expectedShielded: expectedShielded,
                        policy: policy
                    )
                    if rescueWorked {
                        try? storage.appendDiagnosticEntry(DiagnosticEntry(
                            category: .enforcement,
                            message: "Deep daemon rescue SUCCEEDED",
                            details: "Daemon unwedged without user action (probeOK=\(recoveryCheck))"
                        ))
                    } else {
                        NSLog("[Enforcement] FC_AUTH_DEGRADED — deep rescue failed. Needs Screen Time toggle.")
                        let degradedDefaults = UserDefaults.appGroup
                        degradedDefaults?.set(true, forKey: "fcAuthDegraded")
                        degradedDefaults?.set(Date().timeIntervalSince1970, forKey: "fcAuthDegradedAt")

                        // Only notify parent once per degradation episode
                        if degradedDefaults?.bool(forKey: "fcAuthDegradedNotificationSent") != true {
                            degradedDefaults?.set(true, forKey: "fcAuthDegradedNotificationSent")

                            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                                category: .auth,
                                message: "FC_AUTH_DEGRADED: ManagedSettings writes failing. Device needs Screen Time toggle.",
                                details: "Settings > Screen Time > App & Website Activity > OFF then ON. Deep rescue sequence already attempted. probeOK=\(recoveryCheck)"
                            ))

                            let content = UNMutableNotificationContent()
                            content.title = "Shields Broken"
                            content.body = "FamilyControls auth degraded — open Settings > Screen Time > App & Website Activity, toggle OFF then ON."
                            content.sound = .default
                            let request = UNNotificationRequest(
                                identifier: "fcAuthDegraded",
                                content: content,
                                trigger: nil
                            )
                            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
                        }

                        try? storage.appendDiagnosticEntry(DiagnosticEntry(
                            category: .enforcement,
                            message: "Enforcement recovery FAILED — ManagedSettings may need App & Website Activity toggle",
                            details: "After reset: shields=\(retryDiag.shieldsActive), apps=\(retryDiag.appCount), cat=\(retryDiag.categoryActive), probeOK=\(recoveryCheck)"
                        ))
                    }
                }
            }
        }
    }

    /// Deep daemon rescue — tries a sequence of tricks reported to un-wedge a
    /// stuck ScreenTimeAgent / ManagedSettings daemon WITHOUT requiring the user
    /// to toggle Screen Time settings or reboot. None is guaranteed; stacking
    /// them gives a real shot at programmatic recovery. Returns true on any
    /// step getting the expected shield state to verify.
    private func attemptDeepDaemonRescue(expectedShielded: Bool, policy: EffectivePolicy) -> Bool {

        // Helper: verify and return true if the current state matches expectation.
        func verifies() -> Bool {
            let d = shieldDiagnostic()
            return d.shieldsActive == expectedShielded
        }

        // Step 1: DeviceActivity kick. Stopping + restarting monitoring forces
        // ScreenTimeAgent to re-read its persistent store, which can flush a
        // stale in-memory cache that's diverged from disk.
        //
        // b432: ONLY kick reconciliation activities. Previously this stopped
        // and restarted ALL activities with a hardcoded 6-hour quarter
        // schedule, which corrupted temp-unlock, lock-until, schedule-window,
        // and time-limit activities (each of which expects its own custom
        // schedule). The kick is purely a daemon-wake side effect, so
        // restricting it to the reconciliation activities is sufficient.
        NSLog("[Rescue] Step 1: DeviceActivity kick (reconciliation only)")
        let center = DeviceActivityCenter()
        let allActivities = center.activities
        let reconciliationActivities = allActivities.filter {
            $0.rawValue.hasPrefix("bigbrother.reconciliation.")
        }
        center.stopMonitoring(reconciliationActivities)
        Thread.sleep(forTimeInterval: 0.3)
        // Re-register the 4 quarter-day reconciliation windows (matches the
        // canonical layout in AppDelegate.reregisterReconciliationSchedule).
        let quarters: [(name: String, startHour: Int, endHour: Int)] = [
            ("bigbrother.reconciliation.q0", 0, 5),
            ("bigbrother.reconciliation.q1", 6, 11),
            ("bigbrother.reconciliation.q2", 12, 17),
            ("bigbrother.reconciliation.q3", 18, 23),
        ]
        for q in quarters {
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: q.startHour, minute: 0),
                intervalEnd: DateComponents(hour: q.endHour, minute: 59),
                repeats: true,
                warningTime: nil
            )
            try? center.startMonitoring(DeviceActivityName(rawValue: q.name), during: schedule)
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Step 2: State-machine flush. Write empty → nil → real. Walks the
        // agent through its full validation path, often resolving cache/disk
        // divergence where the agent's in-memory state is stale but disk is OK.
        NSLog("[Rescue] Step 2: state-machine flush")
        enforcementStore.shield.applications = []
        Thread.sleep(forTimeInterval: 0.2)
        enforcementStore.shield.applications = nil
        Thread.sleep(forTimeInterval: 0.2)
        if expectedShielded {
            applyShield(
                allowExemptions: policy.resolvedMode == .restricted,
                policyRestrictions: policy.deviceRestrictions
            )
        }
        Thread.sleep(forTimeInterval: 0.5)
        if verifies() {
            NSLog("[Rescue] State-machine flush recovered shields")
            return true
        }

        // Step 3: clearAllSettings on every named store we know about, then
        // re-apply. Broadens the clear beyond just enforcementStore.
        NSLog("[Rescue] Step 3: broad clearAllSettings")
        clearAllShieldStores()
        enforcementStore.clearAllSettings()
        Thread.sleep(forTimeInterval: 0.3)
        if expectedShielded {
            applyShield(
                allowExemptions: policy.resolvedMode == .restricted,
                policyRestrictions: policy.deviceRestrictions
            )
        }
        Thread.sleep(forTimeInterval: 0.5)
        if verifies() {
            NSLog("[Rescue] Broad clear recovered shields")
            return true
        }

        // Step 4: Hail mary — poke the FC XPC daemon. Forum reports indicate
        // that calling AuthorizationCenter.requestAuthorization on an already-
        // authorized device can rebuild the XPC handle even though the call
        // itself is a no-op. We bypass fcManager.requestAuthorization() here
        // because b431 added a no-op guard there that would prevent the call
        // from reaching AuthorizationCenter at all. Pass `.individual` since
        // that's the preferred type for new auth, but the value doesn't really
        // matter — the daemon-wake side effect is what we want.
        NSLog("[Rescue] Step 4: AuthorizationCenter XPC poke")
        let rescueSemaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            } catch {
                NSLog("[Rescue] AuthorizationCenter call threw: \(error.localizedDescription)")
            }
            rescueSemaphore.signal()
        }
        _ = rescueSemaphore.wait(timeout: .now() + 3.0)

        // After auth re-request, reapply and check.
        if expectedShielded {
            applyShield(
                allowExemptions: policy.resolvedMode == .restricted,
                policyRestrictions: policy.deviceRestrictions
            )
        }
        Thread.sleep(forTimeInterval: 0.5)
        if verifies() {
            NSLog("[Rescue] Auth re-request recovered shields")
            return true
        }

        NSLog("[Rescue] All rescue steps failed — daemon needs user intervention")
        return false
    }

    /// Apply shields using per-app tokens from the picker selection.
    ///
    /// When a FamilyActivitySelection exists, uses `shield.applications` so
    /// ShieldAction receives the ApplicationToken directly (per-app unlock).
    /// Falls back to `.all(except:)` category blocking when no selection exists.
    /// Global limit on shield.applications tokens (undocumented Apple constraint).
    /// Exceeding this silently fails — no apps are shielded and reads back nil.
    private static let maxShieldApplications = 50

    /// Sort tokens deterministically by their encoded data. Set iteration order
    /// is non-deterministic and changes across process restarts, causing different
    /// apps to be dropped from the 50-token cap on each enforcement cycle.
    private static func stableSorted(_ tokens: Set<ApplicationToken>) -> [ApplicationToken] {
        let encoder = JSONEncoder()
        return tokens.sorted { a, b in
            let da = (try? encoder.encode(a))?.base64EncodedString() ?? ""
            let db = (try? encoder.encode(b))?.base64EncodedString() ?? ""
            return da < db
        }
    }

    /// - Parameters:
    ///   - allowExemptions: When false (essentialOnly), blocks ALL apps with no exemptions.
    ///   - policyRestrictions: Device restrictions from the policy, if available.
    private func applyShield(allowExemptions: Bool, policyRestrictions: DeviceRestrictions? = nil) {
        // applyShield is called for restricted/locked/lockedDown — i.e. real
        // shielding is intended. Clear the wide-open sentinel so shieldDiagnostic
        // recognizes the resulting category shield as functionally active.
        UserDefaults.appGroup?
            .set(false, forKey: "shieldStoreWideOpen")

        var allowedTokens = allowExemptions ? collectAllowedTokens() : Set<ApplicationToken>()
        let pickerTokens = loadPickerTokens()
        // For locked/lockedDown: load always-allowed tokens so we can
        // explicitly add them to shield.applications. System apps like Safari
        // are exempt from .all() category catch-all, but per-app shields
        // via shield.applications DO block them.
        let alwaysAllowedForShielding: Set<ApplicationToken> = allowExemptions ? [] : {
            guard let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                  let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data)
            else { return [] }
            return tokens
        }()
        NSLog("[Enforcement] applyShield: allowExemptions=\(allowExemptions) picker=\(pickerTokens.count) allowed=\(allowedTokens.count)")
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "applyShield: allowExemptions=\(allowExemptions) picker=\(pickerTokens.count) allowed=\(allowedTokens.count)"
        ))

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
                perAppTokens = Set(Self.stableSorted(tokensToBlock).prefix(Self.maxShieldApplications))
            }
            // Add exhausted tokens to shield.applications for "Request More Time".
            // Re-enforce the 50-token cap after union — exceeding it causes Apple to
            // silently fail, dropping ALL shields.
            // Priority: exhausted tokens (time-limited apps that MUST be shielded) always
            // kept; picker tokens fill remaining slots sorted deterministically.
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
                        message: "Token cap: \(dropped) apps dropped from shield.applications (50 limit). \(exhaustedTokens.count) exhausted kept.",
                        details: "source=app"
                    ))
                }
            }
            // Prefer nil over empty set for shield.applications. Apple's API
            // treats an empty set and nil equivalently at the daemon level,
            // but nil is the documented "clear" value — using it avoids any
            // potential implementation-defined behavior where a cached empty
            // set could shadow the category policy.
            let effectiveApps: Set<ApplicationToken>? = perAppTokens.isEmpty ? nil : perAppTokens
            assignShieldApplicationsIfChanged(effectiveApps)
            assignShieldApplicationCategoriesIfChanged(.all(except: allowedTokens))
            recordShieldedAppCount(perAppTokens.count)
            NSLog("[Enforcement] applyShield: wrote shield.applications=\(perAppTokens.count) apps + .all(except: \(allowedTokens.count)) catch-all")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "applyShield WROTE: shield.applications=\(perAppTokens.count) + .all(except: \(allowedTokens.count))"
            ))
        } else {
            // No picker selection or essentialOnly — block everything.
            var explicitApps: Set<ApplicationToken>? = allowExemptions ? nil : pickerTokens.isEmpty ? nil : pickerTokens
            // Add always-allowed tokens to shield.applications in locked mode
            // so system apps (Safari, etc.) get per-app shielded. The .all()
            // category catch-all exempts system apps, but explicit per-app
            // shields block them.
            if !alwaysAllowedForShielding.isEmpty {
                explicitApps = (explicitApps ?? Set()).union(alwaysAllowedForShielding)
            }
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
                let keptNonExhausted = Set(Self.stableSorted(nonExhausted).prefix(remainingSlots))
                explicitApps = Set(Self.stableSorted(exhaustedTokens).prefix(exhaustedCount)).union(keptNonExhausted)
            }
            let effectiveExplicitApps: Set<ApplicationToken>? = (explicitApps?.isEmpty == true) ? nil : explicitApps
            assignShieldApplicationsIfChanged(effectiveExplicitApps)
            if allowedTokens.isEmpty {
                assignShieldApplicationCategoriesIfChanged(.all())
                NSLog("[Enforcement] applyShield: wrote shield.applications=\(explicitApps?.count ?? 0) apps + .all() (no exemptions)")
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "applyShield WROTE: shield.applications=\(explicitApps?.count ?? 0) + .all()"
                ))
            } else {
                assignShieldApplicationCategoriesIfChanged(.all(except: allowedTokens))
                NSLog("[Enforcement] applyShield: wrote shield.applications=\(explicitApps?.count ?? 0) apps + .all(except: \(allowedTokens.count))")
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "applyShield WROTE: shield.applications=\(explicitApps?.count ?? 0) + .all(except: \(allowedTokens.count))"
                ))
            }
            recordShieldedAppCount(explicitApps?.count ?? 0)
        }
        applyWebBlocking(policyRestrictions, forceBlock: !allowExemptions)
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

    /// Apply web domain blocking based on mode and the denyWebWhenRestricted restriction.
    /// Locked/lockedDown modes ALWAYS block web regardless of the flag.
    /// Restricted mode respects the denyWebWhenRestricted parent setting.
    /// Uses the provided restrictions when available, falling back to storage read.
    private func applyWebBlocking(_ policyRestrictions: DeviceRestrictions? = nil, forceBlock: Bool = false) {
        let restrictions = policyRestrictions ?? storage.readDeviceRestrictions() ?? DeviceRestrictions()
        guard restrictions.denyWebWhenRestricted || forceBlock else {
            enforcementStore.shield.webDomainCategories = nil
            enforcementStore.webContent.blockedByFilter = nil
            ManagedSettingsStore().shield.webDomainCategories = nil
            return
        }

        enforcementStore.shield.webDomainCategories = .all()
        enforcementStore.webContent.blockedByFilter = .all()
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
    /// Apply "wide open" shields — allows everything but keeps stores non-nil.
    /// Used for temp unlock and unlocked mode to avoid the clear-then-reapply
    /// cycle that triggers silent auth re-validation failures on .child auth.
    private func applyWideOpenShields() {
        // Collect every known token to except from the category block.
        var allTokens = collectAllowedTokens()
        allTokens.formUnion(loadPickerTokens())

        // Also include time-limited app tokens
        let decoder = JSONDecoder()
        for limit in storage.readAppTimeLimits() {
            if let token = try? decoder.decode(ApplicationToken.self, from: limit.tokenData) {
                allTokens.insert(token)
            }
        }

        // Set enforcement store to .all(except: everything) — effectively allowing all apps
        // but keeping the store populated so the daemon doesn't re-validate auth.
        enforcementStore.shield.applications = nil
        enforcementStore.shield.applicationCategories = allTokens.isEmpty ? nil : .all(except: allTokens)
        enforcementStore.shield.webDomainCategories = nil
        enforcementStore.shield.webDomains = nil

        // Clear the default (unnamed) store as well.
        let defaultStore = ManagedSettingsStore()
        defaultStore.shield.applications = nil
        defaultStore.shield.applicationCategories = nil
        defaultStore.shield.webDomainCategories = nil
        defaultStore.shield.webDomains = nil

        recordShieldedAppCount(0)
        // Mark this state so shieldDiagnostic doesn't count the wide-open
        // .all(except: allTokens) sentinel as "shields active" — it's a daemon
        // pacifier, nothing is functionally blocked.
        UserDefaults.appGroup?
            .set(true, forKey: "shieldStoreWideOpen")

        // Clear DNS blocklists
        try? storage.writeEnforcementBlockedDomains([])
        try? storage.writeTimeLimitBlockedDomains([])
    }

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
        defaultStore.webContent.blockedByFilter = nil

        // b432: Defensive clear of the recovery probe store. The probe path
        // (apply() recovery branch) writes .all() to enforcement.recovery
        // briefly to test if a fresh store name accepts writes. It immediately
        // clears the probe, but in case any code path ever leaves state in
        // it, this safety net guarantees enforcement.recovery never accumulates
        // ghost shields that "most-restrictive wins" merge into the kid's view.
        let recoveryStore = ManagedSettingsStore(named: .init("enforcement.recovery"))
        recoveryStore.shield.applications = nil
        recoveryStore.shield.applicationCategories = nil
        recoveryStore.shield.webDomainCategories = nil
        recoveryStore.shield.webDomains = nil

        // ALSO clear legacy named stores (base, schedule, tempUnlock) on every
        // call, not just during the one-time migration. ManagedSettings merges
        // "most restrictive wins" across ALL named stores — if any legacy
        // store still has stale shield data (because migration silently
        // failed during a daemon-wedge window), iOS will continue rendering
        // those stale shields even though our current enforcement store is
        // empty. This is a suspected cause of "shields stuck on" after unlock.
        //
        // b431: Verify the writes actually took effect by reading back. If a
        // property is still non-nil after our nil write, retry once with
        // clearAllSettings() (more aggressive — touches every property at
        // once). If still non-nil after that, log a diagnostic so we can see
        // which legacy store is wedged in production.
        for name in AppConstants.legacyStoreNames {
            let legacy = ManagedSettingsStore(named: .init(name))
            legacy.shield.applications = nil
            legacy.shield.applicationCategories = nil
            legacy.shield.webDomainCategories = nil
            legacy.shield.webDomains = nil

            // Read-back verification. ManagedSettings reads return the value
            // we wrote (not the merged daemon state), so a non-nil readback
            // here means our write silently failed.
            let stillHasApps = legacy.shield.applications != nil
            let stillHasCats = legacy.shield.applicationCategories != nil
            let stillHasWebCat = legacy.shield.webDomainCategories != nil
            let stillHasWebDom = legacy.shield.webDomains != nil
            if stillHasApps || stillHasCats || stillHasWebCat || stillHasWebDom {
                NSLog("[Enforcement] Legacy store '\(name)' did not clear on first attempt — escalating to clearAllSettings")
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Legacy store '\(name)' clear failed — retrying with clearAllSettings",
                    details: "apps=\(stillHasApps) cats=\(stillHasCats) webCat=\(stillHasWebCat) webDom=\(stillHasWebDom)"
                ))
                legacy.clearAllSettings()
                // Final readback for diagnostics. If this still shows data, the
                // daemon is wedged for this store name and the parent should
                // be alerted (the next foreground rescue will handle it).
                let f1 = legacy.shield.applications != nil
                let f2 = legacy.shield.applicationCategories != nil
                let f3 = legacy.shield.webDomainCategories != nil
                let f4 = legacy.shield.webDomains != nil
                if f1 || f2 || f3 || f4 {
                    NSLog("[Enforcement] CRITICAL: legacy store '\(name)' STILL not cleared after clearAllSettings — daemon wedge or external writer (iCloud Screen Time sync)")
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .enforcement,
                        message: "Legacy store '\(name)' WEDGED — clearAllSettings failed",
                        details: "apps=\(f1) cats=\(f2) webCat=\(f3) webDom=\(f4) — likely external writer (iCloud sync) or daemon wedge"
                    ))
                    // Mark the ghost shield flag — this is the same condition
                    // ShieldConfiguration detects from the kid's perspective.
                    let defaults = UserDefaults.appGroup
                    defaults?.set(true, forKey: "ghostShieldsDetected")
                    defaults?.set(Date().timeIntervalSince1970, forKey: "ghostShieldsDetectedAt")
                    defaults?.set("legacy store '\(name)' wedged after clearAllSettings", forKey: "ghostShieldsDetectedReason")
                    let count = (defaults?.integer(forKey: "ghostShieldsDetectedCount") ?? 0) + 1
                    defaults?.set(count, forKey: "ghostShieldsDetectedCount")
                }
            }
        }

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

    /// Always write shield.applications. The prior read-before-write
    /// "optimization" was the primary cause of locked-not-raising-shields:
    /// ManagedSettingsStore reads return OUR last-written value, not the
    /// daemon's actual enforcement state. When a background write silently
    /// fails at the daemon level, the store still reads back the value we
    /// tried to set — so equality check suppresses every future retry even
    /// though the daemon never applied the shields. Direct writes guarantee
    /// that repeat parent lock commands always push fresh data through the
    /// XPC pipe. Burst-write mitigation lives in beginEnforcementBatch, not
    /// here.
    private func assignShieldApplicationsIfChanged(_ newValue: Set<ApplicationToken>?) {
        enforcementStore.shield.applications = newValue
    }

    /// Always write shield.applicationCategories. Same reasoning as
    /// assignShieldApplicationsIfChanged — the store's cached view lies about
    /// the daemon's real state, so equality suppression was silently dropping
    /// the writes the parent most needs.
    private func assignShieldApplicationCategoriesIfChanged(
        _ newValue: ShieldSettings.ActivityCategoryPolicy<Application>
    ) {
        enforcementStore.shield.applicationCategories = newValue
    }

    private func collectAllowedTokens() -> Set<ApplicationToken> {
        var tokens = Set<ApplicationToken>()
        let decoder = JSONDecoder()

        // Permanently allowed apps. DO NOT GC these — earlier attempts to GC
        // "stale" tokens removed every legitimately allowed token because the
        // staleness check used "in familyActivitySelection" as the validity
        // signal. allowedAppTokens and familyActivitySelection are TWO SEPARATE
        // LISTS with different purposes:
        //   - familyActivitySelection = the parent's BLOCK list (apps to shield)
        //   - allowedAppTokens = the always-allowed list (apps the kid can use
        //     even in restricted mode — exempted from the category block)
        // They do NOT overlap. Treating "not in selection" as "stale" deleted
        // every entry in the always-allowed list, leaving the kid with almost
        // everything blocked in restricted mode.
        //
        // Stale tokens in this list are harmless: if the underlying app is
        // gone, the daemon exempts nothing for that token. We have no
        // programmatic way to verify token liveness (Application(token:).
        // bundleIdentifier doesn't work outside picker context), so we
        // accept the stale entries and let the user manually re-pick if
        // they end up with bloat.
        var fileReadSource = "none"
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens) {
            if let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
                tokens.formUnion(allowed)
                fileReadSource = "file(\(allowed.count))"
            } else {
                fileReadSource = "file(decodeFail,\(data.count)B)"
            }
        } else {
            fileReadSource = "file(nil)"
        }

        // Snapshot fallback: if the file read returned nothing, try the
        // snapshot's embedded allowedAppTokensData. The Monitor already does
        // this; main app didn't, which caused locked→restricted transitions to
        // look like no-ops when the file read transiently failed (App Group
        // file coordination, reinstall state, etc.). Always-allowed apps would
        // be absent from the exception set, and .all(except: []) collapses to
        // .all() — the same shield state as locked.
        if tokens.isEmpty,
           let snapshot = storage.readPolicySnapshot(),
           let tokenData = snapshot.effectivePolicy.allowedAppTokensData,
           !tokenData.isEmpty,
           let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: tokenData) {
            tokens.formUnion(allowed)
            fileReadSource += " +snap(\(allowed.count))"
        }

        // Temporarily allowed apps (non-expired only).
        let tempEntries = storage.readTemporaryAllowedApps()
        var tempCount = 0
        for entry in tempEntries where entry.isValid {
            if let token = try? decoder.decode(ApplicationToken.self, from: entry.tokenData) {
                tokens.insert(token)
                tempCount += 1
            }
        }

        NSLog("[Enforcement] collectAllowedTokens: total=\(tokens.count) source=\(fileReadSource) temp=\(tempCount)")
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "collectAllowedTokens: total=\(tokens.count) source=\(fileReadSource) temp=\(tempCount)"
        ))
        return tokens
    }

    /// Compute per-token shield verdicts for the current state, for the test
    /// harness / heartbeat diagnostic. Walks the union of picker + allowed +
    /// time-limit-exhausted token sources and stamps each with the expected
    /// block verdict for `mode`. Returns at most 100 entries (oldest by sort
    /// order dropped) to keep the embedded heartbeat JSON bounded.
    func computeTokenVerdicts(for mode: LockMode) -> [DiagnosticSnapshot.TokenVerdict] {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let pickerTokens = loadPickerTokens()

        // allowedTokens — file first, snapshot fallback, plus temp-allowed
        var allowedTokens = Set<ApplicationToken>()
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            allowedTokens.formUnion(allowed)
        }
        if allowedTokens.isEmpty,
           let snap = storage.readPolicySnapshot(),
           let data = snap.effectivePolicy.allowedAppTokensData,
           !data.isEmpty,
           let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            allowedTokens.formUnion(allowed)
        }
        let tempEntries = storage.readTemporaryAllowedApps()
        for entry in tempEntries where entry.isValid {
            if let token = try? decoder.decode(ApplicationToken.self, from: entry.tokenData) {
                allowedTokens.insert(token)
            }
        }

        // exhaustedTokens — today's time-limit-exhausted list
        let today: String = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        var exhaustedTokens = Set<ApplicationToken>()
        for app in storage.readTimeLimitExhaustedApps() where app.dateString == today {
            if let token = try? decoder.decode(ApplicationToken.self, from: app.tokenData) {
                exhaustedTokens.insert(token)
            }
        }

        // Union of all tokens we know about
        var allTokens = Set<ApplicationToken>()
        allTokens.formUnion(pickerTokens)
        allTokens.formUnion(allowedTokens)
        allTokens.formUnion(exhaustedTokens)

        // Resolve names from the cached app-name index (harvested via picker flows).
        let nameCache = storage.readAllCachedAppNames()

        // Build verdicts; stable sort by fingerprint so the list is deterministic
        // for the test harness replay path.
        var verdicts: [DiagnosticSnapshot.TokenVerdict] = []
        verdicts.reserveCapacity(min(allTokens.count, 100))
        for token in allTokens {
            guard let tokenData = try? encoder.encode(token) else { continue }
            let fingerprint = String(TokenFingerprint.fingerprint(for: tokenData).prefix(16))
            let appName = nameCache[tokenData.base64EncodedString()]
            let inPicker = pickerTokens.contains(token)
            let inAllowed = allowedTokens.contains(token)
            let inExhausted = exhaustedTokens.contains(token)
            let expectedBlocked: Bool = {
                switch mode {
                case .unlocked: return false
                case .locked, .lockedDown: return true
                case .restricted:
                    // Allowed tokens are exempted unless their time limit is exhausted.
                    // Non-allowed tokens (including anything in the picker block list
                    // that wasn't also added to the always-allowed list) are blocked
                    // by the .all(except: allowed) catch-all.
                    return !inAllowed || inExhausted
                }
            }()
            verdicts.append(DiagnosticSnapshot.TokenVerdict(
                fingerprint: fingerprint,
                appName: appName,
                inPicker: inPicker,
                inAllowed: inAllowed,
                inExhausted: inExhausted,
                expectedBlocked: expectedBlocked
            ))
        }
        verdicts.sort { $0.fingerprint < $1.fingerprint }
        if verdicts.count > 100 {
            verdicts = Array(verdicts.prefix(100))
        }
        return verdicts
    }

    func clearAllRestrictions() throws {
        Self.applyLock.lock()
        defer { Self.applyLock.unlock() }
        UserDefaults.appGroup?
            .set("clearAll", forKey: "lastShieldChangeReason")
        clearAllShieldStores()
        recordShieldedAppCount(0)
        enforcementStore.clearAllSettings()
        // Re-apply device-level restrictions (denyAppRemoval, lockAccounts, etc.)
        // that should persist even when shields are cleared during unlocked mode.
        applyRestrictions()
    }

    func clearTemporaryUnlock() throws {
        Self.applyLock.lock()
        defer { Self.applyLock.unlock() }
        UserDefaults.appGroup?
            .set("tempUnlockClear", forKey: "lastShieldChangeReason")
        enforcementStore.clearAllSettings()
        // Re-apply device-level restrictions (denyAppRemoval, lockAccounts, etc.)
        // that must persist even after clearing temp unlock shields.
        applyRestrictions()
    }

    func applyEssentialOnly() throws {
        Self.applyLock.lock()
        defer { Self.applyLock.unlock() }
        UserDefaults.appGroup?
            .set("vpnDenied", forKey: "lastShieldChangeReason")
        applyRestrictions()
        applyShield(allowExemptions: false)
    }

    // MARK: - Shield Diagnostic

    /// Track shielded app count ourselves because ManagedSettingsStore.shield.applications
    /// doesn't reliably return the tokens that were written to it.
    private func recordShieldedAppCount(_ count: Int) {
        UserDefaults.appGroup?
            .set(count, forKey: "shieldedAppCount")
    }

    func shieldDiagnostic() -> ShieldDiagnostic {
        let enfCat = enforcementStore.shield.applicationCategories

        let appCount = UserDefaults.appGroup?
            .integer(forKey: "shieldedAppCount") ?? 0
        let webBlocking = enforcementStore.shield.webDomainCategories != nil
        // Track whether the wide-open snapshot wrote the .all(except: allTokens)
        // pattern. When that flag is set, applicationCategories being non-nil
        // means "store has data but nothing is functionally shielded" — we
        // should NOT count that as shieldsActive. In every other case, a non-nil
        // applicationCategories DOES enforce against everything outside the
        // exception set, even when shieldedAppCount is 0 (e.g. restricted mode
        // where the user has allowed every picker-selected app). Without this,
        // verification falsely loops on legitimately-correct state.
        let isWideOpen = UserDefaults.appGroup?
            .bool(forKey: "shieldStoreWideOpen") ?? false
        let categoryActive = enfCat != nil && !isWideOpen
        let shieldsActive = appCount > 0 || webBlocking || categoryActive

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

    /// Apply device-level restrictions from parent settings on the default (unnamed) store.
    /// Uses the provided restrictions when available, falling back to storage read.
    private func applyRestrictions(_ policyRestrictions: DeviceRestrictions? = nil) {
        let r = policyRestrictions ?? storage.readDeviceRestrictions() ?? DeviceRestrictions()

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

/// Schedule a one-shot DeviceActivity that wakes the Monitor extension in the
/// near future so it can re-apply enforcement from its privileged context.
///
/// **Why this replaces stopMonitoring-as-trigger:**
/// Empirical iOS 17+ behavior (confirmed against Apple dev forum threads):
/// 1. `DeviceActivityCenter.stopMonitoring([name])` does NOT reliably fire
///    `intervalDidEnd` in the Monitor extension. It's not a documented wake
///    mechanism; the behavior we were relying on is undefined.
/// 2. Calling `startMonitoring` with a schedule whose `intervalStart` is in
///    the past (e.g., re-registering the current reconciliation quarter)
///    does NOT fire `intervalDidStart` — it just silently attaches to the
///    ongoing interval.
/// Both failure modes meant that every "wake the Monitor" call from the main
/// app / tunnel was silently a no-op, and the Monitor only ever ran on its
/// natural 6-hour quarter boundaries (or when usage-tracking milestones
/// fired — which requires the kid to actually use the device). That's why
/// parent lock commands felt like "nothing happens": the Monitor wasn't
/// being woken between quarters.
///
/// **What this does instead:**
/// Registers a NEW one-shot DeviceActivity with a future start time (default
/// ~90 seconds). iOS fires `intervalDidStart` when the start time is
/// reached; the Monitor's existing `bigbrother.enforcementRefresh.*` prefix
/// handler catches it, reads ModeStackResolver, and applies shields from its
/// privileged context. The Monitor then stops the activity to reclaim the
/// slot.
///
/// **Delay/interval rationale:**
/// Apple doesn't publish a minimum delay, but forum threads report that
/// sub-minute schedules are unreliable. 60 seconds sits at the bottom of
/// the "reliable" range and caps parent-lock-to-shields-up at roughly
/// 60–90 seconds worst case (when the main app's background write fails
/// silently). The 16-minute interval length satisfies iOS's
/// `intervalTooShort` rule (~15 minutes minimum) with headroom.
///
/// **Cleanup:** The Monitor's `intervalDidStart` handler calls
/// `stopMonitoring` on the activity after processing it, so each refresh
/// is self-cleaning. Stale refresh activities (e.g. if the Monitor never
/// fires) are also swept here before registering a new one, to stay under
/// iOS's ~20 activity cap.
///
/// **Shared helper:** called from CommandProcessor, EnforcementService
/// recovery paths, AppDelegate background launch, and the VPN tunnel's
/// relay/verify paths. The tunnel and Monitor have their own local copies
/// of this helper because the function needs `import DeviceActivity`, which
/// isn't available in BigBrotherCore.
@inline(never)
func scheduleEnforcementRefreshActivity(
    source: String,
    delaySeconds: TimeInterval = 60,
    intervalMinutes: Int = 16
) {
    let center = DeviceActivityCenter()

    // Sweep stale enforcementRefresh activities so we don't bump into iOS's
    // ~20 activity cap on repeated parent commands.
    for activity in center.activities
    where activity.rawValue.hasPrefix("bigbrother.enforcementRefresh.") {
        center.stopMonitoring([activity])
    }

    let now = Date()
    let fireAt = now.addingTimeInterval(delaySeconds)
    let endAt = fireAt.addingTimeInterval(TimeInterval(intervalMinutes * 60))
    let cal = Calendar.current
    let schedule = DeviceActivitySchedule(
        intervalStart: cal.dateComponents([.hour, .minute, .second], from: fireAt),
        intervalEnd: cal.dateComponents([.hour, .minute, .second], from: endAt),
        repeats: false,
        warningTime: nil
    )
    let activityName = DeviceActivityName(
        rawValue: "bigbrother.enforcementRefresh.\(Int(now.timeIntervalSince1970))"
    )

    // Write the wake flag so Monitor's checkEnforcementRefreshSignal also
    // handles the refresh if it's running for any other reason (usage
    // threshold, natural boundary) in the interim.
    UserDefaults.appGroup?
        .set(Date().timeIntervalSince1970, forKey: "needsEnforcementRefresh")

    do {
        try center.startMonitoring(activityName, during: schedule)
        NSLog("[EnforcementRefresh] \(source): registered \(activityName.rawValue), fires ~\(Int(delaySeconds))s from now")
    } catch {
        NSLog("[EnforcementRefresh] \(source): FAILED to register \(activityName.rawValue): \(error.localizedDescription)")
        try? AppGroupStorage().appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "EnforcementRefresh schedule failed",
            details: "source=\(source) error=\(error.localizedDescription)"
        ))
    }
}
