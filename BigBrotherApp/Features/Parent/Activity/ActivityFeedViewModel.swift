import Foundation
import SwiftUI
import BigBrotherCore

/// View model for the Activity feed tab on the parent dashboard.
@Observable
@MainActor
final class ActivityFeedViewModel {

    let appState: AppState

    var events: [ActivityEvent] = []
    var isLoading = false
    var selectedChildID: ChildProfileID?
    var selectedFilter: EventFilter = .all
    var unreadCount: Int = 0

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
        .modeChanged, .localPINUnlock, .enrollmentCompleted, .enrollmentRevoked,
        .sosAlert,
    ]

    private func matchesFilter(_ type: EventType) -> Bool {
        switch selectedFilter {
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
        do {
            let rawEvents = try await cloudKit.fetchEventLogs(familyID: familyID, since: since)
            let profiles = appState.childProfiles
            let devices = appState.childDevices

            let filtered = rawEvents
                .filter { Self.visibleTypes.contains($0.eventType) }
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

            unreadCount = rawEvents.filter {
                Self.visibleTypes.contains($0.eventType) && $0.timestamp > lastViewedAt
            }.count

            // Safety notifications
            for profile in profiles {
                let deviceIDs = Set(devices.filter { $0.childProfileID == profile.id }.map(\.id))
                let childEvents = rawEvents.filter { deviceIDs.contains($0.deviceID) }
                SafetyEventNotificationService.checkAndNotify(events: childEvents, childName: profile.name)
            }
        } catch {
            #if DEBUG
            print("[Activity] Failed to load events: \(error.localizedDescription)")
            #endif
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

    private func resolveChildName(deviceID: DeviceID, profiles: [ChildProfile], devices: [ChildDevice]) -> String {
        guard let device = devices.first(where: { $0.id == deviceID }),
              let profile = profiles.first(where: { $0.id == device.childProfileID }) else {
            return "Unknown"
        }
        return profile.name
    }
}

// MARK: - Activity Event

struct ActivityEvent: Identifiable, Equatable {
    let id: UUID
    let childName: String
    let eventType: EventType
    let details: String?
    let timestamp: Date

    init(entry: EventLogEntry, childName: String) {
        self.id = entry.id
        self.childName = childName
        self.eventType = entry.eventType
        self.details = entry.details
        self.timestamp = entry.timestamp
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
        case .sosAlert: return "sos"
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
        case .sosAlert: return "\(childName) — SOS EMERGENCY"
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
        guard let details, !details.isEmpty, !details.hasPrefix("{") else { return nil }
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
