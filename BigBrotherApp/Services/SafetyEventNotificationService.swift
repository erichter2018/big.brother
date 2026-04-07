import Foundation
import UserNotifications
import BigBrotherCore

/// Posts local notifications to the parent for driving safety events.
/// Follows the same pattern as UnlockRequestNotificationService:
/// CloudKit push wakes the app → events fetched → local notification posted.
enum SafetyEventNotificationService {

    /// Event types that trigger parent notifications.
    static let notifiableTypes: Set<EventType> = [
        .speedingDetected,
        .phoneWhileDriving,
        .hardBrakingDetected,
        .namedPlaceArrival,
        .namedPlaceDeparture,
        .sosAlert,
        .newAppDetected,
        .enforcementDegraded,
        .authorizationLost,
        .familyControlsAuthChanged,
    ]

    /// Check recent events and post notifications for safety-relevant ones.
    /// Deduplicates by event ID to avoid repeat notifications.
    static func checkAndNotify(
        events: [EventLogEntry],
        childName: String,
        namedPlaces: [NamedPlace] = []
    ) {
        let defaults = UserDefaults.standard
        var notifiedIDs = Set(defaults.stringArray(forKey: "safetyNotifiedEventIDs") ?? [])

        for event in events {
            guard notifiableTypes.contains(event.eventType) else { continue }
            let idStr = event.id.uuidString
            guard !notifiedIDs.contains(idStr) else { continue }
            // Only notify for events in the last hour (avoid stale batch)
            guard Date().timeIntervalSince(event.timestamp) < 3600 else { continue }

            // Respect per-place notification toggles for arrival/departure events.
            if event.eventType == .namedPlaceArrival || event.eventType == .namedPlaceDeparture {
                if let details = event.details,
                   let place = namedPlaces.first(where: { details.contains($0.name) }) {
                    if event.eventType == .namedPlaceArrival && !place.notifyArrival { continue }
                    if event.eventType == .namedPlaceDeparture && !place.notifyDeparture { continue }
                }
            }

            // Debounce enforcementDegraded: max one per hour per device.
            // These fire on transient app deaths that often self-resolve.
            if event.eventType == .enforcementDegraded {
                let key = "lastEnforcementDegradedNotif_\(event.deviceID.rawValue)"
                let lastNotif = defaults.double(forKey: key)
                if lastNotif > 0 && Date().timeIntervalSince1970 - lastNotif < 3600 { continue }
                defaults.set(Date().timeIntervalSince1970, forKey: key)
            }

            notifiedIDs.insert(idStr)
            postNotification(for: event, childName: childName)
        }

        // Cap stored IDs to last 500
        if notifiedIDs.count > 500 {
            notifiedIDs = Set(notifiedIDs.suffix(500))
        }
        defaults.set(Array(notifiedIDs), forKey: "safetyNotifiedEventIDs")
    }

    private static func postNotification(for event: EventLogEntry, childName: String) {
        let content = UNMutableNotificationContent()

        switch event.eventType {
        case .speedingDetected:
            content.title = "\(childName) — Speeding"
            content.body = event.details ?? "Speed limit exceeded"
            content.sound = .default
            content.interruptionLevel = .timeSensitive

        case .phoneWhileDriving:
            content.title = "\(childName) — Phone While Driving"
            content.body = event.details ?? "Phone used while driving"
            content.sound = .default
            content.interruptionLevel = .timeSensitive

        case .hardBrakingDetected:
            content.title = "\(childName) — Hard Braking"
            content.body = event.details ?? "Hard braking detected"
            content.sound = .default

        case .namedPlaceArrival:
            content.title = "\(childName)"
            content.body = event.details ?? "Arrived at a location"
            content.sound = .default

        case .namedPlaceDeparture:
            content.title = "\(childName)"
            content.body = event.details ?? "Left a location"
            content.sound = .default

        case .sosAlert:
            content.title = "\(childName) — SOS ALERT"
            content.body = event.details ?? "Emergency alert triggered"
            content.sound = UNNotificationSound.defaultCritical
            content.interruptionLevel = .critical

        case .newAppDetected:
            content.title = "\(childName) — New App Activity"
            content.body = event.details ?? "New app detected on device"
            content.sound = .default

        case .enforcementDegraded:
            content.title = "\(childName) — Protection Alert"
            content.body = event.details ?? "Device protection may be compromised"
            content.sound = .default
            content.interruptionLevel = .timeSensitive

        case .authorizationLost:
            content.title = "\(childName) — Permissions Revoked"
            content.body = event.details ?? "Screen Time permissions were disabled"
            content.sound = .defaultCritical
            content.interruptionLevel = .critical

        case .familyControlsAuthChanged:
            content.title = "\(childName) — Permission Change"
            content.body = event.details ?? "FamilyControls authorization changed"
            content.sound = .default
            content.interruptionLevel = .timeSensitive

        default:
            return
        }

        let request = UNNotificationRequest(
            identifier: "safety-\(event.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
