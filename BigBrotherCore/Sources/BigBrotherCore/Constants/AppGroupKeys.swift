import Foundation

/// Central registry of every App Group `UserDefaults` key used across
/// the main app and its extensions.
///
/// Before this type existed, keys were string literals scattered across
/// the codebase. Several real bugs came from that soup:
///   * "buildMismatchDNSBlock" was read in 4 places and written in 3, with
///     no single place that explained when it should be cleared. The
///     Olivia/Daphne/Juliet stuck-blackhole incident was rooted in one
///     writer setting it with a 24h TTL while no reader knew to clear
///     it after the build mismatch resolved.
///   * "internetBlockedUntil" had the same story — a legacy flag that
///     was read by the tunnel and written by the monitor, with no owner.
///   * Typos went silently undetected until a writer and a reader
///     disagreed, at which point the bug was indistinguishable from
///     "feature doesn't work."
///
/// This type does three things:
///   1. Names every known key as a compile-time constant so spelling is
///      verified at build time, not at runtime.
///   2. Documents ownership and semantics (what writes it, what reads it,
///      and the contract between them) inline next to the constant.
///   3. Gives future readers a single place to audit cross-process state
///      when hunting "which process wrote what to whom" bugs.
///
/// ### Migration status
/// Adoption is ongoing. New code should always use these constants.
/// Existing string-literal call sites are being migrated file-by-file;
/// the tunnel was migrated first because that's where most of the
/// cross-process bugs have been hitting.
public enum AppGroupKeys {

    // MARK: - Liveness / build tracking

    /// Epoch seconds; written by the main app every ~30s while in the
    /// foreground, and by AppDelegate once on launch. Read by the tunnel
    /// and the monitor to tell whether the main app is still alive.
    /// If > `AppConstants.appDeathThresholdSeconds` old, the main app is
    /// considered dead and fallback enforcement kicks in.
    public static let mainAppLastActiveAt = "mainAppLastActiveAt"

    /// Build number of the main app the LAST time `setupOnLaunch` ran.
    /// Compared against `AppConstants.appBuildNumber` in the monitor and
    /// tunnel to detect a deploy where the main app hasn't yet re-launched
    /// on the new build (which triggers the build-mismatch blackhole).
    public static let mainAppLastLaunchedBuild = "mainAppLastLaunchedBuild"

    /// Epoch seconds; written by the main app when it enters foreground.
    /// More specific than `mainAppLastActiveAt` — only updated on
    /// transitions, not every heartbeat.
    public static let mainAppLastForegroundAt = "mainAppLastForegroundAt"

    /// Epoch seconds; written by the monitor extension every time it
    /// fires a DeviceActivity callback. Read by the tunnel to decide if
    /// the monitor is still alive.
    public static let monitorLastActiveAt = "monitorLastActiveAt"

    /// Epoch seconds; written by the monitor extension at the end of a
    /// full reconcile pass.
    public static let monitorLastReconcileAt = "monitorLastReconcileAt"

    /// Epoch seconds; written by the tunnel on its liveness tick.
    public static let tunnelLastActiveAt = "tunnelLastActiveAt"

    /// Build number of each extension. Each extension writes this on its
    /// first run; the main app reads them for the "diagnostic" view so
    /// the parent can see whether the on-device extensions are running
    /// the deployed build.
    public static let monitorBuildNumber = "monitorBuildNumber"
    public static let shieldBuildNumber = "shieldBuildNumber"
    public static let shieldActionBuildNumber = "shieldActionBuildNumber"
    public static let tunnelBuildNumber = "tunnelBuildNumber"

    // MARK: - DNS blackhole / enforcement signals

    /// Legacy "parent commanded internet off until this epoch". Written by
    /// the main app's `applyInternetBlock` path AND by the monitor's
    /// build-mismatch path (`checkAppLaunchNeeded`). Read by the tunnel
    /// at `seedBlockReasonsOnStart` and every liveness tick.
    ///
    /// Pair with `buildMismatchDNSBlock`: if both are set, the source is
    /// the build-mismatch path and the flag should be cleared when the
    /// main app launches on the current build. If only this is set,
    /// treat it as a parent-issued directive with a TTL.
    public static let internetBlockedUntil = "internetBlockedUntil"

