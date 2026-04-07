import Foundation
import DeviceActivity
import ManagedSettings
import BigBrotherCore

/// Registers DeviceActivity schedules on the child device based on the
/// assigned ScheduleProfile. Each free window becomes a monitored
/// DeviceActivity interval.
///
/// When an interval starts, the DeviceActivityMonitor extension unlocks the device.
/// When it ends, the extension re-applies the locked mode.
///
/// DeviceActivity schedules persist across app launches and reboots (after first unlock).
///
/// Cross-midnight windows (e.g., 9:30 PM – 7:00 AM) are split into two
/// DeviceActivity registrations: evening (start→23:59) and morning (00:00→end).
/// Both use the same window ID so the Monitor maps them to the same ActiveWindow.
enum ScheduleRegistrar {

    /// Prefix for unlocked-window schedule activities.
    static let activityPrefix = "bigbrother.scheduleprofile."
    /// Prefix for locked-window schedule activities.
    static let essentialPrefix = "bigbrother.essentialwindow."
    /// Prefix for the usage tracking schedule.
    static let usageTrackingPrefix = "bigbrother.usagetracking"

    /// Suffix for the evening portion of a cross-midnight window.
    private static let eveningSuffix = ".pm"
    /// Suffix for the morning portion of a cross-midnight window.
    private static let morningSuffix = ".am"

    /// Register DeviceActivity schedules for the given profile.
    /// Clears any previously registered schedule profile activities first.
    static func register(_ profile: ScheduleProfile, storage: any SharedStorageProtocol) {
        let center = DeviceActivityCenter()

        // Clear existing schedule profile activities.
        clearAll(center: center)

        // Write the profile to App Group so the extension can read it.
        try? storage.writeActiveScheduleProfile(profile)

        // Register one DeviceActivity per unlocked window.
        for window in profile.unlockedWindows {
            registerWindow(window, prefix: activityPrefix, label: "unlocked", center: center)
        }

        // Register one DeviceActivity per locked window.
        for window in profile.lockedWindows {
            registerWindow(window, prefix: essentialPrefix, label: "locked", center: center)
        }

        // Register usage tracking milestones.
        registerUsageTracking()
    }

