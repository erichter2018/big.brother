import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

/// Detect active user-configured VPN connections.
///
/// Checks two signals:
/// 1. CFNetworkCopySystemProxySettings for VPN-specific routing entries
///    (ipsec/ppp interfaces in __SCOPED__ — these are unambiguously VPN)
/// 2. Network interface dictionary keys that indicate active VPN tunnels
///
/// Deliberately excludes utun interfaces to avoid false positives from
/// iCloud Private Relay and other Apple system tunnels.
public struct VPNDetector {

    /// Returns true if a user-configured VPN tunnel is currently active.
    public static func isVPNActive() -> Bool {
        #if canImport(CFNetwork)
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else {
            return false
        }
        // Only flag interfaces that are unambiguously user VPNs.
        // ipsec = IPSec VPN, ppp = L2TP/PPTP VPN, tap = OpenVPN tap adapter.
        // Exclude tun/utun — these are used by iCloud Private Relay, Hotspot,
        // and other system services on modern iOS.
        let vpnPrefixes = ["ipsec", "ppp", "tap"]
        return scoped.keys.contains { key in
            let lower = key.lowercased()
            return vpnPrefixes.contains { lower.hasPrefix($0) }
        }
        #else
        return false
        #endif
    }
}
