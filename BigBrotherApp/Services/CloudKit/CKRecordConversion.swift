import Foundation
import CloudKit
import os.log
import BigBrotherCore

private let ckLogger = Logger(subsystem: "fr.bigbrother.app", category: "CKRecordConversion")

/// Bidirectional mapping between BigBrotherCore domain models and CKRecord.
///
/// Each model type gets a pair of functions:
///   - toCKRecord(_:) → CKRecord
///   - fromCKRecord(_:) → Model?
///
/// Record IDs use a predictable naming convention based on the model's logical ID
/// to make upserts idempotent.
enum CKRecordConversion {

    // MARK: - Record ID Helpers

    static func recordID(_ logicalID: String, type: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(type)_\(logicalID)")
    }

    // MARK: - ChildProfile

    static func toCKRecord(_ profile: ChildProfile) -> CKRecord {
        let id = recordID(profile.id.rawValue, type: CKRecordType.childProfile)
        let record = CKRecord(recordType: CKRecordType.childProfile, recordID: id)
        record[CKFieldName.profileID] = profile.id.rawValue
        record[CKFieldName.familyID] = profile.familyID.rawValue
        record[CKFieldName.name] = profile.name
        record[CKFieldName.avatarName] = profile.avatarName
        record[CKFieldName.avatarEmoji] = profile.avatarEmoji
        record[CKFieldName.avatarColor] = profile.avatarColor
        record[CKFieldName.avatarPhotoBase64] = profile.avatarPhotoBase64
        do {
            let cats = try JSONEncoder().encode(profile.alwaysAllowedCategories)
            record[CKFieldName.alwaysAllowedCategoriesJSON] = String(data: cats, encoding: .utf8)
        } catch {
            ckLogger.error("Failed to encode alwaysAllowedCategories for profile \(profile.id.rawValue): \(error.localizedDescription)")
        }
        record[CKFieldName.createdAt] = profile.createdAt as NSDate
        record[CKFieldName.updatedAt] = profile.updatedAt as NSDate
        return record
    }

    static func childProfile(from record: CKRecord) -> ChildProfile? {
        guard record.recordType == CKRecordType.childProfile,
              let profileID = record[CKFieldName.profileID] as? String,
              let familyID = record[CKFieldName.familyID] as? String,
              let name = record[CKFieldName.name] as? String,
              let createdAt = record[CKFieldName.createdAt] as? Date,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else {
            ckLogger.error("Failed to deserialize ChildProfile from record \(record.recordID.recordName) — missing required fields")
            return nil
        }

        var categories: Set<String> = []
        if let json = record[CKFieldName.alwaysAllowedCategoriesJSON] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            categories = decoded
        }