    private static func registerWindow(_ window: ActiveWindow, prefix: String, label: String, center: DeviceActivityCenter) {
        if window.startTime < window.endTime {
            // Same-day window — register directly.
            let activityName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)")
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
                intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
                repeats: true
            )
            register(activityName, schedule: schedule, label: label, center: center)
        } else {
            // Cross-midnight window (e.g., 21:30 → 07:00).
            // Split into evening (21:30→23:59) and morning (00:00→07:00).
            // The Monitor's day-of-week check + ActiveWindow.contains() handle correctness.

            // Evening portion: start → 23:59
            let eveningName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)\(eveningSuffix)")
            let eveningSchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true
            )
            register(eveningName, schedule: eveningSchedule, label: "\(label)-pm", center: center)

            // Morning portion: 00:00 → end
            let morningName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)\(morningSuffix)")
            let morningSchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
                repeats: true
            )
            register(morningName, schedule: morningSchedule, label: "\(label)-am", center: center)
        }
    }

    private static func register(_ name: DeviceActivityName, schedule: DeviceActivitySchedule, label: String, center: DeviceActivityCenter) {
        do {
            try center.startMonitoring(name, during: schedule)
        } catch {
            // Log in all builds — silent registration failures cause enforcement gaps.
            let storage = AppGroupStorage()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Schedule registration FAILED",
                details: "\(label): \(name.rawValue) — \(error.localizedDescription)"
            ))
        }
    }

    /// Clear all schedule profile activities and remove stored profile.
    static func clearAll(storage: any SharedStorageProtocol) {
        clearAll(center: DeviceActivityCenter())
        try? storage.writeActiveScheduleProfile(nil)
    }

    /// Clear all schedule profile and usage tracking activities from DeviceActivityCenter.
    private static func clearAll(center: DeviceActivityCenter) {
        for activity in center.activities {
            if activity.rawValue.hasPrefix(activityPrefix)
                || activity.rawValue.hasPrefix(essentialPrefix)
                || activity.rawValue.hasPrefix(usageTrackingPrefix) {
                center.stopMonitoring([activity])
            }
        }
    }

    /// Register a daily usage tracking schedule with milestone events.
    /// Each milestone fires `eventDidReachThreshold` in the Monitor extension
    /// when total device screen time reaches that threshold.
    ///
    /// Milestones: 15m, 30m, 45m, 1h, then every 30m up to 12h.
    static func registerUsageTracking() {
        let center = DeviceActivityCenter()

        // Remove any existing usage tracking schedule.
        for activity in center.activities {
            if activity.rawValue.hasPrefix(usageTrackingPrefix) {
                center.stopMonitoring([activity])
            }
        }

        let activityName = DeviceActivityName(rawValue: usageTrackingPrefix)

        // Schedule runs all day, repeating daily.
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )

        // Build milestone events at tiered granularity:
        //   0–2h:  every 5 minutes  (24 events)
        //   2–6h:  every 15 minutes (16 events)
        //   6–12h: every 30 minutes (12 events)
        // Total: 52 events — well within DeviceActivity limits.
        // Empty applications/categories = tracks ALL device activity.
        var milestoneMinutes: [Int] = []
        for m in stride(from: 5, through: 120, by: 5) { milestoneMinutes.append(m) }      // 5-min steps up to 2h
        for m in stride(from: 135, through: 360, by: 15) { milestoneMinutes.append(m) }    // 15-min steps 2h–6h
        for m in stride(from: 390, through: 720, by: 30) { milestoneMinutes.append(m) }    // 30-min steps 6h–12h

        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minutes in milestoneMinutes {
            let eventName = DeviceActivityEvent.Name(rawValue: "usage.\(minutes)")
            let hours = minutes / 60
            let mins = minutes % 60
            var threshold = DateComponents()
            threshold.hour = hours
            threshold.minute = mins
            events[eventName] = DeviceActivityEvent(
                applications: [],
                categories: [],
                webDomains: [],
                threshold: threshold
            )
        }

        do {
            try center.startMonitoring(activityName, during: schedule, events: events)
            #if DEBUG
            print("[BigBrother] Registered usage tracking with \(events.count) milestones")
            #endif
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to register usage tracking: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Per-App Time Limits

    static let timeLimitPrefix = "bigbrother.timelimit."

    /// Register DeviceActivityEvents for each per-app time limit.
    /// Each app gets its own schedule with:
    /// - 5-minute usage milestones (for precise tracking reported to parent)
    /// - Exhaustion threshold (blocks the app when limit is reached)
    /// Clears previously registered time limit activities first.
    static func registerTimeLimitEvents(limits: [AppTimeLimit]) {
        let center = DeviceActivityCenter()

        // Clear existing time limit activities.
        for activity in center.activities {
            if activity.rawValue.hasPrefix(timeLimitPrefix) {
                center.stopMonitoring([activity])
            }
        }

        let decoder = JSONDecoder()

        for limit in limits where limit.dailyLimitMinutes > 0 {
            // Auto-resolve stale pending name resolution — if pending for over 1 hour,
            // apply the resolved limit so the app isn't stuck at 1 minute forever.
            if limit.pendingNameResolution == true,
               Date().timeIntervalSince(limit.createdAt) > 3600 {
                let storage = AppGroupStorage()
                var allLimits = storage.readAppTimeLimits()
                if let idx = allLimits.firstIndex(where: { $0.id == limit.id }) {
                    allLimits[idx].pendingNameResolution = false
                    allLimits[idx].dailyLimitMinutes = limit.resolvedDailyLimitMinutes ?? 60
                    allLimits[idx].updatedAt = Date()
                    if allLimits[idx].appName.hasPrefix("Temporary Name") {
                        allLimits[idx].appName = limit.bundleID ?? "App"
                    }
                    try? storage.writeAppTimeLimits(allLimits)
                }
                continue // Re-registration will pick up the corrected limit on next call
            }
            guard let appToken = try? decoder.decode(ApplicationToken.self, from: limit.tokenData) else {
                #if DEBUG
                print("[BigBrother] Failed to decode token for time limit: \(limit.appName)")
                #endif
                continue
            }

            let activityName = DeviceActivityName(rawValue: "\(timeLimitPrefix)\(limit.id.uuidString)")

            // All-day schedule, repeats daily. Midnight reset clears exhausted status.
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true
            )

            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]

            // Usage milestones every 5 minutes for precise tracking.
            // The Monitor writes actual usage to App Group on each milestone.
            let maxMilestone = limit.dailyLimitMinutes + 120 // Track well beyond limit (multiple extra time grants)
            for m in stride(from: 5, through: maxMilestone, by: 5) {
                let eventName = DeviceActivityEvent.Name(rawValue: "timelimit.usage.\(m)")
                var threshold = DateComponents()
                threshold.hour = m / 60
                threshold.minute = m % 60
                events[eventName] = DeviceActivityEvent(
                    applications: [appToken],
                    categories: [],
                    webDomains: [],
                    threshold: threshold
                )
            }

            // Exhaustion threshold — fires when the limit is reached.
            // Include the limit value in the event name so that re-registering after
            // grantExtraTime creates a genuinely new event. Without this, iOS may not
            // re-fire "timelimit.exhausted" if it already fired at the old threshold
            // within the same schedule interval.
            let exhaustionName = DeviceActivityEvent.Name(rawValue: "timelimit.exhausted.\(limit.dailyLimitMinutes)")
            var exhaustionThreshold = DateComponents()
            exhaustionThreshold.hour = limit.dailyLimitMinutes / 60
            exhaustionThreshold.minute = limit.dailyLimitMinutes % 60
            events[exhaustionName] = DeviceActivityEvent(
                applications: [appToken],
                categories: [],
                webDomains: [],
                threshold: exhaustionThreshold
            )

            do {
                try center.startMonitoring(activityName, during: schedule, events: events)
                #if DEBUG
                print("[BigBrother] Registered time limit: \(limit.appName) = \(limit.dailyLimitMinutes) min/day (\(events.count) events)")
                #endif
            } catch {
                #if DEBUG
                print("[BigBrother] Failed to register time limit for \(limit.appName): \(error.localizedDescription)")
                #endif
            }
        }
    }
}
