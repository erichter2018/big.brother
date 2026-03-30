import Foundation
import Observation
import BigBrotherCore

@Observable
@MainActor
final class InsightsViewModel {
    let appState: AppState

    var timeRange: InsightsTimeRange = .day
    var isLoading = false
    var errorMessage: String?
    var familySummary: FamilySummary?
    var childSummaries: [ChildInsightsSummary] = []
    var recentCommands: [CommandLatencyRecord] = []
    var bucketCounts: [BucketCount] = []
    var lockPrecisionRecords: [LockPrecisionRecord] = []
    var scheduleTransitionRecords: [ScheduleTransitionRecord] = []

    init(appState: AppState) {
        self.appState = appState
    }

    func load() async {
        guard let familyID = appState.parentState?.familyID,
              let cloudKit = appState.cloudKit else { return }

        isLoading = true
        errorMessage = nil

        do {
            let since = timeRange.since
            async let fetchedCommands = cloudKit.fetchRecentCommands(familyID: familyID, since: since)
            async let fetchedReceipts = cloudKit.fetchReceipts(familyID: familyID, since: since)
            async let fetchedEvents = cloudKit.fetchEventLogs(familyID: familyID, since: since)
            async let fetchedHeartbeats = cloudKit.fetchLatestHeartbeats(familyID: familyID)

            let commands = try await fetchedCommands
            let receipts = try await fetchedReceipts
            let events = try await fetchedEvents
            let heartbeats = try await fetchedHeartbeats

            // Process off main actor to avoid blocking UI.
            let result = Self.processInsights(
                commands: commands,
                receipts: receipts,
                events: events,
                heartbeats: heartbeats,
                childProfiles: appState.orderedChildProfiles,
                childDevices: appState.childDevices,
                scheduleProfiles: appState.scheduleProfiles
            )

            familySummary = result.familySummary
            childSummaries = result.childSummaries
            recentCommands = result.recentCommands
            bucketCounts = result.bucketCounts
            lockPrecisionRecords = result.lockPrecisionRecords
            scheduleTransitionRecords = result.scheduleTransitionRecords

            dumpToLog()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Processing (pure function, no UI blocking)

    struct InsightsResult {
        let familySummary: FamilySummary
        let childSummaries: [ChildInsightsSummary]
        let recentCommands: [CommandLatencyRecord]
        let bucketCounts: [BucketCount]
        let lockPrecisionRecords: [LockPrecisionRecord]
        let scheduleTransitionRecords: [ScheduleTransitionRecord]
    }

    nonisolated static func processInsights(
        commands: [RemoteCommand],
        receipts: [CommandReceipt],
        events: [EventLogEntry],
        heartbeats: [DeviceHeartbeat],
        childProfiles: [ChildProfile],
        childDevices: [ChildDevice],
        scheduleProfiles: [ScheduleProfile]
    ) -> InsightsResult {
        // Build lookups once.
        let receiptMap = Dictionary(grouping: receipts, by: \.commandID)
        let childNameMap = Dictionary(uniqueKeysWithValues: childProfiles.map { ($0.id, $0.name) })
        let deviceToChild = Dictionary(uniqueKeysWithValues: childDevices.map { ($0.id, $0.childProfileID) })

        // Filter out config/housekeeping commands.
        let actionableCommands = commands.filter { cmd in
            switch cmd.action {
            case .setSelfUnlockBudget, .setRestrictions, .nameApp, .syncPINHash,
                 .setScheduleProfile, .clearScheduleProfile, .setHeartbeatProfile,
                 .setPenaltyTimer, .requestHeartbeat, .setAllowedWebDomains:
                return false
            default:
                return true
            }
        }

        // Build command lookup by ID for O(1) access.
        let commandByID = Dictionary(uniqueKeysWithValues: actionableCommands.map { ($0.id, $0) })

        // Join commands with receipts.
        let latencyRecords: [CommandLatencyRecord] = actionableCommands.map { cmd in
            let receipt = receiptMap[cmd.id]?.first
            let childName: String? = {
                switch cmd.target {
                case .child(let cid): return childNameMap[cid]
                case .device(let did): return deviceToChild[did].flatMap { childNameMap[$0] }
                case .allDevices: return "All"
                }
            }()
            return CommandLatencyRecord(
                id: cmd.id,
                action: cmd.action,
                targetChildName: childName,
                issuedAt: cmd.issuedAt,
                appliedAt: receipt?.appliedAt,
                status: receipt?.status ?? cmd.status
            )
        }

        // Filter out expired commands.
        let activeRecords = latencyRecords.filter { $0.status != .expired }

        // Compute latency stats.
        let successLatencies = activeRecords.compactMap(\.latencySeconds).sorted()
        let avgLat = successLatencies.isEmpty ? nil : successLatencies.reduce(0, +) / Double(successLatencies.count)
        let medLat = successLatencies.isEmpty ? nil : successLatencies[successLatencies.count / 2]
        let p95Lat = successLatencies.isEmpty ? nil : successLatencies[min(successLatencies.count - 1, Int(Double(successLatencies.count) * 0.95))]

        let successCount = activeRecords.filter { $0.status == .applied }.count
        let failCount = activeRecords.filter { $0.status == .failed }.count
        let pendingCount = activeRecords.filter { $0.status == .pending || $0.status == .delivered }.count

        // Event counts.
        let unlockRequests = events.filter { $0.eventType == .unlockRequested }.count
        let selfUnlocks = events.filter { $0.eventType == .localPINUnlock }.count

        // Device health.
        let now = Date()
        let onlineThreshold = AppConstants.onlineThresholdSeconds
        let onlineCount = heartbeats.filter {
            now.timeIntervalSince($0.timestamp) < onlineThreshold
        }.count

        let familySummary = FamilySummary(
            totalCommands: activeRecords.count,
            successCount: successCount,
            failCount: failCount,
            pendingCount: pendingCount,
            avgLatency: avgLat,
            medianLatency: medLat,
            p95Latency: p95Lat,
            onlineDevices: onlineCount,
            totalDevices: childDevices.count,
            unlockRequestCount: unlockRequests,
            selfUnlockCount: selfUnlocks
        )

        // Bucket histogram.
        var buckets: [LatencyBucket: Int] = [:]
        for record in activeRecords {
            buckets[record.latencyBucket, default: 0] += 1
        }
        let bucketCounts = LatencyBucket.allCases
            .map { BucketCount(bucket: $0, count: buckets[$0] ?? 0) }
            .filter { $0.count > 0 }

        // Recent commands (newest first).
        let recentCommands = Array(activeRecords
            .sorted { $0.issuedAt > $1.issuedAt }
            .prefix(50))

        // Per-child summaries — use commandByID for O(1) target resolution.
        let allChildIDs = childProfiles.map(\.id)
        var childGrouped: [ChildProfileID: [CommandLatencyRecord]] = [:]
        for record in activeRecords {
            let targetChildIDs: [ChildProfileID]
            if let cmd = commandByID[record.id] {
                switch cmd.target {
                case .child(let cid): targetChildIDs = [cid]
                case .device(let did): targetChildIDs = deviceToChild[did].map { [$0] } ?? []
                case .allDevices: targetChildIDs = allChildIDs
                }
            } else {
                targetChildIDs = []
            }
            for childID in targetChildIDs {
                childGrouped[childID, default: []].append(record)
            }
        }

        // Group events by child.
        var childEvents: [ChildProfileID: [EventLogEntry]] = [:]
        for event in events {
            if let childID = deviceToChild[event.deviceID] {
                childEvents[childID, default: []].append(event)
            }
        }

        // --- Lock precision ---
        // Pre-sort events by type for efficient pairing.
        let unlockStarts = events
            .filter { $0.eventType == .temporaryUnlockStarted }
            .sorted { $0.timestamp < $1.timestamp }
        let unlockExpires = events
            .filter { $0.eventType == .temporaryUnlockExpired }
            .sorted { $0.timestamp < $1.timestamp }

        // Group unlock starts by device for O(1) lookup instead of linear scan.
        let startsByDevice = Dictionary(grouping: unlockStarts, by: \.deviceID)

        // Index temporaryUnlock commands by device+time for faster matching.
        struct CmdKey: Hashable { let deviceID: DeviceID; let bucket: Int }
        var unlockCmdsByDevice: [DeviceID: [(date: Date, seconds: Int)]] = [:]
        for cmd in actionableCommands {
            if case .temporaryUnlock(let secs) = cmd.action, secs > 0 {
                let deviceIDs: [DeviceID]
                switch cmd.target {
                case .child(let cid):
                    deviceIDs = childDevices.filter { $0.childProfileID == cid }.map(\.id)
                case .device(let did):
                    deviceIDs = [did]
                case .allDevices:
                    deviceIDs = childDevices.map(\.id)
                }
                for did in deviceIDs {
                    unlockCmdsByDevice[did, default: []].append((cmd.issuedAt, secs))
                }
            }
        }

        var precisionRecords: [LockPrecisionRecord] = []
        for expire in unlockExpires {
            // Find most recent unlock start on same device before this expiry.
            guard let deviceStarts = startsByDevice[expire.deviceID],
                  let matchingStart = deviceStarts.last(where: { $0.timestamp < expire.timestamp })
            else { continue }

            // Find matching command within 2 minutes of start.
            // If no command matched, this was a self-unlock or PIN unlock — we don't know
            // the intended duration so precision is meaningless. Skip it.
            guard let cmds = unlockCmdsByDevice[expire.deviceID],
                  let match = cmds.first(where: { abs(matchingStart.timestamp.timeIntervalSince($0.date)) < 120 })
            else { continue }
            let duration = match.seconds
            guard duration >= 60 else { continue }

            let childName = deviceToChild[expire.deviceID].flatMap { childNameMap[$0] }
            precisionRecords.append(LockPrecisionRecord(
                id: expire.id,
                childName: childName,
                expectedDurationSeconds: duration,
                unlockStartedAt: matchingStart.timestamp,
                lockExpiredAt: expire.timestamp
            ))
        }
        // Filter out manually overridden unlocks (parent sent lock shortly after unlock).
        // These aren't timing precision issues — they skew the stats.
        let lockPrecisionRecords = precisionRecords
            .filter { !$0.wasManuallyOverridden }
            .sorted { $0.lockExpiredAt > $1.lockExpiredAt }

        // --- Schedule transition precision ---
        let scheduleStarts = events
            .filter { $0.eventType == .scheduleTriggered }
            .sorted { $0.timestamp < $1.timestamp }
        let scheduleEnds = events
            .filter { $0.eventType == .scheduleEnded }
            .sorted { $0.timestamp < $1.timestamp }

        let deviceProfileMap = Dictionary(
            uniqueKeysWithValues: childDevices
                .compactMap { dev in dev.scheduleProfileID.map { (dev.id, $0) } }
        )
        let profileMap = Dictionary(
            uniqueKeysWithValues: scheduleProfiles.map { ($0.id, $0) }
        )
        let windowPrefix = "bigbrother.scheduleprofile."
        let cal = Calendar.current
        var transitionRecords: [ScheduleTransitionRecord] = []

        // Group schedule starts by device for efficient lookup.
        let schedStartsByDevice = Dictionary(grouping: scheduleStarts, by: \.deviceID)

        // Unlock transitions
        for event in scheduleStarts {
            guard let details = event.details,
                  let range = details.range(of: windowPrefix) else { continue }
            let windowIDStr = String(details[range.upperBound...])
            guard let windowUUID = UUID(uuidString: windowIDStr),
                  let profileID = deviceProfileMap[event.deviceID],
                  let profile = profileMap[profileID],
                  let window = profile.unlockedWindows.first(where: { $0.id == windowUUID }) else { continue }

            var comps = cal.dateComponents([.year, .month, .day], from: event.timestamp)
            comps.hour = window.startTime.hour
            comps.minute = window.startTime.minute
            comps.second = 0
            guard let expectedDate = cal.date(from: comps) else { continue }

            let childName = deviceToChild[event.deviceID].flatMap { childNameMap[$0] }
            transitionRecords.append(ScheduleTransitionRecord(
                id: event.id, childName: childName, transitionType: .unlock,
                scheduledTime: expectedDate, actualTime: event.timestamp
            ))
        }

        // Lock transitions
        for event in scheduleEnds {
            guard let details = event.details,
                  details.hasPrefix("Unlocked window ended") || details.hasPrefix("Free window ended") else { continue }
            guard let deviceStarts = schedStartsByDevice[event.deviceID],
                  let matchingStart = deviceStarts.last(where: { $0.timestamp < event.timestamp }),
                  let startDetails = matchingStart.details,
                  let range = startDetails.range(of: windowPrefix) else { continue }

            let windowIDStr = String(startDetails[range.upperBound...])
            guard let windowUUID = UUID(uuidString: windowIDStr),
                  let profileID = deviceProfileMap[event.deviceID],
                  let profile = profileMap[profileID],
                  let window = profile.unlockedWindows.first(where: { $0.id == windowUUID }) else { continue }

            var comps = cal.dateComponents([.year, .month, .day], from: event.timestamp)
            comps.hour = window.endTime.hour
            comps.minute = window.endTime.minute
            comps.second = 0
            guard let expectedDate = cal.date(from: comps) else { continue }

            let childName = deviceToChild[event.deviceID].flatMap { childNameMap[$0] }
            transitionRecords.append(ScheduleTransitionRecord(
                id: event.id, childName: childName, transitionType: .lock,
                scheduledTime: expectedDate, actualTime: event.timestamp
            ))
        }

        let scheduleTransitionRecords = transitionRecords.sorted { $0.actualTime > $1.actualTime }

        // Build heartbeat lookup.
        let heartbeatMap = Dictionary(uniqueKeysWithValues: heartbeats.map { ($0.deviceID, $0) })

        let childSummaries: [ChildInsightsSummary] = childProfiles.compactMap { child in
            let records = childGrouped[child.id] ?? []
            let lats = records.compactMap(\.latencySeconds).sorted()
            let childSuccessCount = records.filter { $0.status == .applied }.count
            let rate = records.isEmpty ? 1.0 : Double(childSuccessCount) / Double(records.count)

            let evts = childEvents[child.id] ?? []
            var eventCounts: [EventType: Int] = [:]
            for e in evts { eventCounts[e.eventType, default: 0] += 1 }

            let devs = childDevices.filter { $0.childProfileID == child.id }
            let snapshots: [DeviceSnapshot] = devs.map { dev in
                let hb = heartbeatMap[dev.id]
                let online = hb.map { now.timeIntervalSince($0.timestamp) < onlineThreshold } ?? false
                return DeviceSnapshot(
                    id: dev.id,
                    displayName: dev.displayName,
                    lastHeartbeat: hb?.timestamp,
                    isOnline: online,
                    currentMode: hb?.currentMode ?? .restricted,
                    batteryLevel: hb?.batteryLevel,
                    lastCommandProcessedAt: hb?.lastCommandProcessedAt,
                    enforcementError: hb?.enforcementError,
                    appBuildNumber: hb?.appBuildNumber
                )
            }

            return ChildInsightsSummary(
                id: child.id,
                childName: child.name,
                commandCount: records.count,
                successRate: rate,
                avgLatency: lats.isEmpty ? nil : lats.reduce(0, +) / Double(lats.count),
                medianLatency: lats.isEmpty ? nil : lats[lats.count / 2],
                latencyRecords: records.sorted { $0.issuedAt > $1.issuedAt },
                eventCounts: eventCounts,
                deviceSnapshots: snapshots
            )
        }

        return InsightsResult(
            familySummary: familySummary,
            childSummaries: childSummaries,
            recentCommands: recentCommands,
            bucketCounts: bucketCounts,
            lockPrecisionRecords: lockPrecisionRecords,
            scheduleTransitionRecords: scheduleTransitionRecords
        )
    }

    // MARK: - Debug Log Dump

    private func dumpToLog() {
        let divider = String(repeating: "\u{2500}", count: 60)
        var lines: [String] = []
        lines.append("\n\(divider)")
        lines.append("INSIGHTS DUMP  [\(timeRange.rawValue)]  \(Date())")
        lines.append(divider)

        if let fs = familySummary {
            lines.append("")
            lines.append("FAMILY SUMMARY")
            lines.append("  Commands: \(fs.totalCommands) total  \u{2713}\(fs.successCount)  \u{2717}\(fs.failCount)  \u{23F3}\(fs.pendingCount)")
            let rate = fs.totalCommands > 0 ? Double(fs.successCount) / Double(fs.totalCommands) * 100 : 0
            lines.append("  Success rate: \(String(format: "%.1f%%", rate))")
            lines.append("  Latency  avg: \(formatLat(fs.avgLatency))  med: \(formatLat(fs.medianLatency))  p95: \(formatLat(fs.p95Latency))")
            lines.append("  Devices: \(fs.onlineDevices)/\(fs.totalDevices) online")
            lines.append("  Unlock requests: \(fs.unlockRequestCount)  Self-unlocks: \(fs.selfUnlockCount)")
        }

        if !bucketCounts.isEmpty {
            lines.append("")
            lines.append("LATENCY HISTOGRAM")
            for bc in bucketCounts {
                let bar = String(repeating: "\u{2588}", count: min(bc.count, 40))
                lines.append("  \(bc.bucket.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(bar) \(bc.count)")
            }
        }

        if !lockPrecisionRecords.isEmpty {
            lines.append("")
            lines.append("LOCK PRECISION (\(lockPrecisionRecords.count) records)")
            let drifts = lockPrecisionRecords.map(\.driftSeconds)
            let avgDrift = drifts.reduce(0, +) / Double(drifts.count)
            let onTime = drifts.filter { abs($0) < 30 }.count
            lines.append("  On-time (\u{00B1}30s): \(onTime)/\(drifts.count)  Avg drift: \(String(format: "%+.1fs", avgDrift))")
            for r in lockPrecisionRecords.prefix(10) {
                let name = r.childName ?? "?"
                let expected = formatDuration(r.expectedDurationSeconds)
                let drift = String(format: "%+.1fs", r.driftSeconds)
                lines.append("  [\(name)] expected \(expected), drift \(drift)  \(shortDate(r.lockExpiredAt))")
            }
        }

        if !scheduleTransitionRecords.isEmpty {
            lines.append("")
            lines.append("SCHEDULE PRECISION (\(scheduleTransitionRecords.count) transitions)")
            let drifts = scheduleTransitionRecords.map(\.driftSeconds)
            let avgDrift = drifts.reduce(0, +) / Double(drifts.count)
            lines.append("  Avg drift: \(String(format: "%+.1fs", avgDrift))")
            for r in scheduleTransitionRecords.prefix(10) {
                let name = r.childName ?? "?"
                let drift = String(format: "%+.1fs", r.driftSeconds)
                lines.append("  [\(name)] \(r.transitionType.rawValue) scheduled \(shortTime(r.scheduledTime)) actual \(shortTime(r.actualTime)) drift \(drift)")
            }
        }

        if !childSummaries.isEmpty {
            lines.append("")
            lines.append("PER-CHILD SUMMARIES")
            for cs in childSummaries {
                lines.append("")
                lines.append("  \(cs.childName)")
                lines.append("    Commands: \(cs.commandCount)  Success: \(String(format: "%.0f%%", cs.successRate * 100))")
                lines.append("    Latency  avg: \(formatLat(cs.avgLatency))  med: \(formatLat(cs.medianLatency))")
                if !cs.eventCounts.isEmpty {
                    let sorted = cs.eventCounts.sorted { $0.value > $1.value }
                    let evtStr = sorted.map { "\($0.key.rawValue):\($0.value)" }.joined(separator: "  ")
                    lines.append("    Events: \(evtStr)")
                }
                for ds in cs.deviceSnapshots {
                    let status = ds.isOnline ? "\u{1F7E2}" : "\u{1F534}"
                    let mode = ds.currentMode.displayName
                    let hb = ds.lastHeartbeat.map { shortDate($0) } ?? "never"
                    let battery = ds.batteryLevel.map { String(format: "%.0f%%", $0 * 100) } ?? "?"
                    let build = ds.appBuildNumber.map { "b\($0)" } ?? "?"
                    var deviceLine = "    \(status) \(ds.displayName)  \(mode)  hb:\(hb)  bat:\(battery)  \(build)"
                    if let err = ds.enforcementError {
                        deviceLine += "  \u{26A0}\u{FE0F} \(err)"
                    }
                    lines.append(deviceLine)
                }
            }
        }

        if !recentCommands.isEmpty {
            lines.append("")
            lines.append("RECENT COMMANDS (last \(min(recentCommands.count, 20)))")
            for cmd in recentCommands.prefix(20) {
                let statusIcon: String
                switch cmd.status {
                case .applied: statusIcon = "\u{2713}"
                case .failed: statusIcon = "\u{2717}"
                case .pending, .delivered: statusIcon = "\u{23F3}"
                case .expired: statusIcon = "\u{23F0}"
                }
                let target = cmd.targetChildName ?? "?"
                let lat = cmd.latencySeconds.map { String(format: "%.1fs", $0) } ?? "-"
                lines.append("  \(statusIcon) \(shortDate(cmd.issuedAt))  \(cmd.action.displayDescription.padding(toLength: 22, withPad: " ", startingAt: 0))  \u{2192} \(target.padding(toLength: 10, withPad: " ", startingAt: 0))  \(lat)")
            }
        }

        lines.append(divider)
        print(lines.joined(separator: "\n"))
    }

    private func formatLat(_ secs: Double?) -> String {
        guard let s = secs else { return "-" }
        if s < 60 { return String(format: "%.1fs", s) }
        return String(format: "%.1fm", s / 60)
    }

    private func formatDuration(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return String(format: "%.1fh", Double(secs) / 3600)
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
