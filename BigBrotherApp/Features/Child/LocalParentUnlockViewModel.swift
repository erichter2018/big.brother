import Foundation
import Observation
import BigBrotherCore

@Observable
final class LocalParentUnlockViewModel {
    let appState: AppState

    var pin = ""
    var errorMessage: String?
    var attemptsRemaining: Int?
    var lockoutDate: Date?
    var unlockSuccess = false

    init(appState: AppState) {
        self.appState = appState
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

        case .lockedOut(let until):
            pin = ""
            lockoutDate = until
            errorMessage = nil
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
        let currentMode = currentSnapshot?.effectivePolicy.resolvedMode ?? .fullLockdown
        let currentVersion = currentSnapshot?.effectivePolicy.policyVersion ?? 0
        let duration = AppConstants.defaultTemporaryUnlockSeconds
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
                try enforcement.apply(snapshot.effectivePolicy)
                try snapshotStore.markApplied()
                appState.currentEffectivePolicy = snapshot.effectivePolicy
                appState.activeWarnings = snapshot.effectivePolicy.warnings
            }
        } catch {
            errorMessage = "Unlock failed: \(error.localizedDescription)"
            return
        }

        // Log the event.
        appState.eventLogger?.log(.localPINUnlock, details: "Local PIN unlock for \(Int(duration))s")

        unlockSuccess = true
    }
}
