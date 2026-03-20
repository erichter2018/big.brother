import Foundation
import CloudKit
import BigBrotherCore

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
        if let cats = try? JSONEncoder().encode(profile.alwaysAllowedCategories) {
            record[CKFieldName.alwaysAllowedCategoriesJSON] = String(data: cats, encoding: .utf8)
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
        else { return nil }

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
        else { return nil }

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
            scheduleProfileVersion: schProfileVersion
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
              let mode = LockMode(rawValue: modeRaw),
              let version = record[CKFieldName.version] as? Int64,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else { return nil }

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

        if let actionData = try? JSONEncoder().encode(command.action),
           let actionStr = String(data: actionData, encoding: .utf8) {
            record[CKFieldName.actionJSON] = actionStr
        }

        record[CKFieldName.issuedBy] = command.issuedBy
        record[CKFieldName.issuedAt] = command.issuedAt as NSDate
        record[CKFieldName.expiresAt] = command.expiresAt as NSDate?
        record[CKFieldName.status] = command.status.rawValue
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
        else { return nil }

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
            status: status
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
        else { return nil }

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
        record[CKFieldName.hbEnforcementError] = hb.enforcementError
        record[CKFieldName.hbActiveScheduleWindow] = hb.activeScheduleWindowName
        record[CKFieldName.hbLastCommandProcessedAt] = hb.lastCommandProcessedAt.map { $0 as NSDate }
    }

    static func deviceHeartbeat(from record: CKRecord) -> DeviceHeartbeat? {
        guard record.recordType == CKRecordType.heartbeat,
              let deviceID = record[CKFieldName.deviceID] as? String,
              let familyID = record[CKFieldName.familyID] as? String,
              let timestamp = record[CKFieldName.timestamp] as? Date,
              let modeRaw = record[CKFieldName.currentMode] as? String,
              let mode = LockMode(rawValue: modeRaw),
              let pv = record[CKFieldName.policyVersion] as? Int64,
              let fc = record[CKFieldName.fcAuthorized] as? Int64
        else { return nil }

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
            enforcementError: record[CKFieldName.hbEnforcementError] as? String,
            activeScheduleWindowName: record[CKFieldName.hbActiveScheduleWindow] as? String,
            lastCommandProcessedAt: record[CKFieldName.hbLastCommandProcessedAt] as? Date
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
        else { return nil }

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
        else { return nil }

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
            revoked: revokedInt != 0
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

        if let daysData = try? JSONEncoder().encode(schedule.daysOfWeek),
           let daysStr = String(data: daysData, encoding: .utf8) {
            record[CKFieldName.daysOfWeekJSON] = daysStr
        }

        return record
    }

    static func schedule(from record: CKRecord) -> Schedule? {
        guard record.recordType == CKRecordType.schedule,
              let familyID = record[CKFieldName.familyID] as? String,
              let profileID = record[CKFieldName.profileID] as? String,
              let name = record[CKFieldName.scheduleName] as? String,
              let modeRaw = record[CKFieldName.mode] as? String,
              let mode = LockMode(rawValue: modeRaw),
              let startH = record[CKFieldName.startHour] as? Int64,
              let startM = record[CKFieldName.startMinute] as? Int64,
              let endH = record[CKFieldName.endHour] as? Int64,
              let endM = record[CKFieldName.endMinute] as? Int64,
              let activeInt = record[CKFieldName.isActive] as? Int64,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else { return nil }

        var days: Set<DayOfWeek> = []
        if let daysJSON = record[CKFieldName.daysOfWeekJSON] as? String,
           let daysData = daysJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Set<DayOfWeek>.self, from: daysData) {
            days = decoded
        }

        // Extract UUID from record name (format: "BBSchedule_<uuid>")
        let recordName = record.recordID.recordName
        let uuidStr = recordName.replacingOccurrences(of: "\(CKRecordType.schedule)_", with: "")
        guard let scheduleID = UUID(uuidString: uuidStr) else { return nil }

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

        if let windowsData = try? JSONEncoder().encode(profile.activeWindows),
           let windowsStr = String(data: windowsData, encoding: .utf8) {
            record[CKFieldName.activeWindowsJSON] = windowsStr
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
        else { return nil }

        // Extract UUID from record name (format: "BBHeartbeatProfile_<uuid>")
        let recordName = record.recordID.recordName
        let uuidStr = recordName.replacingOccurrences(of: "\(CKRecordType.heartbeatProfile)_", with: "")
        guard let profileID = UUID(uuidString: uuidStr) else { return nil }

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

        if let windowsData = try? JSONEncoder().encode(profile.freeWindows),
           let windowsStr = String(data: windowsData, encoding: .utf8) {
            record[CKFieldName.freeWindowsJSON] = windowsStr
        }

        if let essentialData = try? JSONEncoder().encode(profile.essentialWindows),
           let essentialStr = String(data: essentialData, encoding: .utf8) {
            record[CKFieldName.essentialWindowsJSON] = essentialStr
        }

        return record
    }

    static func scheduleProfile(from record: CKRecord) -> ScheduleProfile? {
        guard record.recordType == CKRecordType.scheduleProfile,
              let familyID = record[CKFieldName.familyID] as? String,
              let name = record[CKFieldName.name] as? String,
              let lockedModeRaw = record[CKFieldName.lockedMode] as? String,
              let lockedMode = LockMode(rawValue: lockedModeRaw),
              let isDefaultInt = record[CKFieldName.isDefault] as? Int64,
              let updatedAt = record[CKFieldName.updatedAt] as? Date
        else { return nil }

        let recordName = record.recordID.recordName
        let uuidStr = recordName.replacingOccurrences(of: "\(CKRecordType.scheduleProfile)_", with: "")
        guard let profileID = UUID(uuidString: uuidStr) else { return nil }

        var windows: [ActiveWindow] = []
        if let json = record[CKFieldName.freeWindowsJSON] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ActiveWindow].self, from: data) {
            windows = decoded
        }

        var essentialWindows: [ActiveWindow] = []
        if let json = record[CKFieldName.essentialWindowsJSON] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ActiveWindow].self, from: data) {
            essentialWindows = decoded
        }

        return ScheduleProfile(
            id: profileID,
            familyID: FamilyID(rawValue: familyID),
            name: name,
            freeWindows: windows,
            essentialWindows: essentialWindows,
            lockedMode: lockedMode,
            isDefault: isDefaultInt != 0,
            updatedAt: updatedAt
        )
    }
}
