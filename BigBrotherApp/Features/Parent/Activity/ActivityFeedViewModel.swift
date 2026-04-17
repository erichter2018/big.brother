import Foundation
import SwiftUI
import CloudKit
import BigBrotherCore

/// View model for the Activity feed tab on the parent dashboard.
@Observable
@MainActor
final class ActivityFeedViewModel {

    let appState: AppState

    var events: [ActivityEvent] = []
    var isLoading = false
    var selectedChildID: ChildProfileID?
    var selectedFilter: EventFilter = .report
    var unreadCount: Int = 0
    var weeklySummary: WeeklySummary?

    private var lastViewedAt: Date {
        get { UserDefaults.standard.object(forKey: "activityLastViewedAt") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "activityLastViewedAt") }
    }

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Sorted Children (uses dashboard order from Settings)

    var sortedChildProfiles: [ChildProfile] {
        appState.orderedChildProfiles
    }

    // MARK: - Grouped by Day

    struct DayGroup {
        let date: String   // "2026-03-27" for identity
        let label: String  // "Today", "Yesterday", "Wed, Mar 26"
        let events: [ActivityEvent]
    }

    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()
    private static let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var groupedByDay: [DayGroup] {
        let cal = Calendar.current
        let formatter = Self.dayLabelFormatter

        var groups: [String: (label: String, events: [ActivityEvent])] = [:]
        let dateKeyFmt = Self.dateKeyFormatter

        for event in events {
            let key = dateKeyFmt.string(from: event.timestamp)
            let label: String
            if cal.isDateInToday(event.timestamp) { label = "Today" }
            else if cal.isDateInYesterday(event.timestamp) { label = "Yesterday" }
            else { label = formatter.string(from: event.timestamp) }

            if groups[key] == nil {
                groups[key] = (label: label, events: [event])
            } else {
                groups[key]!.events.append(event)
            }
        }

        return groups.sorted { $0.key > $1.key }
            .map { DayGroup(date: $0.key, label: $0.value.label, events: $0.value.events) }
    }

    // MARK: - Filtering

    enum EventFilter: String, CaseIterable {
        case report = "Report"
        case all = "All"
        case driving = "Driving"
        case places = "Places"
        case safety = "Safety"
    }

    /// Event types to show in the feed. Excludes noisy internal events like
    /// authorizationRestored (fires every heartbeat cycle) and policyReconciled.
    private static let visibleTypes: Set<EventType> = [
        .speedingDetected, .phoneWhileDriving, .hardBrakingDetected,
        .namedPlaceArrival, .namedPlaceDeparture, .tripCompleted,
        .authorizationLost, .enforcementDegraded,
        .unlockRequested, .temporaryUnlockStarted, .temporaryUnlockExpired,
        .localPINUnlock, .enrollmentCompleted, .enrollmentRevoked,
        .sosAlert, .selfUnlockUsed, .newAppDetected,
    ]

    private func matchesFilter(_ type: EventType) -> Bool {
        switch selectedFilter {
        case .report: return false
        case .all: return true
        case .driving:
            return [.speedingDetected, .phoneWhileDriving, .hardBrakingDetected, .tripCompleted].contains(type)
        case .places:
            return [.namedPlaceArrival, .namedPlaceDeparture].contains(type)
        case .safety:
            return [.authorizationLost, .authorizationRestored, .enforcementDegraded,
                    .familyControlsAuthChanged, .enrollmentRevoked].contains(type)
        }
    }

    // MARK: - Data Loading

    func loadEvents() async {
        isLoading = true
        defer { isLoading = false }

        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }

        let since = Date().addingTimeInterval(-7 * 86400)
        let profiles = appState.childProfiles
        let devices = appState.childDevices
        do {
            let rawEvents = try await cloudKit.fetchEventLogs(familyID: familyID, since: since, types: Self.visibleTypes)

            let filtered = rawEvents
                .filter { selectedChildID == nil || deviceBelongsToChild($0.deviceID, childID: selectedChildID!, devices: devices) }
                .filter { matchesFilter($0.eventType) }
                .sorted { $0.timestamp > $1.timestamp }

            // Deduplicate rapid-fire events: collapse same type + same device within 5 min
            var deduped: [EventLogEntry] = []
            for entry in filtered {
                if let last = deduped.last,
                   last.eventType == entry.eventType,
                   last.deviceID == entry.deviceID,
                   abs(last.timestamp.timeIntervalSince(entry.timestamp)) < 300 {
                    continue // Skip duplicate
                }
                deduped.append(entry)
            }

            events = deduped
                .prefix(200)
                .map { entry in
                    ActivityEvent(
                        entry: entry,
                        childName: resolveChildName(deviceID: entry.deviceID, profiles: profiles, devices: devices)
                    )
                }

            unreadCount = rawEvents.filter { $0.timestamp > lastViewedAt }.count

            // Safety notifications
            for profile in profiles {
                let deviceIDs = Set(devices.filter { $0.childProfileID == profile.id }.map(\.id))
                let childEvents = rawEvents.filter { deviceIDs.contains($0.deviceID) }
                SafetyEventNotificationService.checkAndNotify(events: childEvents, childName: profile.name)
            }

            // Compute weekly summary (unfiltered — always shows full picture)
            // Use ordered profiles so children appear in the same order as the dashboard
            weeklySummary = await computeWeeklySummary(events: rawEvents, profiles: sortedChildProfiles, devices: devices)

            // Weekly digest push notification (fires at most once per 6 days)
            var heartbeatsByChild: [ChildProfileID: [DeviceHeartbeat]] = [:]
            for profile in profiles {
                heartbeatsByChild[profile.id] = appState.latestHeartbeats(for: profile.id)
            }
            WeeklyDigestService.checkAndSend(
                profiles: profiles,
                devices: devices,
                heartbeats: heartbeatsByChild,
                events: rawEvents
            )
        } catch {
            NSLog("[Activity] fetchEventLogs failed: \(error.localizedDescription) — building summary from heartbeat/DNS only")
            // Don't leave the Report tab blank on CK failure — heartbeat and
            // DNS snapshots are cached locally and still produce a meaningful
            // weekly summary (screen time, top apps, unlock counts). Events
            // drive the safety/unlock counters, which will just read as 0.
            weeklySummary = await computeWeeklySummary(events: [], profiles: sortedChildProfiles, devices: devices)
        }
    }

    func markAsViewed() {
        lastViewedAt = Date()
        unreadCount = 0
    }

    // MARK: - Helpers

    private func deviceBelongsToChild(_ deviceID: DeviceID, childID: ChildProfileID, devices: [ChildDevice]) -> Bool {
        devices.first { $0.id == deviceID }?.childProfileID == childID
    }

    /// Resolve the child profile for a device ID (used by the view for navigation).
    func resolveChild(deviceID: DeviceID) -> ChildProfile? {
        guard let device = appState.childDevices.first(where: { $0.id == deviceID }),
              let profile = appState.childProfiles.first(where: { $0.id == device.childProfileID }) else {
            return nil
        }
        return profile
    }

    private func resolveChildName(deviceID: DeviceID, profiles: [ChildProfile], devices: [ChildDevice]) -> String {
        guard let device = devices.first(where: { $0.id == deviceID }),
              let profile = profiles.first(where: { $0.id == device.childProfileID }) else {
            return "I"
        }
        return profile.name
    }

    // MARK: - Weekly Summary

    /// Fetch and merge DNS snapshots for a child across all devices for the
    /// last 7 days. All CK record fetches run in parallel — previously this
    /// was a serial N×7 waterfall which took ~30-60s on a slow cloudd and
    /// left the Activity Report tab stuck on "No Data" waiting for it.
    private func fetchWeekDNSSnapshot(for childID: ChildProfileID, devices: [ChildDevice]) async -> DomainActivitySnapshot? {
        guard appState.cloudKit != nil else { return nil }
        let childDevices = devices.filter { $0.childProfileID == childID }
        guard !childDevices.isEmpty else { return nil }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let dates = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }.map { dateFmt.string(from: $0) }

        let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase

        struct FetchResult: Sendable {
            let hits: [DomainHit]
            let total: Int
        }

        let results = await withTaskGroup(of: FetchResult?.self) { group -> [FetchResult] in
            for device in childDevices {
                for dateStr in dates {
                    let recordName = "BBDNSActivity_\(device.id.rawValue)_\(dateStr)"
                    group.addTask {
                        do {
                            let record = try await db.record(for: CKRecord.ID(recordName: recordName))
                            guard let json = record["domainsJSON"] as? String,
                                  let data = json.data(using: .utf8),
                                  let hits = try? JSONDecoder().decode([DomainHit].self, from: data) else { return nil }
                            let recTotal = (record["totalQueries"] as? Int64).map { Int($0) } ?? hits.reduce(0) { $0 + $1.count }
                            return FetchResult(hits: hits, total: recTotal)
                        } catch {
                            return nil // Record may not exist for this date
                        }
                    }
                }
            }
            var collected: [FetchResult] = []
            for await value in group {
                if let value { collected.append(value) }
            }
            return collected
        }

        var allHits: [String: DomainHit] = [:]
        var totalQueries = 0
        for result in results {
            totalQueries += result.total
            for hit in result.hits {
                if var existing = allHits[hit.domain] {
                    existing.count += hit.count
                    if let sc = hit.slotCounts {
                        var merged = existing.slotCounts ?? [:]
                        for (s, c) in sc { merged[s, default: 0] += c }
                        existing.slotCounts = merged
                    }
                    if hit.flagged { existing.flagged = true; existing.category = hit.category }
                    allHits[hit.domain] = existing
                } else {
                    allHits[hit.domain] = hit
                }
            }
        }

        guard !allHits.isEmpty else { return nil }
        return DomainActivitySnapshot(
            deviceID: childDevices.first!.id,
            familyID: childDevices.first!.familyID,
            date: dateFmt.string(from: Date()),
            domains: Array(allHits.values),
            totalQueries: totalQueries
        )
    }

    private func computeWeeklySummary(events: [EventLogEntry], profiles: [ChildProfile], devices: [ChildDevice]) async -> WeeklySummary {
        var childSummaries: [WeeklySummary.ChildWeek] = []

        for profile in profiles {
            let deviceIDs = Set(devices.filter { $0.childProfileID == profile.id }.map(\.id))
            let childEvents = events.filter { deviceIDs.contains($0.deviceID) }

            let safetyCount = childEvents.filter {
                [.speedingDetected, .phoneWhileDriving, .hardBrakingDetected, .sosAlert].contains($0.eventType)
            }.count

            let unlockRequests = childEvents.filter { $0.eventType == .unlockRequested }.count
            let selfUnlocks = childEvents.filter { $0.eventType == .selfUnlockUsed }.count
            let trips = childEvents.filter { $0.eventType == .tripCompleted }.count

            let newApps = childEvents
                .filter { $0.eventType == .newAppDetected }
                .compactMap { $0.details?.replacingOccurrences(of: "New app activity: ", with: "") }

            // Heartbeat data
            let heartbeats = appState.latestHeartbeats(for: profile.id)

            let avgScreenTime: Int? = {
                let values = heartbeats.compactMap(\.screenTimeMinutes).filter { $0 > 0 }
                guard !values.isEmpty else { return nil }
                return values.reduce(0, +) / values.count
            }()

            let avgUnlocks: Int? = {
                let values = heartbeats.compactMap(\.screenUnlockCount).filter { $0 > 0 }
                guard !values.isEmpty else { return nil }
                return values.reduce(0, +) / values.count
            }()

            // DNS activity — fetch week snapshot from CloudKit
            let weekSnap = await fetchWeekDNSSnapshot(for: profile.id, devices: devices)
            let topApps: [(name: String, minutes: Double)] = weekSnap?.estimatedAppUsage().prefix(5).map { (name: $0.appName, minutes: $0.minutes) } ?? []
            let flaggedCount = weekSnap?.flaggedDomains.count ?? 0
            let flaggedDomains = weekSnap?.flaggedDomains.prefix(5).map(\.domain) ?? []
            let sitesVisited = weekSnap?.domains.filter { !DomainCategorizer.isNoise($0.domain) }.count ?? 0

            // Most active time of day
            let peakHour: String? = {
                guard let snap = weekSnap else { return nil }
                let slots = (0..<96).map { (slot: $0, count: snap.totalQueries(forSlot: $0)) }
                guard let peak = slots.max(by: { $0.count < $1.count }), peak.count > 0 else { return nil }
                let hour = peak.slot / 4
                let ampm = hour < 12 ? "AM" : "PM"
                let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
                return "\(displayHour) \(ampm)"
            }()

            childSummaries.append(WeeklySummary.ChildWeek(
                name: profile.name,
                totalEvents: childEvents.count,
                safetyEvents: safetyCount,
                unlockRequests: unlockRequests,
                selfUnlocks: selfUnlocks,
                trips: trips,
                newApps: newApps,
                avgScreenTimeMinutes: avgScreenTime,
                avgDailyUnlocks: avgUnlocks,
                topApps: topApps,
                flaggedAttempts: flaggedCount,
                flaggedDomains: flaggedDomains,
                sitesVisited: sitesVisited,
                peakHour: peakHour
            ))
        }

        return WeeklySummary(children: childSummaries)
    }
}

