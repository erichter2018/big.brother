import Foundation

/// In-memory Keychain implementation for unit testing.
/// Stores data in a dictionary instead of the system Keychain.
public final class MockKeychain: KeychainProtocol, @unchecked Sendable {

    private var storage: [String: Data] = [:]
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    public func set<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try encoder.encode(value)
        try setData(data, forKey: key)
    }

    public func get<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let data = try getData(forKey: key) else { return nil }
        return try decoder.decode(type, from: data)
    }

    public func setData(_ data: Data, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }

    public func getData(forKey key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func delete(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func contains(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] != nil
    }

    /// Reset all stored data. Useful between tests.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
