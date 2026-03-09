import Foundation
import BigBrotherCore

/// Generates cryptographically random enrollment codes.
///
/// Codes are 8 characters from a 32-char alphabet (uppercase letters + digits,
/// excluding ambiguous: 0/O, 1/I/L).
///
/// 32^8 ≈ 1.1 trillion combinations — infeasible to brute-force
/// within the 30-minute validity window.
struct CodeGenerator {

    /// Generate a random enrollment code.
    static func generate(length: Int = AppConstants.enrollmentCodeLength) -> String {
        let chars = Defaults.enrollmentCodeCharacterSet
        var code = ""
        code.reserveCapacity(length)

        for _ in 0..<length {
            var randomByte: UInt8 = 0
            // Use SecRandomCopyBytes for cryptographic randomness.
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &randomByte)
            let index = Int(randomByte) % chars.count
            code.append(chars[index])
        }

        return code
    }
}
