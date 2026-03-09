import Foundation

/// The intended policy for a device, as set by the parent.
/// This represents what the parent WANTS applied — the PolicyResolver
/// combines this with schedule, temp unlock, and capabilities to produce
/// the EffectivePolicy.
public struct Policy: Codable, Sendable, Equatable {
    public let targetDeviceID: DeviceID

    /// The base lock mode.
    public var mode: LockMode

    /// If set and in the future, device is temporarily unlocked until this time.
    public var temporaryUnlockUntil: Date?

    /// Reference to an active schedule, if any.
    public var activeScheduleID: UUID?

    /// Monotonically increasing version number. Higher version wins conflicts.
    public var version: Int64

    public var updatedAt: Date

    public init(
        targetDeviceID: DeviceID,
        mode: LockMode,
        temporaryUnlockUntil: Date? = nil,
        activeScheduleID: UUID? = nil,
        version: Int64 = 1,
        updatedAt: Date = Date()
    ) {
        self.targetDeviceID = targetDeviceID
        self.mode = mode
        self.temporaryUnlockUntil = temporaryUnlockUntil
        self.activeScheduleID = activeScheduleID
        self.version = version
        self.updatedAt = updatedAt
    }
}
