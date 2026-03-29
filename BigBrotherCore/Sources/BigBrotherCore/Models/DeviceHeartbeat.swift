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

    /// Number of permanently allowed apps (raw token count, independent of name resolution).
    public let allowedAppCount: Int?

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

    /// When the Monitor extension last fired (reconciliation, schedule transition).
    /// Used by parent to detect force-close: if this is recent but heartbeat is stale,
    /// the device is alive but the main app was force-closed.
    public let monitorLastActiveAt: Date?

    /// Whether a VPN tunnel interface was detected on the device.
    public let vpnDetected: Bool?

    /// The device's current time zone identifier (e.g. "America/New_York").
    public let timeZoneIdentifier: String?

    /// The device's current UTC offset in seconds (e.g. -18000 for EST).
    public let timeZoneOffsetSeconds: Int?

    /// Approximate screen time in minutes for today (nil = not yet reported).
    public let screenTimeMinutes: Int?
    /// Number of screen unlocks today.
    public let screenUnlockCount: Int?

    /// Whether jailbreak indicators were detected on the device.
    public let jailbreakDetected: Bool?
    /// Which jailbreak check triggered (e.g. "suspicious_paths", "dyld_injection:/path/to/lib").
    public let jailbreakReason: String?

    /// Whether CoreMotion detects the device is currently in a vehicle.
    public let isDriving: Bool?
    /// Current speed in m/s (from CLLocation.speed, nil when not moving or invalid).
    public let currentSpeed: Double?
    /// Who sent this heartbeat: "mainApp" or "vpnExtension".
    public let heartbeatSource: String?

    /// Whether the BigBrother VPN tunnel is connected on the child device.
    public let tunnelConnected: Bool?

    /// Whether CoreMotion activity permission is authorized.
    public let motionAuthorized: Bool?

    /// Whether notification permission is granted.
    public let notificationsAuthorized: Bool?

    /// Whether the device screen is currently locked (true) or unlocked (false).
    /// nil = old build or DeviceLockMonitor not active.
    public let isDeviceLocked: Bool?

    /// Whether ManagedSettingsStore shields are actually active on the device right now.
    public let shieldsActive: Bool?
    /// What the active schedule profile resolves to at this moment (may differ from reported mode).
    public let scheduleResolvedMode: String?
    /// What code path last modified shields (e.g., "command", "reconcile", "launchRestore", "freeWindowStart").
    public let lastShieldChangeReason: String?
    /// Number of individual app tokens currently in shield.applications.
    public let shieldedAppCount: Int?
    /// Whether the category catch-all (shield.applicationCategories) is set.
    public let shieldCategoryActive: Bool?

    // Location (piggybacks on heartbeat when available)
    public let latitude: Double?
    public let longitude: Double?
    public let locationTimestamp: Date?
    public let locationAddress: String?
    public let locationAccuracy: Double?

    /// CLAuthorizationStatus on the child device: "always", "whenInUse", "denied", "restricted", "notDetermined".
    /// nil = old build that doesn't report this.
    public let locationAuthorization: String?

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
        allowedAppCount: Int? = nil,
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
        lastCommandProcessedAt: Date? = nil,
        monitorLastActiveAt: Date? = nil,
        vpnDetected: Bool? = nil,
        timeZoneIdentifier: String? = nil,
        timeZoneOffsetSeconds: Int? = nil,
        screenTimeMinutes: Int? = nil,
        screenUnlockCount: Int? = nil,
        jailbreakDetected: Bool? = nil,
        jailbreakReason: String? = nil,
        isDriving: Bool? = nil,
        currentSpeed: Double? = nil,
        heartbeatSource: String? = nil,
        tunnelConnected: Bool? = nil,
        motionAuthorized: Bool? = nil,
        notificationsAuthorized: Bool? = nil,
        isDeviceLocked: Bool? = nil,
        shieldsActive: Bool? = nil,
        scheduleResolvedMode: String? = nil,
        lastShieldChangeReason: String? = nil,
        shieldedAppCount: Int? = nil,
        shieldCategoryActive: Bool? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationTimestamp: Date? = nil,
        locationAddress: String? = nil,
        locationAccuracy: Double? = nil,
        locationAuthorization: String? = nil
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
        self.allowedAppCount = allowedAppCount
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
        self.monitorLastActiveAt = monitorLastActiveAt
        self.vpnDetected = vpnDetected
        self.timeZoneIdentifier = timeZoneIdentifier
        self.timeZoneOffsetSeconds = timeZoneOffsetSeconds
        self.screenTimeMinutes = screenTimeMinutes
        self.screenUnlockCount = screenUnlockCount
        self.jailbreakDetected = jailbreakDetected
        self.jailbreakReason = jailbreakReason
        self.isDriving = isDriving
        self.currentSpeed = currentSpeed
        self.heartbeatSource = heartbeatSource
        self.tunnelConnected = tunnelConnected
        self.motionAuthorized = motionAuthorized
        self.notificationsAuthorized = notificationsAuthorized
        self.isDeviceLocked = isDeviceLocked
        self.shieldsActive = shieldsActive
        self.scheduleResolvedMode = scheduleResolvedMode
        self.lastShieldChangeReason = lastShieldChangeReason
        self.shieldedAppCount = shieldedAppCount
        self.shieldCategoryActive = shieldCategoryActive
        self.latitude = latitude
        self.longitude = longitude
        self.locationTimestamp = locationTimestamp
        self.locationAddress = locationAddress
        self.locationAccuracy = locationAccuracy
        self.locationAuthorization = locationAuthorization
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case deviceID, familyID, timestamp, currentMode, policyVersion
        case familyControlsAuthorized, batteryLevel, isCharging
        case appBlockingConfigured, blockedCategoryCount, blockedAppCount
        case blockedAppNames, blockedCategoryNames
        case installID, heartbeatSeq, cloudKitStatus
        case allowedAppNames, allowedAppCount, temporaryAllowedAppNames
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
        case monitorLastActiveAt
        case vpnDetected
        case timeZoneIdentifier
        case timeZoneOffsetSeconds
        case screenTimeMinutes
        case screenUnlockCount
        case jailbreakDetected
        case jailbreakReason
        case isDriving, currentSpeed, heartbeatSource, tunnelConnected
        case motionAuthorized, notificationsAuthorized
        case isDeviceLocked
        case shieldsActive, scheduleResolvedMode, lastShieldChangeReason
        case shieldedAppCount, shieldCategoryActive
        case latitude, longitude, locationTimestamp, locationAddress, locationAccuracy
        case locationAuthorization
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
        allowedAppCount = try container.decodeIfPresent(Int.self, forKey: .allowedAppCount)
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
        monitorLastActiveAt = try container.decodeIfPresent(Date.self, forKey: .monitorLastActiveAt)
        vpnDetected = try container.decodeIfPresent(Bool.self, forKey: .vpnDetected)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        timeZoneOffsetSeconds = try container.decodeIfPresent(Int.self, forKey: .timeZoneOffsetSeconds)
        screenTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .screenTimeMinutes)
        screenUnlockCount = try container.decodeIfPresent(Int.self, forKey: .screenUnlockCount)
        jailbreakDetected = try container.decodeIfPresent(Bool.self, forKey: .jailbreakDetected)
        jailbreakReason = try container.decodeIfPresent(String.self, forKey: .jailbreakReason)
        isDriving = try container.decodeIfPresent(Bool.self, forKey: .isDriving)
        currentSpeed = try container.decodeIfPresent(Double.self, forKey: .currentSpeed)
        heartbeatSource = try container.decodeIfPresent(String.self, forKey: .heartbeatSource)
        tunnelConnected = try container.decodeIfPresent(Bool.self, forKey: .tunnelConnected)
        motionAuthorized = try container.decodeIfPresent(Bool.self, forKey: .motionAuthorized)
        notificationsAuthorized = try container.decodeIfPresent(Bool.self, forKey: .notificationsAuthorized)
        isDeviceLocked = try container.decodeIfPresent(Bool.self, forKey: .isDeviceLocked)
        shieldsActive = try container.decodeIfPresent(Bool.self, forKey: .shieldsActive)
        scheduleResolvedMode = try container.decodeIfPresent(String.self, forKey: .scheduleResolvedMode)
        lastShieldChangeReason = try container.decodeIfPresent(String.self, forKey: .lastShieldChangeReason)
        shieldedAppCount = try container.decodeIfPresent(Int.self, forKey: .shieldedAppCount)
        shieldCategoryActive = try container.decodeIfPresent(Bool.self, forKey: .shieldCategoryActive)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        locationTimestamp = try container.decodeIfPresent(Date.self, forKey: .locationTimestamp)
        locationAddress = try container.decodeIfPresent(String.self, forKey: .locationAddress)
        locationAccuracy = try container.decodeIfPresent(Double.self, forKey: .locationAccuracy)
        locationAuthorization = try container.decodeIfPresent(String.self, forKey: .locationAuthorization)
    }
}
