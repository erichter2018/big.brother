import Foundation

/// A command issued by a parent device, synced via CloudKit,
/// and processed by one or more child devices.
public struct RemoteCommand: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let familyID: FamilyID
    public let target: CommandTarget
    public let action: CommandAction
    /// Identifier of the parent device or name that issued this command.
    public let issuedBy: String
    public let issuedAt: Date
    /// Commands without explicit expiry default to 24 hours.
    public let expiresAt: Date?
    public var status: CommandStatus

    public init(
        id: UUID = UUID(),
        familyID: FamilyID,
        target: CommandTarget,
        action: CommandAction,
        issuedBy: String,
        issuedAt: Date = Date(),
        expiresAt: Date? = nil,
        status: CommandStatus = .pending
    ) {
        self.id = id
        self.familyID = familyID
        self.target = target
        self.action = action
        self.issuedBy = issuedBy
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt ?? issuedAt.addingTimeInterval(86400)
        self.status = status
    }
}

/// What the command targets.
public enum CommandTarget: Codable, Sendable, Equatable {
    case device(DeviceID)
    case child(ChildProfileID)
    case allDevices
}

/// What the command does.
public enum CommandAction: Codable, Sendable, Equatable {
    case setMode(LockMode)
    case temporaryUnlock(durationSeconds: Int)
    case requestHeartbeat
    case unenroll
}

/// Monotonic status transitions: pending → delivered → applied | failed | expired.
/// A command never goes backward in status.
public enum CommandStatus: String, Codable, Sendable, Equatable {
    case pending
    case delivered
    case applied
    case failed
    case expired
}