    /// Companion flag to `internetBlockedUntil` indicating the source was
    /// a build mismatch, not a parent command. Lets the tunnel
    /// self-heal when the main app launches on the current build.
    public static let buildMismatchDNSBlock = "buildMismatchDNSBlock"

    /// Written by the tunnel whenever `shouldBlackhole` transitions.
    /// Read by the main app and by heartbeat builders so the parent
    /// dashboard sees the current DNS state.
    public static let tunnelInternetBlocked = "tunnelInternetBlocked"

    /// Human-readable reason string for `tunnelInternetBlocked`. The
    /// highest-priority active DNSBlockReason's `humanDescription`.
    public static let tunnelInternetBlockedReason = "tunnelInternetBlockedReason"

    /// FamilyControls authorization status as a string
    /// ("approved"/"notDetermined"/"denied"). Written by the main app
    /// when authorization changes; read by tunnel to decide if the
    /// `.permissionsRevoked` blackhole should activate.
    public static let familyControlsAuthStatus = "familyControlsAuthStatus"

    /// True if FC `authorizationStatus == .approved` but ManagedSettings
    /// writes are silently failing. Requires a Settings > Screen Time
    /// toggle to recover.
    public static let fcAuthDegraded = "fcAuthDegraded"

    /// Epoch seconds when `fcAuthDegraded` first flipped true.
    public static let fcAuthDegradedAt = "fcAuthDegradedAt"

    /// True if the child explicitly paused all restrictions (testing /
    /// emergency mode). When set, the tunnel releases ALL DNS blackhole
    /// reasons until the flag is cleared.
    public static let restrictionsPausedByChild = "restrictionsPausedByChild"

    // MARK: - Shield state (cross-process)

    /// True if `ManagedSettingsStore.enforcement` currently has shields
    /// applied. Written by the monitor's apply path. Read by the tunnel
    /// for heartbeat reporting and by the main app's audit.
    public static let shieldsActiveAtLastHeartbeat = "shieldsActiveAtLastHeartbeat"

    /// Epoch seconds of the last `shieldsActiveAtLastHeartbeat` write.
    /// Used by the tunnel to suppress stale "shields down" reports
    /// during mode transitions where the monitor hasn't written the new
    /// state yet.
    public static let shieldsActiveAtLastHeartbeatAt = "shieldsActiveAtLastHeartbeatAt"

    /// b459: set by `applyWideOpenShields` to signal that the enforcement
    /// store was intentionally cleared. The monitor's reconcile path
    /// reads this to avoid a confusing "shields down in unlocked mode"
    /// being treated as a drift failure.
    public static let shieldStoreWideOpen = "shieldStoreWideOpen"

    /// Count of app tokens currently in `shield.applications`. Written
    /// by the monitor's apply path. Read by heartbeat builders.
    public static let shieldedAppCount = "shieldedAppCount"

    /// Human-readable "who last changed shields and why" string
    /// (e.g. "command", "reconcile", "launchRestore", "freeWindowStart").
    public static let lastShieldChangeReason = "lastShieldChangeReason"

    /// Most recent shield audit fingerprint string (format:
    /// "writer|mode|shieldsUp|count|epoch"). Used by the diagnostic
    /// snapshot for parent-side verification.
    public static let lastShieldAudit = "lastShieldAudit"

    // MARK: - Enforcement timing (harness metrics)

    /// Epoch seconds at start of an enforcement apply. Written by the
    /// tunnel's test-command path and the monitor's apply path. The
    /// test harness reads these to measure apply latency end-to-end.
    public static let enforcementApplyStartedAt = "enforcementApplyStartedAt"

    /// Epoch seconds at end of an enforcement apply (post-verify).
    public static let enforcementApplyFinishedAt = "enforcementApplyFinishedAt"

    /// Epoch seconds of the most recent command processed (applied
    /// successfully). Used by the main app to skip the 10s
    /// post-command enforcement verification (avoids clobbering the
    /// just-applied result).
    public static let lastCommandProcessedAt = "fr.bigbrother.lastCommandProcessedAt"

