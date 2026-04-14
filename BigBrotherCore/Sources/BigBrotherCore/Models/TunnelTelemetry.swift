import Foundation

/// Per-day counters tracking the tunnel's DNS proxy health and recovery
/// activity. Populated by `BigBrotherTunnel/PacketTunnelProvider.swift`
/// and `BigBrotherTunnel/DNSProxy.swift`; rendered by the parent's
/// Remote Diagnostics UI.
///
/// Purpose: give the parent a way to tell WHICH internet-loss failure
/// mode a kid hit, without pulling raw logs. If `dnsProbeTimeouts > 0`
/// and `dnsReconnects > 0`, the b545 wedge-probe caught a real dead
/// interface and recovered it. If those are 0 and the kid still lost
/// internet, the root cause is elsewhere (CloudKit auth, carrier issue,
/// tunnel process killed by iOS, etc.) and we dig into the next counter.
///
/// Counters reset at local midnight — on any write, if `dateString`
/// differs from today, the whole struct is zeroed out (and yesterday's
/// snapshot preserved under `AppGroupKeys.tunnelTelemetryYesterday`).
public struct TunnelTelemetry: Codable, Equatable, Sendable {

    /// "YYYY-MM-DD" in the device's local time zone. When the stored
    /// value differs from today's, counters get reset on the next write.
    public var dateString: String

    // MARK: - DNS proxy health

    /// Active probes that timed out waiting for an upstream response.
    /// Every timeout triggers a `reconnectUpstream()`. A non-zero count
    /// is a direct positive signal that the b545 wedge-probe fix fired
    /// and caught a dead NWUDPSession.
    public var dnsProbeTimeouts: Int

    /// Upstream reconnect events. Includes reconnects triggered by probe
    /// timeout, `.cancelled`/`.failed` session state, pending-queue
    /// stall, and write errors.
    public var dnsReconnects: Int

    /// Upstream UDP write errors observed by the DNS proxy. Each error
    /// flags the session for reconnect on the next client query
    /// (see `markUpstreamUnhealthy` + `reconnectIfFlagged`).
    public var dnsUpstreamWriteErrors: Int

    /// Unix epoch (seconds) of the most recent reconnect, or nil if no
    /// reconnect has happened today. Useful for correlating with a
    /// kid's complaint: "Safari broke at 3:42, last reconnect 3:43" =
    /// the fix caught it.
    public var lastReconnectAt: TimeInterval?

    /// Unix epoch (seconds) of the most recent probe timeout.
    public var lastProbeTimeoutAt: TimeInterval?

    // MARK: - Network path / interface

    /// Number of network path transitions (wifi ↔ cellular / interface
    /// swaps) observed by the tunnel's `NWPathMonitor`.
    public var pathChanges: Int

    /// Network-health recovery ladder escalations (L1-L4) that fired
    /// today. Each level is more invasive than the last.
    public var networkRecoveryL1: Int
    public var networkRecoveryL2: Int
    public var networkRecoveryL3: Int
    public var networkRecoveryL4: Int

    // MARK: - Tunnel process

    /// Number of times `PacketTunnelProvider.startTunnel` ran. iOS
    /// kills and restarts Network Extension processes under memory
    /// pressure — a high count here means iOS is churning the tunnel.
    public var tunnelStarts: Int

    public init(
        dateString: String,
        dnsProbeTimeouts: Int = 0,
        dnsReconnects: Int = 0,
        dnsUpstreamWriteErrors: Int = 0,
        lastReconnectAt: TimeInterval? = nil,
        lastProbeTimeoutAt: TimeInterval? = nil,
        pathChanges: Int = 0,
        networkRecoveryL1: Int = 0,
        networkRecoveryL2: Int = 0,
        networkRecoveryL3: Int = 0,
        networkRecoveryL4: Int = 0,
        tunnelStarts: Int = 0
    ) {
        self.dateString = dateString
        self.dnsProbeTimeouts = dnsProbeTimeouts
        self.dnsReconnects = dnsReconnects
        self.dnsUpstreamWriteErrors = dnsUpstreamWriteErrors
        self.lastReconnectAt = lastReconnectAt
        self.lastProbeTimeoutAt = lastProbeTimeoutAt
        self.pathChanges = pathChanges
        self.networkRecoveryL1 = networkRecoveryL1
        self.networkRecoveryL2 = networkRecoveryL2
        self.networkRecoveryL3 = networkRecoveryL3
        self.networkRecoveryL4 = networkRecoveryL4
        self.tunnelStarts = tunnelStarts
    }

    public static func todayDateString(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: now)
    }

    public static func empty(for dateString: String) -> TunnelTelemetry {
        TunnelTelemetry(dateString: dateString)
    }

    // MARK: - Persistence

    /// Serialization lock — writes from DNSProxy (multiple queues) and
    /// PacketTunnelProvider (liveness timer) can race without this.
    private static let ioLock = NSLock()

    /// Load today's telemetry from app-group UserDefaults. Returns an
    /// empty record dated today if no prior data exists or the stored
    /// record is from a previous day (in which case the prior record is
    /// archived as "yesterday").
    public static func load(defaults: UserDefaults? = UserDefaults.appGroup) -> TunnelTelemetry {
        let today = todayDateString()
        guard let defaults else { return empty(for: today) }
        ioLock.lock(); defer { ioLock.unlock() }
        if let data = defaults.data(forKey: AppGroupKeys.tunnelTelemetry),
           let decoded = try? JSONDecoder().decode(TunnelTelemetry.self, from: data),
           decoded.dateString == today {
            return decoded
        }
        // Rollover: preserve yesterday's snapshot if one exists and is
        // older than today.
        if let data = defaults.data(forKey: AppGroupKeys.tunnelTelemetry),
           let decoded = try? JSONDecoder().decode(TunnelTelemetry.self, from: data),
           decoded.dateString != today {
            defaults.set(data, forKey: AppGroupKeys.tunnelTelemetryYesterday)
        }
        return empty(for: today)
    }

    /// Read-modify-write the current telemetry record. Handles midnight
    /// rollover internally. The mutation closure sees a telemetry dated
    /// today — callers just bump counters, they don't care about dates.
    @discardableResult
    public static func update(
        defaults: UserDefaults? = UserDefaults.appGroup,
        _ mutation: (inout TunnelTelemetry) -> Void
    ) -> TunnelTelemetry {
        var current = load(defaults: defaults)
        mutation(&current)
        save(current, defaults: defaults)
        return current
    }

    public static func save(
        _ telemetry: TunnelTelemetry,
        defaults: UserDefaults? = UserDefaults.appGroup
    ) {
        guard let defaults,
              let encoded = try? JSONEncoder().encode(telemetry) else { return }
        ioLock.lock(); defer { ioLock.unlock() }
        defaults.set(encoded, forKey: AppGroupKeys.tunnelTelemetry)
    }

    public static func loadYesterday(
        defaults: UserDefaults? = UserDefaults.appGroup
    ) -> TunnelTelemetry? {
        guard let defaults,
              let data = defaults.data(forKey: AppGroupKeys.tunnelTelemetryYesterday),
              let decoded = try? JSONDecoder().decode(TunnelTelemetry.self, from: data)
        else { return nil }
        return decoded
    }
}
