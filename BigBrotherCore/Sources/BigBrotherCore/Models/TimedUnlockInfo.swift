import Foundation
import Darwin

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
    /// Monotonic continuous clock reading (`CLOCK_MONOTONIC_RAW`) captured at
    /// creation. Persisted as seconds. Used to detect wall-clock manipulation.
    /// Uses the continuous monotonic clock (not `ProcessInfo.systemUptime`,
    /// which pauses while the device sleeps — a screen-lock during penalty
    /// would look like clock advance and falsely trap the child in penalty).
    public let uptimeAtStart: TimeInterval?
    /// When this timed unlock was created (wall clock).
    public let createdAt: Date?

    public init(commandID: UUID, activityName: String, unlockAt: Date, lockAt: Date, previousMode: LockMode? = nil,
                uptimeAtStart: TimeInterval? = TimedUnlockInfo.currentMonotonicSeconds(), createdAt: Date? = Date()) {
        self.commandID = commandID
        self.activityName = activityName
        self.unlockAt = unlockAt
        // Allow lockAt == unlockAt ("penalty for entire window, no free phase"
        // — used by the penalty>=total branch) but still guard against
        // lockAt < unlockAt (caller bug) by clamping to unlockAt+60s.
        self.lockAt = lockAt >= unlockAt ? lockAt : unlockAt.addingTimeInterval(60)
        self.previousMode = previousMode
        self.uptimeAtStart = uptimeAtStart
        self.createdAt = createdAt
    }

    // MARK: - Phase helpers (clock-manipulation-aware)

    /// Whether the timed unlock is currently in its penalty (locked) phase.
    /// Wall-clock primary; if `uptimeAtStart` and `createdAt` are set and the
    /// wall clock has advanced substantially faster than monotonic uptime
    /// (tolerance: 60s), we assume the child moved the clock forward to
    /// skip the penalty and keep reporting "still in penalty".
    public func isInPenaltyPhase(at time: Date = Date()) -> Bool {
        if time >= unlockAt { return suspiciousClockAdvance(at: time) }
        return true
    }

    /// Whether the timed unlock is currently in its free (unlocked) phase.
    /// Penalty must be legitimately served AND we must be before `lockAt`.
    public func isInFreePhase(at time: Date = Date()) -> Bool {
        if isInPenaltyPhase(at: time) { return false }
        return time < lockAt
    }

    /// Current continuous monotonic clock in seconds. Unlike
    /// `ProcessInfo.systemUptime`, this keeps counting while the device is
    /// asleep / screen-locked — so a kid locking their phone during penalty
    /// doesn't look like clock manipulation.
    public static func currentMonotonicSeconds() -> TimeInterval {
        var ts = timespec()
        let result = clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
        guard result == 0 else {
            // Fallback to systemUptime if the syscall fails (shouldn't happen on iOS 17+).
            return ProcessInfo.processInfo.systemUptime
        }
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000.0
    }

    /// Returns true if there is strong evidence that the wall clock was
    /// advanced after creation (e.g. kid opened Settings and moved the date
    /// forward to skip penalty). Returns false on reboot or if we don't have
    /// enough data to be sure.
    private func suspiciousClockAdvance(at time: Date) -> Bool {
        guard let uptimeAtStart, let createdAt else { return false }
        let currentUptime = TimedUnlockInfo.currentMonotonicSeconds()
        // Reboot zeroes monotonic time; we can't compare across that, so trust wall clock.
        guard currentUptime >= uptimeAtStart else { return false }
        let wallDelta = time.timeIntervalSince(createdAt)
        let uptimeDelta = currentUptime - uptimeAtStart
        // If wall clock has advanced noticeably more than uptime, clock was jumped forward.
        // 60s tolerance covers NTP corrections and minor drift.
        return wallDelta > uptimeDelta + 60
    }
}
