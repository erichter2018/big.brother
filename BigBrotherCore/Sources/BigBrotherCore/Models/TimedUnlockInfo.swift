import Foundation

/// State for a penalty-offset timed unlock registered with DeviceActivitySchedule.
/// Written by CommandProcessor, read by DeviceActivityMonitor extension.
public struct TimedUnlockInfo: Codable, Sendable {
    /// The command that initiated this timed unlock.
    public let commandID: UUID
    /// The DeviceActivityName used for the schedule.
    public let activityName: String
    /// When the device should unlock (after penalty expires).
    public let unlockAt: Date
    /// When the device should re-lock (end of total window).
    public let lockAt: Date
    /// The mode that was active before this timed unlock — restored on expiry.
    public let previousMode: LockMode?
    /// Monotonic system uptime when the timed unlock was created.
    /// Used to detect clock manipulation (wall clock set forward to skip penalty).
    public let uptimeAtStart: TimeInterval?
    /// When this timed unlock was created (wall clock).
    public let createdAt: Date?

    public init(commandID: UUID, activityName: String, unlockAt: Date, lockAt: Date, previousMode: LockMode? = nil,
                uptimeAtStart: TimeInterval? = ProcessInfo.processInfo.systemUptime, createdAt: Date? = Date()) {
        self.commandID = commandID
        self.activityName = activityName
        self.unlockAt = unlockAt
        // Graceful fallback: if lockAt is not after unlockAt, default to 60s after unlock
        self.lockAt = lockAt > unlockAt ? lockAt : unlockAt.addingTimeInterval(60)
        self.previousMode = previousMode
        self.uptimeAtStart = uptimeAtStart
        self.createdAt = createdAt
    }
}
