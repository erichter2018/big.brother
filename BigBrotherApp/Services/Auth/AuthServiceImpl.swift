import Foundation
import LocalAuthentication
import BigBrotherCore

/// PIN lockout state stored in Keychain to prevent tampering via UserDefaults editing.
private struct PINLockoutState: Codable {
    var failedAttempts: Int = 0
    var lockoutStreak: Int = 0
    var lockoutUntil: Date? = nil
}

/// Concrete authentication service using LocalAuthentication (Face ID / Touch ID)
/// and PINHasher for fallback PIN verification.
final class AuthServiceImpl: AuthServiceProtocol {

    private let keychain: any KeychainProtocol
    private let hasher: PINHasher
    private let storage: any SharedStorageProtocol

    init(
        keychain: any KeychainProtocol = KeychainManager(),
        hasher: PINHasher = PINHasher(),
        storage: any SharedStorageProtocol = AppGroupStorage()
    ) {
        self.keychain = keychain
        self.hasher = hasher
        self.storage = storage
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
        var state = loadLockoutState()

        // Check lockout
        if let lockoutUntil = state.lockoutUntil, lockoutUntil > Date() {
            return .lockedOut(until: lockoutUntil)
        }

        // Clear expired lockout
        if state.lockoutUntil != nil {
            state.lockoutUntil = nil
            saveLockoutState(state)
        }

        // Load stored hash — if none exists, no PIN is configured so validation passes.
        guard let hashData = try? keychain.getData(forKey: StorageKeys.parentPINHash),
              let storedHash = PINHasher.PINHash(combined: hashData)
        else {
            return .success
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
                var freshState = loadLockoutState()
                freshState.failedAttempts = 0
                freshState.lockoutUntil = lockoutEnd
                saveLockoutState(freshState)
                return .lockedOut(until: lockoutEnd)
            }

            return .failure(attemptsRemaining: remaining)
        }
    }

    func setPIN(_ pin: String) throws {
        guard let hash = hasher.hash(pin: pin) else { return }
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
        let state = loadLockoutState()
        guard let date = state.lockoutUntil, date > Date() else { return nil }
        return date
    }

    // MARK: - Private Helpers

    private func loadLockoutState() -> PINLockoutState {
        (try? keychain.get(PINLockoutState.self, forKey: StorageKeys.pinLockoutState)) ?? PINLockoutState()
    }

    private func saveLockoutState(_ state: PINLockoutState) {
        try? keychain.set(state, forKey: StorageKeys.pinLockoutState)
    }

    private func incrementFailedAttempts() -> Int {
        var state = loadLockoutState()
        state.failedAttempts += 1
        saveLockoutState(state)
        return state.failedAttempts
    }

    private func resetFailedAttempts() {
        saveLockoutState(PINLockoutState())
    }

    private func incrementLockoutStreak() -> Int {
        var state = loadLockoutState()
        state.lockoutStreak += 1
        saveLockoutState(state)
        return state.lockoutStreak
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
