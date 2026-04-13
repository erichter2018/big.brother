import Foundation

/// Parent-controlled time limit configuration stored in CloudKit.
/// No tokens — uses fingerprint to match with device-local AppTimeLimit entries.
/// One record per app per CHILD (shared across all devices for that child).
public struct TimeLimitConfig: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let familyID: FamilyID
    public let childProfileID: ChildProfileID
    /// Optional device ID — when set, limit only applies to this device.
    /// When nil, applies to all devices for this child.
    public var deviceID: DeviceID?
    /// FNV-1a fingerprint matching the child's AppTimeLimit.fingerprint.
    public let appFingerprint: String
    public var appName: String
    /// Daily time budget in minutes (shared across all devices).
    public var dailyLimitMinutes: Int
    public var isActive: Bool
    /// App Store category from iTunes Search API (e.g. "Games", "Social Networking").
    public var appCategory: String?
    /// Bundle identifier — stable across token rotations and device reinstalls.
    /// The canonical identity for auto-approve matching.
    public var bundleID: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        familyID: FamilyID,
        childProfileID: ChildProfileID,
        deviceID: DeviceID? = nil,
        appFingerprint: String,
        appName: String,
        dailyLimitMinutes: Int,
        isActive: Bool = true,
        appCategory: String? = nil,
        bundleID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.familyID = familyID
        self.childProfileID = childProfileID
        self.deviceID = deviceID
        self.appFingerprint = appFingerprint
        self.appName = appName
        self.dailyLimitMinutes = dailyLimitMinutes
        self.isActive = isActive
        self.appCategory = appCategory
        self.bundleID = bundleID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
