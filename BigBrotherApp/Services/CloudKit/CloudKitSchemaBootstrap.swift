import Foundation
import CloudKit
import BigBrotherCore

/// Bootstraps the CloudKit schema by saving a seed record for each record type.
///
/// In the Development environment, CloudKit auto-creates record types and fields
/// when a record of a new type is saved. Queries for non-existent types fail,
/// so we must create the schema before any queries run.
///
/// This is idempotent — seed records use a fixed record name prefix ("_schema_seed_")
/// so re-running overwrites the same records rather than creating duplicates.
/// Seed records use a sentinel familyID ("__schema__") that will never match
/// real queries.
enum CloudKitSchemaBootstrap {

    private static let seedFamilyID = "SchemaSeed"
    private static let seedPrefix = "SchemaSeed-"

    /// Ensure all record types exist in the CloudKit container.
    /// Uses direct database.save() for reliable per-record error reporting.
    static func bootstrapIfNeeded(database: CKDatabase) async {
        let records = buildSeedRecords()

        #if DEBUG
        print("[BigBrother] Checking CloudKit schema (\(records.count) record types)...")
        #endif

        var created = 0
        var existed = 0
        for record in records {
            do {
                // Use database.save() directly — throws real errors, no silent failures.
                _ = try await database.save(record)
                created += 1
                #if DEBUG
                print("[BigBrother]   ✓ \(record.recordType) — saved")
                #endif
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Record already exists (conflict) — record type exists, which is what we need.
                existed += 1
                #if DEBUG
                print("[BigBrother]   ✓ \(record.recordType) — already exists")
                #endif
            } catch {
                #if DEBUG
                print("[BigBrother]   ✗ \(record.recordType) — FAILED: \(error)")
                #endif
            }
        }

        #if DEBUG
        print("[BigBrother] Schema bootstrap done: \(created) created, \(existed) existed, \(records.count - created - existed) failed")
        #endif
    }

    // MARK: - Seed Record Builders

    private static func buildSeedRecords() -> [CKRecord] {
        [
            buildFamily(),
            buildChildProfile(),
            buildChildDevice(),
            buildPolicy(),
            buildRemoteCommand(),
            buildCommandReceipt(),
            buildHeartbeat(),
            buildEventLog(),
            buildEnrollmentInvite(),
            buildSchedule(),
            buildHeartbeatProfile(),
            buildScheduleProfile(),
        ]
    }

    private static func seed(_ type: String) -> CKRecord {
        CKRecord(recordType: type, recordID: CKRecord.ID(recordName: "\(seedPrefix)\(type)"))
    }

    private static func buildFamily() -> CKRecord {
        let r = seed(CKRecordType.family)
        r[CKFieldName.familyID] = seedFamilyID
        return r
    }

