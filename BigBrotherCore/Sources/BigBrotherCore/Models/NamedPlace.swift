import Foundation

/// A named geographic location configured by the parent for arrival/departure notifications.
/// Stored in CloudKit (BBNamedPlace) and synced to child devices as geofences.
public struct NamedPlace: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let familyID: FamilyID
    public let name: String               // "School", "Grandma's House"
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double       // default 150
    public let createdAt: Date
    public let createdBy: String          // parent device/name

    /// Which child profiles this place applies to (empty = all children).
    public let childProfileIDs: [ChildProfileID]

    public init(
        id: UUID = UUID(),
        familyID: FamilyID,
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 150,
        createdAt: Date = Date(),
        createdBy: String = "Parent",
        childProfileIDs: [ChildProfileID] = []
    ) {
        self.id = id
        self.familyID = familyID
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.childProfileIDs = childProfileIDs
    }
}
