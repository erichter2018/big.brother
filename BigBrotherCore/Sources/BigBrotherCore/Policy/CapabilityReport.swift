import Foundation

/// Summary of what the enforcement layer can and cannot do on this device.
/// Used to inform the parent of enforcement limitations.
public struct CapabilityReport: Codable, Sendable, Equatable {
    /// Whether FamilyControls .individual authorization is granted.
    public let familyControlsAuthorized: Bool

    /// System apps that can never be blocked by ManagedSettings.
    /// For informational display only.
    public static let unblockableSystemApps: [String] = [
        "Phone",
        "Settings",
    ]

    /// System apps that are partially controllable (may vary by iOS version).
    public static let partiallyControllableApps: [String] = [
        "Messages",
        "FaceTime",
        "Safari",
    ]

    /// Generate a human-readable summary of current limitations.
    public var limitations: [String] {
        var result: [String] = []
        if !familyControlsAuthorized {
            result.append("FamilyControls authorization not granted. No enforcement possible.")
        }
        result.append("Phone and Settings can never be blocked.")
        return result
    }

    public init(familyControlsAuthorized: Bool) {
        self.familyControlsAuthorized = familyControlsAuthorized
    }
}
