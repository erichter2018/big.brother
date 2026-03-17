import Foundation
import LocalAuthentication
import BigBrotherCore

/// Concrete authentication service using LocalAuthentication (Face ID / Touch ID)
/// and PINHasher for fallback PIN verification.
final class AuthServiceImpl: AuthServiceProtocol {

    private let keychain: any KeychainProtocol
    private let hasher: PINHasher
    private let storage: any SharedStorageProtocol

    /// UserDefaults for lockout state (App Group so child device extensions could read if needed).
    private let defaults: UserDefaults

    init(
        keychain: any KeychainProtocol = KeychainManager(),
        hasher: PINHasher = PINHasher(),
        storage: any SharedStorageProtocol = AppGroupStorage(),
        defaults: UserDefaults? = nil
    ) {
        self.keychain = keychain
        self.hasher = hasher
        self.storage = storage
        self.defaults = defaults ?? UserDefaults(
            suiteName: AppConstants.appGroupIdentifier
        ) ?? .standard
    }

    // MARK: - AuthServiceProtocol

    func authenticateParent() async throws -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Biometrics unavailable — caller should fall back to PIN UI.
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Authenticate to access Big Brother parent controls"
            )
            if success {
                resetFailedAttempts()
            }
            return success
        } catch {
            // Biometric failed or was cancelled — caller should offer PIN entry.
            return false
        }
    }

    func validatePIN(_ pin: String) -> PINValidationResult {
        // Check lockout
        if let lockoutUntil = lockoutExpiresAt, lockoutUntil > Date() {
            return .lockedOut(until: lockoutUntil)
        }

        // Clear expired lockout
        if lockoutExpiresAt != nil {
            defaults.removeObject(forKey: StorageKeys.pinLockoutUntil)
        }

        // Load stored hash
        guard let hashData = try? keychain.getData(forKey: StorageKeys.parentPINHash),
              let storedHash = PINHasher.PINHash(combined: hashData)
        else {
            return .failure(attemptsRemaining: 0)
        }

        if hasher.verify(pin: pin, against: storedHash) {
            resetFailedAttempts()
            return .success
        } else {
            let attempts = incrementFailedAttempts()
            let remaining = max(0, AppConstants.maxPINAttempts - attempts)

            if remaining == 0 {
                let streak = incrementLockoutStreak()
                let duration = lockoutDuration(forStreak: streak)
                let lockoutEnd = Date().addingTimeInterval(duration)
                defaults.set(lockoutEnd.timeIntervalSince1970, forKey: StorageKeys.pinLockoutUntil)
                defaults.set(0, forKey: StorageKeys.failedPINAttempts)
                return .lockedOut(until: lockoutEnd)
            }

            return .failure(attemptsRemaining: remaining)
        }
    }

    func setPIN(_ pin: String) throws {
        let hash = hasher.hash(pin: pin)
        try keychain.setData(hash.combined, forKey: StorageKeys.parentPINHash)
    }

    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var isPINLockedOut: Bool {
        guard let lockoutUntil = lockoutExpiresAt else { return false }
        return lockoutUntil > Date()
    }

    var lockoutExpiresAt: Date? {
        let timestamp = defaults.double(forKey: StorageKeys.pinLockoutUntil)
        guard timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        return date > Date() ? date : nil
    }

    // MARK: - Private Helpers

    private func incrementFailedAttempts() -> Int {
        let current = defaults.integer(forKey: StorageKeys.failedPINAttempts) + 1
        defaults.set(current, forKey: StorageKeys.failedPINAttempts)
        return current
    }

    private func resetFailedAttempts() {
        defaults.set(0, forKey: StorageKeys.failedPINAttempts)
        defaults.set(0, forKey: StorageKeys.pinLockoutStreak)
        defaults.removeObject(forKey: StorageKeys.pinLockoutUntil)
    }

    private func incrementLockoutStreak() -> Int {
        let current = defaults.integer(forKey: StorageKeys.pinLockoutStreak) + 1
        defaults.set(current, forKey: StorageKeys.pinLockoutStreak)
        return current
    }

    /// Escalating lockout: 5 min → 15 min → 1 hour → 4 hours (capped).
    private func lockoutDuration(forStreak streak: Int) -> TimeInterval {
        switch streak {
        case 1:  return 5 * 60      // 5 minutes
        case 2:  return 15 * 60     // 15 minutes
        case 3:  return 60 * 60     // 1 hour
        default: return 4 * 3600    // 4 hours
        }
    }
}
