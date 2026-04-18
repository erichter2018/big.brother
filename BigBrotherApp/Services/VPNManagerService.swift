import Foundation
import NetworkExtension
import BigBrotherCore

final class VPNManagerService {

    private(set) var connectionStatus: NEVPNStatus = .invalid
    private var statusObserver: Any?
    private var lastLoggedStatus: NEVPNStatus = .invalid
    private var lastRestartAt: Date?
    /// Counts consecutive restart failures. Used to apply exponential-style
    /// throttle so a permanently-broken VPN config doesn't hammer the system
    /// once a minute for the life of the app.
    private var consecutiveRestartFailures: Int = 0

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let connection = notification.object as? NEVPNConnection else { return }
            if let tunnelProtocol = connection.manager.protocolConfiguration as? NETunnelProviderProtocol,
               tunnelProtocol.providerBundleIdentifier != AppConstants.tunnelBundleID {
                return
            }
            self.connectionStatus = connection.status
            if self.lastLoggedStatus != connection.status {
                self.lastLoggedStatus = connection.status
                BBLog("[VPN] Status changed: \(connection.status.rawValue)")
            }
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Configuration

    func installAndStart() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let existing = managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == AppConstants.tunnelBundleID
        }

        let manager = existing ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleID
        proto.serverAddress = "BigBrother Local"
        proto.providerConfiguration = ["version": AppConstants.appBuildNumber]
        proto.disconnectOnSleep = false

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Big Brother Protection"
        manager.isEnabled = true

        let connectRule = NEOnDemandRuleConnect()
        connectRule.interfaceTypeMatch = .any
        manager.onDemandRules = [connectRule]
        manager.isOnDemandEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        if let existing, manager.connection.status == .connected || manager.connection.status == .connecting {
            let oldConfig = (existing.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            let oldBuild = oldConfig?["version"] as? Int ?? 0
            if oldBuild != AppConstants.appBuildNumber {
                BBLog("[VPN] Build mismatch: tunnel=b\(oldBuild) app=b\(AppConstants.appBuildNumber) — restarting tunnel")
                manager.connection.stopVPNTunnel()
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if manager.connection.status == .disconnected { break }
                }
            }
        }

        if manager.connection.status != .connected && manager.connection.status != .connecting {
            try manager.connection.startVPNTunnel()
            BBLog("[VPN] Tunnel started on b\(AppConstants.appBuildNumber)")
        }

        connectionStatus = manager.connection.status
        lastRestartAt = Date()
    }

    var isConnected: Bool {
        connectionStatus == .connected
    }

    func liveConnectionStatus() async -> NEVPNStatus {
        guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences(),
              let manager = managers.first(where: {
                  ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                      .providerBundleIdentifier == AppConstants.tunnelBundleID
              }) else { return .invalid }
        let live = manager.connection.status
        connectionStatus = live
        return live
    }

    func isConfigured() async -> Bool {
        guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences() else {
            return false
        }
        return managers.contains {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == AppConstants.tunnelBundleID
        }
    }

    func restartIfNeeded() async {
        let live = await liveConnectionStatus()
        guard live != .connected && live != .connecting else {
            // Healthy — reset failure counter.
            if consecutiveRestartFailures > 0 {
                consecutiveRestartFailures = 0
            }
            return
        }
        // Exponential throttle: 60s after 0–1 failures, 120s after 2, 300s after 3,
        // 600s (10min) after 4+. Prevents battery drain if VPN can't come up at all
        // (permission revoked, config corrupt, etc.) — previously we'd retry every
        // 60s indefinitely, quietly swallowing errors via `try?`.
        let throttle: TimeInterval = {
            switch consecutiveRestartFailures {
            case 0...1: return 60
            case 2: return 120
            case 3: return 300
            default: return 600
            }
        }()
        if let last = lastRestartAt, Date().timeIntervalSince(last) < throttle { return }
        // Stamp the attempt time BEFORE calling installAndStart. installAndStart
        // only writes `lastRestartAt` on its success path — if it throws, the
        // field would stay stale and the throttle check above would let another
        // retry fire immediately on the next heartbeat tick, defeating the
        // whole backoff strategy (caught by Gemini round-2 audit).
        lastRestartAt = Date()
        BBLog("[VPN] Tunnel disconnected (status=\(live.rawValue)), failures=\(consecutiveRestartFailures), throttle=\(Int(throttle))s — restarting")
        do {
            try await installAndStart()
            consecutiveRestartFailures = 0
        } catch {
            consecutiveRestartFailures += 1
            BBLog("[VPN] Restart failed (attempt #\(consecutiveRestartFailures)): \(error.localizedDescription)")
        }
    }

    // MARK: - IPC

    func sendPing() {
        Task {
            guard let session = await tunnelSession() else { return }
            try? session.sendProviderMessage("ping".data(using: .utf8)!) { _ in }
        }
    }

    func requestHeartbeat() async {
        guard let session = await tunnelSession() else { return }
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            do {
                try session.sendProviderMessage("forceHeartbeat".data(using: .utf8)!) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func getTunnelStatus() async -> [String: Any]? {
        guard let session = await tunnelSession() else { return nil }
        let data = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            do {
                try session.sendProviderMessage("status".data(using: .utf8)!) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Private

    private func tunnelSession() async -> NETunnelProviderSession? {
        guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences(),
              let manager = managers.first(where: {
                  ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                      .providerBundleIdentifier == AppConstants.tunnelBundleID
              }),
              let session = manager.connection as? NETunnelProviderSession else {
            return nil
        }
        return session
    }
}