    /// CommandID of the most recent command processed. Paired with
    /// `lastCommandProcessedAt` so the parent/test-harness can verify a
    /// specific command landed.
    public static let lastCommandID = "fr.bigbrother.lastCommandID"

    /// CommandID of the last command for which shields were VERIFIED applied
    /// (post-write shieldDiagnostic passed, or Monitor confirmed). Pairs with
    /// `lastShieldAppliedForCmdAt`. Lets harness/parent measure the gap
    /// between command-ack and shield-actually-enforced.
    public static let lastShieldAppliedForCmdID = "fr.bigbrother.lastShieldAppliedForCmdID"

    /// Timestamp (epoch seconds) paired with `lastShieldAppliedForCmdID`.
    public static let lastShieldAppliedForCmdAt = "fr.bigbrother.lastShieldAppliedForCmdAt"

    // MARK: - Reconcile signals

    /// Epoch seconds written by the main app when it wants the monitor
    /// to re-run reconcile now. The tunnel relays this by bouncing the
    /// DeviceActivity monitoring quarters.
    public static let needsEnforcementRefresh = "needsEnforcementRefresh"

    /// Epoch seconds written by the monitor after it processed a
    /// `needsEnforcementRefresh` signal. Used by the tunnel to detect
    /// a missing monitor (if the signal was set but never confirmed).
    public static let monitorEnforcementConfirmedAt = "monitorEnforcementConfirmedAt"

    /// Epoch seconds when the tunnel first detected a build mismatch
    /// that hasn't yet resolved. Only after the mismatch has persisted
    /// for the grace window does the tunnel escalate to a blackhole.
    public static let monitorBuildMismatchFirstSeenAt = "monitorBuildMismatchFirstSeenAt"

    /// Trigger timestamp the tunnel can set to wake the monitor's
    /// enforcement pass (mirrors `needsEnforcementRefresh`).
    public static let tunnelEnforcementTriggerAt = "tunnelEnforcementTriggerAt"

    // MARK: - Device lock state

    /// True if the device screen is currently locked. Written by
    /// DeviceLockMonitor in the main app. Read by the tunnel for
    /// liveness calculations (emergency blackhole is screen-unlock-gated).
    public static let isDeviceLocked = "isDeviceLocked"

    // MARK: - Schedule / mode flags

    /// Whether the device is in schedule-driven mode (default true).
    /// `false` means a parent directive has overridden the schedule.
    public static let scheduleDrivenMode = "scheduleDrivenMode"

    /// Last mode the monitor notified the child UI about. Used for
    /// post-mode-change nag notifications.
    public static let monitorLastNotifiedMode = "monitorLastNotifiedMode"

    // MARK: - Ghost shield detection

    /// True if the ShieldConfiguration extension observed a shield being
    /// rendered for an app our policy says shouldn't be shielded.
    /// Evidence of an external writer (iCloud Screen Time sync).
    public static let ghostShieldsDetected = "ghostShieldsDetected"
    public static let ghostShieldsDetectedAt = "ghostShieldsDetectedAt"
    public static let ghostShieldsDetectedReason = "ghostShieldsDetectedReason"
    public static let ghostShieldsDetectedCount = "ghostShieldsDetectedCount"

    // MARK: - Auth type / permissions

    /// "child" or "individual" — whether FamilyControls was granted via
    /// Family Sharing or individual authorization. Written by the main
    /// app, read by heartbeat builders.
    public static let authorizationType = "fr.bigbrother.authorizationType"

    /// If `.child` auth failed, why. Human-readable diagnostic.
    public static let childAuthFailReason = "fr.bigbrother.childAuthFailReason"

    /// JSON snapshot of per-permission booleans written by
    /// ChildHomeViewModel. Read by heartbeat builders.
    public static let permissionSnapshot = "permissionSnapshot"

    /// Coarse "all requested permissions granted" flag.
    public static let allPermissionsGranted = "allPermissionsGranted"

    /// True if the main app has FC authorization and ManagedSettings
    /// writes are succeeding. Main app writes it after a successful apply.
    public static let enforcementPermissionsOK = "enforcementPermissionsOK"

    // MARK: - Extension heartbeat coordination

