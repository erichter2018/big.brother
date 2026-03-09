import Foundation
import Observation
import BigBrotherCore

@Observable
final class ChildDetailViewModel: CommandSendable {
    let appState: AppState
    let child: ChildProfile

    var isSendingCommand = false
    var commandFeedback: String?
    var isCommandError = false
    var recentEvents: [EventLogEntry] = []

    init(appState: AppState, child: ChildProfile) {
        self.appState = appState
        self.child = child
    }

    var devices: [ChildDevice] {
        appState.childDevices.filter { $0.childProfileID == child.id }
    }

    func heartbeat(for device: ChildDevice) -> DeviceHeartbeat? {
        appState.latestHeartbeats.first { $0.deviceID == device.id }
    }

    // MARK: - Actions (target all devices for this child)

    func setMode(_ mode: LockMode) async {
        await performCommand(.setMode(mode), target: .child(child.id))
    }

    func temporaryUnlock(seconds: Int = 900) async {
        await performCommand(.temporaryUnlock(durationSeconds: seconds), target: .child(child.id))
    }

    func loadEvents() async {
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }

        let since = Date().addingTimeInterval(-86400) // last 24h
        recentEvents = (try? await cloudKit.fetchEventLogs(familyID: familyID, since: since))
            ?? []
    }

    func refresh() async {
        try? await appState.refreshDashboard()
        await loadEvents()
    }
}
