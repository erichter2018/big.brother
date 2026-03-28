import Foundation
import CryptoKit

/// Derive symmetric encryption keys from the family ID for encrypting
/// sensitive data before storing in CloudKit's public database.
///
/// Uses HKDF-SHA256 with the familyID as input key material and a purpose
/// string as context info. Each purpose produces a unique key.
public struct FamilyDerivedKey {

    /// Derive a 256-bit symmetric key from the family ID, an enrollment secret,
    /// and a purpose string.
    ///
    /// The enrollmentSecret (typically the command signing public key) is only
    /// distributed during enrollment, so it's not available to unenrolled devices
    /// reading the public CloudKit database. This prevents someone who only knows
    /// the familyID from deriving the same key.
    public static func deriveKey(from familyID: FamilyID, enrollmentSecret: Data? = nil, purpose: String) -> SymmetricKey {
        var ikm = Data(familyID.rawValue.utf8)
        if let secret = enrollmentSecret, !secret.isEmpty {
            ikm.append(secret)
        } else {
            #if DEBUG
            print("[FamilyDerivedKey] WARNING: Deriving key without enrollment secret — weaker protection")
            #endif
        }
        let info = Data(purpose.utf8)
        let salt = Data("fr.bigbrother.hkdf.salt.v1".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    /// Encrypt data using AES-GCM with a family-derived key.
    public static func encrypt(_ data: Data, familyID: FamilyID, enrollmentSecret: Data? = nil, purpose: String) throws -> Data {
        let key = deriveKey(from: familyID, enrollmentSecret: enrollmentSecret, purpose: purpose)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw FamilyKeyError.encryptionFailed
        }
        return combined
    }

    /// Decrypt data using AES-GCM with a family-derived key.
    public static func decrypt(_ data: Data, familyID: FamilyID, enrollmentSecret: Data? = nil, purpose: String) throws -> Data {
        let key = deriveKey(from: familyID, enrollmentSecret: enrollmentSecret, purpose: purpose)
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    public enum FamilyKeyError: Error {
        case encryptionFailed
    }
}
