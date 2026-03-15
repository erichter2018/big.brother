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
    private let interval: TimeInterval

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
    }

    // MARK: - HeartbeatServiceProtocol

    func startHeartbeat() {
        stopHeartbeat()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                try? await self.sendNow(force: false)
            }
        }
        // Fire immediately on start.
        Task { try? await sendNow(force: false) }
    }

    func stopHeartbeat() {
        timer?.invalidate()
        timer = nil
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
        let currentMode = snapshot?.effectivePolicy.resolvedMode ?? .unlocked
        let policyVersion = snapshot?.effectivePolicy.policyVersion ?? 0
        let tempUnlockExpiry: Date? = {
            // Only report expiry if the device is actually unlocked.
            // The TemporaryUnlockState file may linger after a lock command.
            guard currentMode == .unlocked,
                  let state = storage.readTemporaryUnlockState(),
                  state.expiresAt > Date() else { return nil }
            return state.expiresAt
        }()

        let blockingConfig = storage.readAppBlockingConfig()
        let cachedAppNames = Self.discoveredAppNames(from: storage)
        let allowedNames = Self.resolvedAllowedAppNames(from: storage)
        let tempAllowedNames = Self.resolvedTemporaryAllowedAppNames(from: storage)

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
            temporaryAllowedAppNames: tempAllowedNames.isEmpty ? nil : tempAllowedNames,
            temporaryUnlockExpiresAt: tempUnlockExpiry,
            isChildAuthorization: UserDefaults.standard.string(forKey: "fr.bigbrother.authorizationType") == "child"
        )

        do {
            try await cloudKit.sendHeartbeat(heartbeat)

            let successStatus = attemptStatus.recordingSuccess()
            try? storage.writeHeartbeatStatus(successStatus)
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

    // MARK: - Device Info

    private static var batteryLevel: Double? {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
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
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        return nil
        #endif
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
    private static func resolvedAllowedAppNames(from storage: any SharedStorageProtocol) -> [String] {
        let cache = storage.readAllCachedAppNames()
        var names: [String] = []

        #if canImport(ManagedSettings)
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
            for token in tokens {
                guard let tokenData = try? JSONEncoder().encode(token) else { continue }
                let key = tokenData.base64EncodedString()
                if let name = cache[key], isUsefulAppName(name) {
                    names.append(name)
                }
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
