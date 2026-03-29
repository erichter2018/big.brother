import Foundation

/// Aggregated DNS activity for a single domain over a time period.
public struct DomainHit: Codable, Sendable, Equatable {
    public let domain: String
    public var count: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var flagged: Bool
    public var category: String?

    public init(domain: String, count: Int = 1, firstSeen: Date = Date(), lastSeen: Date = Date(), flagged: Bool = false, category: String? = nil) {
        self.domain = domain
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.flagged = flagged
        self.category = category
    }
}

/// A snapshot of DNS activity for a device, synced to CloudKit periodically.
public struct DomainActivitySnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let deviceID: DeviceID
    public let familyID: FamilyID
    public let date: String          // "2026-03-29"
    public let timestamp: Date       // when this snapshot was taken
    public let domains: [DomainHit]  // all observed domains
    public let totalQueries: Int

    public init(
        id: UUID = UUID(),
        deviceID: DeviceID,
        familyID: FamilyID,
        date: String,
        timestamp: Date = Date(),
        domains: [DomainHit],
        totalQueries: Int
    ) {
        self.id = id
        self.deviceID = deviceID
        self.familyID = familyID
        self.date = date
        self.timestamp = timestamp
        self.domains = domains
        self.totalQueries = totalQueries
    }

    /// Top N domains by query count.
    public func topDomains(_ n: Int) -> [DomainHit] {
        domains.sorted { $0.count > $1.count }.prefix(n).map { $0 }
    }

    /// Only flagged domains, sorted by count.
    public var flaggedDomains: [DomainHit] {
        domains.filter(\.flagged).sorted { $0.count > $1.count }
    }
}
