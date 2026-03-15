import Foundation
import Security

/// Concrete Keychain implementation using Security framework.
///
/// Uses a shared Keychain access group so both the main app and
/// extensions can access enrollment state and role information.
public final class KeychainManager: KeychainProtocol, @unchecked Sendable {

    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Initialize with the shared keychain access group by default.
    ///
    /// By passing `nil` as the default, iOS automatically uses the first keychain access
    /// group defined in the target's .entitlements file (which resolves the Team ID dynamically).
    /// This prevents errSecMissingEntitlement (-34018) across different developer accounts.
    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    // MARK: - KeychainProtocol

    public func set<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try encoder.encode(value)
        try setData(data, forKey: key)
    }

    public func get<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let data = try getData(forKey: key) else { return nil }
        return try decoder.decode(type, from: data)
    }

    public func setData(_ data: Data, forKey key: String) throws {
        // Delete existing item first to avoid errSecDuplicateItem
        try? delete(forKey: key)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func getData(forKey key: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func delete(forKey key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func contains(key: String) -> Bool {
        (try? getData(forKey: key)) != nil
    }
}

/// Keychain operation errors.
public enum KeychainError: Error, Sendable {
    case unhandledError(status: OSStatus)
}
