import Foundation
import Observation
import BigBrotherCore

@Observable
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

            // Build receipt lookup by commandID.
            let receiptMap = Dictionary(grouping: receipts, by: \.commandID)

            // Build child name lookup.
            let childNameMap = Dictionary(
                uniqueKeysWithValues: appState.childProfiles.map { ($0.id, $0.name) }
            )

            // Build device→child mapping.
            let deviceToChild = Dictionary(
                uniqueKeysWithValues: appState.childDevices.map { ($0.id, $0.childProfileID) }
            )

            // Filter out config/housekeeping commands — they're fire-and-forget,
            // not worth tracking latency on, and they spam the insights.
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

            // Filter out expired commands — they're stale noise, not useful for analytics.
            let activeRecords = latencyRecords.filter { $0.status != .expired }

            // Compute latency stats from active (non-expired) commands only.
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

            familySummary = FamilySummary(
                totalCommands: activeRecords.count,
                successCount: successCount,
                failCount: failCount,
                pendingCount: pendingCount,
                avgLatency: avgLat,
                medianLatency: medLat,
                p95Latency: p95Lat,
                onlineDevices: onlineCount,
                totalDevices: appState.childDevices.count,
                unlockRequestCount: unlockRequests,
                selfUnlockCount: selfUnlocks
            )

            // Bucket histogram (active commands only).
            var buckets: [LatencyBucket: Int] = [:]
            for record in activeRecords {
                buckets[record.latencyBucket, default: 0] += 1
            }
            bucketCounts = LatencyBucket.allCases
                .map { BucketCount(bucket: $0, count: buckets[$0] ?? 0) }
                .filter { $0.count > 0 }

            // Recent commands (newest first, exclude expired noise).
            recentCommands = activeRecords
                .sorted { $0.issuedAt > $1.issuedAt }
                .prefix(50)
                .map { $0 }

            // Per-child summaries (active commands only).
            // `.allDevices` commands count for ALL children.
            let allChildIDs = appState.orderedChildProfiles.map(\.id)
            var childGrouped: [ChildProfileID: [CommandLatencyRecord]] = [:]
            for record in activeRecords {
                let targetChildIDs: [ChildProfileID] = {
                    if let cmd = actionableCommands.first(where: { $0.id == record.id }) {
                        switch cmd.target {
                        case .child(let cid): return [cid]
                        case .device(let did): return deviceToChild[did].map { [$0] } ?? []
                        case .allDevices: return allChildIDs
                        }
                    }
                    return []
                }()
                for childID in targetChildIDs {
                    childGrouped[childID, default: []].append(record)
                }
            }

            // Group events by child's device(s).
            var childEvents: [ChildProfileID: [EventLogEntry]] = [:]
            for event in events {
                if let childID = deviceToChild[event.deviceID] {
                    childEvents[childID, default: []].append(event)
                }
            }

            // Lock precision: pair temporaryUnlockStarted with temporaryUnlockExpired
            // events on the same device, then compare actual duration vs expected.
            let unlockStarts = events
                .filter { $0.eventType == .temporaryUnlockStarted }
                .sorted { $0.timestamp < $1.timestamp }
            let unlockExpires = events
                .filter { $0.eventType == .temporaryUnlockExpired }
                .sorted { $0.timestamp < $1.timestamp }

            var precisionRecords: [LockPrecisionRecord] = []
            for expire in unlockExpires {
                // Find the most recent unlock start on the same device before this expiry.
                guard let matchingStart = unlockStarts.last(where: {
                    $0.deviceID == expire.deviceID && $0.timestamp < expire.timestamp
                }) else { continue }

                // Try to find the command that triggered this unlock to get the intended duration.
                // Look for temporaryUnlock commands issued within 2 minutes of the start event.
                let matchingCmd = actionableCommands.first(where: { cmd in
                    if case .temporaryUnlock(let secs) = cmd.action {
                        let diff = abs(matchingStart.timestamp.timeIntervalSince(cmd.issuedAt))
                        return diff < 120 && secs > 0
                    }
                    return false
                })

                let duration: Int
                if case .temporaryUnlock(let secs) = matchingCmd?.action {
                    duration = secs
                } else {
                    // Infer from the gap between start and expiry — assume it was intended.
                    duration = Int(expire.timestamp.timeIntervalSince(matchingStart.timestamp))
                }

                let childName = deviceToChild[expire.deviceID].flatMap { childNameMap[$0] }
                precisionRecords.append(LockPrecisionRecord(
                    id: expire.id,
                    childName: childName,
                    expectedDurationSeconds: duration,
                    unlockStartedAt: matchingStart.timestamp,
                    lockExpiredAt: expire.timestamp
                ))
            }
            lockPrecisionRecords = precisionRecords.sorted { $0.lockExpiredAt > $1.lockExpiredAt }

            // Build heartbeat lookup by deviceID.
            let heartbeatMap = Dictionary(uniqueKeysWithValues: heartbeats.map { ($0.deviceID, $0) })

            childSummaries = appState.orderedChildProfiles.compactMap { child in
                let records = childGrouped[child.id] ?? []
                let lats = records.compactMap(\.latencySeconds).sorted()
                let childSuccessCount = records.filter { $0.status == .applied }.count
                let rate = records.isEmpty ? 1.0 : Double(childSuccessCount) / Double(records.count)

                // Event type counts.
                let evts = childEvents[child.id] ?? []
                var eventCounts: [EventType: Int] = [:]
                for e in evts { eventCounts[e.eventType, default: 0] += 1 }

                // Device snapshots.
                let devs = appState.childDevices.filter { $0.childProfileID == child.id }
                let snapshots: [DeviceSnapshot] = devs.map { dev in
                    let hb = heartbeatMap[dev.id]
                    let online = hb.map { now.timeIntervalSince($0.timestamp) < onlineThreshold } ?? false
                    return DeviceSnapshot(
                        id: dev.id,
                        displayName: dev.displayName,
                        lastHeartbeat: hb?.timestamp,
                        isOnline: online,
                        currentMode: hb?.currentMode ?? .dailyMode,
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
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
