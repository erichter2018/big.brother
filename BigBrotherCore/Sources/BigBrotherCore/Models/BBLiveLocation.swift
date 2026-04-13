import Foundation
import CoreLocation

/// High-frequency location update stored in a single CloudKit record per device.
/// Updated every 2-3 seconds during active live tracking sessions.
public struct BBLiveLocation: Codable, Sendable, Identifiable, Equatable {
    /// The DeviceID of the child device (used as the CKRecord name).
    public let id: DeviceID
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let timestamp: Date
    public let speed: Double?
    public let course: Double?
    /// Recent coordinates for breadcrumb trail visualization (e.g., last 30-60 points).
    public let trail: [Coord]

    public struct Coord: Codable, Sendable, Equatable {
        public let lat: Double
        public let lon: Double

        public init(lat: Double, lon: Double) {
            self.lat = lat
            self.lon = lon
        }
    }

    public init(
        id: DeviceID,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        timestamp: Date = Date(),
        speed: Double? = nil,
        course: Double? = nil,
        trail: [Coord] = []
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.speed = speed
        self.course = course
        self.trail = trail
    }
}
