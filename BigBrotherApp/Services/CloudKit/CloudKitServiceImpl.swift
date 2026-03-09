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
        let record = CKRecordConversion.toCKRecord(device)
        try await save(record)
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

    func saveReceipt(_ receipt: CommandReceipt) async throws {
        let record = CKRecordConversion.toCKRecord(receipt)
        try await save(record)
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

    // MARK: - Subscriptions

    func setupSubscriptions(familyID: FamilyID, deviceID: DeviceID?) async throws {
        // Subscribe to new pending commands for this family.
        let commandPredicate: NSPredicate
        if deviceID != nil {
            // Child device: subscribe to commands targeting this device, its profile, or all.
            // We use a broad filter on familyID + pending status; the CommandProcessor
            // handles fine-grained targeting.
            commandPredicate = NSPredicate(
                format: "%K == %@ AND %K == %@",
                CKFieldName.familyID, familyID.rawValue,
                CKFieldName.status, CommandStatus.pending.rawValue
            )
        } else {
            // Parent device: subscribe to receipts and heartbeats.
            commandPredicate = NSPredicate(
                format: "%K == %@",
                CKFieldName.familyID, familyID.rawValue
            )
        }

        let commandSub = CKQuerySubscription(
            recordType: CKRecordType.remoteCommand,
            predicate: commandPredicate,
            subscriptionID: "commands-\(familyID.rawValue)",
            options: [.firesOnRecordCreation]
        )
        let notifInfo = CKSubscription.NotificationInfo()
        notifInfo.shouldSendContentAvailable = true // silent push
        commandSub.notificationInfo = notifInfo

        let op = CKModifySubscriptionsOperation(
            subscriptionsToSave: [commandSub],
            subscriptionIDsToDelete: nil
        )
        op.qualityOfService = .utility

        #if DEBUG
        print("[BigBrother] 🔔 Setting up CloudKit subscription: commands-\(familyID.rawValue) (deviceID: \(deviceID?.rawValue ?? "nil"))")
        #endif

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            op.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    #if DEBUG
                    print("[BigBrother] ✅ CloudKit subscription active: commands-\(familyID.rawValue)")
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

    // MARK: - Private CloudKit Helpers

    private func save(_ record: CKRecord) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: [record])
        op.savePolicy = .changedKeys
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

    private func saveMultiple(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }

        let op = CKModifyRecordsOperation(recordsToSave: records)
        op.savePolicy = .changedKeys
        op.isAtomic = false // allow partial success
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
