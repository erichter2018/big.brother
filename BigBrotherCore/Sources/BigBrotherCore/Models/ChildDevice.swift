import Foundation

/// An enrolled child device linked to a ChildProfile.
/// Each physical device gets a unique DeviceID on enrollment.
public struct ChildDevice: Codable, Sendable, Identifiable, Equatable {
    public let id: DeviceID
    public let childProfileID: ChildProfileID
    public let familyID: FamilyID

    /// User-facing name, e.g. "Simon's iPad"
    public var displayName: String

    /// Hardware model, e.g. "iPad14,1"
    public var modelIdentifier: String

    /// iOS/iPadOS version string
    public var osVersion: String

    public let enrolledAt: Date

    /// Timestamp of the most recent heartbeat from this device.
    public var lastHeartbeat: Date?

    /// The mode most recently confirmed applied by this device.
    public var confirmedMode: LockMode?

    /// The policy version most recently confirmed by this device.
    public var confirmedPolicyVersion: Int64?

    /// Whether FamilyControls .individual authorization is active.
    public var familyControlsAuthorized: Bool

    /// Heuristic: device is considered online if heartbeat is within 10 minutes.
    public var isOnline: Bool {
        guard let hb = lastHeartbeat else { return false }
        return Date().timeIntervalSince(hb) < 600
    }

    public init(
        id: DeviceID = .generate(),
        childProfileID: ChildProfileID,
        familyID: FamilyID,
        displayName: String,
        modelIdentifier: String,
        osVersion: String,
        enrolledAt: Date = Date(),
        lastHeartbeat: Date? = nil,
        confirmedMode: LockMode? = nil,
        confirmedPolicyVersion: Int64? = nil,
        familyControlsAuthorized: Bool = false
    ) {
        self.id = id
        self.childProfileID = childProfileID
        self.familyID = familyID
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.osVersion = osVersion
        self.enrolledAt = enrolledAt
        self.lastHeartbeat = lastHeartbeat
        self.confirmedMode = confirmedMode
        self.confirmedPolicyVersion = confirmedPolicyVersion
        self.familyControlsAuthorized = familyControlsAuthorized
    }
}
