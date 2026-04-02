import Foundation

/// Who is currently driving the device's enforcement mode.
///
/// Replaces the binary `scheduleDrivenMode` UserDefaults flag with a proper
/// state machine. Stored in PolicySnapshot and ExtensionSharedState so all
/// processes (main app, Monitor, Tunnel) agree on who is in charge.
///
/// Priority order (ModeStackResolver):
///   temporaryUnlock > timedUnlock > lockUntil > schedule > parentManual > failSafe
public enum ControlAuthority: String, Codable, Sendable, Equatable {
    /// Device follows the active schedule profile (default).
    case schedule

    /// Parent explicitly set a mode (setMode command). Schedule is overridden.
    case parentManual

    /// Parent-granted temporary unlock is active.
    case temporaryUnlock

    /// Timed unlock is active (penalty or free phase).
    case timedUnlock

    /// Parent locked device until a specific time.
    case lockUntil

    /// Child used a self-unlock from their daily budget.
    case selfUnlock

    /// Enforcement is in a degraded/fail-safe state (permission loss, etc.).
    case failSafe
}
