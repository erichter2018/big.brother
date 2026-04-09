import Foundation

/// Lightweight enrollment identifiers cached in App Group storage.
///
/// Extensions (ShieldAction, ShieldConfiguration, DeviceActivityMonitor) need
/// deviceID and familyID to create event log entries but cannot reliably
/// access the Keychain from extension context. This struct is written to
/// App Group by the main app at enrollment time and read by extensions.
public struct CachedEnrollmentIDs: Codable, Sendable, Equatable {
    public let deviceID: DeviceID
    public let familyID: FamilyID
    /// User-facing device name, e.g. "Olivia's iPhone". Populated from
    /// ChildDevice.displayName so the tunnel can tag enforcement log records
    /// without relying on UIDevice.current.name (which returns generic
    /// "iPhone"/"iPad" since iOS 16).
    public var deviceDisplayName: String?

    public init(deviceID: DeviceID, familyID: FamilyID, deviceDisplayName: String? = nil) {
        self.deviceID = deviceID
        self.familyID = familyID
        self.deviceDisplayName = deviceDisplayName
    }
}
