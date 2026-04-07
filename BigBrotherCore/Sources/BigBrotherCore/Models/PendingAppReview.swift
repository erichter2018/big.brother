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
    /// FNV-1a fingerprint of the device-local ApplicationToken.
    public let appFingerprint: String
    /// Display name — starts as picker name or "Temporary Name N", updated when resolved.
    public var appName: String
    /// Bundle identifier if available.
    public var bundleID: String?
    /// Whether the real app name has been captured via ShieldConfiguration.
    public var nameResolved: Bool
    public let createdAt: Date
    public var updatedAt: Date

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
        updatedAt: Date = Date()
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
