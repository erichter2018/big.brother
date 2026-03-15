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
    case requestAppConfiguration
    case unenroll
    /// Permanently allow a specific app that was requested via "Ask for More Time".
    /// The requestID references a pending unlock request stored on the child device.
    case allowApp(requestID: UUID)
    /// Permanently allow a specific app by its cached display name.
    /// The child resolves the app name back to a device-local ApplicationToken.
    case allowManagedApp(appName: String)
    /// Revoke a previously allowed app.
    case revokeApp(requestID: UUID)
    /// Re-block a managed app by its cached display name.
    /// The child resolves the app name back to a device-local ApplicationToken.
    case blockManagedApp(appName: String)
    /// Temporarily unlock a specific app for a limited time.
    /// The requestID references a pending unlock request stored on the child device.
    case temporaryUnlockApp(requestID: UUID, durationSeconds: Int)
    /// Set the display name for an app identified by its token fingerprint.
    /// Sent by the parent so the child's ShieldAction uses the correct name.
    case nameApp(fingerprint: String, name: String)
    /// Set device-level restrictions (app removal, explicit content, etc.).
    case setRestrictions(DeviceRestrictions)
    /// Revoke all allowed apps on the device (clears permanent + temporary allow lists).
    case revokeAllApps
    /// Open the always-allowed apps picker on the child device.
    case requestAlwaysAllowedSetup

    /// Human-readable description for UI feedback.
    public var displayDescription: String {
        switch self {
        case .setMode(let mode):
            return "Set mode to \(mode.displayName)"
        case .temporaryUnlock(let seconds):
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            let duration: String
            if hours > 0 && mins > 0 {
                duration = "\(hours)h \(mins)m"
            } else if hours > 0 {
                duration = "\(hours)h"
            } else {
                duration = "\(mins)m"
            }
            return "Temporary unlock (\(duration))"
        case .requestHeartbeat:
            return "Heartbeat request"
        case .requestAppConfiguration:
            return "App configuration request"
        case .unenroll:
            return "Unenroll"
        case .allowApp:
            return "Allow app permanently"
        case .allowManagedApp(let appName):
            return "Allow \(appName)"
        case .revokeApp:
            return "Revoke app access"
        case .blockManagedApp(let appName):
            return "Block \(appName)"
        case .temporaryUnlockApp(_, let seconds):
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            let duration: String
            if hours > 0 && mins > 0 {
                duration = "\(hours)h \(mins)m"
            } else if hours > 0 {
                duration = "\(hours)h"
            } else {
                duration = "\(mins)m"
            }
            return "Unlock app (\(duration))"
        case .nameApp(_, let name):
            return "Name app: \(name)"
        case .setRestrictions:
            return "Update device restrictions"
        case .revokeAllApps:
            return "Revoke all allowed apps"
        case .requestAlwaysAllowedSetup:
            return "Configure always-allowed apps"
        }
    }
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
