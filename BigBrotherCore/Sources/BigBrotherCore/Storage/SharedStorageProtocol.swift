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

    /// POSIX flock() failed — another process may hold the lock or the system is under pressure.
    /// Running the body without the lock would risk cross-process data corruption.
    case fileLockFailed(lockName: String, errno: Int32)
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

    /// Read precise per-app usage from DeviceActivityEvent milestones.
    func readAppUsageSnapshot() -> AppUsageSnapshot?

    /// Write per-app usage snapshot.
    func writeAppUsageSnapshot(_ snapshot: AppUsageSnapshot) throws

    // MARK: - Last Shielded App

    /// Read the last shielded app (written by ShieldConfiguration, read by ShieldAction).
    func readLastShieldedApp() -> LastShieldedApp?

    /// Write the last shielded app entry.
    func writeLastShieldedApp(_ entry: LastShieldedApp) throws

    // MARK: - Unlock Picker Pending Flag

    /// Read the timestamp when the child last tapped "Ask for More Time".
    /// Written by ShieldAction, read by the main app to auto-show the picker.
    func readUnlockPickerPendingDate() -> Date?

    /// Read the full pending state (timestamp + optional app name/bundle).
    /// The optional name comes from ShieldConfiguration's Darwin notification
    /// bridge, hinting which app the kid was trying to open.
    func readUnlockPickerPending() -> UnlockPickerPending?

    /// Signal that the child tapped "Ask for More Time" on a shield.
    func writeUnlockPickerPending() throws

    /// Signal that the child tapped "Ask for access" with a known app name.
    /// Used by ShieldAction when iOS provided no token but a name was
    /// resolved via the Darwin notification bridge.
    func writeUnlockPickerPending(appName: String?, bundleID: String?) throws

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

    /// Read time-limit blocked domains.
    func readTimeLimitBlockedDomains() -> Set<String>

    /// Write the set of domains to DNS-block for exhausted time limits.
    func writeTimeLimitBlockedDomains(_ domains: Set<String>) throws

    // MARK: - File Pre-creation

    /// Ensure all files that extensions need to modify already exist.
    /// Extensions cannot create new files in the App Group container (silent failure).
    /// The main app MUST call this at startup.
    func ensureSharedFilesExist()
}

// MARK: - Extension-safe snapshot commit

/// File-based lock for cross-process snapshot commit coordination.
/// NSLock only works within a single process; this uses POSIX flock()
/// to coordinate between main app, Monitor, and Tunnel.
///
/// - If `open()` fails: runs body without lock (lock file may not exist yet).
/// - If `flock()` fails: throws an error to avoid silent race conditions.
enum SnapshotFileLock {
    private static let lockFileName = "snapshot_commit.lock"

    static func withLock<T>(in groupID: String = AppConstants.appGroupIdentifier, body: () throws -> T) throws -> T {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return try body() // Fallback: run without lock if container unavailable
        }
        let lockURL = container.appendingPathComponent(lockFileName)
        // Create lock file if needed
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        }
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o666)
        guard fd >= 0 else {
            // Lock file can't be opened — may be first boot.
            #if DEBUG
            print("[BigBrother] SnapshotFileLock: open() failed, errno=\(errno) — running unprotected")
            #endif
            return try body()
        }
        defer { close(fd) }
        // Blocking exclusive lock — do NOT fall through on failure
        guard flock(fd, LOCK_EX) == 0 else {
            throw StorageError.fileLockFailed(lockName: lockFileName, errno: errno)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

extension SharedStorageProtocol {
    /// Commit a corrected snapshot from an extension (Monitor, Tunnel).
    /// Uses file-based locking to prevent cross-process generation collisions.
    /// Lightweight alternative to PolicySnapshotStore.commit() that:
    /// - Bumps generation number to avoid staleness rejection
    /// - Updates ExtensionSharedState for cross-process consistency
    /// - Writes the snapshot atomically
    ///
    /// Does NOT record SnapshotTransition history (only main app does).
    @discardableResult
    public func commitCorrectedSnapshot(_ snapshot: PolicySnapshot) throws -> PolicySnapshot {
        try SnapshotFileLock.withLock {
            let current = readPolicySnapshot()

            // b462: record a SnapshotTransition entry on every corrected
            // commit. Previously `commitCorrectedSnapshot` bypassed the
            // history log — which meant the tunnel's dead-app CK command
            // path, Monitor's writeCorrectedSnapshot, HeartbeatService's
            // reconcile, and AppLaunchRestorer could all flip the
            // snapshot's resolvedMode (including to .lockedDown) without
            // leaving any breadcrumb. A parent debugging "my kid lost
            // internet and I don't know why" would see a transition log
            // that stopped hours before the actual bad commit. Writing a
            // transition here closes that visibility gap — no matter which
            // process wrote the snapshot, there's a row in history.
            if let current {
                let transition = SnapshotTransition.between(from: current, to: snapshot)
                var history = readSnapshotHistory()
                history.append(transition)
                if history.count > AppConstants.snapshotHistoryMaxEntries {
                    let overflow = history.count - AppConstants.snapshotHistoryMaxEntries
                    history.removeFirst(overflow)
                }
                try? writeSnapshotHistory(history)
            }

            // Ensure generation is higher than current to prevent staleness rejection.
            let nextGen: Int64
            if let current, snapshot.generation <= current.generation {
                nextGen = current.generation + 1
            } else {
                nextGen = snapshot.generation
            }

            // Preserve authority: if the incoming snapshot has nil controlAuthority
            // (callers like Monitor/HeartbeatService that build EffectivePolicy manually),
            // carry forward the existing snapshot's authority so we don't lose it.
            let finalPolicy: EffectivePolicy
            if snapshot.effectivePolicy.controlAuthority == nil,
               let existingAuthority = current?.effectivePolicy.controlAuthority {
                finalPolicy = EffectivePolicy(
                    resolvedMode: snapshot.effectivePolicy.resolvedMode,
                    controlAuthority: existingAuthority,
                    isTemporaryUnlock: snapshot.effectivePolicy.isTemporaryUnlock,
                    temporaryUnlockExpiresAt: snapshot.effectivePolicy.temporaryUnlockExpiresAt,
                    shieldedCategoriesData: snapshot.effectivePolicy.shieldedCategoriesData,
                    allowedAppTokensData: snapshot.effectivePolicy.allowedAppTokensData,
                    deviceRestrictions: snapshot.effectivePolicy.deviceRestrictions,
                    warnings: snapshot.effectivePolicy.warnings,
                    policyVersion: snapshot.effectivePolicy.policyVersion,
                    resolvedAt: snapshot.effectivePolicy.resolvedAt
                )
            } else {
                finalPolicy = snapshot.effectivePolicy
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
                effectivePolicy: finalPolicy,
                temporaryUnlockState: snapshot.temporaryUnlockState,
                authorizationHealth: snapshot.authorizationHealth,
                policyFingerprint: snapshot.policyFingerprint,
                childProfile: snapshot.childProfile
            )
            try writePolicySnapshot(snap)

            // Derive scheduleDrivenMode from the snapshot's control authority.
            UserDefaults.appGroup?
                .set(snap.effectivePolicy.effectiveAuthority == .schedule, forKey: "scheduleDrivenMode")

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
