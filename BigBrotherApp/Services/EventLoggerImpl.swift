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
        try? storage.appendEventLog(entry)
    }

    func syncPendingEvents() async throws {
        let pending = storage.readPendingEventLogs()
            .filter { $0.uploadState == .pending }

        guard !pending.isEmpty else { return }

        // Upload in batches of 50 to avoid CloudKit limits.
        let batchSize = 50
        for batchStart in stride(from: 0, to: pending.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, pending.count)
            let batch = Array(pending[batchStart..<batchEnd])
            let batchIDs = Set(batch.map(\.id))

            // Mark as uploading.
            try? storage.updateEventUploadState(ids: batchIDs, state: .uploading)

            do {
                try await cloudKit.syncEventLogs(batch)
                // Remove uploaded events from the queue.
                try storage.clearSyncedEventLogs(ids: batchIDs)
            } catch {
                // Mark as failed so they can be retried later.
                try? storage.updateEventUploadState(ids: batchIDs, state: .failed)

                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .eventUpload,
                    message: "Event batch upload failed",
                    details: "\(batchIDs.count) events, error: \(error.localizedDescription)"
                ))
            }
        }
    }

    func pendingEvents() -> [EventLogEntry] {
        storage.readPendingEventLogs()
    }

    // MARK: - Private

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
            try? storage.appendEventLog(entry)
            return
        }

        // Last resort: log with placeholder IDs. At least the event is captured.
        let entry = EventLogEntry(
            deviceID: DeviceID(rawValue: "unknown"),
            familyID: FamilyID(rawValue: "unknown"),
            eventType: eventType,
            details: details
        )
        try? storage.appendEventLog(entry)
    }
}
