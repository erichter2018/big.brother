import Foundation
import Combine
import FamilyControls
import BigBrotherCore

/// Concrete wrapper around FamilyControls.AuthorizationCenter.
///
/// Provides a clean interface that doesn't leak framework types.
/// Monitors authorization status changes, persists AuthorizationHealth
/// transitions, and reports them via callback.
///
/// Note: AuthorizationCenter conforms to ObservableObject and publishes
/// status changes via Combine's @Published. This is the only supported
/// observation mechanism — there is no NotificationCenter notification.
final class FamilyControlsManagerImpl: FamilyControlsManagerProtocol, @unchecked Sendable {

    private var changeHandler: (@Sendable (FCAuthorizationStatus) -> Void)?
    private let storage: (any SharedStorageProtocol)?
    private var cancellable: AnyCancellable?

    init(storage: (any SharedStorageProtocol)? = nil) {
        self.storage = storage
    }

    var status: FCAuthorizationStatus {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .approved:
            return .authorized
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }

    func observeAuthorizationChanges(handler: @escaping @Sendable (FCAuthorizationStatus) -> Void) {
        self.changeHandler = handler

        // AuthorizationCenter is an ObservableObject with @Published authorizationStatus.
        // Combine is the only supported observation mechanism for this API.
        cancellable = AuthorizationCenter.shared.$authorizationStatus
            .dropFirst() // Skip the initial value (we only want changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let newStatus = self.status

                // Persist authorization health transition.
                self.updateAuthorizationHealth(newStatus: newStatus)

                self.changeHandler?(newStatus)
            }
    }

    // MARK: - Private

    private func updateAuthorizationHealth(newStatus: FCAuthorizationStatus) {
        guard let storage else { return }

        let authState: AuthorizationState
        switch newStatus {
        case .authorized: authState = .authorized
        case .denied: authState = .denied
        case .notDetermined: authState = .notDetermined
        }

        let currentHealth = storage.readAuthorizationHealth() ?? .unknown
        let updatedHealth = currentHealth.withTransition(to: authState)
        try? storage.writeAuthorizationHealth(updatedHealth)

        // Log diagnostic on transitions.
        if updatedHealth.currentState != currentHealth.currentState {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .auth,
                message: "Authorization changed: \(currentHealth.currentState.rawValue) → \(updatedHealth.currentState.rawValue)"
            ))
        }
    }

    deinit {
        cancellable?.cancel()
    }
}
