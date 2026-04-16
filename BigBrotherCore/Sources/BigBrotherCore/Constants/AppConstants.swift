import Foundation

/// Central constants shared across all targets.
public enum AppConstants {

    /// App Group identifier for shared storage between the main app and extensions.
    public static let appGroupIdentifier = "group.fr.bigbrother.shared"

    /// CloudKit container identifier.
    public static let cloudKitContainerIdentifier = "iCloud.fr.bigbrother.app"

    /// Keychain access group for shared secrets between app and extensions.
    /// Must include the Team ID prefix for cross-process access (app + extensions).
    public static let keychainAccessGroup = "Y2G5FUN342.fr.bigbrother.shared"

    /// Main app bundle identifier.
    public static let appBundleID = "fr.bigbrother.app"

    /// DeviceActivityMonitor extension bundle identifier.
    public static let monitorBundleID = "fr.bigbrother.app.monitor"

    /// ShieldConfiguration extension bundle identifier.
    public static let shieldBundleID = "fr.bigbrother.app.shield"

    /// ShieldAction extension bundle identifier.
    public static let shieldActionBundleID = "fr.bigbrother.app.shield-action"

    /// VPN Packet Tunnel extension bundle identifier.
    public static let tunnelBundleID = "fr.bigbrother.app.tunnel"

    /// Interval between VPN extension heartbeat sends when main app is dead (5 minutes).
    public static let vpnHeartbeatIntervalSeconds: TimeInterval = 300

    /// How long without main app activity before tunnel considers the app dead (10 minutes).
    public static let appDeathThresholdSeconds: TimeInterval = 600

    // MARK: - Build Tracking

    /// Manual build number — bump each time you deploy new code during development.
    /// Both parent and child read this constant; matching numbers = same code.
    public static let appBuildNumber = 628

    // MARK: - Enrollment

    /// How long an enrollment code remains valid (30 minutes).
    public static let enrollmentCodeValiditySeconds: TimeInterval = 1800

    /// Length of generated enrollment codes.
    public static let enrollmentCodeLength = 8

    // MARK: - Heartbeat

    /// Interval between heartbeat sends (5 minutes).
    public static let heartbeatIntervalSeconds: TimeInterval = 300

    /// Threshold for considering a device "online" (10 minutes).
    public static let onlineThresholdSeconds: TimeInterval = 600

    // MARK: - Force-Close Detection

    /// Heartbeat age threshold for force-close when device is locked (10 min).
    /// Shorter than unlocked because a locked device has no reason to suspend the app.
    public static let forceCloseThresholdLocked: TimeInterval = 600

    /// Heartbeat age threshold for force-close when device is unlocked (20 min).
    /// Balances detection speed against false positives from games suspending the app.
    public static let forceCloseThresholdUnlocked: TimeInterval = 1200

    /// How old the extensionHeartbeatRequestedAt flag must be to confirm
    /// the main app never cleared it (reconciliation interval + buffer).
    public static let forceCloseFlagStaleness: TimeInterval = 960

    // MARK: - Commands

    /// Default command expiry (24 hours).
    public static let defaultCommandExpirySeconds: TimeInterval = 86400

    // MARK: - PIN Security

    /// Maximum consecutive failed PIN attempts before lockout.
    public static let maxPINAttempts = 5

    /// PIN lockout duration (5 minutes).
    public static let pinLockoutDurationSeconds: TimeInterval = 300

    // MARK: - Temporary Unlock

    /// Default temporary unlock duration (30 minutes).
    public static let defaultTemporaryUnlockSeconds: TimeInterval = 1800

    // MARK: - ManagedSettings Store Names

    /// Single named store for ALL shield enforcement (apps, categories, web).
    /// Replaces the old base/schedule/tempUnlock 3-store architecture.
    /// ManagedSettingsStore uses "most restrictive wins" merge across named stores,
    /// so multiple stores caused conflicts where one store's restrictions couldn't
    /// be overridden by another. A single store eliminates this.
    public static let managedSettingsStoreEnforcement = "enforcement"

    /// Legacy store names to clear during migration. Still referenced by the
    /// monitor and enforcement service migration paths so devices that
    /// upgrade from an older build have their old stores cleared on first
    /// launch. Safe to remove once every device in the fleet has been
    /// through the single-store migration at least once.
    public static let legacyStoreNames = ["base", "schedule", "tempUnlock"]

    // MARK: - Heartbeat Retry

    /// Base interval for heartbeat retry backoff (seconds).
    public static let heartbeatRetryBaseSeconds: TimeInterval = 10

    /// Maximum backoff interval for heartbeat retry (30 minutes).
    public static let heartbeatMaxBackoffSeconds: TimeInterval = 1800

    /// Window within which a heartbeat is considered "recently sent" (seconds).
    /// Used to avoid duplicate sends when quick sync already included a heartbeat.
    public static let heartbeatRecentWindow: TimeInterval = 60

    // MARK: - Event Queue

    /// Maximum number of events to keep in the local queue before pruning oldest.
    public static let eventQueueMaxSize = 500

    /// Maximum number of diagnostic entries to retain.
    public static let diagnosticsMaxEntries = 200

    // MARK: - Command Processing

    /// How long to keep processed command IDs (48 hours).
    public static let processedCommandRetentionSeconds: TimeInterval = 172800

    // MARK: - Background Tasks

    /// BGTaskScheduler identifier for periodic heartbeat + command sync.
    public static let bgTaskHeartbeat = "fr.bigbrother.app.heartbeat-refresh"

    /// BGTaskScheduler identifier for enforcement re-lock at unlock expiry.
    public static let bgTaskRelock = "fr.bigbrother.app.relock"

    // MARK: - Cross-process Darwin notifications

    /// Posted by the main app whenever it receives a remote push. The VPN
    /// tunnel observes this and triggers an immediate command poll, bypassing
    /// its normal 1-second cadence. When iOS delivers pushes quickly this
    /// collapses the poll wait to zero; when it doesn't, the 1s timer still
    /// acts as the reliable backbone.
    public static let darwinNotifTunnelPokeCommands = "fr.bigbrother.tunnel.pokeCommands"

    /// Posted by the VPN tunnel after it applies a mode command. The main
    /// app observes this and — if alive — immediately runs
    /// `enforcement.apply()` + shield verify, writing `lastShieldAppliedForCmd*`
    /// within a second. When the main app is suspended the observer doesn't
    /// fire; the bg URLSession wake / Monitor DeviceActivity paths cover
    /// that case. This notification is the fast path for the common case
    /// of the kid actively using the phone.
    public static let darwinNotifAppApplyShieldsNow = "fr.bigbrother.app.applyShieldsNow"

    // MARK: - Snapshot History

    /// Maximum number of snapshot transitions to retain in history buffer.
    public static let snapshotHistoryMaxEntries = 50

    // MARK: - Schedule Mode

    /// Whether the device is in schedule-driven mode (default: true).
    /// Centralized check to avoid scattered UserDefaults reads with inconsistent nil handling.
    public static func isScheduleDriven(defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)) -> Bool {
        // If the key was never set, default to schedule-driven.
        guard let defaults else { return true }
        return defaults.object(forKey: "scheduleDrivenMode") == nil
            || defaults.bool(forKey: "scheduleDrivenMode")
    }
}
