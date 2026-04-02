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

    // MARK: - Pending Unlock Requests

    /// Append a pending unlock request (written by ShieldAction, read by CommandProcessor).
    func appendPendingUnlockRequest(_ request: PendingUnlockRequest) throws

    /// Read all pending unlock requests.
    func readPendingUnlockRequests() -> [PendingUnlockRequest]

    /// Remove a pending unlock request by ID.
    func removePendingUnlockRequest(id: UUID) throws

    // MARK: - Shielded App Name Cache

    /// Cache an app name keyed by its token data (base64).
    func cacheAppName(_ name: String, forTokenKey key: String)

    /// Look up a cached app name by token key.
    func cachedAppName(forTokenKey key: String) -> String?

    /// Read all cached app entries (tokenBase64 → appName).
    func readAllCachedAppNames() -> [String: String]

    /// Replace the entire cached app-name dictionary.
    func writeCachedAppNames(_ cache: [String: String]) throws

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

    // MARK: - Timed Unlock Info

    /// Read the current timed unlock info (penalty-offset unlock).
    func readTimedUnlockInfo() -> TimedUnlockInfo?

    /// Write timed unlock info.
    func writeTimedUnlockInfo(_ info: TimedUnlockInfo) throws

    /// Clear timed unlock info.
    func clearTimedUnlockInfo() throws

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

    // MARK: - App Blocking

    /// Read the app blocking configuration summary.
    func readAppBlockingConfig() -> AppBlockingConfig?

    /// Write the app blocking configuration summary.
    func writeAppBlockingConfig(_ config: AppBlockingConfig) throws

    // MARK: - Active Schedule Profile (child device)

    /// Read the schedule profile assigned to this device (written by child app, read by extension).
    func readActiveScheduleProfile() -> ScheduleProfile?

    /// Write the active schedule profile for extension consumption.
    func writeActiveScheduleProfile(_ profile: ScheduleProfile?) throws

    // MARK: - Self Unlock State

    /// Read the current self-unlock usage state (child device).
    func readSelfUnlockState() -> SelfUnlockState?

    /// Write the self-unlock usage state.
    func writeSelfUnlockState(_ state: SelfUnlockState) throws

    // MARK: - Temporary Allowed Apps

    /// Read all temporary allowed app entries (includes expired; caller should filter).
    func readTemporaryAllowedApps() -> [TemporaryAllowedAppEntry]

    /// Write the full temporary allowed apps list (replaces existing).
    func writeTemporaryAllowedApps(_ entries: [TemporaryAllowedAppEntry]) throws

    // MARK: - App Time Limits

    /// Read per-app time limits (child device).
    func readAppTimeLimits() -> [AppTimeLimit]

    /// Write per-app time limits (replaces existing).
    func writeAppTimeLimits(_ limits: [AppTimeLimit]) throws

    /// Read apps that have exhausted their daily time budget.
    func readTimeLimitExhaustedApps() -> [TimeLimitExhaustedApp]

    /// Write exhausted apps list (replaces existing).
    func writeTimeLimitExhaustedApps(_ apps: [TimeLimitExhaustedApp]) throws

    // MARK: - Last Shielded App

    /// Read the last shielded app (written by ShieldConfiguration, read by ShieldAction).
    func readLastShieldedApp() -> LastShieldedApp?

    /// Write the last shielded app entry.
    func writeLastShieldedApp(_ entry: LastShieldedApp) throws

    // MARK: - Unlock Picker Pending Flag

    /// Read the timestamp when the child last tapped "Ask for More Time".
    /// Written by ShieldAction, read by the main app to auto-show the picker.
    func readUnlockPickerPendingDate() -> Date?

    /// Signal that the child tapped "Ask for More Time" on a shield.
    func writeUnlockPickerPending() throws

    /// Clear the pending flag after the picker has been shown.
    func clearUnlockPickerPending() throws

    // MARK: - Device Restrictions

    /// Read device-level restrictions set by the parent.
    func readDeviceRestrictions() -> DeviceRestrictions?

    /// Write device-level restrictions.
    func writeDeviceRestrictions(_ restrictions: DeviceRestrictions) throws

    // MARK: - Parent Messages

    /// Read all parent messages (includes dismissed; caller should filter).
    func readParentMessages() -> [ParentMessage]

    /// Write the full parent messages list (replaces existing).
    func writeParentMessages(_ messages: [ParentMessage]) throws

    // MARK: - Raw Data

    /// Write raw data for a given key. Pass nil to delete.
    func writeRawData(_ data: Data?, forKey key: String) throws

    /// Read raw data for a given key. Returns nil if not found.
    func readRawData(forKey key: String) -> Data?

    // MARK: - Enforcement DNS Blocking

    /// Domains to DNS-block because their apps are shielded (not in always-allowed list).
    /// Written by main app enforcement, read by VPN tunnel.
    func readEnforcementBlockedDomains() -> Set<String>

    /// Write the set of domains to DNS-block during enforcement.
    func writeEnforcementBlockedDomains(_ domains: Set<String>) throws

    // MARK: - File Pre-creation

    /// Ensure all files that extensions need to modify already exist.
    /// Extensions cannot create new files in the App Group container (silent failure).
    /// The main app MUST call this at startup.
    func ensureSharedFilesExist()
}

// MARK: - Extension-safe snapshot commit

extension SharedStorageProtocol {
    /// Commit a corrected snapshot from an extension (Monitor, Tunnel).
    /// Lightweight alternative to PolicySnapshotStore.commit() that:
    /// - Bumps generation number to avoid staleness rejection
    /// - Updates ExtensionSharedState for cross-process consistency
    /// - Writes the snapshot atomically
    ///
    /// Does NOT record SnapshotTransition history (only main app does).
    @discardableResult
    public func commitCorrectedSnapshot(_ snapshot: PolicySnapshot) throws -> PolicySnapshot {
        // Ensure generation is higher than current to prevent staleness rejection.
        let nextGen: Int64
        if let current = readPolicySnapshot(), snapshot.generation <= current.generation {
            nextGen = current.generation + 1
        } else {
            nextGen = snapshot.generation
        }

        let snap = PolicySnapshot(
            snapshotID: UUID(),
            generation: nextGen,
            createdAt: Date(),
            appliedAt: snapshot.appliedAt,
            source: snapshot.source,
            trigger: snapshot.trigger,
            deviceID: snapshot.deviceID,
            intendedMode: snapshot.intendedMode,
            activeScheduleID: snapshot.activeScheduleID,
            effectivePolicy: snapshot.effectivePolicy,
            temporaryUnlockState: snapshot.temporaryUnlockState,
            authorizationHealth: snapshot.authorizationHealth,
            policyFingerprint: snapshot.policyFingerprint,
            childProfile: snapshot.childProfile
        )
        try writePolicySnapshot(snap)

        // Update extension shared state so all processes see the change.
        let extState = ExtensionSharedState(
            currentMode: snap.effectivePolicy.resolvedMode,
            isTemporaryUnlock: snap.effectivePolicy.isTemporaryUnlock,
            temporaryUnlockExpiresAt: snap.effectivePolicy.temporaryUnlockExpiresAt,
            authorizationAvailable: snap.authorizationHealth?.isAuthorized ?? true,
            enforcementDegraded: snap.authorizationHealth?.enforcementDegraded ?? false,
            policyVersion: snap.effectivePolicy.policyVersion
        )
        try? writeExtensionSharedState(extState)
        return snap
    }
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
