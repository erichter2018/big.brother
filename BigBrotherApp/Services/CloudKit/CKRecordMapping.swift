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
    static let lockedMode = "lockedMode"

    // BBChildDevice (profile links)
    static let heartbeatProfileID = "heartbeatProfileID"
    static let scheduleProfileID = "scheduleProfileID"
    static let penaltySeconds = "penaltySeconds"
    static let penaltyTimerEndTime = "penaltyTimerEndTime"
    static let selfUnlocksPerDay = "selfUnlocksPerDay"
    static let scheduleProfileVersion = "scheduleProfileVersion"

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
}
