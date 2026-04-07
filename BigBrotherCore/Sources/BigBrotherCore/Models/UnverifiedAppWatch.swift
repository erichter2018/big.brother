import Foundation

/// Tracks an unverified app for DNS-based name verification.
/// Created when a child names an app — the tunnel monitors DNS traffic
/// to verify or correct the name over the following days.
public struct UnverifiedAppWatch: Codable, Identifiable {
    public var id: UUID
    public var fingerprint: String
    public var childGivenName: String
    public var deviceID: DeviceID
    public var childProfileID: ChildProfileID
    public var unblockedAt: Date
    /// DNS domains seen in the 60-second window after unblock
    public var immediateDomains: [String]
    /// DNS domains that spiked after this app was allowed (accumulated over days)
    public var newDomainsSinceAllow: [String]
    /// Verified name from DNS catalog match (nil = not yet verified)
    public var verifiedName: String?
    /// Whether the child's name matched the verified name
    public var deceptionDetected: Bool
    /// Whether verification is complete (matched or timed out)
    public var resolved: Bool
    public var resolvedAt: Date?
    public var createdAt: Date

    public init(
        fingerprint: String,
        childGivenName: String,
        deviceID: DeviceID,
        childProfileID: ChildProfileID,
        unblockedAt: Date = Date()
    ) {
        self.id = UUID()
        self.fingerprint = fingerprint
        self.childGivenName = childGivenName
        self.deviceID = deviceID
        self.childProfileID = childProfileID
        self.unblockedAt = unblockedAt
        self.immediateDomains = []
        self.newDomainsSinceAllow = []
        self.verifiedName = nil
        self.deceptionDetected = false
        self.resolved = false
        self.resolvedAt = nil
        self.createdAt = Date()
    }
}
