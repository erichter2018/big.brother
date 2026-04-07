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

    /// Estimated app usage for a specific 15-minute slot.
    /// Returns apps active in that slot with their proportional share of 15 minutes.
    public func estimatedAppUsage(forSlot slot: Int) -> [(appName: String, minutes: Double)] {
        let slotDomains = domains.filter { ($0.slotCounts?[slot] ?? 0) > 0 }
        guard !slotDomains.isEmpty else { return [] }

        let slotTotal = slotDomains.reduce(0) { $0 + ($1.slotCounts?[slot] ?? 0) }
        guard slotTotal > 0 else { return [] }

        var appQueries: [String: Int] = [:]
        for hit in slotDomains {
            guard let name = DomainCategorizer.appName(for: DomainCategorizer.rootDomain(hit.domain)) else { continue }
            appQueries[name, default: 0] += hit.slotCounts?[slot] ?? 0
        }

        // Meta disambiguation for this slot
        if let igQ = appQueries["Instagram"], igQ > 0, let fbQ = appQueries["Facebook"] {
            appQueries["Instagram"] = igQ + fbQ
            appQueries.removeValue(forKey: "Facebook")
        }

        return appQueries
            .map { (appName: $0.key, minutes: Double($0.value) / Double(slotTotal) * 15.0) }
            .filter { $0.minutes >= 0.5 }
            .sorted { $0.minutes > $1.minutes }
    }

    /// Estimated app usage in minutes using proportional time allocation.
    ///
    /// For each 15-minute slot, app queries are divided by total queries in that slot
    /// to get the app's share of that time window. This avoids inflating usage when
    /// multiple apps share a slot or background queries dominate.
    ///
    /// Returns sorted array of (appName, estimatedMinutes) descending by minutes.
    public func estimatedAppUsage() -> [(appName: String, minutes: Double)] {
        // Map each domain to its app name (if any)
        var appDomains: [String: [DomainHit]] = [:]
        for hit in domains {
            guard let name = DomainCategorizer.appName(for: DomainCategorizer.rootDomain(hit.domain)) else { continue }
            appDomains[name, default: []].append(hit)
        }

        // Meta disambiguation: Instagram app makes heavy use of facebook.com API.
        // If both "Instagram" and "Facebook" have activity, re-attribute facebook.com
        // queries to Instagram for slots where both are active. Only count Facebook
        // when there's no concurrent Instagram activity.
        if appDomains["Instagram"] != nil, let fbHits = appDomains["Facebook"] {
            let igHits = appDomains["Instagram"]!
            let hasSlots = igHits.contains { $0.slotCounts != nil }
            if hasSlots {
                // Per-slot: check which slots have Instagram activity
                var igSlots = Set<Int>()
                for hit in igHits {
                    if let sc = hit.slotCounts { for (s, c) in sc where c > 0 { igSlots.insert(s) } }
                }
                // Move facebook.com queries in Instagram-active slots to Instagram
                var movedToIG: [DomainHit] = []
                var remainFB: [DomainHit] = []
                for var hit in fbHits {
                    if let sc = hit.slotCounts {
                        var igPart: [Int: Int] = [:]
                        var fbPart: [Int: Int] = [:]
                        for (s, c) in sc {
                            if igSlots.contains(s) { igPart[s] = c } else { fbPart[s] = c }
                        }
                        if !igPart.isEmpty {
                            var igHit = hit; igHit.slotCounts = igPart
                            igHit.count = igPart.values.reduce(0, +)
                            movedToIG.append(igHit)
                        }
                        if !fbPart.isEmpty {
                            hit.slotCounts = fbPart; hit.count = fbPart.values.reduce(0, +)
                            remainFB.append(hit)
                        }
                    } else {
                        // No slot data — attribute all to Instagram if IG has more total queries
                        let igTotal = igHits.reduce(0) { $0 + $1.count }
                        let fbTotal = fbHits.reduce(0) { $0 + $1.count }
                        if igTotal > fbTotal { movedToIG.append(hit) } else { remainFB.append(hit) }
                    }
                }
                appDomains["Instagram"]!.append(contentsOf: movedToIG)
                if remainFB.isEmpty {
                    appDomains.removeValue(forKey: "Facebook")
                } else {
                    appDomains["Facebook"] = remainFB
                }
            } else {
                // No slot data — if Instagram queries > Facebook, attribute all FB to IG
                let igTotal = igHits.reduce(0) { $0 + $1.count }
                _ = fbHits.reduce(0) { $0 + $1.count } // FB total unused but kept for clarity
                if igTotal > 0 {
                    appDomains["Instagram"]!.append(contentsOf: fbHits)
                    appDomains.removeValue(forKey: "Facebook")
                }
            }
        }

        guard !appDomains.isEmpty else { return [] }

        // Check if we have slot data (per-day snapshots) or just aggregate counts (7-day).
        let hasSlotData = domains.contains { $0.slotCounts != nil && !($0.slotCounts?.isEmpty ?? true) }

        var appMinutes: [String: Double] = [:]

        if hasSlotData {
            // Per-slot proportional allocation (accurate for single-day snapshots)
            for slot in 0..<96 {
                let slotTotal = totalQueries(forSlot: slot)
                guard slotTotal > 0 else { continue }

                for (appName, hits) in appDomains {
                    let appQueries = hits.reduce(0) { $0 + ($1.slotCounts?[slot] ?? 0) }
                    guard appQueries > 0 else { continue }
                    let share = Double(appQueries) / Double(slotTotal) * 15.0
                    appMinutes[appName, default: 0] += share
                }
            }
        } else {
            // Fallback for multi-day aggregates (no slot data): use query count proportions.
            // Total recognized app queries determine each app's share of total screen time.
            let totalAppQueries = appDomains.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
            guard totalAppQueries > 0, totalQueries > 0 else { return [] }

            // Estimate total screen-on minutes from active slots across all days in the snapshot.
            // Each unique slot with activity ≈ 15 minutes of screen time.
            // For multi-day, use totalQueries as a proxy: ~4 queries/min is typical.
            let estimatedTotalMinutes = Double(totalQueries) / 4.0

            for (appName, hits) in appDomains {
                let appQueries = hits.reduce(0) { $0 + $1.count }
                let share = Double(appQueries) / Double(totalQueries) * estimatedTotalMinutes
                appMinutes[appName, default: 0] += share
            }
        }

        return appMinutes
            .map { (appName: $0.key, minutes: $0.value) }
            .filter { $0.minutes >= 1.0 }
            .sorted { $0.minutes > $1.minutes }
    }
}
