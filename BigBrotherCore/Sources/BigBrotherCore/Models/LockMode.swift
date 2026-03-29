import Foundation

/// The restriction modes that can be applied to a child device.
public enum LockMode: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    /// No restrictions. All apps accessible.
    case unlocked

    /// Block everything except explicitly allowed apps.
    /// The allowed list is defined per-child and per-device.
    case restricted = "dailyMode"

    /// Allow only a narrow essential set: Messages, Maps, Phone,
    /// FaceTime, Find My, Camera, Clock, Contacts.
    /// Best-effort — some system apps cannot be blocked regardless.
    case locked = "essentialOnly"

    /// Essential-only apps AND internet disabled (VPN DNS blackhole).
    /// Most restrictive mode — device is effectively offline.
    case lockedDown

    public var displayName: String {
        switch self {
        case .unlocked: "Unlocked"
        case .restricted: "Restricted"
        case .locked: "Locked"
        case .lockedDown: "Locked Down"
        }
    }

    /// How restrictive this mode is (higher = more restrictive).
    /// Used to determine if a mismatch is a problem (less restrictive than expected = bad).
    public var restrictionLevel: Int {
        switch self {
        case .unlocked: 0
        case .restricted: 1
        case .locked: 2
        case .lockedDown: 3
        }
    }
}
