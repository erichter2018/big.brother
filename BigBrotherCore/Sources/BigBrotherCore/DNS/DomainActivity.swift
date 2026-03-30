import Foundation

/// Aggregated DNS activity for a single domain over a time period.
public struct DomainHit: Codable, Sendable, Equatable {
    public let domain: String
    public var count: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var flagged: Bool
    public var category: String?
    /// Per-slot query counts (key = slot index 0-95, value = count).
    /// Each slot = 15 minutes. Slot 0 = 00:00-00:14, Slot 4 = 01:00-01:14, etc.
    /// Enables time-based scrubbing on the parent dashboard.
    public var slotCounts: [Int: Int]?

    /// Convert hour + minute to slot index (0-95).
    public static func slotIndex(hour: Int, minute: Int) -> Int {
        hour * 4 + minute / 15
    }

    /// Convert slot index to display string like "2:30 PM".
    public static func slotLabel(_ slot: Int) -> String {
        let hour = slot / 4
        let minute = (slot % 4) * 15
        let h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        let ampm = hour < 12 ? "AM" : "PM"
        if minute == 0 { return "\(h12) \(ampm)" }
        return "\(h12):\(String(format: "%02d", minute)) \(ampm)"
    }

    /// Slot range label like "2:30 - 2:45 PM".
    public static func slotRangeLabel(_ slot: Int) -> String {
        let startH = slot / 4, startM = (slot % 4) * 15
        let endSlot = slot + 1
        let endH = endSlot / 4, endM = (endSlot % 4) * 15
        let fmt: (Int, Int) -> String = { h, m in
            let h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
            let ampm = h < 12 ? "AM" : "PM"
            return m == 0 ? "\(h12) \(ampm)" : "\(h12):\(String(format: "%02d", m)) \(ampm)"
        }
        return "\(fmt(startH, startM)) – \(fmt(endH, endM))"
    }

    public init(domain: String, count: Int = 1, firstSeen: Date = Date(), lastSeen: Date = Date(), flagged: Bool = false, category: String? = nil, slotCounts: [Int: Int]? = nil) {
        self.domain = domain
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.flagged = flagged
        self.category = category
        self.slotCounts = slotCounts
    }

    // Backward-compatible decoding
    private enum CodingKeys: String, CodingKey {
        case domain, count, firstSeen, lastSeen, flagged, category, slotCounts, hourlyCounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(String.self, forKey: .domain)
        count = try container.decode(Int.self, forKey: .count)
        firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        flagged = try container.decode(Bool.self, forKey: .flagged)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        // Decode [Int: Int] from [String: Int] since JSON keys must be strings
        if let stringKeyed = try? container.decodeIfPresent([String: Int].self, forKey: .slotCounts) {
            slotCounts = Dictionary(uniqueKeysWithValues: stringKeyed.compactMap { k, v in
                Int(k).map { ($0, v) }
            })
        } else if let stringKeyed = try? container.decodeIfPresent([String: Int].self, forKey: .hourlyCounts) {
            // Migrate old hourly format: spread each hour across 4 slots
            var migrated: [Int: Int] = [:]
            for (k, v) in stringKeyed {
                if let hour = Int(k) { migrated[hour * 4] = v }
            }
            slotCounts = migrated.isEmpty ? nil : migrated
        } else {
            slotCounts = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(count, forKey: .count)
        try container.encode(firstSeen, forKey: .firstSeen)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encode(flagged, forKey: .flagged)
        try container.encodeIfPresent(category, forKey: .category)
        if let slots = slotCounts {
            let stringKeyed = Dictionary(uniqueKeysWithValues: slots.map { (String($0.key), $0.value) })
            try container.encode(stringKeyed, forKey: .slotCounts)
        }
    }

    /// Count for a specific 15-minute slot (0-95).
    public func count(forSlot slot: Int) -> Int {
        slotCounts?[slot] ?? 0
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

    /// Domains active during a specific 15-minute slot, sorted by count for that slot.
    public func domains(forSlot slot: Int) -> [DomainHit] {
        domains
            .filter { ($0.slotCounts?[slot] ?? 0) > 0 }
            .sorted { ($0.slotCounts?[slot] ?? 0) > ($1.slotCounts?[slot] ?? 0) }
    }

    /// Slots (0-95) that have any activity.
    public var activeSlots: Set<Int> {
        var slots = Set<Int>()
        for hit in domains {
            if let sc = hit.slotCounts {
                for (s, c) in sc where c > 0 { slots.insert(s) }
            }
        }
        return slots
    }

    /// Total query count across all domains for a specific slot.
    public func totalQueries(forSlot slot: Int) -> Int {
        domains.reduce(0) { $0 + ($1.slotCounts?[slot] ?? 0) }
    }
}
