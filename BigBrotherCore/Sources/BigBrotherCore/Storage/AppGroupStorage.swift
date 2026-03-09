import Foundation

/// Concrete implementation of SharedStorageProtocol using App Group container.
///
/// All writes use atomic file operations (Data.write with .atomic option)
/// to prevent extensions from reading a partially written file.
///
/// Thread safety: NSLock protects read-modify-write sequences on
/// collection-type files (event queue, processed commands, diagnostics).
public final class AppGroupStorage: SharedStorageProtocol, @unchecked Sendable {

    private let containerURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default
    private let lock = NSLock()

    /// File names within the App Group container.
    private enum FileName {
        static let policySnapshot = "policy_snapshot.json"
        static let shieldConfig = "shield_config.json"
        static let eventLogQueue = "event_log_queue.json"
        static let processedCommands = "processed_commands.json"
        static let temporaryUnlockState = "temporary_unlock_state.json"
        static let authorizationHealth = "authorization_health.json"
        static let heartbeatStatus = "heartbeat_status.json"
        static let extensionSharedState = "extension_shared_state.json"
        static let diagnosticsLog = "diagnostics_log.json"
        static let snapshotHistory = "snapshot_history.json"
    }

    public init(appGroupIdentifier: String = AppConstants.appGroupIdentifier) {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            self.containerURL = url
        } else {
            // App Group unavailable (simulator without entitlement, or provisioning issue).
            // Fall back to a local directory so the app remains functional for UI testing.
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("BigBrotherAppGroup")
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            self.containerURL = fallback
            #if DEBUG
            print("[BigBrother] ⚠️ App Group unavailable, using fallback: \(fallback.path)")
            #endif
        }
    }

    /// Init with a custom directory URL. Used for testing without App Group entitlement.
    public init(containerURL: URL) {
        self.containerURL = containerURL
    }

    // MARK: - Policy Snapshot

    public func readPolicySnapshot() -> PolicySnapshot? {
        read(FileName.policySnapshot)
    }

    public func writePolicySnapshot(_ snapshot: PolicySnapshot) throws {
        try writeAtomically(snapshot, to: FileName.policySnapshot)
    }

    // MARK: - Shield Configuration

    public func readShieldConfiguration() -> ShieldConfig? {
        read(FileName.shieldConfig)
    }

    public func writeShieldConfiguration(_ config: ShieldConfig) throws {
        try writeAtomically(config, to: FileName.shieldConfig)
    }

    // MARK: - Event Log Queue

    public func appendEventLog(_ entry: EventLogEntry) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries: [EventLogEntry] = read(FileName.eventLogQueue) ?? []
        entries.append(entry)

        // Prune oldest entries if queue exceeds max size
        if entries.count > AppConstants.eventQueueMaxSize {
            let overflow = entries.count - AppConstants.eventQueueMaxSize
            entries.removeFirst(overflow)
        }

        try writeAtomically(entries, to: FileName.eventLogQueue)
    }

    public func readPendingEventLogs() -> [EventLogEntry] {
        (read(FileName.eventLogQueue) as [EventLogEntry]?) ?? []
    }

    public func clearSyncedEventLogs(ids: Set<UUID>) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries: [EventLogEntry] = read(FileName.eventLogQueue) ?? []
        entries.removeAll { ids.contains($0.id) }
        try writeAtomically(entries, to: FileName.eventLogQueue)
    }

    public func updateEventUploadState(ids: Set<UUID>, state: EventUploadState) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries: [EventLogEntry] = read(FileName.eventLogQueue) ?? []
        for i in entries.indices where ids.contains(entries[i].id) {
            entries[i].uploadState = state
        }
        try writeAtomically(entries, to: FileName.eventLogQueue)
    }

    // MARK: - Processed Commands

    /// Wrapper to store command IDs with timestamps for pruning.
    private struct ProcessedCommandEntry: Codable {
        let id: UUID
        let processedAt: Date
    }

    public func readProcessedCommandIDs() -> Set<UUID> {
        let entries: [ProcessedCommandEntry]? = read(FileName.processedCommands)
        return Set(entries?.map(\.id) ?? [])
    }

    public func markCommandProcessed(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries: [ProcessedCommandEntry] = read(FileName.processedCommands) ?? []
        guard !entries.contains(where: { $0.id == id }) else { return }
        entries.append(ProcessedCommandEntry(id: id, processedAt: Date()))
        try writeAtomically(entries, to: FileName.processedCommands)
    }

    public func pruneProcessedCommands(olderThan cutoff: Date) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries: [ProcessedCommandEntry] = read(FileName.processedCommands) ?? []
        entries.removeAll { $0.processedAt < cutoff }
        try writeAtomically(entries, to: FileName.processedCommands)
    }

    // MARK: - Temporary Unlock State

    public func readTemporaryUnlockState() -> TemporaryUnlockState? {
        read(FileName.temporaryUnlockState)
    }

    public func writeTemporaryUnlockState(_ state: TemporaryUnlockState) throws {
        try writeAtomically(state, to: FileName.temporaryUnlockState)
    }

    public func clearTemporaryUnlockState() throws {
        try deleteFile(FileName.temporaryUnlockState)
    }

    // MARK: - Authorization Health

    public func readAuthorizationHealth() -> AuthorizationHealth? {
        read(FileName.authorizationHealth)
    }

    public func writeAuthorizationHealth(_ health: AuthorizationHealth) throws {
        try writeAtomically(health, to: FileName.authorizationHealth)
    }

    // MARK: - Heartbeat Status

    public func readHeartbeatStatus() -> HeartbeatStatus? {
        read(FileName.heartbeatStatus)
    }

    public func writeHeartbeatStatus(_ status: HeartbeatStatus) throws {
        try writeAtomically(status, to: FileName.heartbeatStatus)
    }

    // MARK: - Extension Shared State

    public func readExtensionSharedState() -> ExtensionSharedState? {
        read(FileName.extensionSharedState)
    }

    public func writeExtensionSharedState(_ state: ExtensionSharedState) throws {
        try writeAtomically(state, to: FileName.extensionSharedState)
    }

    // MARK: - Diagnostics

    public func appendDiagnosticEntry(_ entry: DiagnosticEntry) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries: [DiagnosticEntry] = read(FileName.diagnosticsLog) ?? []
        entries.append(entry)

        // Prune oldest entries if log exceeds max size
        if entries.count > AppConstants.diagnosticsMaxEntries {
            let overflow = entries.count - AppConstants.diagnosticsMaxEntries
            entries.removeFirst(overflow)
        }

        try writeAtomically(entries, to: FileName.diagnosticsLog)
    }

    public func readDiagnosticEntries(category: DiagnosticCategory?) -> [DiagnosticEntry] {
        let entries: [DiagnosticEntry] = read(FileName.diagnosticsLog) ?? []
        if let category {
            return entries.filter { $0.category == category }
        }
        return entries
    }

    public func pruneDiagnosticEntries(olderThan cutoff: Date) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries: [DiagnosticEntry] = read(FileName.diagnosticsLog) ?? []
        entries.removeAll { $0.timestamp < cutoff }
        try writeAtomically(entries, to: FileName.diagnosticsLog)
    }

    // MARK: - Snapshot History

    public func readSnapshotHistory() -> [SnapshotTransition] {
        (read(FileName.snapshotHistory) as [SnapshotTransition]?) ?? []
    }

    public func writeSnapshotHistory(_ history: [SnapshotTransition]) throws {
        try writeAtomically(history, to: FileName.snapshotHistory)
    }

    // MARK: - Private Helpers

    private func fileURL(for name: String) -> URL {
        containerURL.appendingPathComponent(name)
    }

    /// Read and decode a JSON file. Returns nil if the file does not exist
    /// or if decoding fails (corrupted data is treated as missing).
    private func read<T: Decodable>(_ fileName: String) -> T? {
        let url = fileURL(for: fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Read with typed error reporting. Distinguishes missing file from corruption.
    /// Used internally where corruption detection matters.
    private func readThrowing<T: Decodable>(_ fileName: String) throws -> T? {
        let url = fileURL(for: fileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StorageError.decodingFailed(fileName: fileName)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw StorageError.fileCorrupted(fileName: fileName)
        }
    }

    /// Write data atomically using Foundation's built-in atomic write.
    /// This writes to a temporary file in the same directory and renames
    /// over the target, ensuring readers never see a partial file.
    private func writeAtomically<T: Encodable>(_ value: T, to fileName: String) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw StorageError.encodingFailed(fileName: fileName)
        }
        let targetURL = fileURL(for: fileName)
        do {
            try data.write(to: targetURL, options: [.atomic])
        } catch {
            throw StorageError.writeFailed(fileName: fileName)
        }
    }

    /// Delete a file if it exists.
    private func deleteFile(_ fileName: String) throws {
        let url = fileURL(for: fileName)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
