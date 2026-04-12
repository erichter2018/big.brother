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

    /// Shared dedup store. See `NotificationDedupStore` for how read-modify-write
    /// on `safetyNotifiedEventIDs` / `safetySemanticKeys` is serialized across
    /// concurrent callers (DeviceMonitor polling vs parent opening the Activity
    /// tab). Previously both call sites did a non-atomic read → decide → write
    /// sequence and raced; the store closes that gap for all three notification
    /// services uniformly.
    private static let dedupStore = NotificationDedupStore(
        configuration: .init(
            notifiedIDsKey: "safetyNotifiedEventIDs",
            contentKeysKey: "safetySemanticKeys",
            maxNotifiedIDs: 500,
            maxContentKeys: 200
        )
    )

    private static let semanticWindow: TimeInterval = 6 * 3600

    /// Check recent events and post notifications for safety-relevant ones.
    ///
    /// Deduplicates on TWO axes:
    /// 1. Event ID (catches exact replays of the same event record).
    /// 2. Semantic key (catches the multi-device case where kid's phone
    ///    and iPad both see "Instagram" for the first time, producing two
    ///    different event IDs with identical child+type+details — without
    ///    this dedup the parent gets two notifications for the same
    ///    observed activity).
    ///
    /// Semantic keys expire after 6 hours — after that, the same app
    /// reappearing is treated as genuinely new activity worth notifying
    /// about again.
    static func checkAndNotify(
        events: [EventLogEntry],
        childName: String,
        namedPlaces: [NamedPlace] = []
    ) {
        let now = Date()
        let defaults = UserDefaults.standard

        let toPost: [EventLogEntry] = dedupStore.withLock { state in
            var items: [EventLogEntry] = []

            for event in events {
                guard notifiableTypes.contains(event.eventType) else { continue }
                let idStr = event.id.uuidString
                guard !state.hasNotified(idStr) else { continue }
                // Only notify for events in the last hour (avoid stale batch)
                guard now.timeIntervalSince(event.timestamp) < 3600 else { continue }

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
                    if lastNotif > 0 && now.timeIntervalSince1970 - lastNotif < 3600 { continue }
                    defaults.set(now.timeIntervalSince1970, forKey: key)
                }

                let semanticKey = Self.semanticKey(childName: childName, eventType: event.eventType, details: event.details)
                if state.isRecentContentKey(semanticKey, within: semanticWindow) {
                    // Mark as notified so we don't re-check on the next call,
                    // even though we suppressed the user-facing notification.
                    state.markNotified(idStr)
                    continue
                }
                state.recordContentKey(semanticKey)
                state.markNotified(idStr)
                items.append(event)
            }
            return items
        }

        for event in toPost {
            postNotification(for: event, childName: childName)
        }
    }

    /// Build a stable semantic-dedup key from the child, event type, and
    /// detail string. Two events from different devices that describe the
    /// same observation will produce the same key.
    private static func semanticKey(childName: String, eventType: EventType, details: String?) -> String {
        let normalizedDetails = (details ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(childName.lowercased())|\(eventType.rawValue)|\(normalizedDetails)"
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
