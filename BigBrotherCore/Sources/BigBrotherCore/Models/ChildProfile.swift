import Foundation

/// A child profile represents one child in the family.
/// A child may have multiple enrolled devices.
public struct ChildProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: ChildProfileID
    public let familyID: FamilyID
    public var name: String
    public var avatarName: String?

    /// Serialized FamilyControls ApplicationTokens for always-allowed apps.
    /// These are device-local opaque tokens. Stored as Data because
    /// BigBrotherCore does not import FamilyControls.
    /// Decoded to ApplicationToken only on the originating device.
    public var alwaysAllowedTokensData: Data?

    /// Category-level always-allowed list (universal across devices).
    /// Values are category identifier strings from ActivityCategoryToken.
    public var alwaysAllowedCategories: Set<String>

    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ChildProfileID = .generate(),
        familyID: FamilyID,
        name: String,
        avatarName: String? = nil,
        alwaysAllowedTokensData: Data? = nil,
        alwaysAllowedCategories: Set<String> = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.familyID = familyID
        self.name = name
        self.avatarName = avatarName
        self.alwaysAllowedTokensData = alwaysAllowedTokensData
        self.alwaysAllowedCategories = alwaysAllowedCategories
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
