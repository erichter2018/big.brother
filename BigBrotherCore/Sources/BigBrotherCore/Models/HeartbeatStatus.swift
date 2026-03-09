import Foundation

/// Local tracking of heartbeat upload health.
///
/// Persisted to App Group storage so the main app can expose
/// health info to UI and include status in diagnostics.
/// Uses immutable-update pattern: each state change returns a new instance.
public struct HeartbeatStatus: Codable, Sendable, Equatable {
    /// When the last heartbeat upload was attempted (regardless of outcome).
    public let lastAttemptAt: Date?

    /// When the last heartbeat was successfully uploaded.
    public let lastSuccessAt: Date?

    /// Number of consecutive failed upload attempts.
    public let consecutiveFailures: Int

    /// Reason for the most recent failure (nil if last attempt succeeded).
    public let lastFailureReason: String?

    /// Whether heartbeat uploads are healthy (no recent failures).
    public var isHealthy: Bool { consecutiveFailures == 0 }

    /// Whether the service should back off based on failure count.
    /// Exponential backoff: 2^failures * base interval, capped at 30 minutes.
    public func backoffSeconds(baseInterval: TimeInterval = 10) -> TimeInterval {
        guard consecutiveFailures > 0 else { return 0 }
        let backoff = baseInterval * pow(2.0, Double(min(consecutiveFailures, 10)))
        return min(backoff, 1800)
    }

    /// Whether enough time has passed since the last attempt to retry,
    /// given the current backoff.
    public func shouldRetry(at time: Date = Date(), baseInterval: TimeInterval = 10) -> Bool {
        guard let lastAttempt = lastAttemptAt else { return true }
        let elapsed = time.timeIntervalSince(lastAttempt)
        return elapsed >= backoffSeconds(baseInterval: baseInterval)
    }

    /// Whether a heartbeat was recently sent (within the given window).
    /// Used to avoid duplicate sends when quick sync already included a heartbeat.
    public func wasRecentlySent(within window: TimeInterval, at time: Date = Date()) -> Bool {
        guard let lastSuccess = lastSuccessAt else { return false }
        return time.timeIntervalSince(lastSuccess) < window
    }

    /// Fresh status with no history.
    public static let initial = HeartbeatStatus(
        lastAttemptAt: nil,
        lastSuccessAt: nil,
        consecutiveFailures: 0,
        lastFailureReason: nil
    )

    /// Record that an attempt was started.
    public func recordingAttempt(at time: Date = Date()) -> HeartbeatStatus {
        HeartbeatStatus(
            lastAttemptAt: time,
            lastSuccessAt: lastSuccessAt,
            consecutiveFailures: consecutiveFailures,
            lastFailureReason: lastFailureReason
        )
    }

    /// Record a successful upload.
    public func recordingSuccess(at time: Date = Date()) -> HeartbeatStatus {
        HeartbeatStatus(
            lastAttemptAt: time,
            lastSuccessAt: time,
            consecutiveFailures: 0,
            lastFailureReason: nil
        )
    }

    /// Record a failed upload.
    public func recordingFailure(reason: String, at time: Date = Date()) -> HeartbeatStatus {
        HeartbeatStatus(
            lastAttemptAt: time,
            lastSuccessAt: lastSuccessAt,
            consecutiveFailures: consecutiveFailures + 1,
            lastFailureReason: reason
        )
    }

    public init(
        lastAttemptAt: Date?,
        lastSuccessAt: Date?,
        consecutiveFailures: Int,
        lastFailureReason: String?
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.consecutiveFailures = consecutiveFailures
        self.lastFailureReason = lastFailureReason
    }
}
