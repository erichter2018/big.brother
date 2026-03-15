import Foundation

/// Configuration for what gets blocked in each mode.
/// Stored locally on the child device (tokens are device-local).
/// This is the pure-Swift representation — actual tokens are stored
/// separately by the app target.
public struct AppBlockingConfig: Codable, Sendable, Equatable {
    /// Human-readable summary of what's blocked (for parent dashboard).
    public var blockedCategoryCount: Int
    public var allowedAppCount: Int
    /// Whether the config has been set up on this device.
    public var isConfigured: Bool
    /// Names of blocked/selected apps (extracted from tokens on child device).
    public var blockedAppNames: [String]
    /// Names of blocked/selected categories.
    public var blockedCategoryNames: [String]

    public init(
        blockedCategoryCount: Int = 0,
        allowedAppCount: Int = 0,
        isConfigured: Bool = false,
        blockedAppNames: [String] = [],
        blockedCategoryNames: [String] = []
    ) {
        self.blockedCategoryCount = blockedCategoryCount
        self.allowedAppCount = allowedAppCount
        self.isConfigured = isConfigured
        self.blockedAppNames = blockedAppNames
        self.blockedCategoryNames = blockedCategoryNames
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case blockedCategoryCount
        case allowedAppCount
        case isConfigured
        case blockedAppNames
        case blockedCategoryNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockedCategoryCount = try container.decode(Int.self, forKey: .blockedCategoryCount)
        allowedAppCount = try container.decode(Int.self, forKey: .allowedAppCount)
        isConfigured = try container.decode(Bool.self, forKey: .isConfigured)
        blockedAppNames = try container.decodeIfPresent([String].self, forKey: .blockedAppNames) ?? []
        blockedCategoryNames = try container.decodeIfPresent([String].self, forKey: .blockedCategoryNames) ?? []
    }
}
