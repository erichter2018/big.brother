import Foundation

/// Local representation of FamilyControls authorization state.
public enum AuthorizationState: String, Codable, Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case revoked
    case unknown
}

/// First-class model for authorization health tracking.
///
/// Persisted to App Group storage so that extensions, heartbeat,
/// and reconciliation logic can all read the current auth state
/// without querying FamilyControls directly.
public struct AuthorizationHealth: Codable, Sendable, Equatable {
    /// Current authorization state.
    public let currentState: AuthorizationState

    /// When the state last changed.
    public let lastTransitionAt: Date

    /// The state before the last transition (nil if first observation).
    public let previousState: AuthorizationState?

    /// Whether enforcement is degraded due to authorization issues.
    public let enforcementDegraded: Bool

    /// Convenience: is authorization currently granted?
    public var isAuthorized: Bool { currentState == .authorized }

    /// Convenience: was authorization revoked (transition from authorized)?
    public var wasRevoked: Bool {
        previousState == .authorized && currentState != .authorized
    }

    public init(
        currentState: AuthorizationState,
        lastTransitionAt: Date = Date(),
        previousState: AuthorizationState? = nil,
        enforcementDegraded: Bool = false
    ) {
        self.currentState = currentState
        self.lastTransitionAt = lastTransitionAt
        self.previousState = previousState
        self.enforcementDegraded = currentState != .authorized
    }

    /// Create a new health record reflecting a transition to a new state.
    /// Returns self unchanged if the state hasn't actually changed.
    public func withTransition(to newState: AuthorizationState, at time: Date = Date()) -> AuthorizationHealth {
        guard newState != currentState else { return self }
        return AuthorizationHealth(
            currentState: newState,
            lastTransitionAt: time,
            previousState: currentState
        )
    }

    /// Initial health for a device that hasn't checked authorization yet.
    public static let unknown = AuthorizationHealth(
        currentState: .unknown,
        lastTransitionAt: Date()
    )
}
