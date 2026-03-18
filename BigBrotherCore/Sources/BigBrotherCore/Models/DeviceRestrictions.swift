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
        denyWebWhenLocked: Bool = true
    ) {
        self.denyAppRemoval = denyAppRemoval
        self.denyExplicitContent = denyExplicitContent
        self.lockAccounts = lockAccounts
        self.requireAutomaticDateAndTime = requireAutomaticDateAndTime
        self.denyWebWhenLocked = denyWebWhenLocked
    }

    /// Whether any restriction is enabled.
    public var hasAnyRestriction: Bool {
        denyAppRemoval || denyExplicitContent || lockAccounts || requireAutomaticDateAndTime || denyWebWhenLocked
    }
}
