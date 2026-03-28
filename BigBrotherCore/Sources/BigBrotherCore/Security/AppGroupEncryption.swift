import Foundation
import CryptoKit

/// Encrypt/decrypt sensitive App Group files using a device-specific key
/// stored in the shared Keychain. Prevents file tampering by a child
/// with file system access (jailbreak, Xcode-tethered Mac).
public struct AppGroupEncryption {

    private static let keychainKey = StorageKeys.appGroupEncryptionKey
    private static let keyLength = 32 // 256-bit AES key

    /// Ensure the encryption key exists in Keychain. Call on app launch.
    /// Returns the key data, generating a new one if none exists.
    /// Throws if a new key cannot be persisted to Keychain.
    @discardableResult
    public static func ensureKey(keychain: any KeychainProtocol) throws -> Data {
        if let existing = try? keychain.getData(forKey: keychainKey) {
            return existing
        }
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try keychain.setData(keyData, forKey: keychainKey)
        return keyData
    }

    /// Encrypt data for App Group file storage.
    public static func encrypt(_ plaintext: Data, keychain: any KeychainProtocol) throws -> Data {
        let keyData = try ensureKey(keychain: keychain)
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw AppGroupEncryptionError.encryptionFailed
        }
        return combined
    }

    /// Decrypt data from App Group file storage.
    /// Returns nil if decryption fails (e.g., data was written before encryption was enabled).
    public static func decrypt(_ ciphertext: Data, keychain: any KeychainProtocol) -> Data? {
        guard let keyData = try? keychain.getData(forKey: keychainKey) else { return nil }
        let key = SymmetricKey(data: keyData)
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    public enum AppGroupEncryptionError: Error {
        case encryptionFailed
        case keyNotFound
    }
}