// MARK: - Weekly Summary Model

struct WeeklySummary {
    let children: [ChildWeek]

    struct ChildWeek {
        let name: String
        let totalEvents: Int
        let safetyEvents: Int
        let unlockRequests: Int
        let selfUnlocks: Int
        let trips: Int
        let newApps: [String]
        let avgScreenTimeMinutes: Int?
        let avgDailyUnlocks: Int?
        let topApps: [(name: String, minutes: Double)]
        let flaggedAttempts: Int
        let flaggedDomains: [String]
        let sitesVisited: Int
        let peakHour: String?
    }
}

// MARK: - Activity Event

struct ActivityEvent: Identifiable, Equatable {
    let id: UUID
    let childName: String
    let eventType: EventType
    let details: String?
    let timestamp: Date
    let deviceID: DeviceID

    init(entry: EventLogEntry, childName: String) {
        self.id = entry.id
        self.childName = childName
        self.eventType = entry.eventType
        self.details = entry.details
        self.timestamp = entry.timestamp
        self.deviceID = entry.deviceID
    }

    var icon: String {
        switch eventType {
        case .speedingDetected: return "gauge.with.dots.needle.67percent"
        case .phoneWhileDriving: return "iphone.gen3.radiowaves.left.and.right"
        case .hardBrakingDetected: return "exclamationmark.octagon"
        case .namedPlaceArrival: return "figure.walk.arrival"
        case .namedPlaceDeparture: return "figure.walk.departure"
        case .tripCompleted: return "car.fill"
        case .authorizationLost, .familyControlsAuthChanged: return "exclamationmark.shield"
        case .authorizationRestored: return "checkmark.shield"
        case .enforcementDegraded: return "shield.slash"
        case .unlockRequested: return "lock.open"
        case .temporaryUnlockStarted: return "lock.open.fill"
        case .temporaryUnlockExpired: return "lock.fill"
        case .modeChanged: return "switch.2"
        case .localPINUnlock: return "key"
        case .enrollmentCompleted: return "person.badge.plus"
        case .enrollmentRevoked: return "person.badge.minus"
        case .selfUnlockUsed: return "lock.rotation"
        case .sosAlert: return "sos"
        case .newAppDetected: return "app.badge"
        default: return "bell"
        }
    }

