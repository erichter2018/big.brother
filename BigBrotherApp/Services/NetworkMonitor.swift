import Foundation
import Network
import Observation

/// Monitors network connectivity for UI indicators.
@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isConnected = true
    /// Human-readable interface kind: "wifi", "cell", "wired", "loopback",
    /// "other", "none". Useful for diagnostics — lets a parent see at a
    /// glance whether the kid is on Wi-Fi or cellular/hotspot when
    /// troubleshooting "internet not working".
    private(set) var interfaceKind: String = "?"
    /// iOS considers a path "expensive" when it uses cellular data. The
    /// same flag appears for Personal Hotspot, which is the single most
    /// useful tell-tale when a kid reports weird internet behavior.
    private(set) var isExpensive: Bool = false
    /// `constrained` is Apple's Low-Data Mode signal — user or system has
    /// asked iOS to minimize background network.
    private(set) var isConstrained: Bool = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "fr.bigbrother.network-monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = Self.describe(path)
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.isConnected = satisfied
                self?.interfaceKind = kind
                self?.isExpensive = expensive
                self?.isConstrained = constrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    nonisolated private static func describe(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cell" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        if path.usesInterfaceType(.loopback) { return "loopback" }
        if path.status == .satisfied { return "other" }
        return "none"
    }
}
