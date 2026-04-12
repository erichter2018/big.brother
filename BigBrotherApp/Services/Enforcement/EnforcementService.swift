import Foundation
import BigBrotherCore

/// Applies and clears ManagedSettings restrictions based on EffectivePolicy.
///
/// This is the bridge between the pure PolicyResolver output and the
/// ManagedSettings framework. Only imported in the main app target
/// (extensions use their own ManagedSettingsStore access directly).
///
/// Named stores used:
///   - "base": primary enforcement from parent-set mode
///   - "schedule": set by DeviceActivityMonitor extension on schedule events
///   - "tempUnlock": clears restrictions during temporary unlock
protocol EnforcementServiceProtocol {
    /// Apply the given effective policy to the "base" ManagedSettingsStore.
    /// Decodes serialized token data and configures shield settings.
    func apply(_ policy: EffectivePolicy) throws

    /// Clear all restrictions from the "base" store (unlocked mode).
    func clearAllRestrictions() throws

    /// Clear the "tempUnlock" store (temporary unlock expired).
    func clearTemporaryUnlock() throws

    /// Current FamilyControls authorization status.
    var authorizationStatus: FCAuthorizationStatus { get }

    /// Request FamilyControls .individual authorization.
    /// Should be called during enrollment with parent physically present.
    func requestAuthorization() async throws

    /// Reconcile: verify that ManagedSettingsStore matches the current
    /// PolicySnapshot. Reapply if mismatched. Called on app launch.
    func reconcile(with snapshot: PolicySnapshot) throws

    /// Apply essential-only mode (block all apps, no exemptions).
    /// Used when the child denies required permissions (VPN, FamilyControls).
    func applyEssentialOnly() throws

    /// Read current shield state from ManagedSettingsStore for diagnostic reporting.
    func shieldDiagnostic() -> ShieldDiagnostic

    /// Compute per-token shield verdicts (union of picker + always-allowed +
    /// exhausted time-limit tokens, each stamped with the expected block
    /// verdict for `mode`). Used by the heartbeat diagnostic snapshot and by
    /// the automated test harness to assert that mode transitions produce
    /// the correct per-app behavior.
    func computeTokenVerdicts(for mode: LockMode) -> [DiagnosticSnapshot.TokenVerdict]

    /// Reset the nuclear enforcement throttle. Call on each fresh app launch
    /// so deploy-driven restarts get a clean slate of reset attempts.
    func resetThrottle()

    /// Force the daemon rescue sequence unconditionally. Called on every
    /// foreground sync so opening BB always attempts to un-wedge a stuck
    /// ManagedSettings daemon. Idempotent: if the daemon is healthy this is
    /// a few extra no-op writes. If it's wedged, the 4-step rescue ladder
    /// (DeviceActivity kick, state-machine flush, clearAllSettings, auth
    /// re-request) tries to kick it free without requiring any user action
    /// beyond opening the app.
    func forceDaemonRescue()
}

/// Snapshot of the current ManagedSettingsStore shield state for heartbeat diagnostics.
struct ShieldDiagnostic {
    let shieldsActive: Bool
    let appCount: Int
    let categoryActive: Bool
    var webBlockingActive: Bool = false
    var denyAppRemoval: Bool = false
}

/// Simplified authorization status (avoids exposing FamilyControls types
/// to code that only needs to check status).
enum FCAuthorizationStatus: String, Sendable {
    case notDetermined
    case authorized
    case denied
}
