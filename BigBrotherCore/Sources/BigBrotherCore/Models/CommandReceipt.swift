import Foundation

/// Acknowledgement from a child device that a command was processed.
/// Each device produces its own receipt, even for child-level or global commands.
public struct CommandReceipt: Codable, Sendable, Equatable {
    public let commandID: UUID
    public let deviceID: DeviceID
    public let familyID: FamilyID
    public let status: CommandStatus
    public let appliedAt: Date?
    public let failureReason: String?

    public init(
        commandID: UUID,
        deviceID: DeviceID,
        familyID: FamilyID,
        status: CommandStatus,
        appliedAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.commandID = commandID
        self.deviceID = deviceID
        self.familyID = familyID
        self.status = status
        self.appliedAt = appliedAt
        self.failureReason = failureReason
    }
}
