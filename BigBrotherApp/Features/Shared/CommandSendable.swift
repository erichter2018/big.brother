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
            commandFeedback = "\(action.displayDescription) sent."
        } catch {
            commandFeedback = "Failed: \(error.localizedDescription)"
            isCommandError = true
        }
        isSendingCommand = false
    }
}
