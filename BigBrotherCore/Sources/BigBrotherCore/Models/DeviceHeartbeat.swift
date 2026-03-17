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

    // App blocking summary (nil = not yet reported)
    public let appBlockingConfigured: Bool?
    public let blockedCategoryCount: Int?
    public let blockedAppCount: Int?
    /// Human-readable names of blocked apps (extracted from tokens on child device).
    public let blockedAppNames: [String]?
    /// Human-readable names of blocked categories.
    public let blockedCategoryNames: [String]?

    /// Unique installation identifier — changes on reinstall, stable across launches.
    public let installID: UUID?

    /// Monotonically increasing sequence number for this install.
    /// Lets the parent detect gaps (missed heartbeats) vs. clock drift.
    public let heartbeatSeq: Int64?

    /// CloudKit account status on the child device ("available", "noAccount", "restricted", "couldNotDetermine").
    public let cloudKitStatus: String?

    /// Human-readable names of permanently allowed apps (parent-approved).
    public let allowedAppNames: [String]?
    /// Human-readable names of temporarily allowed apps with expiry dates.
    public let temporaryAllowedAppNames: [String]?

    /// When a temporary unlock expires (nil if not in temp unlock).
    /// Used by parent dashboard to show countdown.
    public let temporaryUnlockExpiresAt: Date?

    /// Whether the device uses .child FamilyControls authorization (stronger).
    /// nil = not yet reported (old build). false = .individual.
    public let isChildAuthorization: Bool?

    /// Available disk space in bytes on the child device.
    public let availableDiskSpace: Int64?

    /// Total disk capacity in bytes on the child device.
    public let totalDiskSpace: Int64?

    /// Number of self-unlocks used today (nil = feature not configured).
    public let selfUnlocksUsedToday: Int?

    /// Origin of the current temporary unlock (nil if not in temp unlock).
    public let temporaryUnlockOrigin: TemporaryUnlockOrigin?

    /// Current iOS version string (e.g. "17.4.1").
    public let osVersion: String?

    /// Device model identifier (e.g. "iPad13,4").
    public let modelIdentifier: String?

    /// Manual build number from AppConstants, carried via heartbeat so parent can compare.
    public let appBuildNumber: Int?

    /// Last enforcement error message (nil = no recent errors).
    public let enforcementError: String?

    /// Name of the currently active schedule free window (nil = not in a free window).
    public let activeScheduleWindowName: String?

    /// When the last command was successfully processed (nil = never).
    public let lastCommandProcessedAt: Date?

    public init(
        deviceID: DeviceID,
        familyID: FamilyID,
        timestamp: Date = Date(),
        currentMode: LockMode,
        policyVersion: Int64,
        familyControlsAuthorized: Bool,
        batteryLevel: Double? = nil,
        isCharging: Bool? = nil,
        appBlockingConfigured: Bool? = nil,
        blockedCategoryCount: Int? = nil,
        blockedAppCount: Int? = nil,
        blockedAppNames: [String]? = nil,
        blockedCategoryNames: [String]? = nil,
        installID: UUID? = nil,
        heartbeatSeq: Int64? = nil,
        cloudKitStatus: String? = nil,
        allowedAppNames: [String]? = nil,
        temporaryAllowedAppNames: [String]? = nil,
        temporaryUnlockExpiresAt: Date? = nil,
        isChildAuthorization: Bool? = nil,
        availableDiskSpace: Int64? = nil,
        totalDiskSpace: Int64? = nil,
        selfUnlocksUsedToday: Int? = nil,
        temporaryUnlockOrigin: TemporaryUnlockOrigin? = nil,
        osVersion: String? = nil,
        modelIdentifier: String? = nil,
        appBuildNumber: Int? = nil,
        enforcementError: String? = nil,
        activeScheduleWindowName: String? = nil,
        lastCommandProcessedAt: Date? = nil
    ) {
        self.deviceID = deviceID
        self.familyID = familyID
        self.timestamp = timestamp
        self.currentMode = currentMode
        self.policyVersion = policyVersion
        self.familyControlsAuthorized = familyControlsAuthorized
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.appBlockingConfigured = appBlockingConfigured
        self.blockedCategoryCount = blockedCategoryCount
        self.blockedAppCount = blockedAppCount
        self.blockedAppNames = blockedAppNames
        self.blockedCategoryNames = blockedCategoryNames
        self.installID = installID
        self.heartbeatSeq = heartbeatSeq
        self.cloudKitStatus = cloudKitStatus
        self.allowedAppNames = allowedAppNames
        self.temporaryAllowedAppNames = temporaryAllowedAppNames
        self.temporaryUnlockExpiresAt = temporaryUnlockExpiresAt
        self.isChildAuthorization = isChildAuthorization
        self.availableDiskSpace = availableDiskSpace
        self.totalDiskSpace = totalDiskSpace
        self.selfUnlocksUsedToday = selfUnlocksUsedToday
        self.temporaryUnlockOrigin = temporaryUnlockOrigin
        self.osVersion = osVersion
        self.modelIdentifier = modelIdentifier
        self.appBuildNumber = appBuildNumber
        self.enforcementError = enforcementError
        self.activeScheduleWindowName = activeScheduleWindowName
        self.lastCommandProcessedAt = lastCommandProcessedAt
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case deviceID, familyID, timestamp, currentMode, policyVersion
        case familyControlsAuthorized, batteryLevel, isCharging
        case appBlockingConfigured, blockedCategoryCount, blockedAppCount
        case blockedAppNames, blockedCategoryNames
        case installID, heartbeatSeq, cloudKitStatus
        case allowedAppNames, temporaryAllowedAppNames
        case temporaryUnlockExpiresAt
        case isChildAuthorization
        case availableDiskSpace
        case totalDiskSpace
        case selfUnlocksUsedToday
        case temporaryUnlockOrigin
        case osVersion
        case modelIdentifier
        case appBuildNumber
        case enforcementError
        case activeScheduleWindowName
        case lastCommandProcessedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(DeviceID.self, forKey: .deviceID)
        familyID = try container.decode(FamilyID.self, forKey: .familyID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        currentMode = try container.decode(LockMode.self, forKey: .currentMode)
        policyVersion = try container.decode(Int64.self, forKey: .policyVersion)
        familyControlsAuthorized = try container.decode(Bool.self, forKey: .familyControlsAuthorized)
        batteryLevel = try container.decodeIfPresent(Double.self, forKey: .batteryLevel)
        isCharging = try container.decodeIfPresent(Bool.self, forKey: .isCharging)
        appBlockingConfigured = try container.decodeIfPresent(Bool.self, forKey: .appBlockingConfigured)
        blockedCategoryCount = try container.decodeIfPresent(Int.self, forKey: .blockedCategoryCount)
        blockedAppCount = try container.decodeIfPresent(Int.self, forKey: .blockedAppCount)
        blockedAppNames = try container.decodeIfPresent([String].self, forKey: .blockedAppNames)
        blockedCategoryNames = try container.decodeIfPresent([String].self, forKey: .blockedCategoryNames)
        installID = try container.decodeIfPresent(UUID.self, forKey: .installID)
        heartbeatSeq = try container.decodeIfPresent(Int64.self, forKey: .heartbeatSeq)
        cloudKitStatus = try container.decodeIfPresent(String.self, forKey: .cloudKitStatus)
        allowedAppNames = try container.decodeIfPresent([String].self, forKey: .allowedAppNames)
        temporaryAllowedAppNames = try container.decodeIfPresent([String].self, forKey: .temporaryAllowedAppNames)
        temporaryUnlockExpiresAt = try container.decodeIfPresent(Date.self, forKey: .temporaryUnlockExpiresAt)
        isChildAuthorization = try container.decodeIfPresent(Bool.self, forKey: .isChildAuthorization)
        availableDiskSpace = try container.decodeIfPresent(Int64.self, forKey: .availableDiskSpace)
        totalDiskSpace = try container.decodeIfPresent(Int64.self, forKey: .totalDiskSpace)
        selfUnlocksUsedToday = try container.decodeIfPresent(Int.self, forKey: .selfUnlocksUsedToday)
        temporaryUnlockOrigin = try container.decodeIfPresent(TemporaryUnlockOrigin.self, forKey: .temporaryUnlockOrigin)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        modelIdentifier = try container.decodeIfPresent(String.self, forKey: .modelIdentifier)
        appBuildNumber = try container.decodeIfPresent(Int.self, forKey: .appBuildNumber)
        enforcementError = try container.decodeIfPresent(String.self, forKey: .enforcementError)
        activeScheduleWindowName = try container.decodeIfPresent(String.self, forKey: .activeScheduleWindowName)
        lastCommandProcessedAt = try container.decodeIfPresent(Date.self, forKey: .lastCommandProcessedAt)
    }
}
