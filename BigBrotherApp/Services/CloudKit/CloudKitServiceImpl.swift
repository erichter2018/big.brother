import Foundation
import CloudKit
import UIKit
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
                // Check for serverRecordChanged both wrapped (CloudKitError) and unwrapped (CKError).
                let isConflict: Bool
                if let ckErr = error as? CKError, ckErr.code == .serverRecordChanged {
                    isConflict = true
                } else if case .serverError(let underlying) = error as? CloudKitError,
                          let ckErr = underlying as? CKError, ckErr.code == .serverRecordChanged {
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

    func fetchPendingModeCommands(familyID: FamilyID, target: CommandTarget) async throws -> [RemoteCommand] {
        let predicate: NSPredicate
        switch target {
        case .child(let cid):
            predicate = NSPredicate(
                format: "%K == %@ AND %K == %@ AND %K == %@ AND %K == %@",
                CKFieldName.targetType, "child",
                CKFieldName.targetID, cid.rawValue,
                CKFieldName.familyID, familyID.rawValue,
                CKFieldName.status, CommandStatus.pending.rawValue
            )
        case .device(let did):
            predicate = NSPredicate(
                format: "%K == %@ AND %K == %@ AND %K == %@ AND %K == %@",
                CKFieldName.targetType, "device",
                CKFieldName.targetID, did.rawValue,
                CKFieldName.familyID, familyID.rawValue,
                CKFieldName.status, CommandStatus.pending.rawValue
            )
        case .allDevices:
            predicate = NSPredicate(
                format: "%K == %@ AND %K == %@ AND %K == %@",
                CKFieldName.targetType, "all",
                CKFieldName.familyID, familyID.rawValue,
                CKFieldName.status, CommandStatus.pending.rawValue
            )
        }
        return try await query(CKRecordType.remoteCommand, predicate: predicate)
            .compactMap(CKRecordConversion.remoteCommand)
            .filter { $0.action.isModeCommand }
    }

    func fetchPendingCommands(
        deviceID: DeviceID,
        childProfileID: ChildProfileID,
        familyID: FamilyID
    ) async throws -> [RemoteCommand] {
        // Fetch commands targeting this device, this child, or all devices.
        // Only fetch commands from the last 24 hours to avoid re-fetching
        // hundreds of already-processed commands on every 5-second poll.
        let cutoff = Date().addingTimeInterval(-24 * 3600) as NSDate

        // 1. Device-specific commands (familyID validated to prevent cross-family injection)
        let devicePred = NSPredicate(
            format: "%K == %@ AND %K == %@ AND %K == %@ AND %K == %@ AND %K >= %@",
            CKFieldName.targetType, "device",
            CKFieldName.targetID, deviceID.rawValue,
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.status, CommandStatus.pending.rawValue,
            CKFieldName.issuedAt, cutoff
        )
        let deviceCmds = try await query(CKRecordType.remoteCommand, predicate: devicePred)

        // 2. Child-profile commands (familyID validated to prevent cross-family injection)
        let childPred = NSPredicate(
            format: "%K == %@ AND %K == %@ AND %K == %@ AND %K == %@ AND %K >= %@",
            CKFieldName.targetType, "child",
            CKFieldName.targetID, childProfileID.rawValue,
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.status, CommandStatus.pending.rawValue,
            CKFieldName.issuedAt, cutoff
        )
        let childCmds = try await query(CKRecordType.remoteCommand, predicate: childPred)

        // 3. Global commands
        let globalPred = NSPredicate(
            format: "%K == %@ AND %K == %@ AND %K == %@ AND %K >= %@",
            CKFieldName.targetType, "all",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.status, CommandStatus.pending.rawValue,
            CKFieldName.issuedAt, cutoff
        )
        let globalCmds = try await query(CKRecordType.remoteCommand, predicate: globalPred)

        let allRecords = deviceCmds + childCmds + globalCmds
        return allRecords.compactMap(CKRecordConversion.remoteCommand)
    }

    func updateCommandStatus(_ commandID: UUID, status: CommandStatus) async throws {
        let recordID = CKRecordConversion.recordID(commandID.uuidString, type: CKRecordType.remoteCommand)
        let existing: CKRecord
        do {
            existing = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            throw CloudKitError.recordNotFound
        } catch {
            throw CloudKitError.serverError(error)
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
        let existing: CKRecord
        do {
            existing = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            throw CloudKitError.recordNotFound
        } catch {
            throw CloudKitError.serverError(error)
        }
        existing[CKFieldName.used] = 1 as NSNumber
        existing[CKFieldName.usedByDeviceID] = deviceID.rawValue
        try await save(existing)
    }

    func fetchParentInvites(familyID: FamilyID) async throws -> [EnrollmentInvite] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.profileID, "__parent_invite__"
        )
        return try await query(CKRecordType.enrollmentInvite, predicate: predicate)
            .compactMap(CKRecordConversion.enrollmentInvite)
    }

    func revokeInvite(code: String) async throws {
        let recordID = CKRecordConversion.recordID(code, type: CKRecordType.enrollmentInvite)
        let existing: CKRecord
        do {
            existing = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            throw CloudKitError.recordNotFound
        } catch {
            throw CloudKitError.serverError(error)
        }
        existing[CKFieldName.revoked] = 1 as NSNumber
        try await save(existing)
    }

    // MARK: - Heartbeat

    func sendHeartbeat(_ heartbeat: DeviceHeartbeat) async throws {
        // Fetch existing record to preserve change tag (avoids serverRecordChanged on repeat saves).
        let recordID = CKRecordConversion.recordID(heartbeat.deviceID.rawValue, type: CKRecordType.heartbeat)
        let existing: CKRecord
        do {
            existing = try await database.record(for: recordID)
        } catch {
            existing = CKRecord(recordType: CKRecordType.heartbeat, recordID: recordID)
        }
        // Don't overwrite a newer heartbeat with a stale one (clock skew / restart race).
        if let existingTimestamp = existing[CKFieldName.timestamp] as? Date,
           existingTimestamp > heartbeat.timestamp {
            #if DEBUG
            print("[CloudKit] Skipped heartbeat: existing \(existingTimestamp) > sent \(heartbeat.timestamp)")
            #endif
            return
        }
        CKRecordConversion.updateCKRecord(existing, from: heartbeat)
        do {
            try await save(existing)
        } catch {
            // "WRITE operation not permitted" means the record was created by a different
            // iCloud account (e.g., after OurPact removal changed auth). Delete and recreate.
            let desc = error.localizedDescription.lowercased()
            if desc.contains("permission") || desc.contains("not permitted") {
                #if DEBUG
                print("[CloudKit] Heartbeat permission denied — deleting stale record and recreating")
                #endif
                _ = try? await database.deleteRecord(withID: recordID)
                let fresh = CKRecord(recordType: CKRecordType.heartbeat, recordID: recordID)
                CKRecordConversion.updateCKRecord(fresh, from: heartbeat)
                try await save(fresh)
            } else {
                throw error
            }
        }
    }

    func fetchLatestHeartbeats(familyID: FamilyID) async throws -> [DeviceHeartbeat] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.familyID, familyID.rawValue)
        return try await query(CKRecordType.heartbeat, predicate: predicate)
            .compactMap(CKRecordConversion.deviceHeartbeat)
    }

    func fetchHeartbeats(familyID: FamilyID, since: Date) async throws -> [DeviceHeartbeat] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K >= %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.timestamp, since as NSDate
        )
        return try await query(CKRecordType.heartbeat, predicate: predicate)
            .compactMap(CKRecordConversion.deviceHeartbeat)
    }

    // MARK: - Events

    @discardableResult
    func syncEventLogs(_ entries: [EventLogEntry]) async throws -> Set<UUID> {
        let records = entries.map(CKRecordConversion.toCKRecord)
        let succeededNames = try await saveMultiple(records)
        // Map record names back to event UUIDs.
        let prefix = "\(CKRecordType.eventLog)_"
        return Set(succeededNames.compactMap { name in
            guard name.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(name.dropFirst(prefix.count)))
        })
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

    func fetchEventLogs(familyID: FamilyID, since: Date, types: Set<EventType>) async throws -> [EventLogEntry] {
        let typeStrings = types.map(\.rawValue) as [String]
        let predicate = NSPredicate(
            format: "%K == %@ AND %K >= %@ AND %K IN %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.timestamp, since as NSDate,
            CKFieldName.eventType, typeStrings
        )
        return try await query(CKRecordType.eventLog, predicate: predicate)
            .compactMap(CKRecordConversion.eventLogEntry)
    }

    // MARK: - Policy

    func savePolicy(_ policy: Policy) async throws {
        // Fetch existing record to preserve change tag (avoids serverRecordChanged on repeat saves).
        let recordID = CKRecordConversion.recordID(policy.targetDeviceID.rawValue, type: CKRecordType.policy)
        let existing: CKRecord
        do {
            existing = try await database.record(for: recordID)
        } catch {
            existing = CKRecord(recordType: CKRecordType.policy, recordID: recordID)
        }
        CKRecordConversion.updateCKRecord(existing, from: policy)
        try await save(existing)
    }

    func fetchPolicy(deviceID: DeviceID) async throws -> Policy? {
        let recordID = CKRecordConversion.recordID(deviceID.rawValue, type: CKRecordType.policy)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw CloudKitError.serverError(error)
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

    // MARK: - Location

    func saveLocationBreadcrumb(_ location: DeviceLocation) async throws {
        let record = CKRecordConversion.toCKRecord(location)
        try await save(record)
    }

    func fetchLocationBreadcrumbs(deviceID: DeviceID, since: Date) async throws -> [DeviceLocation] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K > %@",
            CKFieldName.deviceID, deviceID.rawValue,
            CKFieldName.locTimestamp, since as NSDate
        )
        return try await query(CKRecordType.deviceLocation, predicate: predicate)
            .compactMap(CKRecordConversion.deviceLocation)
            .sorted { $0.timestamp < $1.timestamp }
    }

    func purgeLocationBreadcrumbs(deviceID: DeviceID, olderThan: Date) async throws {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K < %@",
            CKFieldName.deviceID, deviceID.rawValue,
            CKFieldName.locTimestamp, olderThan as NSDate
        )
        _ = try await deleteRecords(type: CKRecordType.deviceLocation, predicate: predicate)
    }

    // MARK: - Named Places

    func fetchNamedPlaces(familyID: FamilyID) async throws -> [NamedPlace] {
        let predicate = NSPredicate(
            format: "%K == %@",
            CKFieldName.familyID, familyID.rawValue
        )
        return try await query(CKRecordType.namedPlace, predicate: predicate)
            .compactMap(CKRecordConversion.namedPlace)
    }

    func saveNamedPlace(_ place: NamedPlace) async throws {
        let record = CKRecordConversion.toCKRecord(place)
        try await save(record)
    }

    func deleteNamedPlace(_ id: UUID) async throws {
        let recordID = CKRecordConversion.recordID(id.uuidString, type: CKRecordType.namedPlace)
        try await delete(recordID)
    }

    // MARK: - Diagnostic Reports

    func saveDiagnosticReport(_ report: DiagnosticReport) async throws {
        let record = CKRecordConversion.toCKRecord(report)
        try await save(record)
    }

    func fetchDiagnosticReports(deviceID: DeviceID) async throws -> [DiagnosticReport] {
        let predicate = NSPredicate(
            format: "%K == %@",
            CKFieldName.deviceID, deviceID.rawValue
        )
        return try await query(CKRecordType.diagnosticReport, predicate: predicate)
            .compactMap(CKRecordConversion.diagnosticReport)
            .sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Time Limit Configs

    func fetchTimeLimitConfigs(childProfileID: ChildProfileID) async throws -> [TimeLimitConfig] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.profileID, childProfileID.rawValue)
        return try await query(CKRecordType.timeLimitConfig, predicate: predicate)
            .compactMap(CKRecordConversion.timeLimitConfig)
    }

    func saveTimeLimitConfig(_ config: TimeLimitConfig) async throws {
        let record = CKRecordConversion.toCKRecord(config)
        try await save(record)
    }

    func deleteTimeLimitConfig(_ id: UUID) async throws {
        let recordID = CKRecordConversion.recordID(id.uuidString, type: CKRecordType.timeLimitConfig)
        try await delete(recordID)
    }

    // MARK: - Pending App Reviews

    func fetchPendingAppReviews(childProfileID: ChildProfileID) async throws -> [PendingAppReview] {
        let predicate = NSPredicate(format: "%K == %@", CKFieldName.profileID, childProfileID.rawValue)
        return try await query(CKRecordType.pendingAppReview, predicate: predicate)
            .compactMap(CKRecordConversion.pendingAppReview)
    }

    func savePendingAppReview(_ review: PendingAppReview) async throws {
        let record = CKRecordConversion.toCKRecord(review)
        try await save(record)
    }

    func deletePendingAppReview(_ id: UUID) async throws {
        let recordID = CKRecordConversion.recordID(id.uuidString, type: CKRecordType.pendingAppReview)
        try await delete(recordID)
    }

    // MARK: - Enforcement Log

    func fetchEnforcementLogs(familyID: FamilyID, since: Date) async throws -> [CKRecord] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K > %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.timestamp, since as NSDate
        )
        return try await query(CKRecordType.enforcementLog, predicate: predicate)
    }

    // MARK: - Subscriptions

    func setupSubscriptions(familyID: FamilyID, deviceID: DeviceID?) async throws {
        // Check if our expected subscriptions already exist in CloudKit.
        // If they do, skip re-registration (fast path — no unnecessary work).
        // If they're missing (iCloud account change, MDM removal wiped them),
        // delete any stale leftovers and re-create from scratch.
        let expectedIDs: Set<String> = deviceID != nil
            ? ["commands-\(familyID.rawValue)", "mode-commands-alert-\(familyID.rawValue)"]
            : ["unlock-requests-v3-\(familyID.rawValue)", "heartbeats-v1-\(familyID.rawValue)", "app-reviews-v1-\(familyID.rawValue)"]

        // Always log what we find for debugging push issues
        let existing: [CKSubscription]
        do {
            existing = try await database.allSubscriptions()
            NSLog("[BigBrother] CK subscriptions found: \(existing.map(\.subscriptionID))")
        } catch {
            NSLog("[BigBrother] CK allSubscriptions() FAILED: \(error.localizedDescription) — will re-create")
            existing = []
        }

        let existingIDs = Set(existing.map(\.subscriptionID))
        let hasAllExpected = expectedIDs.isSubset(of: existingIDs)

        if hasAllExpected {
            NSLog("[BigBrother] CK subscriptions all present (\(expectedIDs)) — push should work")
            // Even if subscription exists, ensure APNs token is fresh
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            return
        }

        // Subscription(s) missing — nuke everything and re-create with fresh APNs token.
        let missing = expectedIDs.subtracting(existingIDs)
        NSLog("[BigBrother] CK subscriptions missing: \(missing) from \(existing.count) subs — deleting stale + re-registering")
        await deleteAllSubscriptions()
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }

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

            // Alert push subscription for mode commands — reliably delivered by iOS.
            // Matches only commands where alertTitle is populated (mode commands).
            // Both subscriptions fire for the same record; ProcessingGate deduplicates.
            let alertPredicate = NSPredicate(
                format: "%K == %@ AND %K == %@ AND %K != nil",
                CKFieldName.familyID, familyID.rawValue,
                CKFieldName.status, CommandStatus.pending.rawValue,
                CKFieldName.alertTitle
            )
            let alertSub = CKQuerySubscription(
                recordType: CKRecordType.remoteCommand,
                predicate: alertPredicate,
                subscriptionID: "mode-commands-alert-\(familyID.rawValue)",
                options: [.firesOnRecordCreation]
            )
            let alertNotifInfo = CKSubscription.NotificationInfo()
            alertNotifInfo.shouldSendContentAvailable = true
            alertNotifInfo.titleLocalizationKey = "%1$@"
            alertNotifInfo.titleLocalizationArgs = [CKFieldName.alertTitle]
            alertNotifInfo.alertLocalizationKey = "%1$@"
            alertNotifInfo.alertLocalizationArgs = [CKFieldName.alertBody]
            alertNotifInfo.soundName = "default"
            alertNotifInfo.shouldBadge = false
            alertSub.notificationInfo = alertNotifInfo
            subscriptionsToSave.append(alertSub)

            #if DEBUG
            print("[BigBrother] Setting up CloudKit subscriptions: silent + alert for \(familyID.rawValue)")
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

            // Also subscribe to safety events (speeding, phone-while-driving, geofence, etc.)
            let safetyPredicate = NSPredicate(
                format: "%K == %@",
                CKFieldName.familyID, familyID.rawValue
            )
            let safetySub = CKQuerySubscription(
                recordType: CKRecordType.eventLog,
                predicate: safetyPredicate,
                subscriptionID: "all-events-v1-\(familyID.rawValue)",
                options: [.firesOnRecordCreation]
            )
            let safetyNotifInfo = CKSubscription.NotificationInfo()
            safetyNotifInfo.shouldSendContentAvailable = true
            safetySub.notificationInfo = safetyNotifInfo
            subscriptionsToSave.append(safetySub)

            #if DEBUG
            print("[BigBrother] Setting up CloudKit subscription: all-events-\(familyID.rawValue)")
            #endif

            // Subscribe to heartbeat updates — fires instantly when child sends heartbeat
            // (unlike event logs which are batch-uploaded with a 5s delay).
            // This gives the parent near-instant dashboard updates after mode changes.
            let heartbeatPredicate = NSPredicate(
                format: "%K == %@",
                CKFieldName.familyID, familyID.rawValue
            )
            let heartbeatSub = CKQuerySubscription(
                recordType: CKRecordType.heartbeat,
                predicate: heartbeatPredicate,
                subscriptionID: "heartbeats-v1-\(familyID.rawValue)",
                options: [.firesOnRecordUpdate]
            )
            let heartbeatNotifInfo = CKSubscription.NotificationInfo()
            heartbeatNotifInfo.shouldSendContentAvailable = true
            heartbeatSub.notificationInfo = heartbeatNotifInfo
            subscriptionsToSave.append(heartbeatSub)

            // Subscribe to new pending app reviews — fires when child submits a request.
            let reviewPredicate = NSPredicate(
                format: "%K == %@",
                CKFieldName.familyID, familyID.rawValue
            )
            let reviewSub = CKQuerySubscription(
                recordType: CKRecordType.pendingAppReview,
                predicate: reviewPredicate,
                subscriptionID: "app-reviews-v1-\(familyID.rawValue)",
                options: [.firesOnRecordCreation]
            )
            let reviewNotifInfo = CKSubscription.NotificationInfo()
            reviewNotifInfo.shouldSendContentAvailable = true
            reviewSub.notificationInfo = reviewNotifInfo
            subscriptionsToSave.append(reviewSub)
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
                    for subscription in subscriptionsToSave {
                        NSLog("[BigBrother] CK subscription SAVED: \(subscription.subscriptionID)")
                    }
                    continuation.resume()
                case .failure(let error):
                    NSLog("[BigBrother] CK subscription SAVE FAILED: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
            database.add(op)
        }
    }

    /// Delete all CK subscriptions for this container, then let setupSubscriptions re-create.
    /// Ensures stale subscriptions with old APNs tokens are fully purged.
    private func deleteAllSubscriptions() async {
        do {
            let subs = try await database.allSubscriptions()
            guard !subs.isEmpty else { return }
            let idsToDelete = subs.map(\.subscriptionID)
            let op = CKModifySubscriptionsOperation(
                subscriptionsToSave: nil,
                subscriptionIDsToDelete: idsToDelete
            )
            op.qualityOfService = .utility
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                op.modifySubscriptionsResultBlock = { result in
                    switch result {
                    case .success:
                        NSLog("[BigBrother] Deleted \(idsToDelete.count) stale CK subscriptions before re-register")
                        continuation.resume()
                    case .failure(let error):
                        NSLog("[BigBrother] Failed to delete CK subscriptions: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    }
                }
                self.database.add(op)
            }
        } catch {
            NSLog("[BigBrother] Could not fetch existing CK subscriptions: \(error.localizedDescription)")
        }
    }

    // MARK: - Cleanup

    func deleteRecords(type: String, predicate: NSPredicate, limit: Int? = nil) async throws -> Int {
        let allRecords = try await query(type, predicate: predicate)
        let records = limit.map { Array(allRecords.prefix($0)) } ?? allRecords
        guard !records.isEmpty else { return 0 }

        // Delete in batches of 400 (CloudKit limit is 400 per operation).
        // Track actual per-record success since public DB only allows the
        // record creator to delete — permission failures are silent at the
        // operation level.
        var deleted = 0
        for batchStart in stride(from: 0, to: records.count, by: 400) {
            let batchEnd = min(batchStart + 400, records.count)
            let ids = records[batchStart..<batchEnd].map(\.recordID)

            let op = CKModifyRecordsOperation(recordIDsToDelete: Array(ids))
            op.qualityOfService = .utility

            let batchDeleted = LockedCounter()

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                op.perRecordDeleteBlock = { _, result in
                    if case .success = result {
                        batchDeleted.increment()
                    }
                }
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
            deleted += batchDeleted.value
        }
        return deleted
    }

    /// Thread-safe counter for use in CloudKit operation callbacks.
    private final class LockedCounter: @unchecked Sendable {
        private var _value = 0
        private let lock = NSLock()
        func increment() { lock.lock(); _value += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
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

    /// Save multiple records, returning the set of record names that succeeded.
    /// Uses non-atomic mode so partial success is possible.
    @discardableResult
    private func saveMultiple(_ records: [CKRecord]) async throws -> Set<String> {
        guard !records.isEmpty else { return [] }

        let op = CKModifyRecordsOperation(recordsToSave: records)
        op.savePolicy = .changedKeys
        op.isAtomic = false // allow partial success
        op.qualityOfService = .userInitiated

        // Thread-safe collection of succeeded record names.
        let succeeded = LockedSet<String>()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            op.perRecordSaveBlock = { recordID, result in
                switch result {
                case .success:
                    succeeded.insert(recordID.recordName)
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
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    // If some records succeeded individually (non-atomic mode),
                    // don't throw — return partial success instead.
                    if !succeeded.values.isEmpty {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: CloudKitError.serverError(error))
                    }
                }
            }
            database.add(op)
        }
        return succeeded.values
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

                // Paginate through all results (CloudKit returns max 200 per page).
                var cursor: CKQueryOperation.Cursor?
                let (firstResults, firstCursor) = try await database.records(matching: query, resultsLimit: 200)
                for (_, result) in firstResults {
                    switch result {
                    case .success(let record):
                        allRecords.append(record)
                    case .failure(let error):
                        #if DEBUG
                        print("[CloudKit] Dropped record in query: \(error.localizedDescription)")
                        #endif
                    }
                }
                cursor = firstCursor

                while let activeCursor = cursor {
                    let (moreResults, nextCursor) = try await database.records(continuingMatchFrom: activeCursor, resultsLimit: 200)
                    for (_, result) in moreResults {
                        switch result {
                        case .success(let record):
                            allRecords.append(record)
                        case .failure(let error):
                            #if DEBUG
                            print("[CloudKit] Dropped record in pagination: \(error.localizedDescription)")
                            #endif
                        }
                    }
                    cursor = nextCursor
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

/// Simple thread-safe Set wrapper for CloudKit callback contexts.
private final class LockedSet<T: Hashable>: @unchecked Sendable {
    private var storage = Set<T>()
    private let lock = NSLock()
    func insert(_ value: T) { lock.lock(); storage.insert(value); lock.unlock() }
    var values: Set<T> { lock.lock(); defer { lock.unlock() }; return storage }
}

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
