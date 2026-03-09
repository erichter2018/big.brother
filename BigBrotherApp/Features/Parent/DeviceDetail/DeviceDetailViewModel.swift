import Foundation
import Observation
import BigBrotherCore

@Observable
final class DeviceDetailViewModel: CommandSendable {
    let appState: AppState
    var device: ChildDevice

    var isSendingCommand = false
    var commandFeedback: String?
    var isCommandError = false

    init(appState: AppState, device: ChildDevice) {
        self.appState = appState
        self.device = device
    }

    var heartbeat: DeviceHeartbeat? {
        appState.latestHeartbeats.first { $0.deviceID == device.id }
    }

    // MARK: - Actions (target this specific device)

    func setMode(_ mode: LockMode) async {
        await performCommand(.setMode(mode), target: .device(device.id))
    }

    func temporaryUnlock(seconds: Int = 900) async {
        await performCommand(.temporaryUnlock(durationSeconds: seconds), target: .device(device.id))
    }

    func requestHeartbeat() async {
        await performCommand(.requestHeartbeat, target: .device(device.id))
    }

    func refresh() async {
        try? await appState.refreshDashboard()
        // Update local device reference.
        if let updated = appState.childDevices.first(where: { $0.id == device.id }) {
            device = updated
        }
    }
}
