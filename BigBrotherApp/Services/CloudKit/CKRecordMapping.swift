import Foundation
import CloudKit
import BigBrotherCore

/// Maps between BigBrotherCore domain models and CKRecord instances.
///
/// CloudKit record type names are prefixed with "BB" to avoid collisions.
/// All records include a familyID field for partition filtering.
enum CKRecordType {
    static let family = "BBFamily"
    static let childProfile = "BBChildProfile"
    static let childDevice = "BBChildDevice"
    static let policy = "BBPolicy"
    static let remoteCommand = "BBRemoteCommand"
    static let commandReceipt = "BBCommandReceipt"
    static let heartbeat = "BBHeartbeat"
    static let eventLog = "BBEventLog"
    static let enrollmentInvite = "BBEnrollmentInvite"
    static let schedule = "BBSchedule"
    static let heartbeatProfile = "BBHeartbeatProfile"
    static let scheduleProfile = "BBScheduleProfile"
    static let deviceLocation = "BBDeviceLocation"
    static let namedPlace = "BBNamedPlace"
    static let diagnosticReport = "BBDiagnosticReport"
    static let timeLimitConfig = "BBTimeLimitConfig"
}

/// Field names used in CloudKit records.
///
/// Centralized here to prevent typos and support refactoring.
enum CKFieldName {
    // Shared
    static let familyID = "familyID"

    // BBChildProfile
    static let profileID = "profileID"
    static let name = "name"
    static let avatarName = "avatarName"
    static let avatarEmoji = "avatarEmoji"
    static let avatarColor = "avatarColor"
    static let avatarPhotoBase64 = "avatarPhotoBase64"
    static let alwaysAllowedCategoriesJSON = "alwaysAllowedCategoriesJSON"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"

    // BBChildDevice
    static let deviceID = "deviceID"
    static let displayName = "displayName"
    static let modelIdentifier = "modelIdentifier"
    static let osVersion = "osVersion"
    static let enrolledAt = "enrolledAt"
    static let familyControlsOK = "familyControlsOK"

    // BBPolicy
    static let mode = "mode"
    static let tempUnlockUntil = "tempUnlockUntil"
    static let scheduleID = "scheduleID"
    static let version = "version"

    // BBRemoteCommand
    static let commandID = "commandID"
    static let targetType = "targetType"
    static let targetID = "targetID"
    static let actionJSON = "actionJSON"
    static let issuedBy = "issuedBy"
    static let issuedAt = "issuedAt"
    static let expiresAt = "expiresAt"
    static let status = "status"

    // BBCommandReceipt
    static let appliedAt = "appliedAt"
    static let failureReason = "failureReason"

    // BBHeartbeat
    static let timestamp = "timestamp"
    static let currentMode = "currentMode"
    static let policyVersion = "policyVersion"
    static let fcAuthorized = "fcAuthorized"
    static let batteryLevel = "batteryLevel"
    static let isCharging = "isCharging"
    static let appBlockingConfigured = "appBlockingConfigured"
    static let blockedCategoryCount = "blockedCategoryCount"
    static let blockedAppCount = "blockedAppCount"
    static let blockedAppNames = "blockedAppNames"
    static let blockedCategoryNames = "blockedCategoryNames"
    static let installID = "installID"
    static let heartbeatSeq = "heartbeatSeq"
    static let cloudKitStatus = "cloudKitStatus"
    static let allowedAppNames = "allowedAppNames"
    static let allowedAppCount = "allowedAppCount"
    static let temporaryAllowedAppNames = "temporaryAllowedAppNames"
    static let temporaryUnlockExpiresAt = "tempUnlockExpiresAt"
    static let isChildAuthorization = "isChildAuth"
    static let availableDiskSpace = "availableDiskSpace"
    static let totalDiskSpace = "totalDiskSpace"

    // BBEventLog
    static let eventID = "eventID"
    static let eventType = "eventType"
    static let details = "details"

    // BBEnrollmentInvite
    static let code = "code"
    static let used = "used"
    static let usedByDeviceID = "usedByDeviceID"
    static let revoked = "revoked"

    // BBSchedule
    static let scheduleName = "scheduleName"
    static let daysOfWeekJSON = "daysOfWeekJSON"
    static let startHour = "startHour"
    static let startMinute = "startMinute"
    static let endHour = "endHour"
    static let endMinute = "endMinute"
    static let isActive = "isActive"

    // BBHeartbeatProfile
    static let activeWindowsJSON = "activeWindowsJSON"
    static let maxHeartbeatGap = "maxHeartbeatGap"
    static let isDefault = "isDefault"

