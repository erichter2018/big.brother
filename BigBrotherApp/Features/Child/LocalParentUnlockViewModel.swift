import Foundation
import UIKit
@preconcurrency import UserNotifications
import Observation
import BigBrotherCore

@Observable
@MainActor
final class LocalParentUnlockViewModel {
    let appState: AppState

    var pin = ""
    var errorMessage: String?
    var attemptsRemaining: Int?
    var lockoutDate: Date?
    var unlockSuccess = false

    /// nil = show duration picker, set = show PIN entry
    var selectedDuration: Int?

    /// Available unlock durations for the duration picker.
    static let durationOptions: [(label: String, icon: String, seconds: Int?)] = [
        ("15 minutes", "clock", 15 * 60),
        ("1 hour", "clock", 1 * 3600),
        ("1.5 hours", "clock", 5400),
        ("2 hours", "clock", 2 * 3600),
        ("Until midnight", "moon.fill", nil), // computed at selection time
        ("24 hours", "clock.badge.checkmark", 24 * 3600),
    ]

    static var secondsUntilMidnight: Int { Date.secondsUntilMidnight }

    init(appState: AppState) {
        self.appState = appState
    }

    private var deviceName: String {
        UIDevice.current.name
    }

    var isLockedOut: Bool {
        if let lockout = lockoutDate, lockout > Date() { return true }
        return appState.auth?.isPINLockedOut ?? false
    }

    var isPINConfigured: Bool {
        (try? appState.keychain.getData(forKey: StorageKeys.parentPINHash)) != nil
    }

    func verifyPIN() {
        guard let auth = appState.auth else { return }

        let result = auth.validatePIN(pin)
        switch result {
        case .success:
            performTemporaryUnlock()

        case .failure(let remaining):
            pin = ""
            attemptsRemaining = remaining
            errorMessage = "Incorrect PIN"
            appState.eventLogger?.log(.localPINUnlock,
                details: "PIN unlock FAILED on \(deviceName) — \(remaining) attempts remaining")
            postLocalNotification(
                title: "PIN Unlock Failed",
                body: "Incorrect PIN entered on \(deviceName). \(remaining) attempts remaining."
            )

        case .lockedOut(let until):
            pin = ""
            lockoutDate = until
            errorMessage = nil
            appState.eventLogger?.log(.localPINUnlock,
                details: "PIN unlock LOCKED OUT on \(deviceName)")
            postLocalNotification(
                title: "PIN Unlock Locked Out",
                body: "Too many failed attempts on \(deviceName). Try again later."
            )
        }
    }

    private func performTemporaryUnlock() {
        guard let snapshotStore = appState.snapshotStore,
              let enforcement = appState.enforcement,
              let enrollment = appState.enrollmentState else {
            errorMessage = "Unable to unlock — device not properly configured."
            return
        }

        let currentSnapshot = snapshotStore.loadCurrentSnapshot()
        let currentMode = currentSnapshot?.effectivePolicy.resolvedMode ?? .locked
        let currentVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0
        let maxDuration: TimeInterval = 24 * 3600 // 24 hours max
        let rawDuration = selectedDuration.map(TimeInterval.init) ?? AppConstants.defaultTemporaryUnlockSeconds
        let duration = min(rawDuration, maxDuration)
        let expiresAt = Date().addingTimeInterval(duration)

        // Create durable temp unlock state.
        let unlockState = TemporaryUnlockState(
            origin: .localPINUnlock,
            previousMode: currentMode,
            expiresAt: expiresAt
        )
        try? appState.storage.writeTemporaryUnlockState(unlockState)

        let policy = Policy(
            targetDeviceID: enrollment.deviceID,
            mode: currentMode,
            temporaryUnlockUntil: expiresAt,
            version: currentVersion + 1
        )

        let capabilities = DeviceCapabilities(
            familyControlsAuthorized: enforcement.authorizationStatus == .authorized,
            isOnline: true
        )

        let inputs = PolicyPipelineCoordinator.Inputs(
            basePolicy: policy,
            alwaysAllowedTokensData: appState.storage.readRawData(forKey: StorageKeys.allowedAppTokens),
            capabilities: capabilities,
            temporaryUnlockState: unlockState,
            authorizationHealth: appState.storage.readAuthorizationHealth(),
            deviceID: enrollment.deviceID,
            source: .temporaryUnlockStarted,
            trigger: "Local PIN unlock"
        )

        let output = PolicyPipelineCoordinator.generateSnapshot(
            from: inputs, previousSnapshot: currentSnapshot
        )

        do {
            let result = try snapshotStore.commit(output.snapshot)
            if case .committed(let snapshot) = result {
                let enf = enforcement
                Task.detached(priority: .userInitiated) {
                    try? enf.apply(snapshot.effectivePolicy)
                }
                try snapshotStore.markApplied()
                appState.currentEffectivePolicy = snapshot.effectivePolicy
                appState.activeWarnings = snapshot.effectivePolicy.warnings
            }
        } catch {
            errorMessage = "Unlock failed: \(error.localizedDescription)"
            return
        }

        // Log the event.
        let durationLabel = Self.durationOptions.first { $0.seconds == selectedDuration }?.label ?? "\(Int(duration))s"
        appState.eventLogger?.log(.localPINUnlock,
            details: "PIN unlock on \(deviceName) for \(durationLabel)")
        postLocalNotification(
            title: "Device Unlocked",
            body: "\(deviceName) unlocked for \(durationLabel) via parent PIN."
        )

        unlockSuccess = true
    }

    private func postLocalNotification(title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            // Request permission if not yet granted (no-op if already decided).
            guard let granted = try? await center.requestAuthorization(
                options: [.alert, .sound]
            ), granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "pin-unlock-\(UUID().uuidString)",
                content: content,
                trigger: nil // deliver immediately
            )
            try? await center.add(request)
        }
    }
}
