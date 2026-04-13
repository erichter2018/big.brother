import Foundation

/// An app selected by the child that awaits parent review.
/// Created during Mode 2 ("Child picks apps") — the child selects apps
/// from the FamilyActivityPicker, each gets a 1-minute probe for name
/// harvesting, and the parent reviews the list to decide: allow always,
/// set time limit, or keep blocked.
///
/// Stored in CloudKit as BBPendingAppReview. Deleted after parent decides.
public struct PendingAppReview: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let familyID: FamilyID
    public let childProfileID: ChildProfileID
    public let deviceID: DeviceID
    public let appFingerprint: String
    public var appName: String
    public var bundleID: String?
    public var nameResolved: Bool
    public let createdAt: Date
    public var updatedAt: Date

    /// Lifecycle status for the local write-ahead log.
    /// - pending: created locally, not yet uploaded to CK
    /// - synced: uploaded to CK, awaiting parent decision
    /// - resolved: parent decided (allow/block/limit), command sent or will be sent
    public var syncStatus: SyncStatus

    public enum SyncStatus: String, Codable, Sendable, Equatable {
        case pending
        case synced
        case resolved
    }

    /// Raw ApplicationToken data (base64). Stored so the parent's command
    /// can reference the exact token without relying on fingerprint matching.
    public var tokenDataBase64: String?

    public init(
        id: UUID = UUID(),
        familyID: FamilyID,
        childProfileID: ChildProfileID,
        deviceID: DeviceID,
        appFingerprint: String,
        appName: String,
        bundleID: String? = nil,
        nameResolved: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        syncStatus: SyncStatus = .pending,
        tokenDataBase64: String? = nil
    ) {
        self.id = id
        self.familyID = familyID
        self.childProfileID = childProfileID
        self.deviceID = deviceID
        self.appFingerprint = appFingerprint
        self.appName = appName
        self.bundleID = bundleID
        self.nameResolved = nameResolved
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncStatus = syncStatus
        self.tokenDataBase64 = tokenDataBase64
    }
}

/// Parent's decision for a pending app review.
public enum AppDisposition: String, Codable, Sendable, Equatable {
    case allowAlways
    case timeLimit
    case keepBlocked
}

/// A single review decision in a batch review command.
public struct AppReviewDecision: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let disposition: AppDisposition
    /// Daily limit in minutes (only used when disposition == .timeLimit).
    public let minutes: Int?

    public init(fingerprint: String, disposition: AppDisposition, minutes: Int? = nil) {
        self.fingerprint = fingerprint
        self.disposition = disposition
        self.minutes = minutes
    }
}