    private static func buildChildProfile() -> CKRecord {
        let r = seed(CKRecordType.childProfile)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.profileID] = seedPrefix
        r[CKFieldName.name] = "_seed_"
        r[CKFieldName.avatarName] = ""
        r[CKFieldName.createdAt] = Date() as NSDate
        r[CKFieldName.updatedAt] = Date() as NSDate
        return r
    }

    private static func buildChildDevice() -> CKRecord {
        let r = seed(CKRecordType.childDevice)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.deviceID] = seedPrefix
        r[CKFieldName.profileID] = seedPrefix
        r[CKFieldName.displayName] = "_seed_"
        r[CKFieldName.modelIdentifier] = ""
        r[CKFieldName.osVersion] = ""
        r[CKFieldName.enrolledAt] = Date() as NSDate
        r[CKFieldName.familyControlsOK] = 0 as NSNumber
        return r
    }

    private static func buildPolicy() -> CKRecord {
        let r = seed(CKRecordType.policy)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.deviceID] = seedPrefix
        r[CKFieldName.mode] = "unlocked"
        r[CKFieldName.version] = 0 as NSNumber
        return r
    }

    private static func buildRemoteCommand() -> CKRecord {
        let r = seed(CKRecordType.remoteCommand)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.commandID] = seedPrefix
        r[CKFieldName.targetType] = "all"
        r[CKFieldName.targetID] = seedPrefix
        r[CKFieldName.actionJSON] = "{}"
        r[CKFieldName.issuedBy] = "_seed_"
        r[CKFieldName.issuedAt] = Date() as NSDate
        r[CKFieldName.expiresAt] = Date() as NSDate
        r[CKFieldName.status] = "expired"
        return r
    }

    private static func buildCommandReceipt() -> CKRecord {
        let r = seed(CKRecordType.commandReceipt)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.commandID] = seedPrefix
        r[CKFieldName.deviceID] = seedPrefix
        r[CKFieldName.appliedAt] = Date() as NSDate
        r[CKFieldName.status] = "expired"
        return r
    }

    private static func buildHeartbeat() -> CKRecord {
        let r = seed(CKRecordType.heartbeat)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.deviceID] = seedPrefix
        r[CKFieldName.timestamp] = Date() as NSDate
        r[CKFieldName.currentMode] = "unlocked"
        r[CKFieldName.policyVersion] = 0 as NSNumber
        r[CKFieldName.fcAuthorized] = 0 as NSNumber
        r[CKFieldName.batteryLevel] = 0.0 as NSNumber
        r[CKFieldName.isCharging] = 0 as NSNumber
        r[CKFieldName.installID] = UUID().uuidString
        r[CKFieldName.heartbeatSeq] = 0 as NSNumber
        r[CKFieldName.cloudKitStatus] = "available"
        return r
    }

    private static func buildEventLog() -> CKRecord {
        let r = seed(CKRecordType.eventLog)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.deviceID] = seedPrefix
        r[CKFieldName.eventID] = seedPrefix
        r[CKFieldName.eventType] = "schemaBootstrap"
        r[CKFieldName.timestamp] = Date() as NSDate
        r[CKFieldName.details] = "Schema seed record"
        return r
    }

    private static func buildEnrollmentInvite() -> CKRecord {
        let r = seed(CKRecordType.enrollmentInvite)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.code] = "\(seedPrefix)CODE"
        r[CKFieldName.profileID] = seedPrefix
        r[CKFieldName.createdAt] = Date() as NSDate
        r[CKFieldName.expiresAt] = Date() as NSDate
        r[CKFieldName.used] = 1 as NSNumber
        return r
    }

    private static func buildSchedule() -> CKRecord {
        let r = seed(CKRecordType.schedule)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.profileID] = seedPrefix
        r[CKFieldName.scheduleName] = "_seed_"
        r[CKFieldName.mode] = "unlocked"
        r[CKFieldName.daysOfWeekJSON] = "[]"
        r[CKFieldName.startHour] = 0 as NSNumber
        r[CKFieldName.startMinute] = 0 as NSNumber
        r[CKFieldName.endHour] = 0 as NSNumber
        r[CKFieldName.endMinute] = 0 as NSNumber
        r[CKFieldName.isActive] = 0 as NSNumber
        return r
    }

    private static func buildHeartbeatProfile() -> CKRecord {
        let r = seed(CKRecordType.heartbeatProfile)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.name] = "_seed_"
        r[CKFieldName.activeWindowsJSON] = "[]"
        r[CKFieldName.maxHeartbeatGap] = 7200.0 as NSNumber
        r[CKFieldName.isDefault] = 0 as NSNumber
        r[CKFieldName.updatedAt] = Date() as NSDate
        return r
    }

    private static func buildScheduleProfile() -> CKRecord {
        let r = seed(CKRecordType.scheduleProfile)
        r[CKFieldName.familyID] = seedFamilyID
        r[CKFieldName.name] = "_seed_"
        r[CKFieldName.freeWindowsJSON] = "[]"
        r[CKFieldName.lockedMode] = "dailyMode"
        r[CKFieldName.isDefault] = 0 as NSNumber
        r[CKFieldName.updatedAt] = Date() as NSDate
        return r
    }
}
