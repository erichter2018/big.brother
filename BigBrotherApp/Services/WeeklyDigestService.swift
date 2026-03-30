import Foundation
import UserNotifications
import BigBrotherCore

/// Schedules and sends a weekly digest local notification summarizing family activity.
/// Fires once per week (Sunday evening). Checks on each app launch.
enum WeeklyDigestService {

    private static let lastDigestKey = "weeklyDigestLastSentAt"

    /// Check if a digest is due and send it. Call on parent app launch.
    static func checkAndSend(
        profiles: [ChildProfile],
        devices: [ChildDevice],
        heartbeats: [ChildProfileID: [DeviceHeartbeat]],
        events: [EventLogEntry]
    ) {
        let defaults = UserDefaults.standard
        let lastSent = defaults.object(forKey: lastDigestKey) as? Date ?? .distantPast
        let daysSince = Calendar.current.dateComponents([.day], from: lastSent, to: Date()).day ?? 999

        // Send at most once per 6 days (allows some flexibility around exact timing)
        guard daysSince >= 6 else { return }

        let body = buildDigestBody(profiles: profiles, devices: devices, heartbeats: heartbeats, events: events)
        guard !body.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Weekly Family Report"
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "weekly-digest-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Fire immediately
        )
        UNUserNotificationCenter.current().add(request)

        defaults.set(Date(), forKey: lastDigestKey)
    }

    private static func buildDigestBody(
        profiles: [ChildProfile],
        devices: [ChildDevice],
        heartbeats: [ChildProfileID: [DeviceHeartbeat]],
        events: [EventLogEntry]
    ) -> String {
        var lines: [String] = []

        for profile in profiles {
            let deviceIDs = Set(devices.filter { $0.childProfileID == profile.id }.map(\.id))
            let childEvents = events.filter { deviceIDs.contains($0.deviceID) }

            var parts: [String] = []

            // Screen time average
            if let hbs = heartbeats[profile.id] {
                let screenTimes = hbs.compactMap(\.screenTimeMinutes).filter { $0 > 0 }
                if !screenTimes.isEmpty {
                    let avg = screenTimes.reduce(0, +) / screenTimes.count
                    parts.append(formatMinutes(avg) + " avg/day")
                }
            }

            // Safety events
            let safety = childEvents.filter {
                [.speedingDetected, .phoneWhileDriving, .hardBrakingDetected, .sosAlert].contains($0.eventType)
            }.count
            if safety > 0 {
                parts.append("\(safety) safety alert\(safety == 1 ? "" : "s")")
            }

            // New apps
            let newApps = Set(childEvents
                .filter { $0.eventType == .newAppDetected }
                .compactMap { $0.details?.replacingOccurrences(of: "New app activity: ", with: "") })
            if !newApps.isEmpty {
                parts.append("\(newApps.count) new app\(newApps.count == 1 ? "" : "s")")
            }

            if !parts.isEmpty {
                lines.append("\(profile.name): \(parts.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: ". ")
    }

    private static func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(minutes)m"
    }
}
