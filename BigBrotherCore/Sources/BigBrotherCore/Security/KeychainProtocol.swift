import Foundation

/// Protocol for Keychain operations.
///
/// Abstracted to a protocol so that:
/// - The main app and extensions can share the interface
/// - Unit tests can use an in-memory mock
///
/// Uses the shared Keychain access group so the main app and
/// extensions (e.g., DeviceActivityMonitor) can both read role state.
public protocol KeychainProtocol: Sendable {

    /// Store a Codable value in the Keychain under the given key.
    func set<T: Encodable>(_ value: T, forKey key: String) throws

    /// Retrieve a Codable value from the Keychain.
    func get<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T?

    /// Store raw data in the Keychain.
    func setData(_ data: Data, forKey key: String) throws

    /// Retrieve raw data from the Keychain.
    func getData(forKey key: String) throws -> Data?

    /// Delete a value from the Keychain.
    func delete(forKey key: String) throws

    /// Check whether a key exists in the Keychain.
    func contains(key: String) -> Bool
}
