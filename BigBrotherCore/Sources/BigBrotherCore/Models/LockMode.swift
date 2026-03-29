import Foundation

/// The restriction modes that can be applied to a child device.
/// Custom Codable: reads both old ("dailyMode"/"essentialOnly") and new ("restricted"/"locked")
/// values, but always writes the new clean values.
public enum LockMode: String, Sendable, CaseIterable, Equatable, Hashable {
    /// No restrictions. All apps accessible.
    case unlocked

    /// Block everything except explicitly allowed apps.
    /// The allowed list is defined per-child and per-device.
    case restricted

    /// Allow only a narrow essential set: Messages, Maps, Phone,
    /// FaceTime, Find My, Camera, Clock, Contacts.
    /// Best-effort — some system apps cannot be blocked regardless.
    case locked

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

    /// Initialize from a raw string, accepting both old ("dailyMode"/"essentialOnly")
    /// and new ("restricted"/"locked") values. Use this instead of init(rawValue:)
    /// when reading from CloudKit or any external storage.
    public static func from(_ raw: String) -> LockMode? {
        if let mode = LockMode(rawValue: raw) { return mode }
        return legacyMapping[raw]
    }

    private static let legacyMapping: [String: LockMode] = [
        "dailyMode": .restricted,
        "essentialOnly": .locked,
    ]
}

// MARK: - Codable (reads old + new values, writes new)

extension LockMode: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let mode = LockMode.from(raw) {
            self = mode
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown LockMode: \(raw)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue) // always writes the new clean value
    }
}
