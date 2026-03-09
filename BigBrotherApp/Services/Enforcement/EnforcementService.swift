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
}

/// Simplified authorization status (avoids exposing FamilyControls types
/// to code that only needs to check status).
enum FCAuthorizationStatus: String, Sendable {
    case notDetermined
    case authorized
    case denied
}
