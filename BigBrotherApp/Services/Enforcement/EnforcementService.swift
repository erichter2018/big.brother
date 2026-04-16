import Foundation
import BigBrotherCore

protocol EnforcementServiceProtocol {
    func apply(_ policy: EffectivePolicy, force: Bool) throws
    func clearAllRestrictions() throws
    func clearTemporaryUnlock() throws
    var authorizationStatus: FCAuthorizationStatus { get }
    func requestAuthorization() async throws
    func reconcile(with snapshot: PolicySnapshot) throws
    func applyEssentialOnly() throws
    func shieldDiagnostic() -> ShieldDiagnostic
    func computeTokenVerdicts(for mode: LockMode) -> [DiagnosticSnapshot.TokenVerdict]
    func resetThrottle()
    func forceDaemonRescue()
}

extension EnforcementServiceProtocol {
    func apply(_ policy: EffectivePolicy) throws {
        try apply(policy, force: false)
    }

    // MARK: - Off-Main-Thread Wrappers
    // enforcement.apply() is synchronous XPC that blocks the calling thread.
    // These async wrappers guarantee the XPC never runs on the main thread.
    // Use from @MainActor contexts (SwiftUI views, AppState, ViewModels).

    func applyOffMain(_ policy: EffectivePolicy, force: Bool = false) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.apply(policy, force: force)
        }.value
    }

    func clearAllRestrictionsOffMain() async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.clearAllRestrictions()
        }.value
    }

    func reconcileOffMain(with snapshot: PolicySnapshot) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.reconcile(with: snapshot)
        }.value
    }
}

struct ShieldDiagnostic {
    let shieldsActive: Bool
    let appCount: Int
    let categoryActive: Bool
    var webBlockingActive: Bool = false
    var denyAppRemoval: Bool = false
}

enum FCAuthorizationStatus: String, Sendable {
    case notDetermined
    case authorized
    case denied
}
