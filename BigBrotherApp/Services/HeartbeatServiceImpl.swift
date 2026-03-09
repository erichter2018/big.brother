import Foundation
import BigBrotherCore
#if canImport(UIKit)
import UIKit
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

        let heartbeat = DeviceHeartbeat(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            currentMode: currentMode,
            policyVersion: policyVersion,
            familyControlsAuthorized: enforcement?.authorizationStatus == .authorized,
            batteryLevel: Self.batteryLevel,
            isCharging: Self.isCharging
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
        return level >= 0 ? Double(level) : nil
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
}
