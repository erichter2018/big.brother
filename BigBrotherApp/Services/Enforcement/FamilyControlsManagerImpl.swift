import Foundation
import Combine
import FamilyControls
import BigBrotherCore

/// Concrete wrapper around FamilyControls.AuthorizationCenter.
///
/// Tries `.child` authorization first (requires Family Sharing child account).
/// Falls back to `.individual` if `.child` fails. Persists which type was
/// granted so the app knows whether system restrictions are enforceable.
final class FamilyControlsManagerImpl: FamilyControlsManagerProtocol, @unchecked Sendable {

    private var changeHandler: (@Sendable (FCAuthorizationStatus) -> Void)?
    private let storage: (any SharedStorageProtocol)?
    private var cancellable: AnyCancellable?

    /// Persisted in UserDefaults so it survives app restarts.
    private static let authTypeKey = "fr.bigbrother.authorizationType"

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

    var isChildAuthorization: Bool {
        UserDefaults.standard.string(forKey: Self.authTypeKey) == "child"
    }

    func requestAuthorization() async throws {
        // Try .child first (stronger — parent must authenticate, child can't revoke).
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .child)
            UserDefaults.standard.set("child", forKey: Self.authTypeKey)
            #if DEBUG
            print("[BigBrother] FamilyControls authorized as .child")
            #endif
            return
        } catch {
            #if DEBUG
            print("[BigBrother] .child auth failed (\(error.localizedDescription)), falling back to .individual")
            #endif
        }

        // Fall back to .individual (self-regulation — user can revoke).
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        UserDefaults.standard.set("individual", forKey: Self.authTypeKey)
        #if DEBUG
        print("[BigBrother] FamilyControls authorized as .individual")
        #endif
    }

    func observeAuthorizationChanges(handler: @escaping @Sendable (FCAuthorizationStatus) -> Void) {
        self.changeHandler = handler

        cancellable = AuthorizationCenter.shared.$authorizationStatus
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let newStatus = self.status
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
