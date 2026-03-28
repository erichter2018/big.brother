import Foundation
import CloudKit
import os.log
import BigBrotherCore

private let cleanupLogger = Logger(subsystem: "fr.bigbrother.app", category: "CloudKitCleanup")

/// Periodically prunes stale CloudKit records to prevent unbounded growth.
///
/// Runs on the parent device only (child devices don't need to clean up).
/// Targets:
///   - Old commands (applied/failed/expired, older than 4 hours)
///   - Old command receipts (older than 4 hours)
///   - Old event logs (older than 7 days)
///
/// Heartbeats use an upsert pattern (one record per device) so they don't
/// accumulate and don't need cleanup.
enum CloudKitCleanupService {

    // MARK: - Retention Periods

    /// Commands and receipts older than this are deleted.
    private static let commandRetention: TimeInterval = 24 * 3600 // 24 hours

    /// Event logs older than this are deleted.
    private static let eventRetention: TimeInterval = 7 * 86400 // 7 days


    // MARK: - Public API

    /// Run a full cleanup pass. Safe to call frequently — only deletes old records.
    /// Returns the total number of records deleted.
    @discardableResult
    static func performCleanup(
        cloudKit: any CloudKitServiceProtocol,
        familyID: FamilyID
    ) async -> Int {
        var total = 0

        // 1. Old commands — includes pending as a safety net for commands that were
        //    never processed (e.g., device was offline for days). The 24-hour retention
        //    is well past the command expiry window.
        let commandCutoff = Date().addingTimeInterval(-commandRetention)
        for status in ["applied", "failed", "expired", "pending"] {
            let predicate = NSPredicate(
                format: "%K == %@ AND %K == %@ AND %K < %@",
                CKFieldName.familyID, familyID.rawValue,
                CKFieldName.status, status,
                CKFieldName.issuedAt, commandCutoff as NSDate
            )
            do {
                let count = try await cloudKit.deleteRecords(
                    type: CKRecordType.remoteCommand,
                    predicate: predicate,
                    limit: nil
                )
                total += count
                #if DEBUG
                if count > 0 {
                    print("[Cleanup] Deleted \(count) old \(status) commands")
                }
                #endif
            } catch {
                cleanupLogger.warning("Failed to clean \(status) commands: \(error.localizedDescription)")
            }
        }

        // 2. Old command receipts.
        let receiptPredicate = NSPredicate(
            format: "%K == %@ AND %K < %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.appliedAt, commandCutoff as NSDate
        )
        do {
            let count = try await cloudKit.deleteRecords(
                type: CKRecordType.commandReceipt,
                predicate: receiptPredicate,
                limit: nil
            )
            total += count
            #if DEBUG
            if count > 0 {
                print("[Cleanup] Deleted \(count) old command receipts")
            }
            #endif
        } catch {
            cleanupLogger.warning("Failed to clean receipts: \(error.localizedDescription)")
        }

        // 3. Old event logs.
        let eventCutoff = Date().addingTimeInterval(-eventRetention)
        let eventPredicate = NSPredicate(
            format: "%K == %@ AND %K < %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.timestamp, eventCutoff as NSDate
        )
        do {
            let count = try await cloudKit.deleteRecords(
                type: CKRecordType.eventLog,
                predicate: eventPredicate,
                limit: nil
            )
            total += count
            #if DEBUG
            if count > 0 {
                print("[Cleanup] Deleted \(count) old event logs")
            }
            #endif
        } catch {
            cleanupLogger.warning("Failed to clean event logs: \(error.localizedDescription)")
        }

        // 4. Old location breadcrumbs (older than 30 days).
        let locationCutoff = Date().addingTimeInterval(-30 * 86400)
        let locationPredicate = NSPredicate(
            format: "%K == %@ AND %K < %@",
            CKFieldName.familyID, familyID.rawValue,
            CKFieldName.locTimestamp, locationCutoff as NSDate
        )
        do {
            let count = try await cloudKit.deleteRecords(
                type: CKRecordType.deviceLocation,
                predicate: locationPredicate,
                limit: nil
            )
            total += count
            #if DEBUG
            if count > 0 {
                print("[Cleanup] Deleted \(count) old location breadcrumbs")
            }
            #endif
        } catch {
            cleanupLogger.warning("Failed to clean location breadcrumbs: \(error.localizedDescription)")
        }

        #if DEBUG
        print("[Cleanup] Total records cleaned: \(total)")
        #endif

        return total
    }
}
