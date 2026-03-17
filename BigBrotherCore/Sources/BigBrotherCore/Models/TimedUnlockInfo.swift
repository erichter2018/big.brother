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

    public init(commandID: UUID, activityName: String, unlockAt: Date, lockAt: Date) {
        assert(lockAt > unlockAt, "lockAt must be after unlockAt")
        self.commandID = commandID
        self.activityName = activityName
        self.unlockAt = unlockAt
        self.lockAt = lockAt
    }
}
