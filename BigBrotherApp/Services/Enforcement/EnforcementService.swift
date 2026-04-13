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
