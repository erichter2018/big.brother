import Foundation
import Observation
import BigBrotherCore

@Observable
final class ChildHomeViewModel {
    let appState: AppState

    var now = Date()
    private var timer: Timer?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Computed State

    var currentMode: LockMode {
        appState.currentEffectivePolicy?.resolvedMode ?? .unlocked
    }

    var isTemporaryUnlock: Bool {
        appState.currentEffectivePolicy?.isTemporaryUnlock ?? false
    }

    var temporaryUnlockState: TemporaryUnlockState? {
        appState.storage.readTemporaryUnlockState()
    }

    var authorizationHealthy: Bool {
        appState.storage.readAuthorizationHealth()?.isAuthorized ?? true
    }

    var warnings: [CapabilityWarning] {
        appState.activeWarnings
    }

    var childName: String {
        // The child's name isn't stored locally. Show device name.
        appState.enrollmentState?.deviceID.rawValue ?? "This Device"
    }

    var lastReconciliation: Date? {
        appState.snapshotStore?.loadCurrentSnapshot()?.appliedAt
    }

    var isEnrolled: Bool {
        appState.enrollmentState != nil
    }

    // MARK: - Timer for temp unlock countdown

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
