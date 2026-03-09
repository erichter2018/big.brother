import Foundation
import Observation
import BigBrotherCore

@Observable
final class ParentDashboardViewModel: CommandSendable {
    let appState: AppState

    var loadingState: ViewLoadingState<[ChildProfile]> = .idle
    var isSendingCommand = false
    var commandFeedback: String?
    var isCommandError = false

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Data

    var childProfiles: [ChildProfile] { appState.childProfiles }
    var childDevices: [ChildDevice] { appState.childDevices }
    var latestHeartbeats: [DeviceHeartbeat] { appState.latestHeartbeats }

    func devices(for child: ChildProfile) -> [ChildDevice] {
        childDevices.filter { $0.childProfileID == child.id }
    }

    func heartbeat(for device: ChildDevice) -> DeviceHeartbeat? {
        latestHeartbeats.first { $0.deviceID == device.id }
    }

    // MARK: - Loading

    func loadDashboard() async {
        loadingState = .loading
        do {
            try await appState.refreshDashboard()
            if appState.childProfiles.isEmpty {
                loadingState = .empty("No children configured yet.")
            } else {
                loadingState = .loaded(appState.childProfiles)
            }
        } catch {
            loadingState = .error(error.localizedDescription)
        }
    }

    // MARK: - Global Actions

    func lockAll() async {
        await performCommand(.setMode(.dailyMode), target: .allDevices)
        startConfirmationPolling()
    }

    func unlockAll(duration: UnlockDuration = .indefinite) async {
        switch duration {
        case .indefinite:
            await performCommand(.setMode(.unlocked), target: .allDevices)
        case .hours(let h):
            await performCommand(.temporaryUnlock(durationSeconds: h * 3600), target: .allDevices)
        case .delayed:
            // TODO: Implement delayed unlock logic.
            commandFeedback = "Delayed unlock coming soon."
            isCommandError = false
            return
        }
        startConfirmationPolling()
    }

    func essentialOnlyAll() async {
        await performCommand(.setMode(.essentialOnly), target: .allDevices)
        startConfirmationPolling()
    }

    enum UnlockDuration {
        case indefinite
        case hours(Int)
        case delayed
    }

    // MARK: - Confirmation Polling

    private var confirmationTask: Task<Void, Never>?

    /// After sending a command, poll CloudKit every 3s for up to 30s
    /// to pick up the child's updated heartbeat. Stops early if heartbeat changes.
    private func startConfirmationPolling() {
        confirmationTask?.cancel()
        let previousHeartbeats = appState.latestHeartbeats
        confirmationTask = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                do {
                    try await self.appState.refreshDashboard()
                    // Update loading state without flashing the spinner.
                    if !self.appState.childProfiles.isEmpty {
                        self.loadingState = .loaded(self.appState.childProfiles)
                    }
                    // Stop early if any heartbeat mode changed.
                    if self.appState.latestHeartbeats != previousHeartbeats {
                        #if DEBUG
                        print("[BigBrother] Heartbeat change detected, stopping confirmation poll")
                        #endif
                        return
                    }
                } catch {
                    // Non-fatal — keep polling.
                }
            }
        }
    }

    // MARK: - Delete

    func deleteChild(_ child: ChildProfile) async {
        do {
            try await appState.cloudKit?.deleteChildProfile(child.id)
            await loadDashboard()
        } catch {
            commandFeedback = "Failed to delete: \(error.localizedDescription)"
            isCommandError = true
        }
    }
}
