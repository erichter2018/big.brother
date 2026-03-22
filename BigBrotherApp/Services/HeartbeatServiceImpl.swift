import Foundation
import CloudKit
import BigBrotherCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ManagedSettings)
import ManagedSettings
#endif

/// Concrete heartbeat service for child devices.
///
/// Periodically sends DeviceHeartbeat records to CloudKit using an upsert pattern
/// (one record per device, updated in place). Uses HeartbeatStatus for backoff
/// on failure and deduplication of recent sends.
final class HeartbeatServiceImpl: HeartbeatServiceProtocol {

    private let cloudKit: any CloudKitServiceProtocol
    private let keychain: any KeychainProtocol
    private let storage: any SharedStorageProtocol
    private let enforcement: (any EnforcementServiceProtocol)?

    private var timer: Timer?
    private var extensionCheckTimer: Timer?
    private let interval: TimeInterval

    /// Called after a successful heartbeat send — piggyback command processing
    /// since the device is clearly online.
    var onHeartbeatSent: (() -> Void)?

    /// Monotonically increasing sequence number for this app launch.
    /// Persisted across heartbeats within a session; resets on app relaunch.
    private var seqCounter: Int64 = 0

    init(
        cloudKit: any CloudKitServiceProtocol,
        keychain: any KeychainProtocol = KeychainManager(),
        storage: any SharedStorageProtocol = AppGroupStorage(),
        enforcement: (any EnforcementServiceProtocol)?,
        interval: TimeInterval = AppConstants.heartbeatIntervalSeconds
    ) {
        self.cloudKit = cloudKit
        self.keychain = keychain
        self.storage = storage
        self.enforcement = enforcement
        self.interval = interval

        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }

    // MARK: - HeartbeatServiceProtocol

