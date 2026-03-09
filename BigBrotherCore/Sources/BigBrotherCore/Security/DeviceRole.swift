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

    public init(
        deviceID: DeviceID,
        childProfileID: ChildProfileID,
        familyID: FamilyID,
        enrolledAt: Date = Date()
    ) {
        self.deviceID = deviceID
        self.childProfileID = childProfileID
        self.familyID = familyID
        self.enrolledAt = enrolledAt
    }
}

/// Persistent state for a parent device.
/// Stored in Keychain.
public struct ParentState: Codable, Sendable, Equatable {
    public let familyID: FamilyID
    public let setupAt: Date

    public init(familyID: FamilyID, setupAt: Date = Date()) {
        self.familyID = familyID
        self.setupAt = setupAt
    }
}
