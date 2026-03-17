import Foundation
import BigBrotherCore

/// Protocol for view models that send commands via AppState.
///
/// Provides a default `performCommand` implementation that manages
/// loading state and feedback. Conforming types just need the stored properties.
protocol CommandSendable: AnyObject {
    var appState: AppState { get }
    var isSendingCommand: Bool { get set }
    var commandFeedback: String? { get set }
    var isCommandError: Bool { get set }
}

extension CommandSendable {
    func performCommand(_ action: CommandAction, target: CommandTarget) async {
        isSendingCommand = true
        commandFeedback = nil
        isCommandError = false

        do {
            try await appState.sendCommand(target: target, action: action)
            let targetLabel = self.targetLabel(for: target)
            commandFeedback = "\(action.displayDescription) sent\(targetLabel)."
        } catch {
            commandFeedback = "Failed: \(error.localizedDescription)"
            isCommandError = true
        }
        isSendingCommand = false

        // Auto-dismiss after 10 seconds.
        let feedback = commandFeedback
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            // Only clear if the feedback hasn't changed (another command might have fired).
            if self?.commandFeedback == feedback {
                self?.commandFeedback = nil
            }
        }
    }

    private func targetLabel(for target: CommandTarget) -> String {
        switch target {
        case .allDevices:
            return " to all devices"
        case .child(let childID):
            if let name = appState.childProfiles.first(where: { $0.id == childID })?.name {
                return " to \(name)"
            }
            return ""
        case .device(let deviceID):
            if let device = appState.childDevices.first(where: { $0.id == deviceID }) {
                return " to \(device.displayName)"
            }
            return ""
        }
    }
}
