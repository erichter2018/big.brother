import Foundation
import NetworkExtension
import BigBrotherCore

/// Manages the VPN tunnel configuration and communication with the
/// PacketTunnelProvider extension.
///
/// The VPN tunnel provides persistent background execution — iOS keeps
/// the tunnel process alive even when the main app is force-closed.
/// Connect On Demand rules ensure auto-restart after disconnect/reboot.
final class VPNManagerService {

    /// Current VPN connection status.
    private(set) var connectionStatus: NEVPNStatus = .invalid

    /// Notification observer for status changes.
    private var statusObserver: Any?
    /// Last status we logged — suppresses identical repeat log lines when the
    /// system re-posts NEVPNStatusDidChange for a status that didn't change.
    private var lastLoggedStatus: NEVPNStatus = .invalid

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let connection = notification.object as? NEVPNConnection else { return }
            // Filter: only react to status changes on OUR tunnel. The observer
            // fires for every VPN on the device (Private Relay, other VPN apps
            // like NordVPN etc). Without this guard, one kid who had a second
            // VPN installed produced 100+ "Status changed: 3" log entries per
            // foreground sync because her other VPN was continuously re-
            // posting its connected status.
            if let tunnelProtocol = connection.manager.protocolConfiguration as? NETunnelProviderProtocol,
               tunnelProtocol.providerBundleIdentifier != AppConstants.tunnelBundleID {
                return
            }
            self.connectionStatus = connection.status
            // Deduplicate identical consecutive statuses even for our own tunnel —
            // iOS sometimes re-posts .connected during ping cycles.
            if self.lastLoggedStatus != connection.status {
                self.lastLoggedStatus = connection.status
                #if DEBUG
                print("[VPN] Status changed: \(connection.status.rawValue)")
                #endif
            }
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Configuration

    /// Install the VPN configuration and start the tunnel.
    /// Called during child enrollment and on each app launch.
    /// Safe to call repeatedly — updates existing configuration if present.
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
        // Don't disconnect on sleep — keep heartbeats flowing overnight
        proto.disconnectOnSleep = false

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Big Brother Protection"
        manager.isEnabled = true

        // Connect On Demand: auto-reconnect whenever network is available.
        // This makes the tunnel persistent across network changes, reboots,
        // and even manual disconnect from Control Center.
        let connectRule = NEOnDemandRuleConnect()
        connectRule.interfaceTypeMatch = .any
        manager.onDemandRules = [connectRule]
        manager.isOnDemandEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences() // Required after save

        // Restart the tunnel if the build changed (picks up new extension code).
        // Without this, the tunnel process keeps running old code after app updates.
        if let existing, manager.connection.status == .connected || manager.connection.status == .connecting {
            let oldConfig = (existing.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            let oldBuild = oldConfig?["version"] as? Int ?? 0
            if oldBuild != AppConstants.appBuildNumber {
                NSLog("[VPN] Build mismatch: tunnel=b\(oldBuild) app=b\(AppConstants.appBuildNumber) — restarting tunnel")
                manager.connection.stopVPNTunnel()
                // Wait for tunnel to fully stop (500ms is often not enough)
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if manager.connection.status == .disconnected { break }
                }
                if manager.connection.status != .disconnected {
                    NSLog("[VPN] Tunnel didn't stop cleanly (status=\(manager.connection.status.rawValue)), starting anyway")
                }
            }
        }

        // Start the tunnel if not already connected
        if manager.connection.status != .connected && manager.connection.status != .connecting {
            try manager.connection.startVPNTunnel()
            NSLog("[VPN] Tunnel started on b\(AppConstants.appBuildNumber)")
        }

        connectionStatus = manager.connection.status
        #if DEBUG
        print("[VPN] Configuration installed, status: \(manager.connection.status.rawValue)")
        #endif
    }

    /// Check if the VPN configuration is installed and the tunnel is connected.
    var isConnected: Bool {
        connectionStatus == .connected
    }

    /// Check if a VPN configuration exists (even if disconnected).
    func isConfigured() async -> Bool {
        guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences() else {
            return false
        }
        return managers.contains {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == AppConstants.tunnelBundleID
        }
    }

    // MARK: - IPC

    /// Send a ping to the tunnel extension to prove the main app is alive.
    func sendPing() {
        Task {
            guard let session = await tunnelSession() else { return }
            try? session.sendProviderMessage("ping".data(using: .utf8)!) { _ in }
        }
    }

    /// Request the tunnel to send an immediate heartbeat.
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

    /// Get the tunnel's current status.
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
