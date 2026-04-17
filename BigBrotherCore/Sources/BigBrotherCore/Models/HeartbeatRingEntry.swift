import Foundation

/// One entry in the app's recent-heartbeat ring buffer.
///
/// The main app writes up to the last 5 heartbeat sends here (App Group
/// key `recentHeartbeats`) so the kid's Diagnostics screen can display a
/// flow history locally, without needing to round-trip CloudKit.
///
/// Parent-side: the CK `DeviceHeartbeat` records are still the authority
/// for the dashboard; this ring buffer exists purely for on-device
/// self-reporting by the kid.
public struct HeartbeatRingEntry: Codable, Sendable, Equatable {
    /// Epoch seconds when the send completed successfully.
    public let epoch: TimeInterval
    /// Mode that was included in the heartbeat payload.
    public let mode: String
    /// Monotonic sequence number from the send loop.
    public let seq: Int64

    public init(epoch: TimeInterval, mode: String, seq: Int64) {
        self.epoch = epoch
        self.mode = mode
        self.seq = seq
    }
}
