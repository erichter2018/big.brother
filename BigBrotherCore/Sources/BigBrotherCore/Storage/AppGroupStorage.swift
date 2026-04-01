import CryptoKit
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

    // MARK: - Pending Unlock Requests
    //
    // Single JSON array file, pre-created by the main app.
    // Extensions can MODIFY existing App Group files but cannot CREATE new ones
    // (silent failure on real devices). The main app must call ensureSharedFilesExist()
    // at startup so extensions only ever append to an existing file.

    public func appendPendingUnlockRequest(_ request: PendingUnlockRequest) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries: [PendingUnlockRequest] = read(FileName.pendingUnlockRequests) ?? []
        entries.append(request)
        if entries.count > 50 {
            entries = Array(entries.suffix(50))
        }
        try writeAtomically(entries, to: FileName.pendingUnlockRequests)
    }

    public func readPendingUnlockRequests() -> [PendingUnlockRequest] {
        let result: [PendingUnlockRequest] = read(FileName.pendingUnlockRequests) ?? []
        #if DEBUG
        print("[BigBrother] Read \(result.count) pending requests")
        #endif
        return result
    }

    public func removePendingUnlockRequest(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries: [PendingUnlockRequest] = read(FileName.pendingUnlockRequests) ?? []
        entries.removeAll { $0.id == id }
        try writeAtomically(entries, to: FileName.pendingUnlockRequests)
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
        let url = fileURL(for: FileName.unlockPickerPending)
        guard let data = try? Data(contentsOf: url),
              let wrapper = try? decoder.decode(UnlockPickerPending.self, from: data) else {
            return nil
        }
        return wrapper.requestedAt
    }

    public func writeUnlockPickerPending() throws {
        let wrapper = UnlockPickerPending(requestedAt: Date())
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
        (read(FileName.temporaryAllowedApps) as [TemporaryAllowedAppEntry]?) ?? []
    }

    public func writeTemporaryAllowedApps(_ entries: [TemporaryAllowedAppEntry]) throws {
        try writeAtomically(entries, to: FileName.temporaryAllowedApps)
    }

    // MARK: - App Time Limits

    public func readAppTimeLimits() -> [AppTimeLimit] {
        (read("app_time_limits.json") as [AppTimeLimit]?) ?? []
    }

    public func writeAppTimeLimits(_ limits: [AppTimeLimit]) throws {
        try writeAtomically(limits, to: "app_time_limits.json")
    }

    public func readTimeLimitExhaustedApps() -> [TimeLimitExhaustedApp] {
        (read("time_limit_exhausted.json") as [TimeLimitExhaustedApp]?) ?? []
    }

    public func writeTimeLimitExhaustedApps(_ apps: [TimeLimitExhaustedApp]) throws {
        try writeAtomically(apps, to: "time_limit_exhausted.json")
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
            // Fallback: write unencrypted (extension may not have Keychain access)
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
            print("[BigBrother] WARNING: Corrupted file \(fileName) (\(data.count) bytes): \(error.localizedDescription)")
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
