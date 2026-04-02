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
    private static let authFailReasonKey = "fr.bigbrother.childAuthFailReason"

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
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)!.string(forKey: Self.authTypeKey) == "child"
    }

    func requestAuthorization() async throws {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)!

        // Try .child first (stronger — parent must authenticate, child can't revoke).
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .child)
            defaults.set("child", forKey: Self.authTypeKey)
            defaults.removeObject(forKey: Self.authFailReasonKey)
            return
        } catch {
            // Map the error to a human-readable reason
            let reason: String
            let errorDesc = "\(error)"
            if errorDesc.contains("restricted") {
                reason = "Device restriction blocks Family auth (likely MDM profile e.g. OurPact)"
            } else if errorDesc.contains("authorizationConflict") || errorDesc.contains("conflict") {
                reason = "Another parental control app holds Family auth"
            } else if errorDesc.contains("invalidAccountType") || errorDesc.contains("invalid") {
                reason = "Device not signed into a child/teen Apple ID in Family Sharing"
            } else if errorDesc.contains("authorizationCanceled") || errorDesc.contains("cancel") {
                reason = "Parent canceled the authorization prompt"
            } else if errorDesc.contains("network") {
                reason = "Network error during Family auth — will retry next launch"
            } else {
                reason = "Family auth failed: \(error.localizedDescription)"
            }
            defaults.set(reason, forKey: Self.authFailReasonKey)

            try? storage?.appendDiagnosticEntry(DiagnosticEntry(
                category: .auth,
                message: "Child auth failed, falling back to Individual",
                details: reason
            ))
        }

        // Fall back to .individual (self-regulation — user can revoke).
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        // Store "individual" as the type. The fail reason is stored separately
        // so the heartbeat authType stays clean for comparison.
        defaults.set("individual", forKey: Self.authTypeKey)
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