    /// Token written by a requester (main app, test harness) to ask the
    /// extension heartbeat path to flush. The extension writes
    /// `extensionHeartbeatAcknowledgedToken` to the same value to confirm.
    public static let extensionHeartbeatRequestToken = "extensionHeartbeatRequestToken"
    public static let extensionHeartbeatAcknowledgedToken = "extensionHeartbeatAcknowledgedToken"
    public static let extensionHeartbeatRequestedAt = "extensionHeartbeatRequestedAt"
    public static let extensionHeartbeatAcknowledgedAt = "extensionHeartbeatAcknowledgedAt"

    /// Epoch seconds of the most recent heartbeat sent by ANY writer.
    /// Used by the tunnel to coordinate "skip if main app sent one recently."
    public static let lastHeartbeatSentAt = "lastHeartbeatSentAt"

    /// True if the monitor should immediately trigger a heartbeat flush.
    public static let monitorNeedsHeartbeat = "monitorNeedsHeartbeat"

    // MARK: - Onboarding / first-launch flags

    /// True on the next main-app launch, asks the onboarding flow to
    /// re-run the permission fixer wizard.
    public static let showPermissionFixerOnNextLaunch = "showPermissionFixerOnNextLaunch"

    /// True once the permission fixer has been completed at least once.
    public static let permissionFixerCompletedOnce = "permissionFixerCompletedOnce"

    // MARK: - Pause / timed unlock

    public static let familyPauseEnabled = "familyPauseEnabled"
    public static let familyPauseExpiresAt = "familyPauseExpiresAt"
    public static let familyPauseSnapshot = "familyPauseSnapshot"

    public static let lockUntilExpiresAt = "lockUntilExpiresAt"
    public static let lockUntilPreviousMode = "lockUntilPreviousMode"

    // MARK: - Web blocking

    public static let safeSearchEnabled = "safeSearchEnabled"
    public static let forceCloseWebBlocked = "forceCloseWebBlocked"

    // MARK: - DNS kill switch
    /// JSON-encoded `DNSFilteringState` describing whether DNS policy filtering
    /// is currently enabled, and if not, when it was disabled (child clock)
    /// and for how long. Single atomic key — writes are race-free because
    /// UserDefaults replaces the whole value in one store. Previously two
    /// separate keys (`dnsFilteringEnabled`, `dnsFilteringDisabledUntil`) had
    /// a visible intermediate state `(enabled=false, until=0)` that a
    /// concurrent reader could interpret as corruption and flip back to
    /// enabled, silently cancelling a fresh disable command.
    public static let dnsFilteringStateJSON = "dnsFilteringStateJSON"

    // MARK: - Command processing

    public static let tunnelProcessedCommandIDs = "tunnelProcessedCommandIDs"
    public static let tunnelAppliedCommandIDs = "tunnelAppliedCommandIDs"
    public static let tunnelHeartbeatRecordPoisoned = "tunnelHeartbeatRecordPoisoned"

    // MARK: - Screen time / usage

    public static let screenTimeMinutes = "screenTimeMinutes"
    public static let screenUnlockCount = "screenUnlockCount"

    // MARK: - Home location (named place)

    public static let homeLatitude = "homeLatitude"
    public static let homeLongitude = "homeLongitude"
    public static let namedPlaces = "namedPlaces"

    // MARK: - Migration markers

    /// b384: marks the device as having migrated from the 3-store
    /// ManagedSettings layout to the single "enforcement" store.
    public static let migratedToSingleStore = "migratedToSingleStore"

    // MARK: - Recovery hints

    /// Epoch seconds written when the tunnel notices the main app died.
    /// Next time the main app launches, it reads this and grabs a fresh
    /// location (gap-filling).
    public static let appDiedNeedLocationAt = "appDiedNeedLocationAt"

    // MARK: - New app detection

    public static let newAppDetections = "newAppDetections"
    public static let newAppLastLoggedAt = "newAppLastLoggedAt"
    public static let knownAppDomains = "knownAppDomains"

    // MARK: - Foreground rescue coordination

    public static let mainAppEnforcementAt = "mainAppEnforcementAt"
    public static let lastNaturalRelockAt = "lastNaturalRelockAt"

    // MARK: - Pending reviews