    var tintColor: Color {
        switch eventType {
        case .speedingDetected, .authorizationLost, .enforcementDegraded, .enrollmentRevoked, .sosAlert:
            return .red
        case .phoneWhileDriving, .hardBrakingDetected, .familyControlsAuthChanged:
            return .orange
        case .namedPlaceArrival, .namedPlaceDeparture:
            return .blue
        case .tripCompleted, .authorizationRestored, .enrollmentCompleted:
            return .green
        case .selfUnlockUsed:
            return .teal
        case .newAppDetected:
            return .indigo
        default:
            return .secondary
        }
    }

    var title: String {
        switch eventType {
        case .speedingDetected: return "\(childName) exceeded speed limit"
        case .phoneWhileDriving: return "\(childName) used phone while driving"
        case .hardBrakingDetected: return "\(childName) braked hard"
        case .namedPlaceArrival: return "\(childName) arrived"
        case .namedPlaceDeparture: return "\(childName) departed"
        case .tripCompleted: return "\(childName) completed a trip"
        case .authorizationLost: return "\(childName) — permissions lost"
        case .authorizationRestored: return "\(childName) — permissions restored"
        case .enforcementDegraded: return "\(childName) — enforcement degraded"
        case .familyControlsAuthChanged: return "\(childName) — permissions changed"
        case .unlockRequested: return "\(childName) requested unlock"
        case .temporaryUnlockStarted: return "\(childName) — temp unlock started"
        case .temporaryUnlockExpired: return "\(childName) — temp unlock expired"
        case .modeChanged: return "\(childName) — mode changed"
        case .localPINUnlock: return "\(childName) — local PIN unlock"
        case .enrollmentCompleted: return "\(childName) enrolled"
        case .enrollmentRevoked: return "\(childName) unenrolled"
        case .selfUnlockUsed: return "\(childName) used self-unlock"
        case .sosAlert: return "\(childName) — SOS EMERGENCY"
        case .newAppDetected: return "\(childName) — new app activity"
        default: return "\(childName) — \(eventType.displayName)"
        }
    }

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Time-only string for display in day-grouped lists (e.g. "3:45 PM").
    var timeOnly: String {
        Self.timeOnlyFormatter.string(from: timestamp)
    }

