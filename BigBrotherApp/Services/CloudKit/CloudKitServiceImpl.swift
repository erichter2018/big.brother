import Foundation
import CloudKit
import BigBrotherCore

/// Concrete CloudKit service using the public database with familyID partitioning.
final class CloudKitServiceImpl: CloudKitServiceProtocol, @unchecked Sendable {

    private let container: CKContainer
    private let database: CKDatabase

    init(containerIdentifier: String = AppConstants.cloudKitContainerIdentifier) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.publicCloudDatabase
    }

    // MARK: - Child Profiles

    func fetchChildProfiles(familyID: FamilyID) async throws -> [ChildProfile] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.familyID, familyID.rawValue)
        return try await query(CKRecordType.childProfile, predicate: predicate)
            .compactMap(CKRecordConversion.childProfile)
    }

    func saveChildProfile(_ profile: ChildProfile) async throws {
        let record = CKRecordConversion.toCKRecord(profile)
        try await save(record)
    }

    func deleteChildProfile(_ id: ChildProfileID) async throws {
        let recordID = CKRecordConversion.recordID(id.rawValue, type: CKRecordType.childProfile)
        try await delete(recordID)
    }

    // MARK: - Devices

    func fetchDevices(familyID: FamilyID) async throws -> [ChildDevice] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.familyID, familyID.rawValue)
        return try await query(CKRecordType.childDevice, predicate: predicate)
            .compactMap(CKRecordConversion.childDevice)
    }

    func fetchDevices(childProfileID: ChildProfileID) async throws -> [ChildDevice] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.profileID, childProfileID.rawValue)
        return try await query(CKRecordType.childDevice, predicate: predicate)
            .compactMap(CKRecordConversion.childDevice)
    }

    func saveDevice(_ device: ChildDevice) async throws {
        // Fetch the existing record so .changedKeys can detect actual changes,
        // including fields set to nil (clearing a value).
        let recordID = CKRecordConversion.recordID(device.id.rawValue, type: CKRecordType.childDevice)
        let existing: CKRecord
        do {
            existing = try await database.record(for: recordID)
        } catch {
            // Record doesn't exist yet — create a new one.
            existing = CKRecord(recordType: CKRecordType.childDevice, recordID: recordID)
        }
        CKRecordConversion.updateCKRecord(existing, from: device)
        try await save(existing)
    }

    func updateDeviceFields(deviceID: DeviceID, fields: [String: CKRecordValue?]) async throws {
        // Retry up to 3 times on serverRecordChanged conflicts.
        for attempt in 1...3 {
            let recordID = CKRecordConversion.recordID(deviceID.rawValue, type: CKRecordType.childDevice)
            let existing = try await database.record(for: recordID)
            for (key, value) in fields {
                existing[key] = value
            }
            do {
                try await save(existing)
                return // success
            } catch {
                let ckError = error as? CloudKitError
                let isConflict: Bool
                if case .serverError(let underlying) = ckError,
                   (underlying as NSError).code == CKError.serverRecordChanged.rawValue {
                    isConflict = true
                } else {
                    isConflict = false
                }
                if isConflict && attempt < 3 {
                    #if DEBUG
                    print("[BigBrother] updateDeviceFields conflict, retry \(attempt + 1)/3")
                    #endif
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                throw error
            }
        }
    }

    func deleteDevice(_ id: DeviceID) async throws {
        let recordID = CKRecordConversion.recordID(id.rawValue, type: CKRecordType.childDevice)
        try await delete(recordID)
    }

    // MARK: - Commands

    func pushCommand(_ command: RemoteCommand) async throws {
        let record = CKRecordConversion.toCKRecord(command)
        try await save(record)
    }

    func fetchPendingCommands(
        deviceID: DeviceID,
        childProfileID: ChildProfileID,
        familyID: FamilyID
    ) async throws -> [RemoteCommand] {
        // Fetch commands targeting this device, this child, or all devices.
        // Three queries combined:

        // 1. Device-specific commands
        let devicePred = NSPredicate(
            format: "%K == %@ AND %K == %@ AND %K == %@",
            CKFieldName.targetType, "device",
            CKFieldName.targetID, deviceID.rawValue,
            CKFieldName.status, CommandStatus.pending.rawValue
        )
        let deviceCmds = try await query(CKRecordType.remoteCommand, predicate: devicePred)

        // 2. Child-profile commands
        let childPred = NSPredicate(
            format: "%K == %@ AND %K == %@ AND %K == %@",
            CKFieldName.targetType, "child",
            CKFieldName.targetID, childProfileID.rawValue,
            CKFieldName.status, CommandStatus.pending.rawValue
        )
        let childCmds = try await query(CKRecordType.remoteCommand, predicate: childPred)

        // 3. Global commands
        let globalPred = NSPredicate(
            format: "%K == %@ AND %K == %@ AND %K == %@",
            CKFieldName.targetType, "all",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.status, CommandStatus.pending.rawValue
        )
        let globalCmds = try await query(CKRecordType.remoteCommand, predicate: globalPred)

        let allRecords = deviceCmds + childCmds + globalCmds
        return allRecords.compactMap(CKRecordConversion.remoteCommand)
    }

    func updateCommandStatus(_ commandID: UUID, status: CommandStatus) async throws {
        let recordID = CKRecordConversion.recordID(commandID.uuidString, type: CKRecordType.remoteCommand)
        guard let existing = try? await database.record(for: recordID) else {
            throw CloudKitError.recordNotFound
        }
        existing[CKFieldName.status] = status.rawValue
        try await save(existing)
    }

    func deleteCommand(_ commandID: UUID) async throws {
        let recordID = CKRecordConversion.recordID(commandID.uuidString, type: CKRecordType.remoteCommand)
        try await database.deleteRecord(withID: recordID)
    }

    func saveReceipt(_ receipt: CommandReceipt) async throws {
        let record = CKRecordConversion.toCKRecord(receipt)
        try await save(record)
    }

    func fetchRecentCommands(familyID: FamilyID, since: Date) async throws -> [RemoteCommand] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K >= %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.issuedAt, since as NSDate
        )
        return try await query(CKRecordType.remoteCommand, predicate: predicate)
            .compactMap(CKRecordConversion.remoteCommand)
    }

    func fetchReceipts(familyID: FamilyID, since: Date) async throws -> [CommandReceipt] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K >= %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.appliedAt, since as NSDate
        )
        return try await query(CKRecordType.commandReceipt, predicate: predicate)
            .compactMap(CKRecordConversion.commandReceipt)
    }

    // MARK: - Enrollment

    func saveEnrollmentInvite(_ invite: EnrollmentInvite) async throws {
        let record = CKRecordConversion.toCKRecord(invite)
        try await save(record)
    }

    func fetchEnrollmentInvite(code: String) async throws -> EnrollmentInvite? {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.code, code)
        let records = try await query(CKRecordType.enrollmentInvite, predicate: predicate)
        return records.first.flatMap(CKRecordConversion.enrollmentInvite)
    }

    func markInviteUsed(code: String, deviceID: DeviceID) async throws {
        let recordID = CKRecordConversion.recordID(code, type: CKRecordType.enrollmentInvite)
        guard let existing = try? await database.record(for: recordID) else {
            throw CloudKitError.recordNotFound
        }
        existing[CKFieldName.used] = 1 as NSNumber
        existing[CKFieldName.usedByDeviceID] = deviceID.rawValue
        try await save(existing)
    }

    // MARK: - Heartbeat

    func sendHeartbeat(_ heartbeat: DeviceHeartbeat) async throws {
        let record = CKRecordConversion.toCKRecord(heartbeat)
        try await save(record)
    }

    func fetchLatestHeartbeats(familyID: FamilyID) async throws -> [DeviceHeartbeat] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.familyID, familyID.rawValue)
        return try await query(CKRecordType.heartbeat, predicate: predicate)
            .compactMap(CKRecordConversion.deviceHeartbeat)
    }

    // MARK: - Events

    func syncEventLogs(_ entries: [EventLogEntry]) async throws {
        let records = entries.map(CKRecordConversion.toCKRecord)
        try await saveMultiple(records)
    }

    func deleteEventLog(_ id: UUID) async throws {
        let recordID = CKRecordConversion.recordID(id.uuidString, type: CKRecordType.eventLog)
        try await delete(recordID)
    }

    func fetchEventLogs(familyID: FamilyID, since: Date) async throws -> [EventLogEntry] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K >= %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.timestamp, since as NSDate
        )
        return try await query(CKRecordType.eventLog, predicate: predicate)
            .compactMap(CKRecordConversion.eventLogEntry)
    }

    // MARK: - Policy

    func savePolicy(_ policy: Policy) async throws {
        let record = CKRecordConversion.toCKRecord(policy)
        try await save(record)
    }

    func fetchPolicy(deviceID: DeviceID) async throws -> Policy? {
        let recordID = CKRecordConversion.recordID(deviceID.rawValue, type: CKRecordType.policy)
        guard let record = try? await database.record(for: recordID) else {
            return nil
        }
        return CKRecordConversion.policy(from: record)
    }

    // MARK: - Schedules

    func fetchSchedules(childProfileID: ChildProfileID) async throws -> [Schedule] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.profileID, childProfileID.rawValue)
        return try await query(CKRecordType.schedule, predicate: predicate)
            .compactMap(CKRecordConversion.schedule)
    }

    func fetchSchedules(familyID: FamilyID) async throws -> [Schedule] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.familyID, familyID.rawValue)
        return try await query(CKRecordType.schedule, predicate: predicate)
            .compactMap(CKRecordConversion.schedule)
    }

    func saveSchedule(_ schedule: Schedule) async throws {
        let record = CKRecordConversion.toCKRecord(schedule)
        try await save(record)
    }

    func deleteSchedule(_ id: UUID, familyID: FamilyID) async throws {
        let recordID = CKRecordConversion.recordID(id.uuidString, type: CKRecordType.schedule)
        try await delete(recordID)
    }

    // MARK: - Heartbeat Profiles

    func fetchHeartbeatProfiles(familyID: FamilyID) async throws -> [HeartbeatProfile] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.familyID, familyID.rawValue)
        return try await query(CKRecordType.heartbeatProfile, predicate: predicate)
            .compactMap(CKRecordConversion.heartbeatProfile)
    }

    func saveHeartbeatProfile(_ profile: HeartbeatProfile) async throws {
        let record = CKRecordConversion.toCKRecord(profile)
        try await save(record)
    }

    func deleteHeartbeatProfile(_ id: UUID) async throws {
        let recordID = CKRecordConversion.recordID(id.uuidString, type: CKRecordType.heartbeatProfile)
        try await delete(recordID)
    }

    // MARK: - Schedule Profiles

    func fetchScheduleProfiles(familyID: FamilyID) async throws -> [ScheduleProfile] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.familyID, familyID.rawValue)
        return try await query(CKRecordType.scheduleProfile, predicate: predicate)
            .compactMap(CKRecordConversion.scheduleProfile)
    }

    func saveScheduleProfile(_ profile: ScheduleProfile) async throws {
        let record = CKRecordConversion.toCKRecord(profile)
        try await save(record)
    }

    func deleteScheduleProfile(_ id: UUID) async throws {
        let recordID = CKRecordConversion.recordID(id.uuidString, type: CKRecordType.scheduleProfile)
        try await delete(recordID)
    }

    // MARK: - Subscriptions

    func setupSubscriptions(familyID: FamilyID, deviceID: DeviceID?) async throws {
        var subscriptionsToSave: [CKSubscription] = []

        if deviceID != nil {
            // Child device: subscribe to pending commands.
            let commandPredicate = NSPredicate(
                format: "%K == %@ AND %K == %@",
                CKFieldName.familyID, familyID.rawValue,
                CKFieldName.status, CommandStatus.pending.rawValue
            )
            let commandSub = CKQuerySubscription(
                recordType: CKRecordType.remoteCommand,
                predicate: commandPredicate,
                subscriptionID: "commands-\(familyID.rawValue)",
                options: [.firesOnRecordCreation]
            )
            let commandNotifInfo = CKSubscription.NotificationInfo()
            commandNotifInfo.shouldSendContentAvailable = true
            commandSub.notificationInfo = commandNotifInfo
            subscriptionsToSave.append(commandSub)

            #if DEBUG
            print("[BigBrother] 🔔 Setting up CloudKit subscription: commands-\(familyID.rawValue) (deviceID: \(deviceID?.rawValue ?? "nil"))")
            #endif
        } else {
            // Parent device: subscribe to unlock request event logs.
            let unlockPredicate = NSPredicate(
                format: "%K == %@ AND %K == %@",
                CKFieldName.familyID, familyID.rawValue,
                CKFieldName.eventType, EventType.unlockRequested.rawValue
            )
            let unlockSub = CKQuerySubscription(
                recordType: CKRecordType.eventLog,
                predicate: unlockPredicate,
                subscriptionID: "unlock-requests-v3-\(familyID.rawValue)",
                options: [.firesOnRecordCreation]
            )
            let unlockNotifInfo = CKSubscription.NotificationInfo()
            unlockNotifInfo.shouldSendContentAvailable = true // wake app for processing
            // No alertBody/soundName/shouldBadge — this is a SILENT push that wakes
            // the app. The app then posts a LOCAL notification via
            // UnlockRequestNotificationService with the child's name, app name,
            // and actionable buttons (15min/1hr/2hr/today/always).
            // Having BOTH a CloudKit alert AND a local notification caused duplicates.
            unlockSub.notificationInfo = unlockNotifInfo
            subscriptionsToSave.append(unlockSub)

            #if DEBUG
            print("[BigBrother] 🔔 Setting up CloudKit subscription: unlock-requests-\(familyID.rawValue)")
            #endif
        }

        let op = CKModifySubscriptionsOperation(
            subscriptionsToSave: subscriptionsToSave,
            subscriptionIDsToDelete: nil
        )
        op.qualityOfService = .utility

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            op.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    #if DEBUG
                    for subscription in subscriptionsToSave {
                        print("[BigBrother] ✅ CloudKit subscription active: \(subscription.subscriptionID)")
                    }
                    #endif
                    continuation.resume()
                case .failure(let error):
                    #if DEBUG
                    print("[BigBrother] ❌ CloudKit subscription failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(throwing: error)
                }
            }
            database.add(op)
        }
    }

    // MARK: - Cleanup

    func deleteRecords(type: String, predicate: NSPredicate) async throws -> Int {
        let records = try await query(type, predicate: predicate)
        guard !records.isEmpty else { return 0 }

        // Delete in batches of 400 (CloudKit limit is 400 per operation).
        var deleted = 0
        for batchStart in stride(from: 0, to: records.count, by: 400) {
            let batchEnd = min(batchStart + 400, records.count)
            let ids = records[batchStart..<batchEnd].map(\.recordID)

            let op = CKModifyRecordsOperation(recordIDsToDelete: Array(ids))
            op.qualityOfService = .utility

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: CloudKitError.serverError(error))
                    }
                }
                database.add(op)
            }
            deleted += ids.count
        }
        return deleted
    }

    // MARK: - Private CloudKit Helpers

    private func save(_ record: CKRecord) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: [record])
        op.savePolicy = .changedKeys
        op.qualityOfService = .userInitiated

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var perRecordError: Error?

            op.perRecordSaveBlock = { recordID, result in
                if case .failure(let error) = result {
                    perRecordError = error
                    #if DEBUG
                    print("[BigBrother] CloudKit per-record save FAILED: \(recordID.recordName) — \(error.localizedDescription)")
                    #endif
                } else {
                    #if DEBUG
                    print("[BigBrother] CloudKit saved record: \(recordID.recordName)")
                    #endif
                }
            }

            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    if let error = perRecordError {
                        continuation.resume(throwing: CloudKitError.serverError(error))
                    } else {
                        continuation.resume()
                    }
                case .failure(let error):
                    continuation.resume(throwing: CloudKitError.serverError(error))
                }
            }
            database.add(op)
        }
    }

    private func saveMultiple(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }

        let op = CKModifyRecordsOperation(recordsToSave: records)
        op.savePolicy = .changedKeys
        op.isAtomic = false // allow partial success
        op.qualityOfService = .userInitiated

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            op.perRecordSaveBlock = { recordID, result in
                switch result {
                case .success:
                    #if DEBUG
                    print("[BigBrother] CloudKit saved record: \(recordID.recordName)")
                    #endif
                case .failure(let error):
                    #if DEBUG
                    print("[BigBrother] CloudKit per-record FAILED: \(recordID.recordName) — \(error.localizedDescription)")
                    #endif
                }
            }

            op.modifyRecordsResultBlock = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: CloudKitError.serverError(error))
                }
            }
            database.add(op)
        }
    }

    private func delete(_ recordID: CKRecord.ID) async throws {
        let op = CKModifyRecordsOperation(recordIDsToDelete: [recordID])
        op.qualityOfService = .userInitiated

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: CloudKitError.serverError(error))
                }
            }
            database.add(op)
        }
    }

    private func query(_ recordType: String, predicate: NSPredicate) async throws -> [CKRecord] {
        // Retry once if the record type isn't found — CloudKit Development environment
        // can have propagation delays after schema bootstrap.
        for attempt in 0..<2 {
            do {
                let query = CKQuery(recordType: recordType, predicate: predicate)
                var allRecords: [CKRecord] = []

                let (results, _) = try await database.records(matching: query, resultsLimit: 200)
                for (_, result) in results {
                    if case .success(let record) = result {
                        allRecords.append(record)
                    }
                }
                return allRecords
            } catch let error as CKError where error.code == .unknownItem && attempt == 0 {
                #if DEBUG
                print("[BigBrother] Record type \(recordType) not found, retrying in 3s...")
                #endif
                try? await Task.sleep(for: .seconds(3))
                continue
            }
        }
        return [] // Shouldn't reach here, but safe fallback
    }
}

// MARK: - Error Type

enum CloudKitError: Error, LocalizedError {
    case recordNotFound
    case invalidRecordData(String)
    case serverError(Error)

    var errorDescription: String? {
        switch self {
        case .recordNotFound: "Record not found"
        case .invalidRecordData(let msg): "Invalid record data: \(msg)"
        case .serverError(let err): "CloudKit error: \(err.localizedDescription)"
        }
    }
}