    public static let pendingReviewNeedsSync = "pendingReviewNeedsSync"
    public static let pendingReviewLocalJSON = "pending_review_local.json"

    // MARK: - Name harvesting / DNS

    public static let harvestedAppNames = "harvestedAppNames"
    public static let tokenToAppName = "tokenToAppName"
    public static let dnsAppUsage = "dnsAppUsage"
    public static let dnsActivityTotalQueries = "dnsActivityTotalQueries"
    public static let dnsActivityDomains = "dnsActivityDomains"
    public static let dnsActivityDate = "dnsActivityDate"

    // MARK: - Tunnel connection state

    public static let tunnelConnected = "tunnelConnected"
    public static let tunnelStatus = "tunnelStatus"
    public static let tunnelLastPathSignature = "tunnelLastPathSignature"
    public static let tunnelNetworkPathChangedAt = "tunnelNetworkPathChangedAt"
    public static let tunnelTestCommandReceiverInstalledAt = "tunnelTestCommandReceiverInstalledAt"
    public static let testCommandReceiverInstalledAt = "testCommandReceiverInstalledAt"

    // MARK: - Push / APNs

    public static let apnsTokenRegisteredAt = "apnsTokenRegisteredAt"
    public static let apnsTokenError = "apnsTokenError"
    public static let lastPushReceivedAt = "lastPushReceivedAt"

    // MARK: - Main app delegate coordination

    public static let appDelegateRestorationAt = "appDelegateRestorationAt"

    // MARK: - Last-shielded-app diagnostic

    public static let lastShieldedTokenBase64 = "lastShielded.tokenBase64"
    public static let lastShieldedBundleID = "lastShielded.bundleID"
    public static let lastShieldedAppName = "lastShielded.appName"
    public static let lastShieldedTimestamp = "lastShielded.timestamp"

    // MARK: - Force-close nag

    public static let forceCloseLastNagAt = "forceCloseLastNagAt"

    // MARK: - Tunnel internals

    /// Queue of token data (base64) that the main app wants the Monitor /
    /// tunnel to treat as "removed" on the next reconcile. Written by the
    /// command processor, read by enforcement reapply.
    public static let pendingTokenRemovals = "pendingTokenRemovals"

    /// Location tracking preference ("always", "whenInUse", "off") selected
    /// by the parent. Read by the tunnel for heartbeat reporting.
    public static let locationTrackingMode = "locationTrackingMode"

    /// Drive settings JSON blob (speed thresholds, named places). Read by
    /// the tunnel and monitor for in-vehicle enforcement.
    public static let drivingSettings = "drivingSettings"

    // MARK: - DNS Proxy / Tunnel Telemetry (b547)
    //
    // Daily-resetting counters that measure how often the tunnel is
    // actually detecting and recovering from the wedged-NWUDPSession bug
    // (b545 active probe) vs other causes of internet loss. Parent's
    // Remote Diagnostics view renders these so we can tell WHICH failure
    // mode a kid is hitting without pulling logs.
    //
    // Semantics:
    //   - Stored as a single JSON-encoded TunnelTelemetry struct in
    //     `tunnelTelemetry`. Single blob so atomic update works without
    //     key races between probe, reconnect, and path-change writers
    //     that all run on the tunnel's liveness timer.
    //   - `dateString` is "YYYY-MM-DD" in UTC. On write, if stored date
    //     != today, counters reset to 0 and yesterday's snapshot is
    //     copied into `previousDayTelemetry` for parent comparison.

    /// JSON-encoded `TunnelTelemetry` — written by the tunnel on every
    /// counted event, read by the tunnel heartbeat builder and the parent
    /// diagnostic UI.
    public static let tunnelTelemetry = "tunnelTelemetry"

    /// JSON-encoded `TunnelTelemetry` from the most recent completed day.
    /// Preserved after midnight rollover so the parent can compare
    /// yesterday's counts with today's.
    public static let tunnelTelemetryYesterday = "tunnelTelemetryYesterday"
}

/// Convenience accessor so callers don't re-type the App Group suite name.
/// Replaces `UserDefaults(suiteName: AppConstants.appGroupIdentifier)`.
public extension UserDefaults {
    static var appGroup: UserDefaults? {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)
    }
}
