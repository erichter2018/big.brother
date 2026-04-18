import Foundation
import NetworkExtension
import BigBrotherCore

final class VPNManagerService {

    private(set) var connectionStatus: NEVPNStatus = .invalid
    private var statusObserver: Any?
    private var lastLoggedStatus: NEVPNStatus = .invalid
    private var lastRestartAt: Date?

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
        guard live != .connected && live != .connecting else { return }
        if let last = lastRestartAt, Date().timeIntervalSince(last) < 60 { return }
        BBLog("[VPN] Tunnel disconnected (status=\(live.rawValue)) — restarting")
        try? await installAndStart()
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