        return ChildProfile(
            id: ChildProfileID(rawValue: profileID),
            familyID: FamilyID(rawValue: familyID),
            name: name,
            avatarName: record[CKFieldName.avatarName] as? String,
            avatarEmoji: record[CKFieldName.avatarEmoji] as? String,
            avatarColor: record[CKFieldName.avatarColor] as? String,
            avatarPhotoBase64: record[CKFieldName.avatarPhotoBase64] as? String,
            alwaysAllowedCategories: categories,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - ChildDevice

    static func toCKRecord(_ device: ChildDevice) -> CKRecord {
        let id = recordID(device.id.rawValue, type: CKRecordType.childDevice)
        let record = CKRecord(recordType: CKRecordType.childDevice, recordID: id)
        updateCKRecord(record, from: device)
        return record
    }

    /// Update an existing CKRecord in-place from a ChildDevice.
    /// Setting fields to nil clears them on the server when using .changedKeys save policy.
    static func updateCKRecord(_ record: CKRecord, from device: ChildDevice) {
        record[CKFieldName.deviceID] = device.id.rawValue
        record[CKFieldName.profileID] = device.childProfileID.rawValue
        record[CKFieldName.familyID] = device.familyID.rawValue
        record[CKFieldName.displayName] = device.displayName
        record[CKFieldName.modelIdentifier] = device.modelIdentifier
        record[CKFieldName.osVersion] = device.osVersion
        record[CKFieldName.enrolledAt] = device.enrolledAt as NSDate
        record[CKFieldName.familyControlsOK] = (device.familyControlsAuthorized ? 1 : 0) as NSNumber
        record[CKFieldName.heartbeatProfileID] = device.heartbeatProfileID?.uuidString
        record[CKFieldName.scheduleProfileID] = device.scheduleProfileID?.uuidString
        record[CKFieldName.penaltySeconds] = device.penaltySeconds.map { $0 as NSNumber }
        record[CKFieldName.penaltyTimerEndTime] = device.penaltyTimerEndTime.map { $0 as NSDate }
        record[CKFieldName.selfUnlocksPerDay] = device.selfUnlocksPerDay.map { $0 as NSNumber }
        record[CKFieldName.scheduleProfileVersion] = device.scheduleProfileVersion.map { $0 as NSDate }
    }

    static func childDevice(from record: CKRecord) -> ChildDevice? {
        guard record.recordType == CKRecordType.childDevice,
              let deviceID = record[CKFieldName.deviceID] as? String,
              let profileID = record[CKFieldName.profileID] as? String,
              let familyID = record[CKFieldName.familyID] as? String,
              let displayName = record[CKFieldName.displayName] as? String,
              let modelID = record[CKFieldName.modelIdentifier] as? String,
              let osVer = record[CKFieldName.osVersion] as? String,
              let enrolledAt = record[CKFieldName.enrolledAt] as? Date
        else {
            ckLogger.error("Failed to deserialize ChildDevice from record \(record.recordID.recordName) — missing required fields")
            return nil
        }

        let fcOK = (record[CKFieldName.familyControlsOK] as? Int64 ?? 0) != 0

        var hbProfileID: UUID?
        if let str = record[CKFieldName.heartbeatProfileID] as? String {
            hbProfileID = UUID(uuidString: str)
        }

        var schProfileID: UUID?
        if let str = record[CKFieldName.scheduleProfileID] as? String {
            schProfileID = UUID(uuidString: str)
        }

        let penaltySecs = record[CKFieldName.penaltySeconds] as? Int
        let penaltyEnd = record[CKFieldName.penaltyTimerEndTime] as? Date
        let selfUnlocksPerDay = record[CKFieldName.selfUnlocksPerDay] as? Int
        let schProfileVersion = record[CKFieldName.scheduleProfileVersion] as? Date
        let restrictionsJSON = record[CKFieldName.restrictionsJSON] as? String

        return ChildDevice(
            id: DeviceID(rawValue: deviceID),
            childProfileID: ChildProfileID(rawValue: profileID),
            familyID: FamilyID(rawValue: familyID),
            displayName: displayName,
            modelIdentifier: modelID,
            osVersion: osVer,
            enrolledAt: enrolledAt,
            familyControlsAuthorized: fcOK,
            heartbeatProfileID: hbProfileID,
            scheduleProfileID: schProfileID,
            penaltySeconds: penaltySecs,
            penaltyTimerEndTime: penaltyEnd,
            selfUnlocksPerDay: selfUnlocksPerDay,
            scheduleProfileVersion: schProfileVersion,
            restrictionsJSON: restrictionsJSON
        )
    }

    // MARK: - Policy

    static func toCKRecord(_ policy: Policy) -> CKRecord {
        let id = recordID(policy.targetDeviceID.rawValue, type: CKRecordType.policy)
        let record = CKRecord(recordType: CKRecordType.policy, recordID: id)
        updateCKRecord(record, from: policy)
        return record
    }

    /// Update an existing CKRecord with policy fields (preserves change tag).
    static func updateCKRecord(_ record: CKRecord, from policy: Policy) {
        record[CKFieldName.deviceID] = policy.targetDeviceID.rawValue
        record[CKFieldName.mode] = policy.mode.rawValue
        record[CKFieldName.tempUnlockUntil] = policy.temporaryUnlockUntil as NSDate?
        record[CKFieldName.scheduleID] = policy.activeScheduleID?.uuidString
        record[CKFieldName.version] = policy.version as NSNumber
        record[CKFieldName.updatedAt] = policy.updatedAt as NSDate
    }

    static func policy(from record: CKRecord) -> Policy? {
        guard record.recordType == CKRecordType.policy,
              let deviceID = record[CKFieldName.deviceID] as? String,
              let modeRaw = record[CKFieldName.mode] as? String,
              let mode = LockMode.from( modeRaw),
              let version = record[CKFieldName.version] as? Int64,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else {
            ckLogger.error("Failed to deserialize Policy from record \(record.recordID.recordName) — missing required fields")
            return nil
        }

        var scheduleID: UUID?
        if let sid = record[CKFieldName.scheduleID] as? String {
            scheduleID = UUID(uuidString: sid)
        }

        return Policy(
            targetDeviceID: DeviceID(rawValue: deviceID),
            mode: mode,
            temporaryUnlockUntil: record[CKFieldName.tempUnlockUntil] as? Date,
            activeScheduleID: scheduleID,
            version: version,
            updatedAt: updatedAt
        )
    }

    // MARK: - RemoteCommand

    static func toCKRecord(_ command: RemoteCommand) -> CKRecord {
        let id = recordID(command.id.uuidString, type: CKRecordType.remoteCommand)
        let record = CKRecord(recordType: CKRecordType.remoteCommand, recordID: id)
        record[CKFieldName.commandID] = command.id.uuidString
        record[CKFieldName.familyID] = command.familyID.rawValue

        switch command.target {
        case .device(let did):
            record[CKFieldName.targetType] = "device"
            record[CKFieldName.targetID] = did.rawValue
        case .child(let cid):
            record[CKFieldName.targetType] = "child"
            record[CKFieldName.targetID] = cid.rawValue
        case .allDevices:
            record[CKFieldName.targetType] = "all"
            record[CKFieldName.targetID] = nil
        }

        do {
            let actionData = try JSONEncoder().encode(command.action)
            record[CKFieldName.actionJSON] = String(data: actionData, encoding: .utf8)
        } catch {
            ckLogger.error("Failed to encode command action for \(command.id.uuidString): \(error.localizedDescription)")
        }

        record[CKFieldName.issuedBy] = command.issuedBy
        record[CKFieldName.issuedAt] = command.issuedAt as NSDate
        record[CKFieldName.expiresAt] = command.expiresAt as NSDate?
        record[CKFieldName.status] = command.status.rawValue
        record[CKFieldName.signatureBase64] = command.signatureBase64

        // Alert push fields — only mode commands get these, enabling the
        // CKQuerySubscription to deliver an alert (non-silent) push.
        if let title = command.action.alertPushTitle {
            record[CKFieldName.alertTitle] = title
        }
        if let body = command.action.alertPushBody {
            record[CKFieldName.alertBody] = body
        }

        return record
    }

    static func remoteCommand(from record: CKRecord) -> RemoteCommand? {
        guard record.recordType == CKRecordType.remoteCommand,
              let cmdIDStr = record[CKFieldName.commandID] as? String,
              let cmdID = UUID(uuidString: cmdIDStr),
              let familyID = record[CKFieldName.familyID] as? String,
              let targetTypeStr = record[CKFieldName.targetType] as? String,
              let actionJSON = record[CKFieldName.actionJSON] as? String,
              let actionData = actionJSON.data(using: .utf8),
              let action = try? JSONDecoder().decode(CommandAction.self, from: actionData),
              let issuedBy = record[CKFieldName.issuedBy] as? String,
              let issuedAt = record[CKFieldName.issuedAt] as? Date,
              let statusRaw = record[CKFieldName.status] as? String,
              let status = CommandStatus(rawValue: statusRaw)
        else {
            ckLogger.error("Failed to deserialize RemoteCommand from record \(record.recordID.recordName) — missing or invalid fields")
            return nil
        }

        let target: CommandTarget
        let targetID = record[CKFieldName.targetID] as? String
        switch targetTypeStr {
        case "device":
            guard let tid = targetID else { return nil }
            target = .device(DeviceID(rawValue: tid))
        case "child":
            guard let tid = targetID else { return nil }
            target = .child(ChildProfileID(rawValue: tid))
        case "all":
            target = .allDevices
        default:
            return nil
        }

        return RemoteCommand(
            id: cmdID,
            familyID: FamilyID(rawValue: familyID),
            target: target,
            action: action,
            issuedBy: issuedBy,
            issuedAt: issuedAt,
            expiresAt: record[CKFieldName.expiresAt] as? Date,
            status: status,
            signatureBase64: record[CKFieldName.signatureBase64] as? String
        )
    }

    // MARK: - CommandReceipt

    static func toCKRecord(_ receipt: CommandReceipt) -> CKRecord {
        let name = "\(receipt.commandID.uuidString)_\(receipt.deviceID.rawValue)"
        let id = recordID(name, type: CKRecordType.commandReceipt)
        let record = CKRecord(recordType: CKRecordType.commandReceipt, recordID: id)
        record[CKFieldName.commandID] = receipt.commandID.uuidString
        record[CKFieldName.deviceID] = receipt.deviceID.rawValue
        record[CKFieldName.familyID] = receipt.familyID.rawValue
        record[CKFieldName.status] = receipt.status.rawValue
        record[CKFieldName.appliedAt] = receipt.appliedAt as NSDate?
        record[CKFieldName.failureReason] = receipt.failureReason
        return record
    }

    static func commandReceipt(from record: CKRecord) -> CommandReceipt? {
        guard record.recordType == CKRecordType.commandReceipt,
              let cmdIDStr = record[CKFieldName.commandID] as? String,
              let cmdID = UUID(uuidString: cmdIDStr),
              let deviceID = record[CKFieldName.deviceID] as? String,
              let familyID = record[CKFieldName.familyID] as? String,
              let statusRaw = record[CKFieldName.status] as? String,
              let status = CommandStatus(rawValue: statusRaw)
        else {
            ckLogger.error("Failed to deserialize CommandReceipt from record \(record.recordID.recordName)")
            return nil
        }

        return CommandReceipt(
            commandID: cmdID,
            deviceID: DeviceID(rawValue: deviceID),
            familyID: FamilyID(rawValue: familyID),
            status: status,
            appliedAt: record[CKFieldName.appliedAt] as? Date,
            failureReason: record[CKFieldName.failureReason] as? String
        )
    }

    // MARK: - DeviceHeartbeat

    static func toCKRecord(_ hb: DeviceHeartbeat) -> CKRecord {
        let id = recordID(hb.deviceID.rawValue, type: CKRecordType.heartbeat)
        let record = CKRecord(recordType: CKRecordType.heartbeat, recordID: id)
        updateCKRecord(record, from: hb)
        return record
    }

    /// Update an existing CKRecord with heartbeat fields (preserves change tag).
    static func updateCKRecord(_ record: CKRecord, from hb: DeviceHeartbeat) {
        record[CKFieldName.deviceID] = hb.deviceID.rawValue
        record[CKFieldName.familyID] = hb.familyID.rawValue
        record[CKFieldName.timestamp] = hb.timestamp as NSDate
        record[CKFieldName.currentMode] = hb.currentMode.rawValue
        record[CKFieldName.policyVersion] = hb.policyVersion as NSNumber
        record[CKFieldName.fcAuthorized] = (hb.familyControlsAuthorized ? 1 : 0) as NSNumber
        record[CKFieldName.hbFCAuthType] = hb.familyControlsAuthType
        record[CKFieldName.hbFCChildFailReason] = hb.childAuthFailReason
        record[CKFieldName.hbPermissions] = hb.permissionDetails
        record[CKFieldName.batteryLevel] = hb.batteryLevel.map { $0 as NSNumber }
        record[CKFieldName.isCharging] = hb.isCharging.map { ($0 ? 1 : 0) as NSNumber }
        record[CKFieldName.appBlockingConfigured] = hb.appBlockingConfigured.map { ($0 ? 1 : 0) as NSNumber }
        record[CKFieldName.blockedCategoryCount] = hb.blockedCategoryCount.map { $0 as NSNumber }
        record[CKFieldName.blockedAppCount] = hb.blockedAppCount.map { $0 as NSNumber }
        record[CKFieldName.blockedAppNames] = hb.blockedAppNames.flatMap { $0.isEmpty ? nil : $0 as NSArray }
        record[CKFieldName.blockedCategoryNames] = hb.blockedCategoryNames.flatMap { $0.isEmpty ? nil : $0 as NSArray }
        record[CKFieldName.installID] = hb.installID?.uuidString
        record[CKFieldName.heartbeatSeq] = hb.heartbeatSeq.map { $0 as NSNumber }
        record[CKFieldName.cloudKitStatus] = hb.cloudKitStatus
        record[CKFieldName.allowedAppNames] = hb.allowedAppNames.flatMap { $0.isEmpty ? nil : $0 as NSArray }
        record[CKFieldName.allowedAppCount] = hb.allowedAppCount.map { $0 as NSNumber }
        record[CKFieldName.temporaryAllowedAppNames] = hb.temporaryAllowedAppNames.flatMap { $0.isEmpty ? nil : $0 as NSArray }
        record[CKFieldName.temporaryUnlockExpiresAt] = hb.temporaryUnlockExpiresAt.map { $0 as NSDate }
        record[CKFieldName.isChildAuthorization] = hb.isChildAuthorization.map { ($0 ? 1 : 0) as NSNumber }
        record[CKFieldName.availableDiskSpace] = hb.availableDiskSpace.map { $0 as NSNumber }
        record[CKFieldName.totalDiskSpace] = hb.totalDiskSpace.map { $0 as NSNumber }
        record[CKFieldName.selfUnlocksUsedToday] = hb.selfUnlocksUsedToday.map { $0 as NSNumber }
        record[CKFieldName.temporaryUnlockOrigin] = hb.temporaryUnlockOrigin?.rawValue
        record[CKFieldName.hbOSVersion] = hb.osVersion
        record[CKFieldName.hbModelIdentifier] = hb.modelIdentifier
        record[CKFieldName.hbAppBuildNumber] = hb.appBuildNumber.map { $0 as NSNumber }
        record[CKFieldName.hbMainAppBuild] = hb.mainAppLastLaunchedBuild.map { $0 as NSNumber }
        record[CKFieldName.hbEnforcementError] = hb.enforcementError
        record[CKFieldName.hbActiveScheduleWindow] = hb.activeScheduleWindowName
        record[CKFieldName.hbLastCommandProcessedAt] = hb.lastCommandProcessedAt.map { $0 as NSDate }
        record[CKFieldName.hbLastCommandID] = hb.lastCommandID
        record[CKFieldName.hbMonitorLastActiveAt] = hb.monitorLastActiveAt.map { $0 as NSDate }
        record[CKFieldName.hbVPNDetected] = hb.vpnDetected.map { NSNumber(value: $0) }
        record[CKFieldName.hbTimeZoneID] = hb.timeZoneIdentifier
        record[CKFieldName.hbTimeZoneOffset] = hb.timeZoneOffsetSeconds.map { NSNumber(value: $0) }
        record[CKFieldName.hbScreenTimeMinutes] = hb.screenTimeMinutes.map { $0 as NSNumber }
        record[CKFieldName.hbScreenUnlockCount] = hb.screenUnlockCount.map { $0 as NSNumber }
        record["hbHasSigningKeys"] = hb.hasSigningKeys.map { NSNumber(value: $0) }
        record[CKFieldName.hbJailbreakDetected] = hb.jailbreakDetected.map { NSNumber(value: $0) }
        record[CKFieldName.hbJailbreakReason] = hb.jailbreakReason
        record[CKFieldName.hbIsDriving] = hb.isDriving.map { NSNumber(value: $0) }
        record[CKFieldName.hbCurrentSpeed] = hb.currentSpeed.map { $0 as NSNumber }
        record[CKFieldName.hbHeartbeatSource] = hb.heartbeatSource
        record[CKFieldName.hbBuildType] = hb.buildType
        record[CKFieldName.hbTunnelConnected] = hb.tunnelConnected.map { NSNumber(value: $0) }
        record[CKFieldName.hbMotionAuthorized] = hb.motionAuthorized.map { NSNumber(value: $0) }
        record[CKFieldName.hbNotificationsAuthorized] = hb.notificationsAuthorized.map { NSNumber(value: $0) }
        record[CKFieldName.hbDeviceLocked] = hb.isDeviceLocked.map { NSNumber(value: $0) }
        record[CKFieldName.hbInternetBlocked] = hb.internetBlocked.map { NSNumber(value: $0) }
        record["hbInternetBlockedReason"] = hb.internetBlockedReason
        record["hbDNSFilteringEnabled"] = hb.dnsFilteringEnabled.map { NSNumber(value: $0) }
        record["hbDNSFilteringAutoReenableAt"] = hb.dnsFilteringAutoReenableAt.map { $0 as NSDate }
        if let usage = hb.appUsageMinutes,
           !usage.isEmpty,
           let data = try? JSONEncoder().encode(usage) {
            record["hbAppUsageMinutes"] = String(data: data, encoding: .utf8)
        } else {
            record["hbAppUsageMinutes"] = nil
        }
        record[CKFieldName.hbExhaustedAppFingerprints] = hb.exhaustedAppFingerprints.flatMap { $0.isEmpty ? nil : $0 as NSArray }
        record[CKFieldName.hbExhaustedAppBundleIDs] = hb.exhaustedAppBundleIDs.flatMap { $0.isEmpty ? nil : $0 as NSArray }
        record[CKFieldName.hbExhaustedAppNames] = hb.exhaustedAppNames.flatMap { $0.isEmpty ? nil : $0 as NSArray }
        record[CKFieldName.hbShieldsActive] = hb.shieldsActive.map { NSNumber(value: $0) }
        record[CKFieldName.hbScheduleResolvedMode] = hb.scheduleResolvedMode
        record[CKFieldName.hbLastShieldChangeReason] = hb.lastShieldChangeReason
        record[CKFieldName.hbShieldedAppCount] = hb.shieldedAppCount.map { $0 as NSNumber }
        record[CKFieldName.hbShieldCategoryActive] = hb.shieldCategoryActive.map { NSNumber(value: $0) }
        record[CKFieldName.hbLatitude] = hb.latitude.map { $0 as NSNumber }
        record[CKFieldName.hbLongitude] = hb.longitude.map { $0 as NSNumber }
        record[CKFieldName.hbLocationTimestamp] = hb.locationTimestamp.map { $0 as NSDate }
        record[CKFieldName.hbLocationAddress] = hb.locationAddress
        record[CKFieldName.hbLocationAccuracy] = hb.locationAccuracy.map { $0 as NSNumber }
        record[CKFieldName.hbLocationAuthorization] = hb.locationAuthorization
        record["hbMonitorBuild"] = hb.monitorBuildNumber.map { $0 as NSNumber }
        record["hbShieldBuild"] = hb.shieldBuildNumber.map { $0 as NSNumber }
        record["hbShieldActionBuild"] = hb.shieldActionBuildNumber.map { $0 as NSNumber }
        record["hbFCDegraded"] = hb.fcAuthDegraded.map { NSNumber(value: $0) }
        record["hbGhostShields"] = hb.ghostShieldsDetected.map { NSNumber(value: $0) }
        record["hbDiagnosticSnapshot"] = hb.diagnosticSnapshot
    }

    static func deviceHeartbeat(from record: CKRecord) -> DeviceHeartbeat? {
        guard record.recordType == CKRecordType.heartbeat,
              let deviceID = record[CKFieldName.deviceID] as? String,
              let familyID = record[CKFieldName.familyID] as? String,
              let timestamp = record[CKFieldName.timestamp] as? Date,
              let modeRaw = record[CKFieldName.currentMode] as? String,
              let mode = LockMode.from( modeRaw),
              let pv = record[CKFieldName.policyVersion] as? Int64,
              let fc = record[CKFieldName.fcAuthorized] as? Int64
        else {
            ckLogger.error("Failed to deserialize DeviceHeartbeat from record \(record.recordID.recordName)")
            return nil
        }

        var installID: UUID?
        if let str = record[CKFieldName.installID] as? String {
            installID = UUID(uuidString: str)
        }

        return DeviceHeartbeat(
            deviceID: DeviceID(rawValue: deviceID),
            familyID: FamilyID(rawValue: familyID),
            timestamp: timestamp,
            currentMode: mode,
            policyVersion: pv,
            familyControlsAuthorized: fc != 0,
            familyControlsAuthType: record[CKFieldName.hbFCAuthType] as? String,
            childAuthFailReason: record[CKFieldName.hbFCChildFailReason] as? String,
            permissionDetails: record[CKFieldName.hbPermissions] as? String,
            batteryLevel: record[CKFieldName.batteryLevel] as? Double,
            isCharging: (record[CKFieldName.isCharging] as? Int64).map { $0 != 0 },
            appBlockingConfigured: (record[CKFieldName.appBlockingConfigured] as? Int64).map { $0 != 0 },
            blockedCategoryCount: (record[CKFieldName.blockedCategoryCount] as? Int64).map { Int($0) },
            blockedAppCount: (record[CKFieldName.blockedAppCount] as? Int64).map { Int($0) },
            blockedAppNames: record[CKFieldName.blockedAppNames] as? [String],
            blockedCategoryNames: record[CKFieldName.blockedCategoryNames] as? [String],
            installID: installID,
            heartbeatSeq: record[CKFieldName.heartbeatSeq] as? Int64,
            cloudKitStatus: record[CKFieldName.cloudKitStatus] as? String,
            allowedAppNames: record[CKFieldName.allowedAppNames] as? [String],
            allowedAppCount: (record[CKFieldName.allowedAppCount] as? Int64).map { Int($0) },
            temporaryAllowedAppNames: record[CKFieldName.temporaryAllowedAppNames] as? [String],
            temporaryUnlockExpiresAt: record[CKFieldName.temporaryUnlockExpiresAt] as? Date,
            isChildAuthorization: (record[CKFieldName.isChildAuthorization] as? Int64).map { $0 != 0 },
            availableDiskSpace: record[CKFieldName.availableDiskSpace] as? Int64,
            totalDiskSpace: record[CKFieldName.totalDiskSpace] as? Int64,
            selfUnlocksUsedToday: (record[CKFieldName.selfUnlocksUsedToday] as? Int64).map { Int($0) },
            temporaryUnlockOrigin: (record[CKFieldName.temporaryUnlockOrigin] as? String).flatMap { TemporaryUnlockOrigin(rawValue: $0) },
            osVersion: record[CKFieldName.hbOSVersion] as? String,
            modelIdentifier: record[CKFieldName.hbModelIdentifier] as? String,
            appBuildNumber: (record[CKFieldName.hbAppBuildNumber] as? Int64).map { Int($0) },
            mainAppLastLaunchedBuild: (record[CKFieldName.hbMainAppBuild] as? Int64).map { Int($0) },
            enforcementError: record[CKFieldName.hbEnforcementError] as? String,
            activeScheduleWindowName: record[CKFieldName.hbActiveScheduleWindow] as? String,
            lastCommandProcessedAt: record[CKFieldName.hbLastCommandProcessedAt] as? Date,
            lastCommandID: record[CKFieldName.hbLastCommandID] as? String,
            monitorLastActiveAt: record[CKFieldName.hbMonitorLastActiveAt] as? Date,
            vpnDetected: (record[CKFieldName.hbVPNDetected] as? Int64).map { $0 != 0 },
            internetBlocked: (record[CKFieldName.hbInternetBlocked] as? Int64).map { $0 != 0 },
            internetBlockedReason: record["hbInternetBlockedReason"] as? String,
            dnsFilteringEnabled: (record["hbDNSFilteringEnabled"] as? Int64).map { $0 != 0 },
            dnsFilteringAutoReenableAt: record["hbDNSFilteringAutoReenableAt"] as? Date,
            appUsageMinutes: (record["hbAppUsageMinutes"] as? String).flatMap { str in
                str.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) }
            },
            exhaustedAppFingerprints: record[CKFieldName.hbExhaustedAppFingerprints] as? [String],
            exhaustedAppBundleIDs: record[CKFieldName.hbExhaustedAppBundleIDs] as? [String],
            exhaustedAppNames: record[CKFieldName.hbExhaustedAppNames] as? [String],
            timeZoneIdentifier: record[CKFieldName.hbTimeZoneID] as? String,
            timeZoneOffsetSeconds: (record[CKFieldName.hbTimeZoneOffset] as? Int64).map { Int($0) },
            screenTimeMinutes: (record[CKFieldName.hbScreenTimeMinutes] as? Int64).map { Int($0) },
            screenUnlockCount: (record[CKFieldName.hbScreenUnlockCount] as? Int64).map { Int($0) },
            hasSigningKeys: (record["hbHasSigningKeys"] as? Int64).map { $0 != 0 },
            jailbreakDetected: (record[CKFieldName.hbJailbreakDetected] as? Int64).map { $0 != 0 },
            jailbreakReason: record[CKFieldName.hbJailbreakReason] as? String,
            isDriving: (record[CKFieldName.hbIsDriving] as? Int64).map { $0 != 0 },
            currentSpeed: record[CKFieldName.hbCurrentSpeed] as? Double,
            heartbeatSource: record[CKFieldName.hbHeartbeatSource] as? String,
            buildType: record[CKFieldName.hbBuildType] as? String,
            tunnelConnected: (record[CKFieldName.hbTunnelConnected] as? Int64).map { $0 != 0 },
            motionAuthorized: (record[CKFieldName.hbMotionAuthorized] as? Int64).map { $0 != 0 },
            notificationsAuthorized: (record[CKFieldName.hbNotificationsAuthorized] as? Int64).map { $0 != 0 },
            isDeviceLocked: (record[CKFieldName.hbDeviceLocked] as? Int64).map { $0 != 0 },
            shieldsActive: (record[CKFieldName.hbShieldsActive] as? Int64).map { $0 != 0 },
            scheduleResolvedMode: record[CKFieldName.hbScheduleResolvedMode] as? String,
            lastShieldChangeReason: record[CKFieldName.hbLastShieldChangeReason] as? String,
            shieldedAppCount: (record[CKFieldName.hbShieldedAppCount] as? Int64).map { Int($0) },
            shieldCategoryActive: (record[CKFieldName.hbShieldCategoryActive] as? Int64).map { $0 != 0 },
            latitude: record[CKFieldName.hbLatitude] as? Double,
            longitude: record[CKFieldName.hbLongitude] as? Double,
            locationTimestamp: record[CKFieldName.hbLocationTimestamp] as? Date,
            locationAddress: record[CKFieldName.hbLocationAddress] as? String,
            locationAccuracy: record[CKFieldName.hbLocationAccuracy] as? Double,
            locationAuthorization: record[CKFieldName.hbLocationAuthorization] as? String,
            monitorBuildNumber: record["hbMonitorBuild"] as? Int,
            shieldBuildNumber: record["hbShieldBuild"] as? Int,
            shieldActionBuildNumber: record["hbShieldActionBuild"] as? Int,
            fcAuthDegraded: (record["hbFCDegraded"] as? Int64).map { $0 != 0 },
            ghostShieldsDetected: (record["hbGhostShields"] as? Int64).map { $0 != 0 },
            diagnosticSnapshot: record["hbDiagnosticSnapshot"] as? String
        )
    }

    // MARK: - DeviceHeartbeat (REST decode path)

    /// Decode a `DeviceHeartbeat` from a `CloudKitRESTClient.RESTRecord`.
    /// Mirrors `deviceHeartbeat(from: CKRecord)` field-for-field but reads
    /// through the REST-shaped `RESTRecord` accessors instead of CKRecord
    /// subscripts. Used by the REST-based `fetchLatestHeartbeats` path —
    /// the framework path (via `cloudd`) remains as a fallback.
    ///
    /// REST encodes booleans as INT64 (0/1) and Dates as TIMESTAMP
    /// (milliseconds-since-epoch), which matches the framework's own
    /// wire format; the accessors on `RESTRecord` handle the conversion
    /// back to Bool / Date so callers don't need to care.
    static func deviceHeartbeat(fromREST rec: CloudKitRESTClient.RESTRecord) -> DeviceHeartbeat? {
        guard let deviceID = rec.string(CKFieldName.deviceID),
              let familyID = rec.string(CKFieldName.familyID),
              let timestamp = rec.date(CKFieldName.timestamp),
              let modeRaw = rec.string(CKFieldName.currentMode),
              let mode = LockMode.from(modeRaw),
              let pv = rec.int64(CKFieldName.policyVersion),
              let fc = rec.int64(CKFieldName.fcAuthorized)
        else {
            ckLogger.error("Failed to deserialize DeviceHeartbeat from REST record \(rec.recordName)")
            return nil
        }

        let installID: UUID? = rec.string(CKFieldName.installID).flatMap(UUID.init)

        return DeviceHeartbeat(
            deviceID: DeviceID(rawValue: deviceID),
            familyID: FamilyID(rawValue: familyID),
            timestamp: timestamp,
            currentMode: mode,
            policyVersion: pv,
            familyControlsAuthorized: fc != 0,
            familyControlsAuthType: rec.string(CKFieldName.hbFCAuthType),
            childAuthFailReason: rec.string(CKFieldName.hbFCChildFailReason),
            permissionDetails: rec.string(CKFieldName.hbPermissions),
            batteryLevel: rec.double(CKFieldName.batteryLevel),
            isCharging: rec.bool(CKFieldName.isCharging),
            appBlockingConfigured: rec.bool(CKFieldName.appBlockingConfigured),
            blockedCategoryCount: rec.int(CKFieldName.blockedCategoryCount),
            blockedAppCount: rec.int(CKFieldName.blockedAppCount),
            blockedAppNames: rec.stringList(CKFieldName.blockedAppNames),
            blockedCategoryNames: rec.stringList(CKFieldName.blockedCategoryNames),
            installID: installID,
            heartbeatSeq: rec.int64(CKFieldName.heartbeatSeq),
            cloudKitStatus: rec.string(CKFieldName.cloudKitStatus),
            allowedAppNames: rec.stringList(CKFieldName.allowedAppNames),
            allowedAppCount: rec.int(CKFieldName.allowedAppCount),
            temporaryAllowedAppNames: rec.stringList(CKFieldName.temporaryAllowedAppNames),
            temporaryUnlockExpiresAt: rec.date(CKFieldName.temporaryUnlockExpiresAt),
            isChildAuthorization: rec.bool(CKFieldName.isChildAuthorization),
            availableDiskSpace: rec.int64(CKFieldName.availableDiskSpace),
            totalDiskSpace: rec.int64(CKFieldName.totalDiskSpace),
            selfUnlocksUsedToday: rec.int(CKFieldName.selfUnlocksUsedToday),
            temporaryUnlockOrigin: rec.string(CKFieldName.temporaryUnlockOrigin).flatMap(TemporaryUnlockOrigin.init(rawValue:)),
            osVersion: rec.string(CKFieldName.hbOSVersion),
            modelIdentifier: rec.string(CKFieldName.hbModelIdentifier),
            appBuildNumber: rec.int(CKFieldName.hbAppBuildNumber),
            mainAppLastLaunchedBuild: rec.int(CKFieldName.hbMainAppBuild),
            enforcementError: rec.string(CKFieldName.hbEnforcementError),
            activeScheduleWindowName: rec.string(CKFieldName.hbActiveScheduleWindow),
            lastCommandProcessedAt: rec.date(CKFieldName.hbLastCommandProcessedAt),
            lastCommandID: rec.string(CKFieldName.hbLastCommandID),
            monitorLastActiveAt: rec.date(CKFieldName.hbMonitorLastActiveAt),
            vpnDetected: rec.bool(CKFieldName.hbVPNDetected),
            internetBlocked: rec.bool(CKFieldName.hbInternetBlocked),
            internetBlockedReason: rec.string("hbInternetBlockedReason"),
            dnsFilteringEnabled: rec.bool("hbDNSFilteringEnabled"),
            dnsFilteringAutoReenableAt: rec.date("hbDNSFilteringAutoReenableAt"),
            appUsageMinutes: rec.string("hbAppUsageMinutes").flatMap { str in
                str.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) }
            },
            exhaustedAppFingerprints: rec.stringList(CKFieldName.hbExhaustedAppFingerprints),
            exhaustedAppBundleIDs: rec.stringList(CKFieldName.hbExhaustedAppBundleIDs),
            exhaustedAppNames: rec.stringList(CKFieldName.hbExhaustedAppNames),
            timeZoneIdentifier: rec.string(CKFieldName.hbTimeZoneID),
            timeZoneOffsetSeconds: rec.int(CKFieldName.hbTimeZoneOffset),
            screenTimeMinutes: rec.int(CKFieldName.hbScreenTimeMinutes),
            screenUnlockCount: rec.int(CKFieldName.hbScreenUnlockCount),
            hasSigningKeys: rec.bool("hbHasSigningKeys"),
            jailbreakDetected: rec.bool(CKFieldName.hbJailbreakDetected),
            jailbreakReason: rec.string(CKFieldName.hbJailbreakReason),
            isDriving: rec.bool(CKFieldName.hbIsDriving),
            currentSpeed: rec.double(CKFieldName.hbCurrentSpeed),
            heartbeatSource: rec.string(CKFieldName.hbHeartbeatSource),
            buildType: rec.string(CKFieldName.hbBuildType),
            tunnelConnected: rec.bool(CKFieldName.hbTunnelConnected),
            motionAuthorized: rec.bool(CKFieldName.hbMotionAuthorized),
            notificationsAuthorized: rec.bool(CKFieldName.hbNotificationsAuthorized),
            isDeviceLocked: rec.bool(CKFieldName.hbDeviceLocked),
            shieldsActive: rec.bool(CKFieldName.hbShieldsActive),
            scheduleResolvedMode: rec.string(CKFieldName.hbScheduleResolvedMode),
            lastShieldChangeReason: rec.string(CKFieldName.hbLastShieldChangeReason),
            shieldedAppCount: rec.int(CKFieldName.hbShieldedAppCount),
            shieldCategoryActive: rec.bool(CKFieldName.hbShieldCategoryActive),
            latitude: rec.double(CKFieldName.hbLatitude),
            longitude: rec.double(CKFieldName.hbLongitude),
            locationTimestamp: rec.date(CKFieldName.hbLocationTimestamp),
            locationAddress: rec.string(CKFieldName.hbLocationAddress),
            locationAccuracy: rec.double(CKFieldName.hbLocationAccuracy),
            locationAuthorization: rec.string(CKFieldName.hbLocationAuthorization),
            monitorBuildNumber: rec.int("hbMonitorBuild"),
            shieldBuildNumber: rec.int("hbShieldBuild"),
            shieldActionBuildNumber: rec.int("hbShieldActionBuild"),
            fcAuthDegraded: rec.bool("hbFCDegraded"),
            ghostShieldsDetected: rec.bool("hbGhostShields"),
            diagnosticSnapshot: rec.string("hbDiagnosticSnapshot")
        )
    }

    // MARK: - EventLogEntry

    static func toCKRecord(_ entry: EventLogEntry) -> CKRecord {
        let id = recordID(entry.id.uuidString, type: CKRecordType.eventLog)
        let record = CKRecord(recordType: CKRecordType.eventLog, recordID: id)
        record[CKFieldName.eventID] = entry.id.uuidString
        record[CKFieldName.deviceID] = entry.deviceID.rawValue
        record[CKFieldName.familyID] = entry.familyID.rawValue
        record[CKFieldName.eventType] = entry.eventType.rawValue
        record[CKFieldName.details] = entry.details
        record[CKFieldName.timestamp] = entry.timestamp as NSDate
        return record
    }

    static func eventLogEntry(from record: CKRecord) -> EventLogEntry? {
        guard record.recordType == CKRecordType.eventLog,
              let idStr = record[CKFieldName.eventID] as? String,
              let id = UUID(uuidString: idStr),
              let deviceID = record[CKFieldName.deviceID] as? String,
              let familyID = record[CKFieldName.familyID] as? String,
              let typeRaw = record[CKFieldName.eventType] as? String,
              let eventType = EventType(rawValue: typeRaw),
              let timestamp = record[CKFieldName.timestamp] as? Date
        else {
            ckLogger.error("Failed to deserialize EventLogEntry from record \(record.recordID.recordName)")
            return nil
        }

        return EventLogEntry(
            id: id,
            deviceID: DeviceID(rawValue: deviceID),
            familyID: FamilyID(rawValue: familyID),
            eventType: eventType,
            details: record[CKFieldName.details] as? String,
            timestamp: timestamp,
            uploadState: .uploaded
        )
    }

    // MARK: - EnforcementLog

    static func enforcementLogRecord(
        entryID: UUID, deviceID: DeviceID, familyID: FamilyID,
        category: String, message: String, details: String?,
        timestamp: Date, build: Int
    ) -> CKRecord {
        let id = recordID(entryID.uuidString, type: CKRecordType.enforcementLog)
        let record = CKRecord(recordType: CKRecordType.enforcementLog, recordID: id)
        record[CKFieldName.deviceID] = deviceID.rawValue
        record[CKFieldName.familyID] = familyID.rawValue
        record[CKFieldName.enfCategory] = category
        record[CKFieldName.enfMessage] = message
        record[CKFieldName.enfDetails] = details
        record[CKFieldName.timestamp] = timestamp as NSDate
        record[CKFieldName.enfBuild] = build as NSNumber
        return record
    }

    // MARK: - EnrollmentInvite

    static func toCKRecord(_ invite: EnrollmentInvite) -> CKRecord {
        let id = recordID(invite.code, type: CKRecordType.enrollmentInvite)
        let record = CKRecord(recordType: CKRecordType.enrollmentInvite, recordID: id)
        record[CKFieldName.code] = invite.code
        record[CKFieldName.familyID] = invite.familyID.rawValue
        record[CKFieldName.profileID] = invite.childProfileID.rawValue
        record[CKFieldName.createdAt] = invite.createdAt as NSDate
        record[CKFieldName.expiresAt] = invite.expiresAt as NSDate
        record[CKFieldName.used] = (invite.used ? 1 : 0) as NSNumber
        record[CKFieldName.usedByDeviceID] = invite.usedByDeviceID?.rawValue
        record[CKFieldName.revoked] = (invite.revoked ? 1 : 0) as NSNumber
        record[CKFieldName.commandSigningPubKey] = invite.commandSigningPublicKeyBase64
        // SECURITY: Private key is never stored in CloudKit.
        return record
    }

    static func enrollmentInvite(from record: CKRecord) -> EnrollmentInvite? {
        guard record.recordType == CKRecordType.enrollmentInvite,
              let code = record[CKFieldName.code] as? String,
              let familyID = record[CKFieldName.familyID] as? String,
              let profileID = record[CKFieldName.profileID] as? String,
              let createdAt = record[CKFieldName.createdAt] as? Date,
              let expiresAt = record[CKFieldName.expiresAt] as? Date,
              let usedInt = record[CKFieldName.used] as? Int64
        else {
            ckLogger.error("Failed to deserialize EnrollmentInvite from record \(record.recordID.recordName)")
            return nil
        }

        var usedByDevice: DeviceID?
        if let ubdStr = record[CKFieldName.usedByDeviceID] as? String {
            usedByDevice = DeviceID(rawValue: ubdStr)
        }

        let revokedInt = record[CKFieldName.revoked] as? Int64 ?? 0

        return EnrollmentInvite(
            code: code,
            familyID: FamilyID(rawValue: familyID),
            childProfileID: ChildProfileID(rawValue: profileID),
            createdAt: createdAt,
            expiresAt: expiresAt,
            used: usedInt != 0,
            usedByDeviceID: usedByDevice,
            revoked: revokedInt != 0,
            commandSigningPublicKeyBase64: record[CKFieldName.commandSigningPubKey] as? String
        )
    }

    // MARK: - Schedule

    static func toCKRecord(_ schedule: Schedule) -> CKRecord {
        let id = recordID(schedule.id.uuidString, type: CKRecordType.schedule)
        let record = CKRecord(recordType: CKRecordType.schedule, recordID: id)
        record[CKFieldName.familyID] = schedule.familyID.rawValue
        record[CKFieldName.profileID] = schedule.childProfileID.rawValue
        record[CKFieldName.scheduleName] = schedule.name
        record[CKFieldName.mode] = schedule.mode.rawValue
        record[CKFieldName.isActive] = (schedule.isActive ? 1 : 0) as NSNumber
        record[CKFieldName.startHour] = schedule.startTime.hour as NSNumber
        record[CKFieldName.startMinute] = schedule.startTime.minute as NSNumber
        record[CKFieldName.endHour] = schedule.endTime.hour as NSNumber
        record[CKFieldName.endMinute] = schedule.endTime.minute as NSNumber
        record[CKFieldName.updatedAt] = schedule.updatedAt as NSDate

        do {
            let daysData = try JSONEncoder().encode(schedule.daysOfWeek)
            record[CKFieldName.daysOfWeekJSON] = String(data: daysData, encoding: .utf8)
        } catch {
            ckLogger.error("Failed to encode daysOfWeek for schedule \(schedule.id.uuidString): \(error.localizedDescription)")
        }

        return record
    }

    static func schedule(from record: CKRecord) -> Schedule? {
        guard record.recordType == CKRecordType.schedule,
              let familyID = record[CKFieldName.familyID] as? String,
              let profileID = record[CKFieldName.profileID] as? String,
              let name = record[CKFieldName.scheduleName] as? String,
              let modeRaw = record[CKFieldName.mode] as? String,
              let mode = LockMode.from( modeRaw),
              let startH = record[CKFieldName.startHour] as? Int64,
              let startM = record[CKFieldName.startMinute] as? Int64,
              let endH = record[CKFieldName.endHour] as? Int64,
              let endM = record[CKFieldName.endMinute] as? Int64,
              let activeInt = record[CKFieldName.isActive] as? Int64,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else {
            ckLogger.error("Failed to deserialize Schedule from record \(record.recordID.recordName)")
            return nil
        }

        var days: Set<DayOfWeek> = []
        if let daysJSON = record[CKFieldName.daysOfWeekJSON] as? String,
           let daysData = daysJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Set<DayOfWeek>.self, from: daysData) {
            days = decoded
        }

        // Extract UUID from record name (format: "BBSchedule_<uuid>")
        let recordName = record.recordID.recordName
        let uuidStr = recordName.replacingOccurrences(of: "\(CKRecordType.schedule)_", with: "")
        guard let scheduleID = UUID(uuidString: uuidStr) else {
            ckLogger.error("Invalid UUID in Schedule record name: \(recordName)")
            return nil
        }

        return Schedule(
            id: scheduleID,
            childProfileID: ChildProfileID(rawValue: profileID),
            familyID: FamilyID(rawValue: familyID),
            name: name,
            mode: mode,
            daysOfWeek: days,
            startTime: DayTime(hour: Int(startH), minute: Int(startM)),
            endTime: DayTime(hour: Int(endH), minute: Int(endM)),
            isActive: activeInt != 0,
            updatedAt: updatedAt
        )
    }

    // MARK: - HeartbeatProfile

    static func toCKRecord(_ profile: HeartbeatProfile) -> CKRecord {
        let id = recordID(profile.id.uuidString, type: CKRecordType.heartbeatProfile)
        let record = CKRecord(recordType: CKRecordType.heartbeatProfile, recordID: id)
        record[CKFieldName.familyID] = profile.familyID.rawValue
        record[CKFieldName.name] = profile.name
        record[CKFieldName.maxHeartbeatGap] = profile.maxHeartbeatGap as NSNumber
        record[CKFieldName.isDefault] = (profile.isDefault ? 1 : 0) as NSNumber
        record[CKFieldName.updatedAt] = profile.updatedAt as NSDate

        do {
            let windowsData = try JSONEncoder().encode(profile.activeWindows)
            record[CKFieldName.activeWindowsJSON] = String(data: windowsData, encoding: .utf8)
        } catch {
            ckLogger.error("Failed to encode activeWindows for heartbeat profile \(profile.id.uuidString): \(error.localizedDescription)")
        }

        return record
    }

    static func heartbeatProfile(from record: CKRecord) -> HeartbeatProfile? {
        guard record.recordType == CKRecordType.heartbeatProfile,
              let familyID = record[CKFieldName.familyID] as? String,
              let name = record[CKFieldName.name] as? String,
              let maxGap = record[CKFieldName.maxHeartbeatGap] as? Double,
              let isDefaultInt = record[CKFieldName.isDefault] as? Int64,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else {
            ckLogger.error("Failed to deserialize HeartbeatProfile from record \(record.recordID.recordName)")
            return nil
        }

        // Extract UUID from record name (format: "BBHeartbeatProfile_<uuid>")
        let recordName = record.recordID.recordName
        let uuidStr = recordName.replacingOccurrences(of: "\(CKRecordType.heartbeatProfile)_", with: "")
        guard let profileID = UUID(uuidString: uuidStr) else {
            ckLogger.error("Invalid UUID in HeartbeatProfile record name: \(recordName)")
            return nil
        }

        var windows: [ActiveWindow] = []
        if let json = record[CKFieldName.activeWindowsJSON] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ActiveWindow].self, from: data) {
            windows = decoded
        }

        return HeartbeatProfile(
            id: profileID,
            familyID: FamilyID(rawValue: familyID),
            name: name,
            activeWindows: windows,
            maxHeartbeatGap: maxGap,
            isDefault: isDefaultInt != 0,
            updatedAt: updatedAt
        )
    }

    // MARK: - ScheduleProfile

    static func toCKRecord(_ profile: ScheduleProfile) -> CKRecord {
        let id = recordID(profile.id.uuidString, type: CKRecordType.scheduleProfile)
        let record = CKRecord(recordType: CKRecordType.scheduleProfile, recordID: id)
        record[CKFieldName.familyID] = profile.familyID.rawValue
        record[CKFieldName.name] = profile.name
        record[CKFieldName.lockedMode] = profile.lockedMode.rawValue
        record[CKFieldName.isDefault] = (profile.isDefault ? 1 : 0) as NSNumber
        record[CKFieldName.updatedAt] = profile.updatedAt as NSDate

        do {
            let windowsData = try JSONEncoder().encode(profile.unlockedWindows)
            record[CKFieldName.freeWindowsJSON] = String(data: windowsData, encoding: .utf8)
        } catch {
            ckLogger.error("Failed to encode unlockedWindows for schedule profile \(profile.id.uuidString): \(error.localizedDescription)")
        }

        do {
            let essentialData = try JSONEncoder().encode(profile.lockedWindows)
            record[CKFieldName.essentialWindowsJSON] = String(data: essentialData, encoding: .utf8)
        } catch {
            ckLogger.error("Failed to encode lockedWindows for schedule profile \(profile.id.uuidString): \(error.localizedDescription)")
        }

        if !profile.exceptionDates.isEmpty {
            do {
                let exceptionData = try JSONEncoder().encode(profile.exceptionDates)
                record[CKFieldName.exceptionDatesJSON] = String(data: exceptionData, encoding: .utf8)
            } catch {
                ckLogger.error("Failed to encode exceptionDates for schedule profile \(profile.id.uuidString): \(error.localizedDescription)")
            }
        }

        return record
    }

    static func scheduleProfile(from record: CKRecord) -> ScheduleProfile? {
        guard record.recordType == CKRecordType.scheduleProfile,
              let familyID = record[CKFieldName.familyID] as? String,
              let name = record[CKFieldName.name] as? String,
              let lockedModeRaw = record[CKFieldName.lockedMode] as? String,
              let lockedMode = LockMode.from( lockedModeRaw),
              let isDefaultInt = record[CKFieldName.isDefault] as? Int64,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else {
            ckLogger.error("Failed to deserialize ScheduleProfile from record \(record.recordID.recordName)")
            return nil
        }

        let recordName = record.recordID.recordName
        let uuidStr = recordName.replacingOccurrences(of: "\(CKRecordType.scheduleProfile)_", with: "")
        guard let profileID = UUID(uuidString: uuidStr) else {
            ckLogger.error("Invalid UUID in ScheduleProfile record name: \(recordName)")
            return nil
        }

        var windows: [ActiveWindow] = []
        if let json = record[CKFieldName.freeWindowsJSON] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ActiveWindow].self, from: data) {
            windows = decoded
        }

        var lockedWindows: [ActiveWindow] = []
        if let json = record[CKFieldName.essentialWindowsJSON] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ActiveWindow].self, from: data) {
            lockedWindows = decoded
        }

        var exceptionDates: [Date] = []
        if let json = record[CKFieldName.exceptionDatesJSON] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Date].self, from: data) {
            exceptionDates = decoded
        }

        return ScheduleProfile(
            id: profileID,
            familyID: FamilyID(rawValue: familyID),
            name: name,
            unlockedWindows: windows,
            lockedWindows: lockedWindows,
            lockedMode: lockedMode,
            exceptionDates: exceptionDates,
            isDefault: isDefaultInt != 0,
            updatedAt: updatedAt
        )
    }

    // MARK: - DeviceLocation

    static func toCKRecord(_ loc: DeviceLocation) -> CKRecord {
        let id = recordID(loc.id.uuidString, type: CKRecordType.deviceLocation)
        let record = CKRecord(recordType: CKRecordType.deviceLocation, recordID: id)
        record[CKFieldName.deviceID] = loc.deviceID.rawValue
        record[CKFieldName.familyID] = loc.familyID.rawValue
        record[CKFieldName.locLatitude] = loc.latitude as NSNumber
        record[CKFieldName.locLongitude] = loc.longitude as NSNumber
        record[CKFieldName.locAccuracy] = loc.horizontalAccuracy as NSNumber
        record[CKFieldName.locTimestamp] = loc.timestamp as NSDate
        record[CKFieldName.locAddress] = loc.address
        record[CKFieldName.locSpeed] = loc.speed.map { $0 as NSNumber }
        record[CKFieldName.locCourse] = loc.course.map { $0 as NSNumber }
        return record
    }

    static func deviceLocation(from record: CKRecord) -> DeviceLocation? {
        guard record.recordType == CKRecordType.deviceLocation,
              let deviceID = record[CKFieldName.deviceID] as? String,
              let familyID = record[CKFieldName.familyID] as? String,
              let lat = record[CKFieldName.locLatitude] as? Double,
              let lon = record[CKFieldName.locLongitude] as? Double,
              let acc = record[CKFieldName.locAccuracy] as? Double,
              let ts = record[CKFieldName.locTimestamp] as? Date
        else { return nil }

        let recordName = record.recordID.recordName
        let uuidStr = recordName.replacingOccurrences(of: "\(CKRecordType.deviceLocation)_", with: "")

        return DeviceLocation(
            id: UUID(uuidString: uuidStr) ?? UUID(),
            deviceID: DeviceID(rawValue: deviceID),
            familyID: FamilyID(rawValue: familyID),
            latitude: lat,
            longitude: lon,
            horizontalAccuracy: acc,
            timestamp: ts,
            address: record[CKFieldName.locAddress] as? String,
            speed: record[CKFieldName.locSpeed] as? Double,
            course: record[CKFieldName.locCourse] as? Double
        )
    }

    // MARK: - Diagnostic Report

    static func toCKRecord(_ report: DiagnosticReport) -> CKRecord {
        let id = recordID(report.id.uuidString, type: CKRecordType.diagnosticReport)
        let record = CKRecord(recordType: CKRecordType.diagnosticReport, recordID: id)
        record[CKFieldName.deviceID] = report.deviceID.rawValue
        record[CKFieldName.familyID] = report.familyID.rawValue
        record[CKFieldName.timestamp] = report.timestamp as NSDate
        if let json = try? JSONEncoder().encode(report),
           let str = String(data: json, encoding: .utf8) {
            record[CKFieldName.diagReportJSON] = str
        }
        return record
    }

    static func diagnosticReport(from record: CKRecord) -> DiagnosticReport? {
        guard record.recordType == CKRecordType.diagnosticReport,
              let jsonStr = record[CKFieldName.diagReportJSON] as? String,
              let data = jsonStr.data(using: .utf8),
              let report = try? JSONDecoder().decode(DiagnosticReport.self, from: data)
        else { return nil }
        return report
    }

    // MARK: - Time Limit Config

    static func toCKRecord(_ config: TimeLimitConfig) -> CKRecord {
        let id = recordID(config.id.uuidString, type: CKRecordType.timeLimitConfig)
        let record = CKRecord(recordType: CKRecordType.timeLimitConfig, recordID: id)
        record[CKFieldName.familyID] = config.familyID.rawValue
        record[CKFieldName.profileID] = config.childProfileID.rawValue
        record[CKFieldName.deviceID] = config.deviceID?.rawValue
        record[CKFieldName.appFingerprint] = config.appFingerprint
        record[CKFieldName.appName] = config.appName
        record[CKFieldName.dailyLimitMinutes] = config.dailyLimitMinutes as NSNumber
        record[CKFieldName.timeLimitIsActive] = (config.isActive ? 1 : 0) as NSNumber
        record["appCategory"] = config.appCategory
        record["appBundleID"] = config.bundleID
        record[CKFieldName.createdAt] = config.createdAt as NSDate
        record[CKFieldName.updatedAt] = config.updatedAt as NSDate
        return record
    }

    static func timeLimitConfig(from record: CKRecord) -> TimeLimitConfig? {
        guard record.recordType == CKRecordType.timeLimitConfig,
              let familyID = record[CKFieldName.familyID] as? String,
              let childProfileID = record[CKFieldName.profileID] as? String,
              let fingerprint = record[CKFieldName.appFingerprint] as? String,
              let appName = record[CKFieldName.appName] as? String,
              let minutes = record[CKFieldName.dailyLimitMinutes] as? Int,
              let createdAt = record[CKFieldName.createdAt] as? Date,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else { return nil }
        let deviceID = record[CKFieldName.deviceID] as? String

        let isActive = (record[CKFieldName.timeLimitIsActive] as? Int64 ?? 1) != 0
        let appCategory = record["appCategory"] as? String
        let bundleID = record["appBundleID"] as? String

        return TimeLimitConfig(
            id: UUID(uuidString: record.recordID.recordName.replacingOccurrences(of: "BBTimeLimitConfig_", with: "")) ?? UUID(),
            familyID: FamilyID(rawValue: familyID),
            childProfileID: ChildProfileID(rawValue: childProfileID),
            deviceID: deviceID.map { DeviceID(rawValue: $0) },
            appFingerprint: fingerprint,
            appName: appName,
            dailyLimitMinutes: minutes,
            isActive: isActive,
            appCategory: appCategory,
            bundleID: bundleID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Pending App Review

    static func toCKRecord(_ review: PendingAppReview) -> CKRecord {
        let id = recordID(review.id.uuidString, type: CKRecordType.pendingAppReview)
        let record = CKRecord(recordType: CKRecordType.pendingAppReview, recordID: id)
        record[CKFieldName.familyID] = review.familyID.rawValue
        record[CKFieldName.profileID] = review.childProfileID.rawValue
        record[CKFieldName.deviceID] = review.deviceID.rawValue
        record[CKFieldName.appFingerprint] = review.appFingerprint
        record[CKFieldName.appName] = review.appName
        if let bundleID = review.bundleID { record["appBundleID"] = bundleID }
        if let token = review.tokenDataBase64 { record["tokenDataBase64"] = token }
        record[CKFieldName.nameResolved] = (review.nameResolved ? 1 : 0) as NSNumber
        record[CKFieldName.createdAt] = review.createdAt as NSDate
        record[CKFieldName.updatedAt] = review.updatedAt as NSDate
        return record
    }

    static func pendingAppReview(from record: CKRecord) -> PendingAppReview? {
        guard record.recordType == CKRecordType.pendingAppReview,
              let familyID = record[CKFieldName.familyID] as? String,
              let childProfileID = record[CKFieldName.profileID] as? String,
              let deviceID = record[CKFieldName.deviceID] as? String,
              let fingerprint = record[CKFieldName.appFingerprint] as? String,
              let appName = record[CKFieldName.appName] as? String,
              let createdAt = record[CKFieldName.createdAt] as? Date,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else { return nil }

        let nameResolved = (record[CKFieldName.nameResolved] as? Int64 ?? 0) != 0

        return PendingAppReview(
            id: UUID(uuidString: record.recordID.recordName.replacingOccurrences(of: "BBPendingAppReview_", with: "")) ?? UUID(),
            familyID: FamilyID(rawValue: familyID),
            childProfileID: ChildProfileID(rawValue: childProfileID),
            deviceID: DeviceID(rawValue: deviceID),
            appFingerprint: fingerprint,
            appName: appName,
            bundleID: record["appBundleID"] as? String,
            nameResolved: nameResolved,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tokenDataBase64: record["tokenDataBase64"] as? String
        )
    }

    // MARK: - Named Place

    static func toCKRecord(_ place: NamedPlace) -> CKRecord {
        let id = recordID(place.id.uuidString, type: CKRecordType.namedPlace)
        let record = CKRecord(recordType: CKRecordType.namedPlace, recordID: id)
        record[CKFieldName.familyID] = place.familyID.rawValue
        record[CKFieldName.placeName] = place.name
        record[CKFieldName.placeLatitude] = place.latitude as NSNumber
        record[CKFieldName.placeLongitude] = place.longitude as NSNumber
        record[CKFieldName.placeRadius] = place.radiusMeters as NSNumber
        record[CKFieldName.timestamp] = place.createdAt as NSDate
        record[CKFieldName.placeCreatedBy] = place.createdBy
        let childIDs = place.childProfileIDs.map(\.rawValue)
        record[CKFieldName.placeChildProfileIDs] = childIDs as [NSString]
        record["placeNotifyArrival"] = (place.notifyArrival ? 1 : 0) as NSNumber
        record["placeNotifyDeparture"] = (place.notifyDeparture ? 1 : 0) as NSNumber
        return record
    }

    static func namedPlace(from record: CKRecord) -> NamedPlace? {
        guard record.recordType == CKRecordType.namedPlace,
              let familyID = record[CKFieldName.familyID] as? String,
              let name = record[CKFieldName.placeName] as? String,
              let lat = record[CKFieldName.placeLatitude] as? Double,
              let lon = record[CKFieldName.placeLongitude] as? Double
        else { return nil }

        let recordName = record.recordID.recordName
        let uuidStr = recordName.replacingOccurrences(of: "\(CKRecordType.namedPlace)_", with: "")
        let radius = record[CKFieldName.placeRadius] as? Double ?? 150
        let createdAt = record[CKFieldName.timestamp] as? Date ?? Date()
        let createdBy = record[CKFieldName.placeCreatedBy] as? String ?? "Parent"
        let childIDStrings = record[CKFieldName.placeChildProfileIDs] as? [String] ?? []

        return NamedPlace(
            id: UUID(uuidString: uuidStr) ?? UUID(),
            familyID: FamilyID(rawValue: familyID),
            name: name,
            latitude: lat,
            longitude: lon,
            radiusMeters: radius,
            createdAt: createdAt,
            createdBy: createdBy,
            childProfileIDs: childIDStrings.map { ChildProfileID(rawValue: $0) },
            notifyArrival: (record["placeNotifyArrival"] as? Int64 ?? 1) != 0,
            notifyDeparture: (record["placeNotifyDeparture"] as? Int64 ?? 1) != 0
        )
    }

    // MARK: - REST decoders
    //
    // Mirrors the `from: CKRecord` decoders above but reads the REST JSON
    // shape (`{fieldName: {value, type}}`) via `RESTRecord`'s typed
    // accessors. One-to-one with the framework decoders so a future
    // schema change requires updating both. We accept that maintenance
    // cost to get out from under `cloudd`.

    static func childProfile(fromREST rec: CloudKitRESTClient.RESTRecord) -> ChildProfile? {
        guard let profileID = rec.string(CKFieldName.profileID),
              let familyID = rec.string(CKFieldName.familyID),
              let name = rec.string(CKFieldName.name),
              let createdAt = rec.date(CKFieldName.createdAt),
              let updatedAt = rec.date(CKFieldName.updatedAt)
        else { return nil }

        var categories: Set<String> = []
        if let json = rec.string(CKFieldName.alwaysAllowedCategoriesJSON),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            categories = decoded
        }

        return ChildProfile(
            id: ChildProfileID(rawValue: profileID),
            familyID: FamilyID(rawValue: familyID),
            name: name,
            avatarName: rec.string(CKFieldName.avatarName),
            avatarEmoji: rec.string(CKFieldName.avatarEmoji),
            avatarColor: rec.string(CKFieldName.avatarColor),
            avatarPhotoBase64: rec.string(CKFieldName.avatarPhotoBase64),
            alwaysAllowedCategories: categories,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func childDevice(fromREST rec: CloudKitRESTClient.RESTRecord) -> ChildDevice? {
        guard let deviceID = rec.string(CKFieldName.deviceID),
              let profileID = rec.string(CKFieldName.profileID),
              let familyID = rec.string(CKFieldName.familyID),
              let displayName = rec.string(CKFieldName.displayName),
              let modelID = rec.string(CKFieldName.modelIdentifier),
              let osVer = rec.string(CKFieldName.osVersion),
              let enrolledAt = rec.date(CKFieldName.enrolledAt)
        else { return nil }

        let fcOK = rec.bool(CKFieldName.familyControlsOK) ?? false
        let hbProfileID = rec.string(CKFieldName.heartbeatProfileID).flatMap(UUID.init)
        let schProfileID = rec.string(CKFieldName.scheduleProfileID).flatMap(UUID.init)

        return ChildDevice(
            id: DeviceID(rawValue: deviceID),
            childProfileID: ChildProfileID(rawValue: profileID),
            familyID: FamilyID(rawValue: familyID),
            displayName: displayName,
            modelIdentifier: modelID,
            osVersion: osVer,
            enrolledAt: enrolledAt,
            familyControlsAuthorized: fcOK,
            heartbeatProfileID: hbProfileID,
            scheduleProfileID: schProfileID,
            penaltySeconds: rec.int(CKFieldName.penaltySeconds),
            penaltyTimerEndTime: rec.date(CKFieldName.penaltyTimerEndTime),
            selfUnlocksPerDay: rec.int(CKFieldName.selfUnlocksPerDay),
            scheduleProfileVersion: rec.date(CKFieldName.scheduleProfileVersion),
            restrictionsJSON: rec.string(CKFieldName.restrictionsJSON)
        )
    }

    static func eventLogEntry(fromREST rec: CloudKitRESTClient.RESTRecord) -> EventLogEntry? {
        guard let idStr = rec.string(CKFieldName.eventID),
              let id = UUID(uuidString: idStr),
              let deviceID = rec.string(CKFieldName.deviceID),
              let familyID = rec.string(CKFieldName.familyID),
              let typeRaw = rec.string(CKFieldName.eventType),
              let eventType = EventType(rawValue: typeRaw),
              let timestamp = rec.date(CKFieldName.timestamp)
        else { return nil }

        return EventLogEntry(
            id: id,
            deviceID: DeviceID(rawValue: deviceID),
            familyID: FamilyID(rawValue: familyID),
            eventType: eventType,
            details: rec.string(CKFieldName.details),
            timestamp: timestamp,
            uploadState: .uploaded
        )
    }

    static func deviceLocation(fromREST rec: CloudKitRESTClient.RESTRecord) -> DeviceLocation? {
        guard let deviceID = rec.string(CKFieldName.deviceID),
              let familyID = rec.string(CKFieldName.familyID),
              let lat = rec.double(CKFieldName.locLatitude),
              let lon = rec.double(CKFieldName.locLongitude),
              let acc = rec.double(CKFieldName.locAccuracy),
              let ts = rec.date(CKFieldName.locTimestamp)
        else { return nil }

        let uuidStr = rec.recordName.replacingOccurrences(of: "\(CKRecordType.deviceLocation)_", with: "")

        return DeviceLocation(
            id: UUID(uuidString: uuidStr) ?? UUID(),
            deviceID: DeviceID(rawValue: deviceID),
            familyID: FamilyID(rawValue: familyID),
            latitude: lat,
            longitude: lon,
            horizontalAccuracy: acc,
            timestamp: ts,
            address: rec.string(CKFieldName.locAddress),
            speed: rec.double(CKFieldName.locSpeed),
            course: rec.double(CKFieldName.locCourse)
        )
    }

    static func pendingAppReview(fromREST rec: CloudKitRESTClient.RESTRecord) -> PendingAppReview? {
        guard let familyID = rec.string(CKFieldName.familyID),
              let childProfileID = rec.string(CKFieldName.profileID),
              let deviceID = rec.string(CKFieldName.deviceID),
              let fingerprint = rec.string(CKFieldName.appFingerprint),
              let appName = rec.string(CKFieldName.appName),
              let createdAt = rec.date(CKFieldName.createdAt),
              let updatedAt = rec.date(CKFieldName.updatedAt)
        else { return nil }

        let nameResolved = rec.bool(CKFieldName.nameResolved) ?? false
        let uuidStr = rec.recordName.replacingOccurrences(of: "BBPendingAppReview_", with: "")

        return PendingAppReview(
            id: UUID(uuidString: uuidStr) ?? UUID(),
            familyID: FamilyID(rawValue: familyID),
            childProfileID: ChildProfileID(rawValue: childProfileID),
            deviceID: DeviceID(rawValue: deviceID),
            appFingerprint: fingerprint,
            appName: appName,
            bundleID: rec.string("appBundleID"),
            nameResolved: nameResolved,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tokenDataBase64: rec.string("tokenDataBase64")
        )
    }

    static func schedule(fromREST rec: CloudKitRESTClient.RESTRecord) -> Schedule? {
        guard let familyID = rec.string(CKFieldName.familyID),
              let profileID = rec.string(CKFieldName.profileID),
              let name = rec.string(CKFieldName.scheduleName),
              let modeRaw = rec.string(CKFieldName.mode),
              let mode = LockMode.from(modeRaw),
              let startH = rec.int(CKFieldName.startHour),
              let startM = rec.int(CKFieldName.startMinute),
              let endH = rec.int(CKFieldName.endHour),
              let endM = rec.int(CKFieldName.endMinute),
              let active = rec.bool(CKFieldName.isActive),
              let updatedAt = rec.date(CKFieldName.updatedAt)
        else { return nil }

        var days: Set<DayOfWeek> = []
        if let daysJSON = rec.string(CKFieldName.daysOfWeekJSON),
           let daysData = daysJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Set<DayOfWeek>.self, from: daysData) {
            days = decoded
        }

        let uuidStr = rec.recordName.replacingOccurrences(of: "\(CKRecordType.schedule)_", with: "")
        guard let scheduleID = UUID(uuidString: uuidStr) else { return nil }

        return Schedule(
            id: scheduleID,
            childProfileID: ChildProfileID(rawValue: profileID),
            familyID: FamilyID(rawValue: familyID),
            name: name,
            mode: mode,
            daysOfWeek: days,
            startTime: DayTime(hour: startH, minute: startM),
            endTime: DayTime(hour: endH, minute: endM),
            isActive: active,
            updatedAt: updatedAt
        )
    }

    static func scheduleProfile(fromREST rec: CloudKitRESTClient.RESTRecord) -> ScheduleProfile? {
        guard let familyID = rec.string(CKFieldName.familyID),
              let name = rec.string(CKFieldName.name),
              let lockedModeRaw = rec.string(CKFieldName.lockedMode),
              let lockedMode = LockMode.from(lockedModeRaw),
              let isDefault = rec.bool(CKFieldName.isDefault),
              let updatedAt = rec.date(CKFieldName.updatedAt)
        else { return nil }

        let uuidStr = rec.recordName.replacingOccurrences(of: "\(CKRecordType.scheduleProfile)_", with: "")
        guard let profileID = UUID(uuidString: uuidStr) else { return nil }

        var windows: [ActiveWindow] = []
        if let json = rec.string(CKFieldName.freeWindowsJSON),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ActiveWindow].self, from: data) {
            windows = decoded
        }

        var lockedWindows: [ActiveWindow] = []
        if let json = rec.string(CKFieldName.essentialWindowsJSON),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ActiveWindow].self, from: data) {
            lockedWindows = decoded
        }

        var exceptionDates: [Date] = []
        if let json = rec.string(CKFieldName.exceptionDatesJSON),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Date].self, from: data) {
            exceptionDates = decoded
        }

        return ScheduleProfile(
            id: profileID,
            familyID: FamilyID(rawValue: familyID),
            name: name,
            unlockedWindows: windows,
            lockedWindows: lockedWindows,
            lockedMode: lockedMode,
            exceptionDates: exceptionDates,
            isDefault: isDefault,
            updatedAt: updatedAt
        )
    }

    // MARK: - RemoteCommand (REST decode)

    static func remoteCommand(fromREST rec: CloudKitRESTClient.RESTRecord) -> RemoteCommand? {
        guard let cmdIDStr = rec.string(CKFieldName.commandID),
              let cmdID = UUID(uuidString: cmdIDStr),
              let familyID = rec.string(CKFieldName.familyID),
              let targetTypeStr = rec.string(CKFieldName.targetType),
              let actionJSON = rec.string(CKFieldName.actionJSON),
              let actionData = actionJSON.data(using: .utf8),
              let action = try? JSONDecoder().decode(CommandAction.self, from: actionData),
              let issuedBy = rec.string(CKFieldName.issuedBy),
              let issuedAt = rec.date(CKFieldName.issuedAt),
              let statusRaw = rec.string(CKFieldName.status),
              let status = CommandStatus(rawValue: statusRaw)
        else { return nil }

        let target: CommandTarget
        let targetID = rec.string(CKFieldName.targetID)
        switch targetTypeStr {
        case "device":
            guard let tid = targetID else { return nil }
            target = .device(DeviceID(rawValue: tid))
        case "child":
            guard let tid = targetID else { return nil }
            target = .child(ChildProfileID(rawValue: tid))
        case "all":
            target = .allDevices
        default:
            return nil
        }

        return RemoteCommand(
            id: cmdID,
            familyID: FamilyID(rawValue: familyID),
            target: target,
            action: action,
            issuedBy: issuedBy,
            issuedAt: issuedAt,
            expiresAt: rec.date(CKFieldName.expiresAt),
            status: status,
            signatureBase64: rec.string(CKFieldName.signatureBase64)
        )
    }

}
