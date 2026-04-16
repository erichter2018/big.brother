import CryptoKit
import Foundation

/// Concrete implementation of SharedStorageProtocol using App Group container.
///
/// All writes use atomic file operations (Data.write with .atomic option)
/// to prevent extensions from reading a partially written file.
///
/// ## Thread safety
///
/// Shared across main app, Monitor, Shield, ShieldAction, Tunnel — every
/// process. Claims `@unchecked Sendable` because:
///   1. `lock` (NSLock) guards all read-modify-write sequences on
///      collection-type files (event queue, processed commands, diagnostics).
///   2. `withFileLock(name:body:)` acquires an `flock()` on a sentinel file
///      under the App Group container for cross-process mutual exclusion.
///      Single-process locking via `lock` isn't enough here because multiple
///      processes hit the same files concurrently.
///   3. `encoder` / `decoder` are stateless Foundation types — concurrent
///      reads on `JSONEncoder`/`JSONDecoder` are documented as safe.
///   4. `fileManager` is `FileManager.default`, thread-safe per Apple's
///      documented behavior for read-only queries.
///   5. `containerURL` is an immutable `let`.
///
/// Actor conversion is NOT practical here: every call site (including many
/// synchronous extension entry points like ShieldAction that can't await)
/// would need to go through an async bridge, which the extension lifetimes
/// can't reliably afford. The NSLock + flock pattern is the right tool.
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
        static let appBlockingConfig = "app_blocking_config.json"
        static let activeScheduleProfile = "active_schedule_profile.json"
        static let pendingUnlockRequests = "pending_unlock_requests.json"
        static let shieldedAppNameCache = "shielded_app_name_cache.json"
        static let temporaryAllowedApps = "temporary_allowed_apps.json"
        static let lastShieldedApp = "last_shielded_app.json"
        static let unlockPickerPending = "unlock_picker_pending.json"
        static let timedUnlockInfo = "timed_unlock_info.json"
        static let selfUnlockState = "self_unlock_state.json"
        static let parentMessages = "parent_messages.json"
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

    // NOTE: Policy snapshot and temporary unlock state are NOT encrypted because
    // the Monitor extension needs to read them and cannot reliably access Keychain.
    // They are protected by the OS-level App Group container sandbox instead.
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
        try withFileLock(name: "eventlog.lock") {
            var entries: [EventLogEntry] = read(FileName.eventLogQueue) ?? []
            entries.append(entry)

            // Prune oldest entries if queue exceeds max size
            if entries.count > AppConstants.eventQueueMaxSize {
                let overflow = entries.count - AppConstants.eventQueueMaxSize
                entries.removeFirst(overflow)
            }

            try writeAtomically(entries, to: FileName.eventLogQueue)
        }
    }

    /// Cross-process file lock using POSIX flock().
    /// NSLock only protects within a single process; this coordinates across
    /// main app, Monitor, Tunnel, and ShieldAction extensions.
    ///
    /// - If `open()` fails: runs body without lock (file may not exist yet on first boot
    ///   before `ensureSharedFilesExist()`). Logs a diagnostic warning.
    /// - If `flock()` fails: throws an error. Running without the lock risks a race
    ///   condition between processes, so we refuse rather than silently corrupt.
    private func withFileLock<T>(name: String, body: () throws -> T) throws -> T {
        let lockURL = containerURL.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: lockURL.path) {
            fileManager.createFile(atPath: lockURL.path, contents: nil)
        }
        // Bounded retry on open() failure — first-boot races (file created
        // concurrently, container not yet mounted) usually resolve within a
        // few tens of milliseconds. If it persists, we log a DIAGNOSTIC
        // entry (visible in the parent dashboard, not just DEBUG prints)
        // and proceed unprotected rather than block the caller forever.
        var fd: Int32 = -1
        for attempt in 0..<5 {
            fd = open(lockURL.path, O_RDWR | O_CREAT, 0o666)
            if fd >= 0 { break }
            let wait = useconds_t(20_000 * (1 << attempt)) // 20ms, 40, 80, 160, 320 = ~620ms total
            usleep(wait)
        }
        guard fd >= 0 else {
            // Persistent open() failure — record to the diagnostic log so
            // the parent dashboard surfaces it, then run the body without
            // the lock. This is still a silent race risk, but the
            // alternative (throwing) would block legitimate first-boot
            // setup paths.
            let errnoSnapshot = errno
            let msg = "withFileLock: open() failed for \(name) after 5 retries, errno=\(errnoSnapshot)"
            #if DEBUG
            print("[BigBrother] ⚠️ \(msg) — running unprotected")
            #endif
            try? appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: msg,
                details: "Cross-process file lock acquisition failed; body ran without lock. If this recurs, the App Group container may be misconfigured."
            ))
            return try body()
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            // flock() failed — another process may hold the lock or something is wrong.
            // Do NOT run the body without the lock; that's a silent race condition.
            throw StorageError.fileLockFailed(lockName: name, errno: errno)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
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

    // MARK: - Pending Unlock Requests
    //
    // Single JSON array file, pre-created by the main app.
    // Extensions can MODIFY existing App Group files but cannot CREATE new ones
    // (silent failure on real devices). The main app must call ensureSharedFilesExist()
    // at startup so extensions only ever append to an existing file.

    public func appendPendingUnlockRequest(_ request: PendingUnlockRequest) throws {
        try withFileLock(name: "unlockrequests.lock") {
            var entries: [PendingUnlockRequest] = read(FileName.pendingUnlockRequests) ?? []
            entries.append(request)
            if entries.count > 50 {
                entries = Array(entries.suffix(50))
            }
            try writeAtomically(entries, to: FileName.pendingUnlockRequests)
        }
    }

    public func readPendingUnlockRequests() -> [PendingUnlockRequest] {
        let result: [PendingUnlockRequest] = read(FileName.pendingUnlockRequests) ?? []
        #if DEBUG
        print("[BigBrother] Read \(result.count) pending requests")
        #endif
        return result
    }

    public func removePendingUnlockRequest(id: UUID) throws {
        try withFileLock(name: "unlockrequests.lock") {
            var entries: [PendingUnlockRequest] = read(FileName.pendingUnlockRequests) ?? []
            entries.removeAll { $0.id == id }
            try writeAtomically(entries, to: FileName.pendingUnlockRequests)
        }
    }

    // MARK: - Shielded App Name Cache
    //
    // Single JSON dictionary file, pre-created by the main app.

    public func cacheAppName(_ name: String, forTokenKey key: String) {
        lock.lock()
        defer { lock.unlock() }

        var cache: [String: String] = read(FileName.shieldedAppNameCache) ?? [:]
        cache[key] = name
        if cache.count > 200 {
            cache = Dictionary(uniqueKeysWithValues: Array(cache.suffix(200)))
        }
        try? writeAtomically(cache, to: FileName.shieldedAppNameCache)
    }

    public func cachedAppName(forTokenKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let cache: [String: String]? = read(FileName.shieldedAppNameCache)
        return cache?[key]
    }

    public func readAllCachedAppNames() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return (read(FileName.shieldedAppNameCache) as [String: String]?) ?? [:]
    }

    public func writeCachedAppNames(_ cache: [String: String]) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeAtomically(cache, to: FileName.shieldedAppNameCache)
    }

    // MARK: - Last Shielded App
    //
    // Written by ShieldConfiguration, read by ShieldAction's category handler.
    // Single JSON file, pre-created by the main app.

    public func readLastShieldedApp() -> LastShieldedApp? {
        read(FileName.lastShieldedApp)
    }

    public func writeLastShieldedApp(_ entry: LastShieldedApp) throws {
        try writeAtomically(entry, to: FileName.lastShieldedApp)
    }

    // MARK: - Unlock Picker Pending Flag

    public func readUnlockPickerPendingDate() -> Date? {
        readUnlockPickerPending()?.requestedAt
    }

    public func readUnlockPickerPending() -> UnlockPickerPending? {
        let url = fileURL(for: FileName.unlockPickerPending)
        guard let data = try? Data(contentsOf: url),
              let wrapper = try? decoder.decode(UnlockPickerPending.self, from: data) else {
            return nil
        }
        return wrapper
    }

    public func writeUnlockPickerPending() throws {
        let wrapper = UnlockPickerPending(requestedAt: Date())
        try writeAtomically(wrapper, to: FileName.unlockPickerPending)
    }

    public func writeUnlockPickerPending(appName: String?, bundleID: String?) throws {
        let wrapper = UnlockPickerPending(requestedAt: Date(), appName: appName, bundleID: bundleID)
        try writeAtomically(wrapper, to: FileName.unlockPickerPending)
    }

    public func clearUnlockPickerPending() throws {
        let url = fileURL(for: FileName.unlockPickerPending)
        try "{}".data(using: .utf8)?.write(to: url, options: [.atomic, .noFileProtection])
    }

    // MARK: - Temporary Allowed Apps
    //
    // Single JSON array file, pre-created by the main app.

    public func readTemporaryAllowedApps() -> [TemporaryAllowedAppEntry] {
        guard let entries: [TemporaryAllowedAppEntry] = read(FileName.temporaryAllowedApps), !entries.isEmpty else {
            return []
        }
        // Prune expired entries on read to prevent unbounded file growth.
        let valid = entries.filter(\.isValid)
        if valid.count < entries.count {
            try? writeAtomically(valid, to: FileName.temporaryAllowedApps)
        }
        return valid
    }

    public func writeTemporaryAllowedApps(_ entries: [TemporaryAllowedAppEntry]) throws {
        try writeAtomically(entries, to: FileName.temporaryAllowedApps)
    }

    // MARK: - App Time Limits

    public func readAppTimeLimits() -> [AppTimeLimit] {
        (try? withFileLock(name: "timelimits.lock") {
            (read("app_time_limits.json") as [AppTimeLimit]?) ?? []
        }) ?? []
    }

    public func writeAppTimeLimits(_ limits: [AppTimeLimit]) throws {
        try withFileLock(name: "timelimits.lock") {
            try writeAtomically(limits, to: "app_time_limits.json")
        }
    }

    public func readTimeLimitExhaustedApps() -> [TimeLimitExhaustedApp] {
        (try? withFileLock(name: "timelimits.lock") {
            (read("time_limit_exhausted.json") as [TimeLimitExhaustedApp]?) ?? []
        }) ?? []
    }

    public func writeTimeLimitExhaustedApps(_ apps: [TimeLimitExhaustedApp]) throws {
        try withFileLock(name: "timelimits.lock") {
            // Prune entries older than 7 days to prevent unbounded file growth.
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            let pruned = apps.filter { $0.exhaustedAt > cutoff }
            try writeAtomically(pruned, to: "time_limit_exhausted.json")
        }
    }

    /// Precise per-app usage from DeviceActivityEvent milestones.
    /// Written by Monitor extension, read by heartbeat and parent.
    public func readAppUsageSnapshot() -> AppUsageSnapshot? {
        read("app_usage_snapshot.json")
    }

    public func writeAppUsageSnapshot(_ snapshot: AppUsageSnapshot) throws {
        try writeAtomically(snapshot, to: "app_usage_snapshot.json")
    }

    /// Domains to block at the DNS level when time-limited apps are exhausted.
    /// Written by Monitor/main app, read by VPN tunnel.
    public func readTimeLimitBlockedDomains() -> Set<String> {
        guard let data: Data = readRawData(forKey: "timeLimitBlockedDomains"),
              let domains = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return domains
    }

    public func writeTimeLimitBlockedDomains(_ domains: Set<String>) throws {
        let data = try JSONEncoder().encode(domains)
        try writeRawData(data, forKey: "timeLimitBlockedDomains")
    }

    /// Domains to DNS-block because their apps are shielded (blocked by enforcement).
    /// When device is in restricted/locked mode, web versions of blocked apps are DNS-blocked
    /// so kids can't bypass shield.applications via Safari web apps.
    public func readEnforcementBlockedDomains() -> Set<String> {
        guard let data: Data = readRawData(forKey: "enforcementBlockedDomains") else {
            return [] // File doesn't exist — legitimate empty state.
        }
        guard let domains = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            // File exists but is corrupted — return sentinel that callers can detect.
            // Log for diagnostics.
            try? appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Corrupted enforcementBlockedDomains file (\(data.count) bytes) — DNS blocking may be stale"
            ))
            return [] // Can't recover; callers should use cached value if they have one.
        }
        return domains
    }

    public func writeEnforcementBlockedDomains(_ domains: Set<String>) throws {
        let data = try JSONEncoder().encode(domains)
        try writeRawData(data, forKey: "enforcementBlockedDomains")
    }

    // MARK: - Pre-create Shared Files
    //
    // Extensions cannot create new files in the App Group container (silent failure).
    // The main app MUST call this at startup to ensure all files that extensions
    // need to modify already exist.

    public func ensureSharedFilesExist() {
        // Set .none protection on the container directory itself so extensions
        // can always access files even in background/locked contexts.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: containerURL.path
        )

        // All files that extensions need to read or write.
        // Pre-create if missing, and fix protection class on ALL existing files.
        let allExtensionFiles: [(name: String, emptyContent: String)] = [
            (FileName.pendingUnlockRequests, "[]"),
            (FileName.temporaryAllowedApps, "[]"),
            (FileName.shieldedAppNameCache, "{}"),
            // Pre-create with valid LastShieldedApp JSON so ShieldConfiguration can
            // overwrite it. Extensions cannot CREATE new files in App Group (silent
            // failure), they can only MODIFY existing ones.
            (FileName.lastShieldedApp, "{\"appName\":\"\",\"tokenBase64\":\"none\",\"cachedAt\":0}"),
            (FileName.unlockPickerPending, "{}"),
            (FileName.eventLogQueue, "[]"),
            (FileName.diagnosticsLog, "[]"),
            (FileName.extensionSharedState, "{}"),
            (FileName.shieldConfig, "{}"),
            (FileName.policySnapshot, "{}"),
            (FileName.parentMessages, "[]"),
            ("app_time_limits.json", "[]"),
            ("time_limit_exhausted.json", "[]"),
            // Pre-create so Monitor's `writeAppUsageSnapshot(_:)` at line 368
            // has a file to modify. iOS App Group rules let extensions modify
            // existing files but NOT create new ones — without this pre-create
            // every Monitor milestone write silently failed on real devices,
            // keeping `appUsageMinutes` empty even when time limits fired.
            // Stub is a valid AppUsageSnapshot with today's date and empty map.
            ("app_usage_snapshot.json", "{\"dateString\":\"1970-01-01\",\"usageByFingerprint\":{}}"),
        ]

        for (name, emptyContent) in allExtensionFiles {
            let url = fileURL(for: name)
            if fileManager.fileExists(atPath: url.path) {
                // Fix protection class on existing files — extensions can't read
                // files with the default completeFileProtection.
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.none],
                    ofItemAtPath: url.path
                )
            } else if !emptyContent.isEmpty {
                // Pre-create with no protection.
                try? emptyContent.data(using: .utf8)?.write(to: url, options: [.atomic, .noFileProtection])
                #if DEBUG
                print("[BigBrother] Pre-created \(name)")
                #endif
            }
        }

        // Also fix protection on raw data files that extensions read.
        let rawFiles = ["cachedEnrollmentIDs", "allowedAppTokens", "temporaryAllowedApps"]
        for key in rawFiles {
            let url = fileURL(for: "raw_\(key).bin")
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.none],
                    ofItemAtPath: url.path
                )
            }
        }

        #if DEBUG
        // Verify protection classes.
        if let files = try? fileManager.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" || file.pathExtension == "bin" {
                let attrs = try? fileManager.attributesOfItem(atPath: file.path)
                let protection = attrs?[.protectionKey] as? FileProtectionType
                print("[BigBrother] \(file.lastPathComponent): protection=\(protection?.rawValue ?? "nil")")
            }
        }
        #endif
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
        try withFileLock(name: "commands.lock") {
            var entries: [ProcessedCommandEntry] = read(FileName.processedCommands) ?? []
            guard !entries.contains(where: { $0.id == id }) else { return }
            entries.append(ProcessedCommandEntry(id: id, processedAt: Date()))
            try writeAtomically(entries, to: FileName.processedCommands)
        }
    }

    public func pruneProcessedCommands(olderThan cutoff: Date) throws {
        try withFileLock(name: "commands.lock") {
            var entries: [ProcessedCommandEntry] = read(FileName.processedCommands) ?? []
            entries.removeAll { $0.processedAt < cutoff }
            try writeAtomically(entries, to: FileName.processedCommands)
        }
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

    // MARK: - Timed Unlock Info

    public func readTimedUnlockInfo() -> TimedUnlockInfo? {
        read(FileName.timedUnlockInfo)
    }

    public func writeTimedUnlockInfo(_ info: TimedUnlockInfo) throws {
        try writeAtomically(info, to: FileName.timedUnlockInfo)
    }

    public func clearTimedUnlockInfo() throws {
        try deleteFile(FileName.timedUnlockInfo)
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

    // MARK: - App Blocking

    public func readAppBlockingConfig() -> AppBlockingConfig? {
        read(FileName.appBlockingConfig)
    }

    public func writeAppBlockingConfig(_ config: AppBlockingConfig) throws {
        try writeAtomically(config, to: FileName.appBlockingConfig)
    }

    // MARK: - Active Schedule Profile

    public func readActiveScheduleProfile() -> ScheduleProfile? {
        read(FileName.activeScheduleProfile)
    }

    public func writeActiveScheduleProfile(_ profile: ScheduleProfile?) throws {
        if let profile {
            try writeAtomically(profile, to: FileName.activeScheduleProfile)
        } else {
            try deleteFile(FileName.activeScheduleProfile)
        }
    }

    // MARK: - Self Unlock State

    public func readSelfUnlockState() -> SelfUnlockState? {
        read(FileName.selfUnlockState)
    }

    public func writeSelfUnlockState(_ state: SelfUnlockState) throws {
        try writeAtomically(state, to: FileName.selfUnlockState)
    }

    // MARK: - Parent Messages

    public func readParentMessages() -> [ParentMessage] {
        (read(FileName.parentMessages) as [ParentMessage]?) ?? []
    }

    public func writeParentMessages(_ messages: [ParentMessage]) throws {
        try writeAtomically(messages, to: FileName.parentMessages)
    }

    // MARK: - Device Restrictions

    public func readDeviceRestrictions() -> DeviceRestrictions? {
        read("device_restrictions.json")
    }

    public func writeDeviceRestrictions(_ restrictions: DeviceRestrictions) throws {
        try writeAtomically(restrictions, to: "device_restrictions.json")
    }

    // MARK: - Raw Data

    public func writeRawData(_ data: Data?, forKey key: String) throws {
        let fileName = "raw_\(key).bin"
        if let data {
            let targetURL = fileURL(for: fileName)
            do {
                try data.write(to: targetURL, options: [.atomic, .noFileProtection])
            } catch {
                throw StorageError.writeFailed(fileName: fileName)
            }
        } else {
            try deleteFile(fileName)
        }
    }

    public func readRawData(forKey key: String) -> Data? {
        let fileName = "raw_\(key).bin"
        let url = fileURL(for: fileName)
        return try? Data(contentsOf: url)
    }

    // MARK: - Encrypted Storage

    /// Write an Encodable value encrypted with the App Group encryption key.
    /// Falls back to unencrypted write if Keychain is unavailable (extension context).
    /// The fallback is LOGGED explicitly — silent plaintext writes on a device
    /// where Keychain should be available would be a real security regression
    /// we want visibility into, not just a shrug.
    private func writeEncrypted<T: Encodable>(_ value: T, to fileName: String) throws {
        let plaintext: Data
        do {
            plaintext = try encoder.encode(value)
        } catch {
            throw StorageError.encodingFailed(fileName: fileName)
        }

        let keychain = KeychainManager()
        if let encrypted = try? AppGroupEncryption.encrypt(plaintext, keychain: keychain) {
            try writeRawData(encrypted, toFile: fileName)
        } else {
            // Fallback: write unencrypted (extension may not have Keychain access).
            // Log every fallback so we can see in the diagnostic stream if this
            // is happening in the main app (where Keychain SHOULD work) vs
            // extensions (where it legitimately may not).
            try? appendDiagnosticEntry(DiagnosticEntry(
                category: .auth,
                message: "AppGroupEncryption unavailable — wrote \(fileName) as plaintext",
                details: "Keychain access failed. Expected in extensions; unexpected in main app. If seen in main app logs, auth keychain state may be corrupt."
            ))
            try writeRawData(plaintext, toFile: fileName)
        }
    }

    /// Read an encrypted Decodable value. Falls back to unencrypted if decryption fails
    /// (backward compatibility for files written before encryption was enabled).
    private func readEncrypted<T: Decodable>(_ fileName: String) -> T? {
        guard let data = readRawFile(fileName) else { return nil }

        // Try decrypting first (new encrypted format)
        let keychain = KeychainManager()
        if let decrypted = AppGroupEncryption.decrypt(data, keychain: keychain),
           let value = try? decoder.decode(T.self, from: decrypted) {
            return value
        }

        // Fall back to plain JSON (pre-encryption data or extension-written)
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - Private Helpers

    /// Write raw Data atomically with no file protection.
    private func writeRawData(_ data: Data, toFile fileName: String) throws {
        let targetURL = fileURL(for: fileName)
        do {
            try data.write(to: targetURL, options: [.atomic, .noFileProtection])
        } catch {
            throw StorageError.writeFailed(fileName: fileName)
        }
    }

    /// Read raw Data from a file. Returns nil if the file does not exist.
    private func readRawFile(_ fileName: String) -> Data? {
        let url = fileURL(for: fileName)
        return try? Data(contentsOf: url)
    }

    private func fileURL(for name: String) -> URL {
        containerURL.appendingPathComponent(name)
    }

    /// Read and decode a JSON file. Returns nil if the file does not exist.
    /// Logs a warning if the file exists but decoding fails (corruption).
    private func read<T: Decodable>(_ fileName: String) -> T? {
        let url = fileURL(for: fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
            // `ensureSharedFilesExist()` pre-creates extension-bound files
            // with stub content (`{}` or `[]`) so extensions — which can't
            // CREATE files in the App Group, only modify existing ones —
            // always have something to write to. Before the first real
            // write, decoding that stub against a non-trivial struct fails
            // every read, which is expected startup state, not corruption.
            // Only warn when the file has actual content we failed to parse.
            if data.count > 2 {
                print("[BigBrother] WARNING: Corrupted file \(fileName) (\(data.count) bytes): \(error.localizedDescription)")
            }
            #endif
            return nil
        }
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

    /// Write data atomically with no file protection.
    /// Uses .noFileProtection so extensions can write even when the device is locked
    /// (the default completeFileProtection can block extension writes).
    private func writeAtomically<T: Encodable>(_ value: T, to fileName: String) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw StorageError.encodingFailed(fileName: fileName)
        }
        let targetURL = fileURL(for: fileName)
        do {
            try data.write(to: targetURL, options: [.atomic, .noFileProtection])
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

    /// Pre-create a file so the extension can open it via FileHandle.
    /// Call from the main app on launch.
    public func ensureFileExists(_ fileName: String) {
        let url = fileURL(for: fileName)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: Data("{}".utf8))
        }
    }

    /// File name constant exposed for extension use.
    public static let shieldedAppNameCacheFileName = FileName.shieldedAppNameCache
}
