import Foundation
import CryptoKit

/// ED25519 command signing and verification.
///
/// Parent signs mode commands with a private key generated during family setup.
/// Child verifies signatures using the parent's public key (delivered at enrollment).
/// This prevents a child from forging commands in the CloudKit public database.
public struct CommandSigner {

    // MARK: - Key Generation

    /// Generate a new ED25519 keypair. Returns raw key data.
    public static func generateKeyPair() -> (privateKey: Data, publicKey: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        return (privateKey.rawRepresentation, privateKey.publicKey.rawRepresentation)
    }

    // MARK: - Signing (parent side)

    /// Sign a command's canonical payload with the parent's private key.
    /// Returns a base64-encoded signature string.
    public static func sign(command: SignableCommand, privateKeyData: Data) throws -> String {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let payload = canonicalPayload(command: command)
        let signature = try privateKey.signature(for: payload)
        return signature.base64EncodedString()
    }

    // MARK: - Verification (child side)

    /// Verify a command's signature against the parent's public key.
    public static func verify(command: SignableCommand, signatureBase64: String, publicKeyData: Data) -> Bool {
        guard let signatureData = Data(base64Encoded: signatureBase64) else { return false }
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else { return false }
        let payload = canonicalPayload(command: command)
        return publicKey.isValidSignature(signatureData, for: payload)
    }

    // MARK: - Canonical Payload

    /// Build a deterministic byte payload from the command fields that matter.
    /// Fields: id, familyID, target (JSON), action (JSON), issuedAt (unix timestamp).
    /// Uses sorted-key JSON encoding for determinism.
    public static func canonicalPayload(command: SignableCommand) -> Data {
        var parts: [Data] = []

        // 1. Command ID
        parts.append(Data(command.id.uuidString.utf8))

        // 2. Family ID
        parts.append(Data(command.familyID.rawValue.utf8))

        // 3. Target — deterministic string representation
        let targetString: String
        switch command.target {
        case .device(let did): targetString = "device:\(did.rawValue)"
        case .child(let cid): targetString = "child:\(cid.rawValue)"
        case .allDevices: targetString = "all"
        }
        parts.append(Data(targetString.utf8))

        // 4. Action — JSON with sorted keys for determinism
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let actionData = try? encoder.encode(command.action) {
            parts.append(actionData)
        }

        // 5. Issued-at timestamp (integer seconds since epoch for determinism)
        let timestamp = String(Int(command.issuedAt.timeIntervalSince1970))
        parts.append(Data(timestamp.utf8))

        // Join with separator byte (0x00) to prevent field concatenation collisions
        var result = Data()
        for (i, part) in parts.enumerated() {
            if i > 0 { result.append(0x00) }
            result.append(part)
        }
        return result
    }
}

/// Protocol for the fields needed by CommandSigner.
/// Avoids coupling directly to RemoteCommand so tests can use lightweight stubs.
public protocol SignableCommand {
    var id: UUID { get }
    var familyID: FamilyID { get }
    var target: CommandTarget { get }
    var action: CommandAction { get }
    var issuedAt: Date { get }
}
