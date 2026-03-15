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

    public init(deviceID: DeviceID, familyID: FamilyID) {
        self.deviceID = deviceID
        self.familyID = familyID
    }
}
