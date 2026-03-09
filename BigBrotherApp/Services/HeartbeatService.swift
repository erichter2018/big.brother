import Foundation
import BigBrotherCore

/// Periodic heartbeat publisher for child devices.
///
/// Sends a DeviceHeartbeat to CloudKit every 5 minutes containing:
/// - Current lock mode
/// - Policy version
/// - FamilyControls authorization status
/// - Battery level and charging state
///
/// Uses an upsert pattern: each device has exactly one BBHeartbeat record
/// that gets updated in place (recordID = deviceID).
///
/// The parent dashboard uses heartbeat data to show device online/offline status.
protocol HeartbeatServiceProtocol {
    /// Start periodic heartbeat sending (every 5 minutes).
    func startHeartbeat()

    /// Stop heartbeat (e.g., app going to background).
    func stopHeartbeat()

    /// Send one heartbeat immediately (e.g., after command application).
    /// - Parameter force: Skip dedup/backoff checks when true.
    func sendNow(force: Bool) async throws
}
