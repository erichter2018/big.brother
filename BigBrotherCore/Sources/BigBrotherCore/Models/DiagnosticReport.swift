import Foundation

/// A diagnostic report collected from a child device on parent request.
/// Uploaded to CloudKit (BBDiagnosticReport) for remote viewing.
public struct DiagnosticReport: Codable, Sendable, Identifiable {
    public let id: UUID
    public let deviceID: DeviceID
    public let familyID: FamilyID
    public let timestamp: Date
    public let appBuildNumber: Int

    // Device state
    public let deviceRole: String
    public let locationMode: String
    public let coreMotionAvailable: Bool
    public let coreMotionMonitoring: Bool
    public let isMoving: Bool
    public let isDriving: Bool
    public let vpnTunnelStatus: String
    public let familyControlsAuth: String

    // Enforcement state
    public let currentMode: String
    public let shieldsActive: Bool
    public let shieldedAppCount: Int
    public let shieldCategoryActive: Bool
    public let lastShieldChangeReason: String?

    // Key flags
    public let flags: [String: String]

    // Recent diagnostic log entries (last 50)
    public let recentLogs: [DiagnosticEntry]

    public init(
        id: UUID = UUID(),
        deviceID: DeviceID,
        familyID: FamilyID,
        timestamp: Date = Date(),
        appBuildNumber: Int,
        deviceRole: String,
        locationMode: String,
        coreMotionAvailable: Bool,
        coreMotionMonitoring: Bool,
        isMoving: Bool,
        isDriving: Bool,
        vpnTunnelStatus: String,
        familyControlsAuth: String,
        currentMode: String,
        shieldsActive: Bool,
        shieldedAppCount: Int,
        shieldCategoryActive: Bool,
        lastShieldChangeReason: String?,
        flags: [String: String],
        recentLogs: [DiagnosticEntry]
    ) {
        self.id = id
        self.deviceID = deviceID
        self.familyID = familyID
        self.timestamp = timestamp
        self.appBuildNumber = appBuildNumber
        self.deviceRole = deviceRole
        self.locationMode = locationMode
        self.coreMotionAvailable = coreMotionAvailable
        self.coreMotionMonitoring = coreMotionMonitoring
        self.isMoving = isMoving
        self.isDriving = isDriving
        self.vpnTunnelStatus = vpnTunnelStatus
        self.familyControlsAuth = familyControlsAuth
        self.currentMode = currentMode
        self.shieldsActive = shieldsActive
        self.shieldedAppCount = shieldedAppCount
        self.shieldCategoryActive = shieldCategoryActive
        self.lastShieldChangeReason = lastShieldChangeReason
        self.flags = flags
        self.recentLogs = recentLogs
    }
}
