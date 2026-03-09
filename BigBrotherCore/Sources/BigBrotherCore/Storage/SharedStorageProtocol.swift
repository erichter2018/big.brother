import Foundation

/// Typed errors for storage operations.
public enum StorageError: Error, Equatable {
    /// Encoding a value for writing failed.
    case encodingFailed(fileName: String)

    /// Writing encoded data to disk failed.
    case writeFailed(fileName: String)

    /// The file exists but could not be decoded.
    case decodingFailed(fileName: String)

    /// The file exists but contains corrupt or unparseable data.
    case fileCorrupted(fileName: String)

    /// The App Group container URL could not be resolved.
    case containerUnavailable
}

/// Protocol for App Group shared storage.
///
/// The main app and all extensions share an App Group container.
/// This protocol defines the read/write operations for cross-target state.
///
/// Implementation note: All writes must be atomic (temp file + rename)
/// to prevent extensions from reading a half-written file.
public protocol SharedStorageProtocol: Sendable {

    // MARK: - Policy Snapshot

    /// Read the current policy snapshot written by the main app.
    func readPolicySnapshot() -> PolicySnapshot?

    /// Write a new policy snapshot. Called by the main app after policy resolution.
    func writePolicySnapshot(_ snapshot: PolicySnapshot) throws

    // MARK: - Shield Configuration

    /// Read the shield configuration for the ShieldConfiguration extension.
    func readShieldConfiguration() -> ShieldConfig?

    /// Write shield configuration. Called by the main app.
    func writeShieldConfiguration(_ config: ShieldConfig) throws

    // MARK: - Event Log Queue

    /// Append an event log entry. Called by app or extensions.
    func appendEventLog(_ entry: EventLogEntry) throws

    /// Read all pending (un-synced) event logs.
    func readPendingEventLogs() -> [EventLogEntry]

    /// Remove event logs that have been synced to CloudKit.
    func clearSyncedEventLogs(ids: Set<UUID>) throws

    /// Update the upload state of specific event log entries.
    func updateEventUploadState(ids: Set<UUID>, state: EventUploadState) throws

    // MARK: - Processed Commands

    /// IDs of commands already processed by this device.
    /// Used for deduplication across app launches.
    func readProcessedCommandIDs() -> Set<UUID>

    /// Mark a command as processed.
    func markCommandProcessed(_ id: UUID) throws

    /// Prune processed command IDs older than the given date
    /// to prevent unbounded growth.
    func pruneProcessedCommands(olderThan cutoff: Date) throws

    // MARK: - Temporary Unlock State

    /// Read the current temporary unlock state.
    func readTemporaryUnlockState() -> TemporaryUnlockState?

    /// Write temporary unlock state.
    func writeTemporaryUnlockState(_ state: TemporaryUnlockState) throws

    /// Clear temporary unlock state (unlock expired or was cancelled).
    func clearTemporaryUnlockState() throws

    // MARK: - Authorization Health

    /// Read the current authorization health.
    func readAuthorizationHealth() -> AuthorizationHealth?

    /// Write authorization health.
    func writeAuthorizationHealth(_ health: AuthorizationHealth) throws

    // MARK: - Heartbeat Status

    /// Read the heartbeat upload status.
    func readHeartbeatStatus() -> HeartbeatStatus?

    /// Write heartbeat upload status.
    func writeHeartbeatStatus(_ status: HeartbeatStatus) throws

    // MARK: - Extension Shared State

    /// Read the lightweight extension state model.
    func readExtensionSharedState() -> ExtensionSharedState?

    /// Write the extension shared state.
    func writeExtensionSharedState(_ state: ExtensionSharedState) throws

    // MARK: - Diagnostics

    /// Append a diagnostic log entry.
    func appendDiagnosticEntry(_ entry: DiagnosticEntry) throws

    /// Read all diagnostic entries, optionally filtered by category.
    func readDiagnosticEntries(category: DiagnosticCategory?) -> [DiagnosticEntry]

    /// Prune diagnostic entries older than the given date.
    func pruneDiagnosticEntries(olderThan cutoff: Date) throws

    // MARK: - Snapshot History

    /// Read the snapshot transition history buffer.
    func readSnapshotHistory() -> [SnapshotTransition]

    /// Write the snapshot transition history buffer.
    func writeSnapshotHistory(_ history: [SnapshotTransition]) throws
}

/// Configuration for the shield (blocked app) screen.
/// Read by BigBrotherShield extension.
public struct ShieldConfig: Codable, Sendable, Equatable {
    public var title: String
    public var message: String
    public var showRequestButton: Bool

    public init(
        title: String = "App Restricted",
        message: String = "Ask a parent to unlock this app.",
        showRequestButton: Bool = false
    ) {
        self.title = title
        self.message = message
        self.showRequestButton = showRequestButton
    }
}