    func startHeartbeat() {
        stopHeartbeat()
        let hbTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                try? await self.sendNow(force: self.checkExtensionHeartbeatRequest())
            }
        }
        RunLoop.main.add(hbTimer, forMode: .common)
        timer = hbTimer
        // Also check more frequently (every 30s) for extension-requested heartbeats.
        let extTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.checkExtensionHeartbeatRequest() else { return }
            Task { try? await self.sendNow(force: true) }
        }
        RunLoop.main.add(extTimer, forMode: .common)
        extensionCheckTimer = extTimer
        // Fire immediately on start.
        Task { try? await sendNow(force: false) }
    }

    func stopHeartbeat() {
        timer?.invalidate()
        timer = nil
        extensionCheckTimer?.invalidate()
        extensionCheckTimer = nil
    }

    /// Check if the Monitor extension requested a heartbeat via App Group flag.
    /// Always clears the flag to prove liveness (prevents false force-close detection).
    /// Returns true only for recent requests (< 5 min) to trigger a forced heartbeat send.
    private func checkExtensionHeartbeatRequest() -> Bool {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let requestedAt = defaults?.double(forKey: "extensionHeartbeatRequestedAt")
        guard let requestedAt, requestedAt > 0 else { return false }
        let age = Date().timeIntervalSince1970 - requestedAt
        // ALWAYS clear the flag — this proves the main app is alive and prevents
        // the Monitor's isAppForceClosed() from triggering a false positive when
        // the app was merely suspended by iOS (e.g., during a resource-intensive game).
        defaults?.removeObject(forKey: "extensionHeartbeatRequestedAt")
        // Only trigger a forced heartbeat send for recent requests.
        guard age < 300 else {
            #if DEBUG
            print("[BigBrother] Extension heartbeat flag cleared (stale: \(Int(age))s ago)")
            #endif
            return false
        }
        #if DEBUG
        print("[BigBrother] Extension requested heartbeat \(Int(age))s ago — sending")
        #endif
        return true
    }

    func sendNow(force: Bool = false) async throws {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        // Check backoff and dedup via HeartbeatStatus (skip if forced).
        let status = storage.readHeartbeatStatus() ?? .initial

        if !force {
            guard status.shouldRetry(
                baseInterval: AppConstants.heartbeatRetryBaseSeconds
            ) else { return }

            guard !status.wasRecentlySent(
                within: AppConstants.heartbeatRecentWindow
            ) else { return }
        }

        // Record attempt.
        let attemptStatus = status.recordingAttempt()
        try? storage.writeHeartbeatStatus(attemptStatus)

        let snapshot = storage.readPolicySnapshot()
        // Determine current mode from multiple sources, in priority order:
        // 1. ExtensionSharedState (Monitor writes this on schedule transitions)
        // 2. PolicySnapshot (ground truth after command processing)
        // 3. Schedule profile (direct check — catches cases where both are stale)
        //
        // Note: PolicySnapshot MUST take priority over schedule profile because
        // a parent command (e.g., temporaryUnlock) overrides the schedule.
        // The schedule would report .dailyMode during a locked period even though
        // the snapshot says .unlocked from the parent's command.
        let extState = storage.readExtensionSharedState()
        let currentMode: LockMode
        if let ext = extState, ext.writtenAt > (snapshot?.createdAt ?? .distantPast) {
            currentMode = ext.currentMode
        } else if let snap = snapshot {
            currentMode = snap.effectivePolicy.resolvedMode
        } else if let profile = storage.readActiveScheduleProfile() {
            currentMode = profile.resolvedMode(at: Date())
        } else {
            currentMode = .unlocked
        }
        let policyVersion = snapshot?.effectivePolicy.policyVersion ?? 0
        let tempUnlockState: TemporaryUnlockState? = {
            // Only report if the device is actually unlocked.
            // The TemporaryUnlockState file may linger after a lock command.
            guard currentMode == .unlocked,
                  let state = storage.readTemporaryUnlockState(),
                  state.expiresAt > Date() else { return nil }
            return state
        }()
        let tempUnlockExpiry = tempUnlockState?.expiresAt

        let blockingConfig = storage.readAppBlockingConfig()
        let cachedAppNames = Self.discoveredAppNames(from: storage)
        let allowedNames = Self.resolvedAllowedAppNames(from: storage)
        let allowedTokenCount = Self.rawAllowedAppTokenCount(from: storage)
        let tempAllowedNames = Self.resolvedTemporaryAllowedAppNames(from: storage)

        let selfUnlocksUsed: Int? = {
            guard let state = storage.readSelfUnlockState() else { return nil }
            let today = SelfUnlockState.todayDateString()
            if state.date != today {
                // Persist the reset so other readers see the updated state.
                let reset = state.resettingIfNeeded(currentDate: today)
                try? storage.writeSelfUnlockState(reset)
                return 0
            }
            return state.usedCount
        }()

        seqCounter += 1
        let ckStatus = await Self.cloudKitAccountStatus()

        let heartbeat = DeviceHeartbeat(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            currentMode: currentMode,
            policyVersion: policyVersion,
            familyControlsAuthorized: enforcement?.authorizationStatus == .authorized,
            batteryLevel: Self.batteryLevel,
            isCharging: Self.isCharging,
            appBlockingConfigured: blockingConfig?.isConfigured,
            blockedCategoryCount: blockingConfig?.blockedCategoryCount,
            blockedAppCount: cachedAppNames.isEmpty ? blockingConfig?.allowedAppCount : cachedAppNames.count,
            blockedAppNames: cachedAppNames.isEmpty
                ? (blockingConfig?.blockedAppNames.isEmpty == false ? blockingConfig?.blockedAppNames : nil)
                : cachedAppNames,
            blockedCategoryNames: blockingConfig?.blockedCategoryNames.isEmpty == false ? blockingConfig?.blockedCategoryNames : nil,
            installID: enrollment.installID,
            heartbeatSeq: seqCounter,
            cloudKitStatus: ckStatus,
            allowedAppNames: allowedNames.isEmpty ? nil : allowedNames,
            allowedAppCount: allowedTokenCount > 0 ? allowedTokenCount : nil,
            temporaryAllowedAppNames: tempAllowedNames.isEmpty ? nil : tempAllowedNames,
            temporaryUnlockExpiresAt: tempUnlockExpiry,
            isChildAuthorization: UserDefaults.standard.string(forKey: "fr.bigbrother.authorizationType") == "child",
            availableDiskSpace: Self.availableDiskSpace,
            totalDiskSpace: Self.totalDiskSpace,
            selfUnlocksUsedToday: selfUnlocksUsed,
            temporaryUnlockOrigin: tempUnlockState?.origin,
            osVersion: Self.currentOSVersion,
            modelIdentifier: Self.currentModelIdentifier,
            appBuildNumber: AppConstants.appBuildNumber,
            enforcementError: Self.lastEnforcementError(from: storage),
            activeScheduleWindowName: Self.activeScheduleWindowName(from: storage),
            lastCommandProcessedAt: Self.lastCommandProcessedAt(from: storage),
            monitorLastActiveAt: Self.monitorLastActiveAt()
        )

        do {
            try await cloudKit.sendHeartbeat(heartbeat)

            let successStatus = attemptStatus.recordingSuccess()
            try? storage.writeHeartbeatStatus(successStatus)

            // Record successful heartbeat timestamp so the Monitor can distinguish
            // between a truly force-closed app and one merely suspended by iOS.
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "lastHeartbeatSentAt")

            // Update device record with current OS version + model if changed.
            await updateDeviceRecordIfNeeded(enrollment: enrollment)

            // Safety net: reconcile enforcement on every successful heartbeat.
            reconcileEnforcement()

            // Process commands — device is online if heartbeat succeeded.
            onHeartbeatSent?()
        } catch {
            let failureStatus = attemptStatus.recordingFailure(reason: error.localizedDescription)
            try? storage.writeHeartbeatStatus(failureStatus)

            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .heartbeat,
                message: "Heartbeat send failed",
                details: "Consecutive failures: \(failureStatus.consecutiveFailures), reason: \(error.localizedDescription)"
            ))
            throw error
        }
    }

    // MARK: - Enforcement Reconciliation

    /// Re-apply enforcement as a safety net after each heartbeat.
    /// Skips during schedule-managed windows (free or essential) to avoid fighting the monitor extension.
    private func reconcileEnforcement() {
        guard let enforcement else { return }
        // Don't re-enforce during schedule-managed windows — Monitor handles this.
        if let profile = storage.readActiveScheduleProfile() {
            let scheduleMode = profile.resolvedMode(at: Date())
            if scheduleMode != profile.lockedMode {
                // In a schedule-managed window (free or essential) — Monitor handles this.
                return
            }
        }
        guard let snapshot = storage.readPolicySnapshot() else { return }
        try? enforcement.apply(snapshot.effectivePolicy)
    }

    // MARK: - Device Info

    private static var batteryLevel: Double? {
        #if canImport(UIKit)
        let level = UIDevice.current.batteryLevel
        // UIDevice.batteryLevel rounds to 5% increments.
        // Return nil if monitoring isn't available (-1.0).
        guard level >= 0 else { return nil }
        return Double(level)
        #else
        return nil
        #endif
    }

    private static var isCharging: Bool? {
        #if canImport(UIKit)
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        return nil
        #endif
    }

    private static var availableDiskSpace: Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return bytes
    }

    private static var totalDiskSpace: Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let bytes = values.volumeTotalCapacity else {
            return nil
        }
        return Int64(bytes)
    }

    private static var currentOSVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    private static var currentModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }

    private static func cloudKitAccountStatus() async -> String {
        do {
            let status = try await CKContainer.default().accountStatus()
            switch status {
            case .available: return "available"
            case .noAccount: return "noAccount"
            case .restricted: return "restricted"
            case .couldNotDetermine: return "couldNotDetermine"
            case .temporarilyUnavailable: return "temporarilyUnavailable"
            @unknown default: return "unknown"
            }
        } catch {
            return "error"
        }
    }

    /// Resolve names for permanently allowed apps using the name cache.
    /// Raw count of permanently allowed app tokens (no name resolution needed).
    private static func rawAllowedAppTokenCount(from storage: any SharedStorageProtocol) -> Int {
        #if canImport(ManagedSettings)
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
            return tokens.count
        }
        #endif
        return 0
    }

    /// Resolve names for allowed apps. Uses cached names when available,
    /// falls back to "App N" placeholders so the count is always accurate.
    private static func resolvedAllowedAppNames(from storage: any SharedStorageProtocol) -> [String] {
        let cache = storage.readAllCachedAppNames()
        var names: [String] = []

        #if canImport(ManagedSettings)
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
            var index = 1
            for token in tokens {
                var resolved: String?
                if let tokenData = try? JSONEncoder().encode(token) {
                    let key = tokenData.base64EncodedString()
                    if let name = cache[key], isUsefulAppName(name) {
                        resolved = name
                    }
                }
                names.append(resolved ?? "App \(index)")
                index += 1
            }
        }
        #endif

        return names.sorted()
    }

    /// Resolve names for temporarily allowed apps (non-expired).
    private static func resolvedTemporaryAllowedAppNames(from storage: any SharedStorageProtocol) -> [String] {
        let entries = storage.readTemporaryAllowedApps()
        let cache = storage.readAllCachedAppNames()
        return entries.filter(\.isValid).compactMap { entry -> String? in
            let key = entry.tokenData.base64EncodedString()
            if let cachedName = cache[key], isUsefulAppName(cachedName) {
                return cachedName
            }
            return isUsefulAppName(entry.appName) ? entry.appName : nil
        }.sorted()
    }

    private static func discoveredAppNames(from storage: any SharedStorageProtocol) -> [String] {
        let names = storage.readAllCachedAppNames().values
            .filter(isUsefulAppName(_:))
        let unique = Set(names)
        return unique.sorted()
    }

    /// Update the BBChildDevice record in CloudKit with current OS version and model
    /// if they've changed since enrollment (or last update).
    /// Only touches osVersion and modelIdentifier — does NOT use saveDevice() to avoid
    /// overwriting parent-set fields (scheduleProfileID, penaltySeconds, etc.).
    private func updateDeviceRecordIfNeeded(enrollment: ChildEnrollmentState) async {
        let osVersion = Self.currentOSVersion
        let model = Self.currentModelIdentifier
        let key = "lastReportedDeviceInfo"
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
        let lastReported = defaults.string(forKey: key)
        let current = "\(osVersion)|\(model)"
        guard lastReported != current else { return }

        do {
            try await cloudKit.updateDeviceFields(
                deviceID: enrollment.deviceID,
                fields: [
                    CKFieldName.osVersion: osVersion as CKRecordValue,
                    CKFieldName.modelIdentifier: model as CKRecordValue
                ]
            )
            defaults.set(current, forKey: key)
            #if DEBUG
            print("[BigBrother] Updated device record: iOS \(osVersion), model \(model)")
            #endif
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to update device record: \(error.localizedDescription)")
            #endif
        }
    }

    private static func lastEnforcementError(from storage: any SharedStorageProtocol) -> String? {
        let entries = storage.readDiagnosticEntries(category: .enforcement)
        guard let last = entries.last else { return nil }
        let isFailed = last.message.contains("failed") || last.message.contains("Failed")
        return isFailed ? last.message : nil
    }

    private static func activeScheduleWindowName(from storage: any SharedStorageProtocol) -> String? {
        guard let profile = storage.readActiveScheduleProfile() else { return nil }
        let now = Date()
        let cal = Calendar.current
        if profile.isInFreeWindow(at: now, calendar: cal) {
            // Find matching window and format its time range.
            let weekday = cal.component(.weekday, from: now)
            guard let today = DayOfWeek(rawValue: weekday) else { return "Free" }
            let hour = cal.component(.hour, from: now)
            let minute = cal.component(.minute, from: now)
            let nowTime = DayTime(hour: hour, minute: minute)
            for window in profile.freeWindows where window.daysOfWeek.contains(today) {
                if nowTime >= window.startTime && nowTime < window.endTime {
                    return "\(profile.name) free window"
                }
            }
            return "Free"
        }
        return nil
    }

    private static func lastCommandProcessedAt(from storage: any SharedStorageProtocol) -> Date? {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
        let timestamp = defaults.double(forKey: "fr.bigbrother.lastCommandProcessedAt")
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    private static func monitorLastActiveAt() -> Date? {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
        let timestamp = defaults.double(forKey: "monitorLastActiveAt")
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    private static func isUsefulAppName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.hasPrefix("blocked app ") &&
            !normalized.contains("token(") &&
            !normalized.contains("data:") &&
            !normalized.contains("bytes)")
    }
}
