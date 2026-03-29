import Foundation
import BigBrotherCore

/// Concrete event logger. Writes events to App Group storage immediately,
/// then syncs to CloudKit in batches.
///
/// Events are written by both the main app and extensions (via shared storage).
/// The main app is responsible for flushing the queue to CloudKit.
/// Uses EventUploadState for upload lifecycle tracking.
final class EventLoggerImpl: EventLoggerProtocol {

    private let cloudKit: any CloudKitServiceProtocol
    private let storage: any SharedStorageProtocol
    private let keychain: any KeychainProtocol

    init(
        cloudKit: any CloudKitServiceProtocol,
        storage: any SharedStorageProtocol = AppGroupStorage(),
        keychain: any KeychainProtocol = KeychainManager()
    ) {
        self.cloudKit = cloudKit
        self.storage = storage
        self.keychain = keychain
    }

    // MARK: - EventLoggerProtocol

    func log(_ eventType: EventType, details: String?) {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else {
            // Not enrolled — try to get IDs from parent state.
            logWithFallbackIDs(eventType: eventType, details: details)
            return
        }

        let entry = EventLogEntry(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            eventType: eventType,
            details: details
        )
        do {
            try storage.appendEventLog(entry)
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to log event: \(error.localizedDescription)")
            #endif
        }
    }

    func syncPendingEvents() async throws {
        let allEvents = storage.readPendingEventLogs()

        // Recover events stuck in .uploading state (app was killed mid-upload).
        let stuckUploading = allEvents.filter { $0.uploadState == .uploading }
        if !stuckUploading.isEmpty {
            try? storage.updateEventUploadState(ids: Set(stuckUploading.map(\.id)), state: .pending)
        }

        let pending = allEvents.filter { $0.uploadState == .pending || $0.uploadState == .uploading }

        #if DEBUG
        if !allEvents.isEmpty || !pending.isEmpty {
            let unlockCount = pending.filter { $0.eventType == .unlockRequested }.count
            print("[BigBrother] Event sync: \(allEvents.count) total, \(pending.count) pending (\(unlockCount) unlock requests)")
        }
        #endif

        guard !pending.isEmpty else { return }

        // Upload in batches of 50 to avoid CloudKit limits.
        let batchSize = 50
        for batchStart in stride(from: 0, to: pending.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, pending.count)
            let batch = Array(pending[batchStart..<batchEnd])
            let batchIDs = Set(batch.map(\.id))

            // Mark as uploading.
            try? storage.updateEventUploadState(ids: batchIDs, state: .uploading)

            #if DEBUG
            for event in batch {
                print("[BigBrother] Event sync: uploading \(event.id) type=\(event.eventType.rawValue) details=\(event.details?.prefix(60) ?? "nil")")
            }
            #endif

            do {
                // Strip TOKEN payloads before uploading — token data is only
                // needed locally (in PendingUnlockRequest). No need to bloat CloudKit.
                let sanitizedBatch = batch.map(Self.stripTokenPayload)
                let succeededIDs = try await cloudKit.syncEventLogs(sanitizedBatch)
                #if DEBUG
                print("[BigBrother] Event sync: \(succeededIDs.count)/\(sanitizedBatch.count) events uploaded")
                #endif
                // Only clear events that actually succeeded (partial success safe).
                // Keep unlockRequested events because their token data is needed
                // when the parent approves. They'll be pruned after 7 days.
                let clearableIDs = succeededIDs.filter { id in
                    !batch.contains { $0.id == id && $0.eventType == .unlockRequested }
                }
                if !clearableIDs.isEmpty {
                    try storage.clearSyncedEventLogs(ids: Set(clearableIDs))
                }
                // Mark successfully uploaded unlock requests.
                let unlockIDs = succeededIDs.subtracting(clearableIDs)
                if !unlockIDs.isEmpty {
                    try? storage.updateEventUploadState(ids: unlockIDs, state: .uploaded)
                }
                // Mark failed events back to pending for retry.
                let failedIDs = batchIDs.subtracting(succeededIDs)
                if !failedIDs.isEmpty {
                    try? storage.updateEventUploadState(ids: failedIDs, state: .pending)
                }
            } catch {
                // Mark back as pending so they will be retried on the next sync.
                try? storage.updateEventUploadState(ids: batchIDs, state: .pending)

                #if DEBUG
                print("[BigBrother] Event sync FAILED: \(error.localizedDescription)")
                #endif

                // Only log diagnostic once per 10 minutes to avoid flooding.
                let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
                let lastFailLogKey = "eventUploadLastFailLogAt"
                let lastFailLog = defaults?.object(forKey: lastFailLogKey) as? Date ?? .distantPast
                if Date().timeIntervalSince(lastFailLog) > 600 {
                    defaults?.set(Date(), forKey: lastFailLogKey)
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .eventUpload,
                        message: "Event batch upload failed",
                        details: "\(batchIDs.count) events, error: \(error.localizedDescription)"
                    ))
                }
            }
        }

        // Prune old synced events to prevent queue bloat.
        // Keep: pending events (not yet uploaded), unlock requests (needed for approval),
        // and anything less than 1 hour old (for diagnostics).
        let pruneThreshold = Date().addingTimeInterval(-3600)
        let allAfterSync = storage.readPendingEventLogs()
        let toPrune = allAfterSync.filter { event in
            event.uploadState != .pending
            && event.eventType != .unlockRequested
            && event.timestamp < pruneThreshold
        }
        if !toPrune.isEmpty {
            try? storage.clearSyncedEventLogs(ids: Set(toPrune.map(\.id)))
            #if DEBUG
            print("[BigBrother] Pruned \(toPrune.count) old synced events")
            #endif
        }
    }

    func pendingEvents() -> [EventLogEntry] {
        storage.readPendingEventLogs()
    }

    // MARK: - Private

    /// Strip TOKEN:base64 payload from event details before CloudKit upload.
    private static func stripTokenPayload(_ entry: EventLogEntry) -> EventLogEntry {
        guard let details = entry.details,
              let tokenRange = details.range(of: "\nTOKEN:") else {
            return entry
        }
        let cleanDetails = String(details[..<tokenRange.lowerBound])
        return EventLogEntry(
            id: entry.id,
            deviceID: entry.deviceID,
            familyID: entry.familyID,
            eventType: entry.eventType,
            details: cleanDetails,
            timestamp: entry.timestamp,
            uploadState: entry.uploadState
        )
    }

    /// Fallback for logging when device is in parent mode or not yet enrolled.
    private func logWithFallbackIDs(eventType: EventType, details: String?) {
        // Try parent state.
        if let parentState = try? keychain.get(
            ParentState.self,
            forKey: StorageKeys.parentState
        ) {
            let entry = EventLogEntry(
                deviceID: DeviceID(rawValue: "parent"),
                familyID: parentState.familyID,
                eventType: eventType,
                details: details
            )
            do {
                try storage.appendEventLog(entry)
            } catch {
                #if DEBUG
                print("[BigBrother] Failed to log event: \(error.localizedDescription)")
                #endif
            }
            return
        }

        // Last resort: log with placeholder IDs. At least the event is captured.
        let entry = EventLogEntry(
            deviceID: DeviceID(rawValue: "unknown"),
            familyID: FamilyID(rawValue: "unknown"),
            eventType: eventType,
            details: details
        )
        do {
            try storage.appendEventLog(entry)
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to log event: \(error.localizedDescription)")
            #endif
        }
    }
}
