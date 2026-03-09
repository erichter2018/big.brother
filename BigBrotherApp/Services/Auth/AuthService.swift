import Foundation
import LocalAuthentication
import BigBrotherCore

/// Authentication service for parent/admin access.
///
/// Supports:
/// - Face ID / Touch ID (primary)
/// - PIN fallback (4–8 digit numeric)
/// - PIN lockout after max failed attempts
protocol AuthServiceProtocol {
    /// Attempt biometric authentication, falling back to PIN prompt if needed.
    /// Returns true if authentication succeeds.
    func authenticateParent() async throws -> Bool

    /// Validate a PIN string against the stored hash.
    /// Manages the failed-attempt counter and lockout state.
    func validatePIN(_ pin: String) -> PINValidationResult

    /// Set or change the parent PIN.
    func setPIN(_ pin: String) throws

    /// Whether biometric authentication is available on this device.
    var isBiometricAvailable: Bool { get }

    /// Whether PIN entry is currently locked out due to too many failed attempts.
    var isPINLockedOut: Bool { get }

    /// When the current lockout expires (nil if not locked out).
    var lockoutExpiresAt: Date? { get }
}

enum PINValidationResult: Sendable {
    case success
    case failure(attemptsRemaining: Int)
    case lockedOut(until: Date)
}
