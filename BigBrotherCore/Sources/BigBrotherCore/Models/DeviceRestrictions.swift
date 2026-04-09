import Foundation

/// Device-level restrictions managed by the parent.
/// Applied to ManagedSettingsStore alongside app blocking.
/// Stored in App Group so enforcement can reapply on launch.
public struct DeviceRestrictions: Codable, Sendable, Equatable {
    public var denyAppRemoval: Bool
    public var denyExplicitContent: Bool
    public var lockAccounts: Bool
    public var requireAutomaticDateAndTime: Bool
    /// Block all web browsing when device is in restricted mode.
    /// (Named "denyWebWhenLocked" in JSON for backwards compatibility.)
    public var denyWebWhenRestricted: Bool
    public var denyWebGamesWhenRestricted: Bool

    /// JSON key mapping — keeps "denyWebWhenLocked" on the wire for
    /// backwards compatibility with existing App Group files and CloudKit.
    private enum CodingKeys: String, CodingKey {
        case denyAppRemoval
        case denyExplicitContent
        case lockAccounts
        case requireAutomaticDateAndTime
        case denyWebWhenRestricted = "denyWebWhenLocked"
        case denyWebGamesWhenRestricted
    }

    public init(
        denyAppRemoval: Bool = false,
        denyExplicitContent: Bool = false,
        lockAccounts: Bool = false,
        requireAutomaticDateAndTime: Bool = false,
        denyWebWhenRestricted: Bool = false,
        denyWebGamesWhenRestricted: Bool = false
    ) {
        self.denyAppRemoval = denyAppRemoval
        self.denyExplicitContent = denyExplicitContent
        self.lockAccounts = lockAccounts
        self.requireAutomaticDateAndTime = requireAutomaticDateAndTime
        self.denyWebWhenRestricted = denyWebWhenRestricted
        self.denyWebGamesWhenRestricted = denyWebGamesWhenRestricted
    }

    /// Custom decoder — uses `decodeIfPresent` so older JSON files missing
    /// newly-added keys still decode instead of failing entirely.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        denyAppRemoval = try container.decodeIfPresent(Bool.self, forKey: .denyAppRemoval) ?? false
        denyExplicitContent = try container.decodeIfPresent(Bool.self, forKey: .denyExplicitContent) ?? false
        lockAccounts = try container.decodeIfPresent(Bool.self, forKey: .lockAccounts) ?? false
        requireAutomaticDateAndTime = try container.decodeIfPresent(Bool.self, forKey: .requireAutomaticDateAndTime) ?? false
        denyWebWhenRestricted = try container.decodeIfPresent(Bool.self, forKey: .denyWebWhenRestricted) ?? false
        denyWebGamesWhenRestricted = try container.decodeIfPresent(Bool.self, forKey: .denyWebGamesWhenRestricted) ?? false
    }

    /// Whether any restriction is enabled.
    public var hasAnyRestriction: Bool {
        denyAppRemoval || denyExplicitContent || lockAccounts || requireAutomaticDateAndTime || denyWebWhenRestricted || denyWebGamesWhenRestricted
    }
}
