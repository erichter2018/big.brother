import Foundation

/// Unique family identifier — generated once during parent setup.
/// Acts as the partition key for all CloudKit records.
public struct FamilyID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> FamilyID {
        FamilyID(rawValue: UUID().uuidString)
    }
}

/// Unique child profile identifier.
public struct ChildProfileID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> ChildProfileID {
        ChildProfileID(rawValue: UUID().uuidString)
    }
}

/// Unique device identifier — generated on enrollment, stored in Keychain.
public struct DeviceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> DeviceID {
        DeviceID(rawValue: UUID().uuidString)
    }
}