    // BBScheduleProfile
    static let freeWindowsJSON = "freeWindowsJSON"
    static let essentialWindowsJSON = "essentialWindowsJSON"
    static let exceptionDatesJSON = "exceptionDatesJSON"
    static let lockedMode = "lockedMode"

    // BBChildDevice (profile links)
    static let heartbeatProfileID = "heartbeatProfileID"
    static let scheduleProfileID = "scheduleProfileID"
    static let penaltySeconds = "penaltySeconds"
    static let penaltyTimerEndTime = "penaltyTimerEndTime"
    static let selfUnlocksPerDay = "selfUnlocksPerDay"
    static let scheduleProfileVersion = "scheduleProfileVersion"
    static let restrictionsJSON = "restrictionsJSON"

    // BBHeartbeat (self-unlock reporting)
    static let selfUnlocksUsedToday = "selfUnlocksUsedToday"
    static let temporaryUnlockOrigin = "tempUnlockOrigin"

    // BBHeartbeat (device info)
    static let hbOSVersion = "hbOSVersion"
    static let hbModelIdentifier = "hbModelIdentifier"
    static let hbAppBuildNumber = "hbAppBuildNumber"

    // BBHeartbeat (diagnostics)
    static let hbEnforcementError = "hbEnforcementError"
    static let hbActiveScheduleWindow = "hbActiveScheduleWindow"
    static let hbLastCommandProcessedAt = "hbLastCmdAt"
    static let hbMonitorLastActiveAt = "hbMonitorActiveAt"

    // BBHeartbeat (location)
    static let hbLatitude = "hbLat"
    static let hbLongitude = "hbLon"
    static let hbLocationTimestamp = "hbLocAt"
    static let hbLocationAddress = "hbLocAddr"
    static let hbLocationAccuracy = "hbLocAcc"
    static let hbLocationAuthorization = "hbLocAuth"

    // BBHeartbeat (shield diagnostics)
    static let hbShieldsActive = "hbShieldsOK"
    static let hbScheduleResolvedMode = "hbSchedMode"
    static let hbLastShieldChangeReason = "hbShieldWhy"
    static let hbShieldedAppCount = "hbShieldApps"
    static let hbShieldCategoryActive = "hbShieldCat"

    // BBHeartbeat (security)
    static let hbVPNDetected = "hbVPNDetected"
    static let hbTimeZoneID = "hbTimeZoneID"
    static let hbTimeZoneOffset = "hbTimeZoneOffset"
    static let hbScreenTimeMinutes = "hbScreenTimeMins"
    static let hbScreenUnlockCount = "hbUnlockCount"
    static let hbJailbreakDetected = "hbJailbreak"
    static let hbJailbreakReason = "hbJailbreakReason"
    static let hbIsDriving = "hbDriving"
    static let hbCurrentSpeed = "hbSpeed"
    static let hbHeartbeatSource = "hbSource"
    static let hbTunnelConnected = "hbTunnel"
    static let hbMotionAuthorized = "hbMotionAuth"
    static let hbNotificationsAuthorized = "hbNotifAuth"
    static let hbMainAppBuild = "hbMainAppBuild"
    static let hbFCAuthType = "hbFCAuthType"
    static let hbDeviceLocked = "hbLocked"
    static let hbInternetBlocked = "hbInetBlocked"

    // BBDeviceLocation (speed)
    static let locSpeed = "locSpeed"
    static let locCourse = "locCourse"

    // BBNamedPlace
    static let placeName = "placeName"
    static let placeLatitude = "placeLat"
    static let placeLongitude = "placeLon"
    static let placeRadius = "placeRadius"
    static let placeChildProfileIDs = "placeChildIDs"
    static let placeCreatedBy = "placeCreatedBy"

    // BBDiagnosticReport
    static let diagReportJSON = "diagJSON"

    // BBTimeLimitConfig
    static let appFingerprint = "appFingerprint"
    static let appName = "appName"
    static let dailyLimitMinutes = "dailyLimitMinutes"
    static let timeLimitIsActive = "isActive"

    // BBRemoteCommand (signing)
    static let signatureBase64 = "signatureBase64"

    // BBEnrollmentInvite (signing)
    static let commandSigningPubKey = "commandSigningPubKey"
    static let commandSigningPrivKey = "commandSigningPrivKey"

    // BBDeviceLocation
    static let locLatitude = "latitude"
    static let locLongitude = "longitude"
    static let locAccuracy = "accuracy"
    static let locTimestamp = "locTimestamp"
    static let locAddress = "address"
}
