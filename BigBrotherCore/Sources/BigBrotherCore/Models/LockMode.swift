import Foundation

/// The restriction modes that can be applied to a child device.
public enum LockMode: String, Codable, Sendable, CaseIterable, Equatable {
    /// No restrictions. All apps accessible.
    case unlocked

    /// Block everything except explicitly allowed apps.
    /// The allowed list is defined per-child and per-device.
    case dailyMode

    /// Block everything possible. Only system-unblockable apps
    /// (Phone, Settings) remain usable.
    case fullLockdown

    /// Allow only a narrow essential set: Messages, Maps, Phone,
    /// FaceTime, Find My, Camera, Clock, Contacts.
    /// Best-effort — some system apps cannot be blocked regardless.
    case essentialOnly

    public var displayName: String {
        switch self {
        case .unlocked: "Unlocked"
        case .dailyMode: "Locked"
        case .fullLockdown: "Disabled"
        case .essentialOnly: "Essential Only"
        }
    }
}