    /// Detail text that adds value beyond the title. Suppresses redundant details
    /// (e.g. "Authorization restored" when the title already says "permissions restored").
    var meaningfulDetail: String? {
        guard let details, !details.isEmpty else { return nil }

        // Parse trip JSON into a human-readable summary
        if eventType == .tripCompleted, details.hasPrefix("{"),
           let data = details.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var parts: [String] = []
            if let dist = json["distanceMiles"] as? String ?? (json["distanceMiles"] as? Double).map({ String(format: "%.1f", $0) }) {
                parts.append("\(dist) mi")
            }
            if let dur = json["durationMinutes"] as? Int {
                parts.append("\(dur) min")
            }
            if let max = json["maxSpeedMPH"] as? Int, max > 0 {
                parts.append("\(max) mph max")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        guard !details.hasPrefix("{") else { return nil }
        // Suppress details that just repeat the event type name
        let lowered = details.lowercased()
        if lowered == eventType.rawValue.lowercased() { return nil }
        if lowered == "authorization restored" || lowered == "authorization lost" { return nil }
        if lowered.hasPrefix("mode changed") && eventType == .modeChanged { return nil }
        // For arrivals/departures, the detail IS the useful info
        if eventType == .namedPlaceArrival || eventType == .namedPlaceDeparture {
            return details
        }
        return details
    }
}
