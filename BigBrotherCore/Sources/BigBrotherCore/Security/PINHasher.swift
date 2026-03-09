import Foundation
import CommonCrypto

/// PIN hashing and verification using PBKDF2 (CommonCrypto).
///
/// PBKDF2-HMAC-SHA256 with 100,000 iterations and a 32-byte random salt.
/// This provides strong resistance to brute-force attacks on a 4–8 digit PIN.
///
/// Note: bcrypt would be ideal, but CommonCrypto's PBKDF2 is available
/// without external dependencies. The iteration count compensates for
/// the shorter key space of numeric PINs.
public struct PINHasher: Sendable {

    /// Number of PBKDF2 iterations. High count to compensate for short PINs.
    private static let iterations: UInt32 = 100_000

    /// Derived key length in bytes.
    private static let keyLength = 32

    /// Salt length in bytes.
    private static let saltLength = 32

    /// The hash result: salt + derived key, packaged together.
    public struct PINHash: Codable, Sendable, Equatable {
        public let salt: Data
        public let derivedKey: Data

        /// Combined representation for storage.
        public var combined: Data {
            salt + derivedKey
        }

        /// Reconstruct from combined representation.
        public init?(combined: Data) {
            guard combined.count == PINHasher.saltLength + PINHasher.keyLength else {
                return nil
            }
            self.salt = combined.prefix(PINHasher.saltLength)
            self.derivedKey = combined.suffix(PINHasher.keyLength)
        }

        public init(salt: Data, derivedKey: Data) {
            self.salt = salt
            self.derivedKey = derivedKey
        }
    }

    public init() {}

    /// Hash a PIN with a random salt.
    public func hash(pin: String) -> PINHash {
        let salt = randomSalt()
        let derivedKey = deriveKey(pin: pin, salt: salt)
        return PINHash(salt: salt, derivedKey: derivedKey)
    }

    /// Verify a PIN against a stored hash.
    public func verify(pin: String, against stored: PINHash) -> Bool {
        let derived = deriveKey(pin: pin, salt: stored.salt)
        // Constant-time comparison to prevent timing attacks.
        return constantTimeEqual(derived, stored.derivedKey)
    }

    // MARK: - Private

    private func randomSalt() -> Data {
        var salt = Data(count: Self.saltLength)
        salt.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, Self.saltLength, buffer.baseAddress!)
        }
        return salt
    }

    private func deriveKey(pin: String, salt: Data) -> Data {
        let pinData = Data(pin.utf8)
        var derivedKey = Data(count: Self.keyLength)

        _ = derivedKey.withUnsafeMutableBytes { derivedBuffer in
            salt.withUnsafeBytes { saltBuffer in
                pinData.withUnsafeBytes { pinBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        Self.iterations,
                        derivedBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        Self.keyLength
                    )
                }
            }
        }

        return derivedKey
    }

    /// Constant-time comparison of two Data values.
    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for (x, y) in zip(a, b) {
            result |= x ^ y
        }
        return result == 0
    }
}
