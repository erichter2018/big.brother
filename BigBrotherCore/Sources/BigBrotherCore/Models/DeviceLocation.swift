import Foundation

/// A location breadcrumb from a child device, stored in CloudKit for parent visibility.
/// Retained for 7 days then auto-purged.
public struct DeviceLocation: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let deviceID: DeviceID
    public let familyID: FamilyID
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let timestamp: Date
    public let address: String?
    /// Speed in m/s from CLLocation.speed (negative = invalid).
    public let speed: Double?
    /// Course in degrees from CLLocation.course (negative = invalid).
    public let course: Double?

    public init(
        id: UUID = UUID(),
        deviceID: DeviceID,
        familyID: FamilyID,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        timestamp: Date = Date(),
        address: String? = nil,
        speed: Double? = nil,
        course: Double? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.familyID = familyID
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.address = address
        self.speed = speed
        self.course = course
    }
}

/// Location tracking mode configured by parent per child.
public enum LocationTrackingMode: String, Codable, Sendable, Equatable {
    case off         // No location tracking
    case onDemand    // Parent taps "Locate" for one-shot
    case continuous  // Background significant-location-change monitoring
}
