import Foundation

/// Periodic check-in from a child device.
/// Sent every 5 minutes from the main app (foreground or background fetch).
/// Parent dashboard uses this for online/offline status.
public struct DeviceHeartbeat: Codable, Sendable, Equatable {
    public let deviceID: DeviceID
    public let familyID: FamilyID
    public let timestamp: Date
    public let currentMode: LockMode
    public let policyVersion: Int64
    public let familyControlsAuthorized: Bool
    public let batteryLevel: Double?
    public let isCharging: Bool?

    public init(
        deviceID: DeviceID,
        familyID: FamilyID,
        timestamp: Date = Date(),
        currentMode: LockMode,
        policyVersion: Int64,
        familyControlsAuthorized: Bool,
        batteryLevel: Double? = nil,
        isCharging: Bool? = nil
    ) {
        self.deviceID = deviceID
        self.familyID = familyID
        self.timestamp = timestamp
        self.currentMode = currentMode
        self.policyVersion = policyVersion
        self.familyControlsAuthorized = familyControlsAuthorized
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
    }
}
