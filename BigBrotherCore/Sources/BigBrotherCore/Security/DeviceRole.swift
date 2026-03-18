import Foundation

/// The role assigned to this device. Stored in Keychain.
/// Determines which UI the app shows on launch.
///
/// Once set, the role cannot be changed through the app UI.
/// Changing from child → parent requires app deletion and re-setup.
public enum DeviceRole: String, Codable, Sendable {
    /// First launch — no role assigned yet. Shows onboarding.
    case unconfigured

    /// This device is used by a parent/admin.
    case parent

    /// This device is enrolled as a child device.
    case child
}

/// Full enrollment state for a child device.
/// Stored in Keychain for tamper resistance.
public struct ChildEnrollmentState: Codable, Sendable, Equatable {
    public let deviceID: DeviceID
    public let childProfileID: ChildProfileID
    public let familyID: FamilyID
    public let enrolledAt: Date

    /// Unique identifier for this specific app installation.
    /// Survives app launches but NOT reinstalls.
    /// Used to distinguish "same instance resumed" from "reinstalled."
    public let installID: UUID

    public init(
        deviceID: DeviceID,
        childProfileID: ChildProfileID,
        familyID: FamilyID,
        enrolledAt: Date = Date(),
        installID: UUID = UUID()
    ) {
        self.deviceID = deviceID
        self.childProfileID = childProfileID
        self.familyID = familyID
        self.enrolledAt = enrolledAt
        self.installID = installID
    }

    // Backward-compatible decoding: generate installID if missing.
    private enum CodingKeys: String, CodingKey {
        case deviceID, childProfileID, familyID, enrolledAt, installID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(DeviceID.self, forKey: .deviceID)
        childProfileID = try container.decode(ChildProfileID.self, forKey: .childProfileID)
        familyID = try container.decode(FamilyID.self, forKey: .familyID)
        enrolledAt = try container.decode(Date.self, forKey: .enrolledAt)
        installID = try container.decodeIfPresent(UUID.self, forKey: .installID) ?? UUID()
    }
}

/// Persistent state for a parent device.
/// Stored in Keychain.
public struct ParentState: Codable, Sendable, Equatable {
    public let familyID: FamilyID
    public let setupAt: Date
    /// The invite code used to join (nil for the original/primary parent).
    public let inviteCode: String?

    public init(familyID: FamilyID, setupAt: Date = Date(), inviteCode: String? = nil) {
        self.familyID = familyID
        self.setupAt = setupAt
        self.inviteCode = inviteCode
    }

    /// Whether this is the original parent (created the family, not invited).
    public var isPrimaryParent: Bool { inviteCode == nil }
}
