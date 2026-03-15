import Foundation

/// FNV-1a hash utility for generating stable, short fingerprints from opaque token data.
///
/// Used across the app and extensions to produce human-readable identifiers for
/// ApplicationToken payloads (which are opaque Data blobs on device).
public enum TokenFingerprint {

    /// Compute a 16-character hex fingerprint (FNV-1a 64-bit) for raw data.
    public static func fingerprint(for data: Data) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    /// Compute a fingerprint from a base64-encoded string.
    /// Returns a descriptive fallback if the base64 is invalid.
    public static func fingerprint(forBase64 base64: String) -> String {
        guard let data = Data(base64Encoded: base64) else {
            return "invalid-base64[\(base64.count)]"
        }
        return fingerprint(for: data)
    }
}
