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

    /// iOS DeviceActivityCenter has a ~20 activity-per-app limit. We share
    /// that budget across several categories; when we exceed it iOS silently
    /// drops the excess with no error, which manifests as "schedule windows
    /// randomly skipped" or "time-limit app not blocked when it should be".
    ///
    /// Reserved slots we don't control here:
    ///   - 4 reconciliation quarters
    ///   - 1 usage tracking
    ///   - 1 enforcement heartbeat
    ///   - 1 for an occasional temp/timed-unlock / lockUntil
    /// Total fixed reservation ≈ 7, leaving ≈ 13 for variable registrations.
    /// We split the remainder: 8 for schedule activities (expanded — see below)
    /// and 5 for time-limit apps. Everything else re-registers on the 6-hour
    /// reconciliation tick so dropped registrations get another chance.
    ///
    /// NOTE: This cap counts CONCRETE DA activities after cross-midnight
    /// expansion. An overnight 21:30→07:00 window contributes 2 (.pm + .am)
    /// to the count, not 1 — before b675 we counted the logical window and
    /// silently doubled our real usage.
    private static let maxScheduleWindowRegistrations = 8
    /// Cap on per-app time-limit DA activity registrations. Each one is a
    /// full `DeviceActivitySchedule` with ~100 milestone events. Capping
    /// protects against an over-eager parent blowing past iOS's activity
    /// limit and knocking out schedule windows in the process.
    static let maxTimeLimitRegistrations = 5

    /// Concrete DA activity we plan to register with the center.
    private struct ConcreteActivity {
        let name: DeviceActivityName
        let schedule: DeviceActivitySchedule
        let label: String
    }

    /// A logical window plus the 1-or-2 concrete DA activities it produces.
    /// Budget accounting happens at THIS level so a cross-midnight window
    /// is either registered whole (both halves) or dropped whole — never
    /// half-registered, which would silently miss one side of the transition.
    private struct PlannedWindow {
        let activities: [ConcreteActivity]
        /// Minutes between "now" and the next real start of this logical
        /// window. 0 if we're currently inside it.
        let proximity: Int
    }

    /// Register DeviceActivity schedules for the given profile.
    /// Clears any previously registered schedule profile activities first.
    ///
    /// Budget policy:
    ///   * Active windows (device is currently inside them) get proximity 0,
    ///     so they always win under budget pressure — dropping an active
    ///     window would unlock apps that are actively supposed to be locked.
    ///   * Cross-midnight windows are ranked + truncated as a PAIR — either
    ///     both halves register or neither. Half-registering silently drops
    ///     one side of the transition.
    ///   * Proximity accounts for day-of-week: a Friday-only window
    ///     evaluated on Wednesday scores two days out, not "next occurrence
    ///     of that H:M today."
    static func register(_ profile: ScheduleProfile, storage: any SharedStorageProtocol) {
        let center = DeviceActivityCenter()

        // Clear existing schedule profile activities.
        clearAll(center: center)

        // Write the profile to App Group so the extension can read it.
        try? storage.writeActiveScheduleProfile(profile)

        let now = Date()

        // Plan every logical window with its concrete activities and proximity score.
        var planned: [PlannedWindow] = []
        for w in profile.unlockedWindows {
            planned.append(planWindow(w, prefix: activityPrefix, label: "unlocked", now: now))
        }
        for w in profile.lockedWindows {
            planned.append(planWindow(w, prefix: essentialPrefix, label: "locked", now: now))
        }

        // Sort by proximity — register soonest-firing windows first.
        planned.sort { $0.proximity < $1.proximity }

        // Greedy budget allocation at the LOGICAL WINDOW level.
        // Cross-midnight windows consume 2 slots; same-day consume 1.
        var toRegister: [ConcreteActivity] = []
        var budgetRemaining = maxScheduleWindowRegistrations
        var droppedWindows = 0
        for w in planned {
            if budgetRemaining >= w.activities.count {
                toRegister.append(contentsOf: w.activities)
                budgetRemaining -= w.activities.count
            } else {
                droppedWindows += 1
            }
        }
        if droppedWindows > 0 {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Schedule budget: \(droppedWindows) window(s) dropped; \(toRegister.count)/\(maxScheduleWindowRegistrations) activity slots used",
                details: "iOS caps ~20 DA activities/app; cross-midnight windows count as 2. Reconciliation (every 6h) re-evaluates by proximity."
            ))
        }

        for a in toRegister {
            register(a.name, schedule: a.schedule, label: a.label, center: center)
        }

        // Register usage tracking milestones.
        registerUsageTracking()
    }

    /// Build the concrete activities + proximity score for a logical window.
    /// Same-day windows produce 1 activity; cross-midnight windows produce 2.
    private static func planWindow(
        _ window: ActiveWindow,
        prefix: String,
        label: String,
        now: Date
    ) -> PlannedWindow {
        let proximity = proximityMinutes(for: window, now: now)

        if window.startTime < window.endTime {
            let name = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)")
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
                intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
                repeats: true
            )
            return PlannedWindow(
                activities: [ConcreteActivity(name: name, schedule: schedule, label: label)],
                proximity: proximity
            )
        }

        // Cross-midnight — two concrete activities, ranked and truncated together.
        let eveningName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)\(eveningSuffix)")
        let eveningSchedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: window.startTime.hour, minute: window.startTime.minute),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let morningName = DeviceActivityName(rawValue: "\(prefix)\(window.id.uuidString)\(morningSuffix)")
        let morningSchedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: window.endTime.hour, minute: window.endTime.minute),
            repeats: true
        )
        return PlannedWindow(
            activities: [
                ConcreteActivity(name: eveningName, schedule: eveningSchedule, label: "\(label)-pm"),
                ConcreteActivity(name: morningName, schedule: morningSchedule, label: "\(label)-am"),
            ],
            proximity: proximity
        )
    }

    /// Minutes until the next real firing of this window.
    ///
    ///   * 0 if the device is currently INSIDE the window (we must keep it
    ///     registered or the Monitor can't run the intervalDidEnd handler).
    ///   * Otherwise: scan days 0–6 forward from today, find the soonest day
    ///     that matches `daysOfWeek`, return minutes-until-start on that day.
    ///
    /// A pure H:M proximity would mis-rank day-of-week-restricted windows
    /// (e.g. a Friday-only window evaluated on Wednesday night would score
    /// "soon" because the H:M fires tonight). Under budget pressure that
    /// Friday window could displace a same-day Thursday window and still
    /// not fire for 24h.
    private static func proximityMinutes(for window: ActiveWindow, now: Date, calendar: Calendar = .current) -> Int {
        if window.contains(now, calendar: calendar) { return 0 }

        let nowHour = calendar.component(.hour, from: now)
        let nowMinute = calendar.component(.minute, from: now)
        let nowMin = nowHour * 60 + nowMinute
        let startMin = window.startTime.hour * 60 + window.startTime.minute
        let todayRaw = calendar.component(.weekday, from: now)
        guard let todayDOW = DayOfWeek(rawValue: todayRaw) else {
            // Unknown weekday — shouldn't happen; fall back to H:M-only
            // math so we don't return Int.max and starve the window.
            return (startMin - nowMin + 1440) % 1440
        }

        // Scan today + next 6 days.
        for offset in 0..<7 {
            guard let dayRaw = DayOfWeek(rawValue: ((todayDOW.rawValue - 1 + offset) % 7) + 1),
                  window.daysOfWeek.contains(dayRaw) else { continue }
            if offset == 0 {
                // Today is an applicable day. Window starts strictly in the future?
                if startMin > nowMin {
                    return startMin - nowMin
                }
                // Start time is "now or past today"; we already know contains() is
                // false so we're past the end — check subsequent days.
                continue
            }
            return offset * 1440 + (startMin - nowMin)
        }
        // No applicable day in a week (empty daysOfWeek). Deprioritise hard.
        return Int.max
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
        // Run on background thread — registering 600+ milestones blocks for 20-30s.
        DispatchQueue.global(qos: .utility).async {
            _registerUsageTrackingSync()
        }
    }

    private static func _registerUsageTrackingSync() {
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
        //   0–5m:  every 1 minute   (4 events)  — fast enforcement detection
        //   5–2h:  every 5 minutes  (24 events)
        //   2–6h:  every 15 minutes (16 events)
        //   6–12h: every 30 minutes (12 events)
        // Total: 56 events — well within DeviceActivity limits.
        // Empty applications/categories = tracks ALL device activity.
        var milestoneMinutes: [Int] = []
        for m in 1...4 { milestoneMinutes.append(m) }                                      // 1-min steps for first 4 min
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

        // Per-app usage milestones for always-allowed apps.
        // 15-minute intervals up to 6 hours per app. Fires eventDidReachThreshold
        // in the Monitor, which writes usage to App Group for heartbeat reporting.
        let storage = AppGroupStorage()
        let decoder = JSONDecoder()
        if let tokenData = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let tokens = try? decoder.decode(Set<ApplicationToken>.self, from: tokenData) {
            let encoder = JSONEncoder()
            for token in tokens {
                guard let encoded = try? encoder.encode(token) else { continue }
                let fp = TokenFingerprint.fingerprint(for: encoded).prefix(8)
                for m in stride(from: 15, through: 360, by: 15) {
                    let eventName = DeviceActivityEvent.Name(rawValue: "appusage.\(fp).\(m)")
                    var threshold = DateComponents()
                    threshold.hour = m / 60
                    threshold.minute = m % 60
                    events[eventName] = DeviceActivityEvent(
                        applications: [token],
                        categories: [],
                        webDomains: [],
                        threshold: threshold
                    )
                }
            }
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

        // First pass: handle stale-pending + undecodable entries OUT of the
        // eligibility set so they don't burn a cap slot only to fall through.
        // - pendingNameResolution older than 1h → auto-resolve in storage and
        //   skip this pass (the next pass of this function will pick up the
        //   resolved entry).
        // - token that won't decode → skip (something's wrong with storage).
        // b675-audit-2 fix: previously this filtering happened AFTER the
        // `prefix(maxTimeLimitRegistrations)` cap, so a top-5 entry that
        // `continue`-ed left the round with 4 real registrations when the
        // budget could have fit 5.
        var eligible: [AppTimeLimit] = []
        for limit in limits where limit.dailyLimitMinutes > 0 {
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
                continue
            }
            if (try? decoder.decode(ApplicationToken.self, from: limit.tokenData)) == nil {
                #if DEBUG
                print("[BigBrother] Failed to decode token for time limit: \(limit.appName)")
                #endif
                continue
            }
            eligible.append(limit)
        }

        // Rank by most-recently-updated first — that's the best proxy for
        // current parent intent. (Codex argued for smallest-limit-first to
        // preserve strictest parent constraints; Gemini argued for most-
        // likely-to-matter. `updatedAt` captures freshness of parent intent
        // without over-optimising for either.) Then cap to
        // `maxTimeLimitRegistrations` so total DA registrations stay under
        // iOS's ~20/process limit.
        eligible.sort { $0.updatedAt > $1.updatedAt }
        let toRegister = Array(eligible.prefix(maxTimeLimitRegistrations))
        let droppedLimits = eligible.count - toRegister.count
        if droppedLimits > 0 {
            let storage = AppGroupStorage()
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Time-limit budget: registering \(toRegister.count)/\(eligible.count) apps (dropped \(droppedLimits))",
                details: "iOS caps ~20 DA activities/app; max \(maxTimeLimitRegistrations) time-limited apps supported. Reduce active rules or increase cap after auditing other registrations."
            ))
        }

        for limit in toRegister {
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
