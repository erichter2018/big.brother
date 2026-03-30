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
    ]

    /// Check recent events and post notifications for safety-relevant ones.
    /// Deduplicates by event ID to avoid repeat notifications.
    static func checkAndNotify(
        events: [EventLogEntry],
        childName: String
    ) {
        let defaults = UserDefaults.standard
        var notifiedIDs = Set(defaults.stringArray(forKey: "safetyNotifiedEventIDs") ?? [])

        for event in events {
            guard notifiableTypes.contains(event.eventType) else { continue }
            let idStr = event.id.uuidString
            guard !notifiedIDs.contains(idStr) else { continue }
            // Only notify for events in the last hour (avoid stale batch)
            guard Date().timeIntervalSince(event.timestamp) < 3600 else { continue }

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
