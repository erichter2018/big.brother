import Foundation

/// Device-level restrictions managed by the parent.
/// Applied to ManagedSettingsStore alongside app blocking.
/// Stored in App Group so enforcement can reapply on launch.
public struct DeviceRestrictions: Codable, Sendable, Equatable {
    public var denyAppRemoval: Bool
    public var denyExplicitContent: Bool
    public var lockAccounts: Bool
    public var requireAutomaticDateAndTime: Bool
    public var denyWebWhenLocked: Bool

    public init(
        denyAppRemoval: Bool = false,
        denyExplicitContent: Bool = false,
        lockAccounts: Bool = false,
        requireAutomaticDateAndTime: Bool = false,
        denyWebWhenLocked: Bool = false
    ) {
        self.denyAppRemoval = denyAppRemoval
        self.denyExplicitContent = denyExplicitContent
        self.lockAccounts = lockAccounts
        self.requireAutomaticDateAndTime = requireAutomaticDateAndTime
        self.denyWebWhenLocked = denyWebWhenLocked
    }

    /// Custom decoder — uses `decodeIfPresent` so older JSON files missing
    /// newly-added keys still decode instead of failing entirely.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        denyAppRemoval = try container.decodeIfPresent(Bool.self, forKey: .denyAppRemoval) ?? false
        denyExplicitContent = try container.decodeIfPresent(Bool.self, forKey: .denyExplicitContent) ?? false
        lockAccounts = try container.decodeIfPresent(Bool.self, forKey: .lockAccounts) ?? false
        requireAutomaticDateAndTime = try container.decodeIfPresent(Bool.self, forKey: .requireAutomaticDateAndTime) ?? false
        denyWebWhenLocked = try container.decodeIfPresent(Bool.self, forKey: .denyWebWhenLocked) ?? false
    }

    /// Whether any restriction is enabled.
    public var hasAnyRestriction: Bool {
        denyAppRemoval || denyExplicitContent || lockAccounts || requireAutomaticDateAndTime || denyWebWhenLocked
    }
}
