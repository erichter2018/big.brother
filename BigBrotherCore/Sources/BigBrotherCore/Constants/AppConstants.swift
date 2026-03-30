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
    public static let appBuildNumber = 215

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

    /// Heartbeat age threshold for force-close when device is locked (20 min).
    /// Shorter than unlocked because a locked device has no reason to suspend the app.
    public static let forceCloseThresholdLocked: TimeInterval = 1200

    /// Heartbeat age threshold for force-close when device is unlocked (45 min).
    /// Longer to avoid false positives from resource-intensive games suspending the app.
    public static let forceCloseThresholdUnlocked: TimeInterval = 2700

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

    /// Named store for base policy enforcement.
    public static let managedSettingsStoreBase = "base"

    /// Named store for schedule-based enforcement (used by extension).
    public static let managedSettingsStoreSchedule = "schedule"

    /// Named store for temporary unlock.
    public static let managedSettingsStoreTempUnlock = "tempUnlock"

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

    // MARK: - Snapshot History

    /// Maximum number of snapshot transitions to retain in history buffer.
    public static let snapshotHistoryMaxEntries = 50
}
