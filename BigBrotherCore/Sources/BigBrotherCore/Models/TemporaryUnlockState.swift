import Foundation

/// How the temporary unlock was initiated.
public enum TemporaryUnlockOrigin: String, Codable, Sendable, Equatable {
    /// Unlock triggered by a parent via remote command.
    case remoteCommand

    /// Unlock triggered by local PIN entry on the child device.
    case localPINUnlock
}

/// Durable metadata about an active (or recently expired) temporary unlock.
///
/// Persisted to App Group storage so that:
/// - Launch restoration can re-evaluate expiry correctly
/// - The previous mode is known for deterministic re-lock
/// - The origin (remote vs local PIN) is recorded for audit
public struct TemporaryUnlockState: Codable, Sendable, Equatable {
    /// Unique identifier for this unlock session.
    public let unlockID: UUID

    /// How this unlock was initiated.
    public let origin: TemporaryUnlockOrigin

    /// The mode that was active before the unlock.
    /// Used to revert when the unlock expires.
    public let previousMode: LockMode

    /// When the unlock started.
    public let startedAt: Date

    /// When the unlock expires.
    public let expiresAt: Date

    /// The command ID that triggered this unlock, if remote.
    public let commandID: UUID?

    /// Whether the unlock has expired.
    public var isExpired: Bool { isExpired(at: Date()) }

    /// Whether the unlock is currently active.
    public var isActive: Bool { !isExpired }

    /// Check expiry at a specific time (for testing / clock-edge handling).
    public func isExpired(at time: Date) -> Bool {
        time >= expiresAt
    }

    /// Duration remaining from a given time, clamped to zero.
    public func remainingSeconds(at time: Date = Date()) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(time))
    }

    public init(
        unlockID: UUID = UUID(),
        origin: TemporaryUnlockOrigin,
        previousMode: LockMode,
        startedAt: Date = Date(),
        expiresAt: Date,
        commandID: UUID? = nil
    ) {
        self.unlockID = unlockID
        self.origin = origin
        self.previousMode = previousMode
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.commandID = commandID
    }
}
