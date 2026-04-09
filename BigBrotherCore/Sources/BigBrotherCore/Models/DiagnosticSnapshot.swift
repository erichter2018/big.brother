import Foundation

/// Structured diagnostic snapshot embedded in every heartbeat.
/// Machine-parseable JSON — parent app renders it into a nice UI.
/// Replaces the freeform string snapshot for faster, richer diagnostics.
public struct DiagnosticSnapshot: Codable, Sendable {

    // MARK: - Mode State

    /// Current resolved mode (unlocked, restricted, locked, lockedDown).
    public let mode: String
    /// Who is driving this mode (schedule, parentManual, temporaryUnlock, etc.).
    public let authority: String
    /// ModeStackResolver reason string.
    public let reason: String
    /// Whether this is a temporary mode.
    public let isTemporary: Bool
    /// When the temporary mode expires (nil if not temporary).
    public let expiresAt: Date?

    // MARK: - Shield State

    /// Whether shields are currently active (from ManagedSettingsStore read).
    public let shieldsUp: Bool
    /// Whether shields SHOULD be up based on resolved mode.
    public let shieldsExpected: Bool
    /// Number of individually shielded apps.
    public let shieldedAppCount: Int
    /// Whether category-wide shield is active.
    public let categoryShieldActive: Bool
    /// Whether web domains are blocked.
    public let webBlocked: Bool
    /// Last shield change reason.
    public let shieldReason: String?
    /// Shield audit fingerprint (hash of what was written).
    public let shieldAudit: String?

    // MARK: - Component Liveness

    /// Build numbers for each component.
    public let builds: ComponentBuilds
    /// Seconds since Monitor last ran.
    public let monitorAge: Int?
    /// Seconds since tunnel last ran.
    public let tunnelAge: Int?
    /// Whether the VPN tunnel is connected.
    public let tunnelConnected: Bool?

    // MARK: - Schedule

    /// Active schedule profile name (nil if none).
    public let scheduleName: String?
    /// Whether schedule-driven mode is ON.
    public let scheduleDriven: Bool
    /// Current schedule window (e.g., "unlocked 3:00-3:15 PM").
    public let scheduleWindow: String?

    // MARK: - Temp Unlock

    /// Active temp unlock remaining seconds (nil if none).
    public let tempUnlockRemaining: Int?
    /// Temp unlock origin (selfUnlock, parentUnlock, etc.).
    public let tempUnlockOrigin: String?

    // MARK: - Restrictions & Internet

    /// Whether denyWebWhenRestricted is set on device.
    public let denyWebWhenRestricted: Bool?
    /// Whether denyAppRemoval is set.
    public let denyAppRemoval: Bool?
    /// Whether VPN tunnel has internet blocked (DNS blackhole active).
    public let internetBlocked: Bool?
    /// Reason for internet block (e.g., "lockedDown", "buildMismatch").
    public let internetBlockReason: String?
    /// Number of domains blocked by DNS enforcement.
    public let dnsBlockedDomains: Int?

    // MARK: - Recent Transitions (THE KEY DATA)

    /// Last 10 mode transitions with timestamps, sources, and shield state.
    public let transitions: [TransitionEntry]

    // MARK: - Recent Enforcement Actions

    /// Last 15 enforcement log entries (compact).
    public let recentLogs: [LogEntry]

    // MARK: - Nested Types

    public struct ComponentBuilds: Codable, Sendable {
        public let app: Int
        public let tunnel: Int
        public let monitor: Int
        public let shield: Int
        public let shieldAction: Int

        public init(app: Int, tunnel: Int, monitor: Int, shield: Int, shieldAction: Int) {
            self.app = app; self.tunnel = tunnel; self.monitor = monitor
            self.shield = shield; self.shieldAction = shieldAction
        }
    }

    public struct TransitionEntry: Codable, Sendable {
        /// When the transition happened.
        public let at: Date
        /// Mode before.
        public let from: String
        /// Mode after.
        public let to: String
        /// What triggered it (schedule, parentManual, command, monitor, etc.).
        public let source: String
        /// Control authority after transition.
        public let authority: String
        /// Whether shields were confirmed UP after transition.
        public let shieldsUp: Bool?
        /// Human-readable changes.
        public let changes: [String]

        public init(at: Date, from: String, to: String, source: String,
                    authority: String, shieldsUp: Bool?, changes: [String]) {
            self.at = at; self.from = from; self.to = to; self.source = source
            self.authority = authority; self.shieldsUp = shieldsUp; self.changes = changes
        }
    }

    public struct LogEntry: Codable, Sendable {
        public let at: Date
        public let msg: String

        public init(at: Date, msg: String) {
            self.at = at; self.msg = msg
        }
    }

    public init(
        mode: String, authority: String, reason: String, isTemporary: Bool, expiresAt: Date?,
        shieldsUp: Bool, shieldsExpected: Bool, shieldedAppCount: Int,
        categoryShieldActive: Bool, webBlocked: Bool, shieldReason: String?, shieldAudit: String?,
        builds: ComponentBuilds, monitorAge: Int?, tunnelAge: Int?, tunnelConnected: Bool?,
        scheduleName: String?, scheduleDriven: Bool, scheduleWindow: String?,
        tempUnlockRemaining: Int?, tempUnlockOrigin: String?,
        denyWebWhenRestricted: Bool?, denyAppRemoval: Bool?,
        internetBlocked: Bool? = nil, internetBlockReason: String? = nil, dnsBlockedDomains: Int? = nil,
        transitions: [TransitionEntry], recentLogs: [LogEntry]
    ) {
        self.mode = mode; self.authority = authority; self.reason = reason
        self.isTemporary = isTemporary; self.expiresAt = expiresAt
        self.shieldsUp = shieldsUp; self.shieldsExpected = shieldsExpected
        self.shieldedAppCount = shieldedAppCount; self.categoryShieldActive = categoryShieldActive
        self.webBlocked = webBlocked; self.shieldReason = shieldReason; self.shieldAudit = shieldAudit
        self.builds = builds; self.monitorAge = monitorAge; self.tunnelAge = tunnelAge
        self.tunnelConnected = tunnelConnected; self.scheduleName = scheduleName
        self.scheduleDriven = scheduleDriven; self.scheduleWindow = scheduleWindow
        self.tempUnlockRemaining = tempUnlockRemaining; self.tempUnlockOrigin = tempUnlockOrigin
        self.denyWebWhenRestricted = denyWebWhenRestricted; self.denyAppRemoval = denyAppRemoval
        self.internetBlocked = internetBlocked; self.internetBlockReason = internetBlockReason
        self.dnsBlockedDomains = dnsBlockedDomains
        self.transitions = transitions; self.recentLogs = recentLogs
    }
}
