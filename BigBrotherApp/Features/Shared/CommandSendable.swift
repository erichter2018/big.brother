import Foundation
import BigBrotherCore

/// Protocol for view models that send commands via AppState.
///
/// Provides a default `performCommand` implementation that manages
/// loading state and feedback. Conforming types just need the stored properties.
@MainActor
protocol CommandSendable: AnyObject {
    var appState: AppState { get }
    var isSendingCommand: Bool { get set }
    var commandFeedback: String? { get set }
    var isCommandError: Bool { get set }
}

extension CommandSendable {
    func performCommand(_ action: CommandAction, target: CommandTarget) async {
        // Freemium gate: check if the target child is within the free tier.
        if !appState.subscriptionManager.isSubscribed {
            let childID: ChildProfileID? = {
                switch target {
                case .child(let cid): return cid
                case .device(let did): return appState.childDevices.first { $0.id == did }?.childProfileID
                case .allDevices: return nil
                }
            }()
            if let childID {
                let sorted = appState.childProfiles.sorted { $0.createdAt < $1.createdAt }
                let idx = sorted.firstIndex { $0.id == childID } ?? sorted.count
                if !appState.subscriptionManager.canControlChild(childIndex: idx) {
                    commandFeedback = "Subscribe to control this child's devices."
                    isCommandError = true
                    return
                }
            }
            if case .allDevices = target, appState.childProfiles.count > SubscriptionManager.freeChildLimit {
                commandFeedback = "Subscribe to control all children's devices."
                isCommandError = true
                return
            }
        }

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
