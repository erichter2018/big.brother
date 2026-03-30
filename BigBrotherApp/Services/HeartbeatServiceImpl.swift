import Foundation
import CloudKit
import CoreMotion
import UserNotifications
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

    /// Event logger for creating new-app-detected events.
    var eventLogger: (any EventLoggerProtocol)?

    /// Called when the main app positively acknowledges an extension liveness
    /// request or otherwise proves it is responsive again.
    var onLivenessConfirmed: (() -> Void)?

    /// Optional location service — reads cached location for heartbeat inclusion.
    var locationService: LocationService?

    /// VPN manager — ping the tunnel every 30s to prove we're alive.
    var vpnManager: VPNManagerService?

    /// Monotonically increasing sequence number for this app launch.
    /// Persisted across heartbeats within a session; resets on app relaunch.
    private var seqCounter: Int64 = 0

    /// When the last heartbeat was successfully sent (in-memory, for movement-based frequency).
    private var lastSendAt: Date?

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

    /// Heartbeat interval when the device is moving (more frequent for better tracking).
    private static let movingHeartbeatInterval: TimeInterval = 60

    func startHeartbeat() {
        stopHeartbeat()
        let hbTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                try? await self.sendNow(force: self.acknowledgeExtensionHeartbeatRequest())
            }
        }
        RunLoop.main.add(hbTimer, forMode: .common)
        timer = hbTimer
        // Check every 30s for extension-requested heartbeats, movement-based sends,
        // and ping the VPN tunnel to prove liveness.
        let extTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Write liveness timestamp for the VPN tunnel to read.
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "mainAppLastActiveAt")

            // Ping the VPN tunnel (IPC liveness signal).
            self.vpnManager?.sendPing()

            // Extension heartbeat request.
            if self.acknowledgeExtensionHeartbeatRequest() {
                Task { try? await self.sendNow(force: true) }
                return
            }
            // While moving, send heartbeats more frequently (every ~60s).
            if self.locationService?.isMoving == true {
                let sinceLastSend = Date().timeIntervalSince(self.lastSendAt ?? .distantPast)
                if sinceLastSend >= Self.movingHeartbeatInterval {
                    Task { try? await self.sendNow(force: false) }
                }
            }
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
    /// Positively acknowledge the current request token to prove liveness.
    /// Returns true only for recent requests (< 5 min) to trigger a forced heartbeat send.
    private func acknowledgeExtensionHeartbeatRequest() -> Bool {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let requestToken = defaults?.string(forKey: "extensionHeartbeatRequestToken")
        guard let requestToken, !requestToken.isEmpty else { return false }

        let ackToken = defaults?.string(forKey: "extensionHeartbeatAcknowledgedToken")
        let requestedAt = defaults?.double(forKey: "extensionHeartbeatRequestedAt") ?? 0
        let justAcknowledged = ackToken != requestToken
        if justAcknowledged {
            defaults?.set(requestToken, forKey: "extensionHeartbeatAcknowledgedToken")
            defaults?.set(Date().timeIntervalSince1970, forKey: "extensionHeartbeatAcknowledgedAt")
            onLivenessConfirmed?()
        }

        guard requestedAt > 0 else { return false }
        let age = Date().timeIntervalSince1970 - requestedAt

        // Only trigger a forced heartbeat send for recent requests.
        guard age < 300 else {
            #if DEBUG
            if justAcknowledged {
                print("[BigBrother] Extension heartbeat request acknowledged (stale: \(Int(age))s old)")
            }
            #endif
            return false
        }
        #if DEBUG
        print("[BigBrother] Extension requested heartbeat \(Int(age))s ago — sending")
        #endif
        return justAcknowledged
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
        // Determine currentMode from ACTUAL device state.
        // The heartbeat must report what the device IS doing, not what it SHOULD be doing.
        // The ground truth is ManagedSettingsStore — if shields are on, the device is locked.
        // If shields are off, the device is unlocked, period.
        let currentMode: LockMode
        #if canImport(ManagedSettings)
        if let enforcement = enforcement {
            let diagnostic = enforcement.shieldDiagnostic()
            if !diagnostic.shieldsActive {
                // Shields are off — device is actually unlocked
                currentMode = .unlocked
            } else {
                // Shields are on — determine which locked mode.
                // Prefer ExtensionSharedState (Monitor's last enforcement action),
                // then PolicySnapshot, as label for which type of lock is active.
                let extState = storage.readExtensionSharedState()
                if let ext = extState, ext.currentMode != .unlocked {
                    currentMode = ext.currentMode
                } else if let snap = snapshot, snap.effectivePolicy.resolvedMode != .unlocked {
                    currentMode = snap.effectivePolicy.resolvedMode
                } else {
                    // Shields are on but no state says which mode — safe default
                    currentMode = .restricted
                }
            }
        } else {
            // No enforcement service (shouldn't happen on child) — fall back to state files
            let extState = storage.readExtensionSharedState()
            if let ext = extState, ext.writtenAt > (snapshot?.createdAt ?? .distantPast) {
                currentMode = ext.currentMode
            } else if let snap = snapshot {
                currentMode = snap.effectivePolicy.resolvedMode
            } else {
                currentMode = .unlocked
            }
        }
        #else
        // Non-child builds (parent) — use state files
        let extState = storage.readExtensionSharedState()
        if let ext = extState, ext.writtenAt > (snapshot?.createdAt ?? .distantPast) {
            currentMode = ext.currentMode
        } else if let snap = snapshot {
            currentMode = snap.effectivePolicy.resolvedMode
        } else {
            currentMode = .unlocked
        }
        #endif
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

        // Refresh location on each heartbeat so data stays reasonably fresh
        // even if device hasn't moved enough for a significant-change event.
        locationService?.refreshLocation()
        let loc = locationService?.lastLocation
        let locAddress = locationService?.lastAddress

        // Shield diagnostic: read actual ManagedSettingsStore state
        let shieldsActive: Bool?
        let shieldedAppCount: Int?
        let shieldCategoryActive: Bool?
        #if canImport(ManagedSettings)
        if let enforcement = enforcement {
            let diagnostic = enforcement.shieldDiagnostic()
            shieldsActive = diagnostic.shieldsActive
            shieldedAppCount = diagnostic.appCount
            shieldCategoryActive = diagnostic.categoryActive
        } else {
            shieldsActive = nil
            shieldedAppCount = nil
            shieldCategoryActive = nil
        }
        #else
        shieldsActive = nil
        shieldedAppCount = nil
        shieldCategoryActive = nil
        #endif

        // Schedule diagnostic — report what the child's LOCAL schedule says right now.
        // If this disagrees with the parent's schedule, the child has stale data.
        let scheduleResolvedMode: String?
        if let profile = storage.readActiveScheduleProfile() {
            let now = Date()
            let mode = profile.resolvedMode(at: now)
            let inFree = profile.isInUnlockedWindow(at: now)
            let inEssential = profile.isInLockedWindow(at: now)
            // Include diagnostic detail: mode + why
            let detail: String
            if inFree {
                detail = "\(mode.rawValue) (in unlocked window)"
            } else if inEssential {
                detail = "\(mode.rawValue) (in locked window)"
            } else {
                let ewCount = profile.lockedWindows.count
                let ewDays = profile.lockedWindows.first?.daysOfWeek.map(\.displayName).sorted().joined(separator: ",") ?? "none"
                let ewStart = profile.lockedWindows.first.map { "\($0.startTime.hour):\(String(format: "%02d", $0.startTime.minute))" } ?? "?"
                let ewEnd = profile.lockedWindows.first.map { "\($0.endTime.hour):\(String(format: "%02d", $0.endTime.minute))" } ?? "?"
                detail = "\(mode.rawValue) (lw:\(ewCount) days:\(ewDays) \(ewStart)-\(ewEnd))"
            }
            scheduleResolvedMode = detail
        } else {
            scheduleResolvedMode = nil
        }

        // Last shield change reason
        let lastShieldChangeReason = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .string(forKey: "lastShieldChangeReason")

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
            monitorLastActiveAt: Self.monitorLastActiveAt(),
            vpnDetected: VPNDetector.isVPNActive(),
            timeZoneIdentifier: TimeZone.current.identifier,
            timeZoneOffsetSeconds: TimeZone.current.secondsFromGMT(),
            screenTimeMinutes: Self.currentScreenTimeMinutes(from: storage),
            screenUnlockCount: UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.integer(forKey: "screenUnlockCount"),
            jailbreakDetected: JailbreakDetector.isJailbroken(),
            jailbreakReason: JailbreakDetector.detectedReason(),
            isDriving: locationService?.isMoving == true ? true : nil,
            currentSpeed: locationService?.lastLocation?.speed,
            heartbeatSource: "mainApp",
            tunnelConnected: vpnManager?.isConnected,
            motionAuthorized: CMMotionActivityManager.authorizationStatus() == .authorized,
            notificationsAuthorized: Self.notificationsAuthorized(),
            isDeviceLocked: DeviceLockMonitor.shared.isDeviceLocked,
            shieldsActive: shieldsActive,
            scheduleResolvedMode: scheduleResolvedMode,
            lastShieldChangeReason: lastShieldChangeReason,
            shieldedAppCount: shieldedAppCount,
            shieldCategoryActive: shieldCategoryActive,
            latitude: loc?.coordinate.latitude,
            longitude: loc?.coordinate.longitude,
            locationTimestamp: loc?.timestamp,
            locationAddress: locAddress,
            locationAccuracy: loc?.horizontalAccuracy,
            locationAuthorization: locationService?.authorizationStatusString
        )

        do {
            try await cloudKit.sendHeartbeat(heartbeat)

            let successStatus = attemptStatus.recordingSuccess()
            try? storage.writeHeartbeatStatus(successStatus)

            // Record successful heartbeat timestamp so the Monitor can distinguish
            // between a truly force-closed app and one merely suspended by iOS.
            lastSendAt = Date()
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(Date().timeIntervalSince1970, forKey: "lastHeartbeatSentAt")

            // Update device record with current OS version + model if changed.
            await updateDeviceRecordIfNeeded(enrollment: enrollment)

            // Safety net: reconcile enforcement on every successful heartbeat.
            reconcileEnforcement()

            // Check for new app activity detected by the VPN tunnel.
            flushNewAppDetections()

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
    /// Uses ModeStackResolver to compute the correct mode from the stack files,
    /// then applies it if shields don't match. This is idempotent — if the Monitor
    /// already applied the correct state, this is a no-op.
    private func reconcileEnforcement() {
        guard let enforcement else { return }
        let resolution = ModeStackResolver.resolve(storage: storage)
        guard let snapshot = storage.readPolicySnapshot() else { return }

        // Check if shields match the resolved mode
        let diagnostic = enforcement.shieldDiagnostic()
        let shouldBeShielded = resolution.mode != .unlocked
        let isShielded = diagnostic.shieldsActive

        if shouldBeShielded != isShielded {
            // Mismatch — apply the correct state
            try? enforcement.apply(snapshot.effectivePolicy)

            #if DEBUG
            print("[BigBrother] Heartbeat reconciliation: shields were \(isShielded ? "up" : "DOWN"), should be \(shouldBeShielded ? "up" : "down") (mode: \(resolution.mode.rawValue), reason: \(resolution.reason))")
            #endif

            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Heartbeat reconciled shields",
                details: "Mode: \(resolution.mode.rawValue), reason: \(resolution.reason)"
            ))
        }
    }

    // MARK: - New App Detection

    /// Flush pending new-app detections written by the VPN tunnel's DNS proxy.
    private func flushNewAppDetections() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard let pending = defaults?.stringArray(forKey: "newAppDetections"),
              !pending.isEmpty else { return }

        // Clear immediately to avoid duplicate processing.
        defaults?.removeObject(forKey: "newAppDetections")

        // Deduplicate in case tunnel wrote the same app multiple times.
        let unique = Set(pending)
        for appName in unique.sorted() {
            eventLogger?.log(.newAppDetected, details: "New app activity: \(appName)")
        }

        #if DEBUG
        print("[BigBrother] Flushed \(unique.count) new app detections: \(unique.sorted().joined(separator: ", "))")
        #endif
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

    private static var currentOSVersion: String { DeviceInfo.osVersion }
    private static var currentModelIdentifier: String { DeviceInfo.modelIdentifier }

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
        if profile.isInUnlockedWindow(at: now, calendar: cal) {
            // Find matching window and format its time range.
            let weekday = cal.component(.weekday, from: now)
            guard let today = DayOfWeek(rawValue: weekday) else { return "Unlocked" }
            let hour = cal.component(.hour, from: now)
            let minute = cal.component(.minute, from: now)
            let nowTime = DayTime(hour: hour, minute: minute)
            for window in profile.unlockedWindows where window.daysOfWeek.contains(today) {
                if nowTime >= window.startTime && nowTime < window.endTime {
                    return "\(profile.name) unlocked window"
                }
            }
            return "Unlocked"
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

    /// Check notification permission synchronously via cached value.
    /// Updated each heartbeat cycle.
    private static let _notifAuthLock = NSLock()
    private static var _notifAuthBacking: Bool?
    private static func notificationsAuthorized() -> Bool? {
        // Async check runs in background, caches result for next heartbeat
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            _notifAuthLock.lock()
            _notifAuthBacking = settings.authorizationStatus == .authorized
            _notifAuthLock.unlock()
        }
        _notifAuthLock.lock()
        defer { _notifAuthLock.unlock() }
        return _notifAuthBacking
    }

    private static func currentScreenTimeMinutes(from storage: any SharedStorageProtocol) -> Int? {
        // Flush any in-progress unlock session so the count is current.
        DeviceLockMonitor.shared.flushCurrentSession()

        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
        let dateKey = "screenTimeDate"
        let minutesKey = "screenTimeMinutes"

        // Only return if the stored date matches today
        let today = SelfUnlockState.todayDateString()
        guard defaults.string(forKey: dateKey) == today else { return nil }
        let minutes = defaults.integer(forKey: minutesKey)
        return minutes > 0 ? minutes : nil
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
