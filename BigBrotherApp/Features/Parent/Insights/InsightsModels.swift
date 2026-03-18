import Foundation
import BigBrotherCore

/// Time range for insights queries.
enum InsightsTimeRange: String, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }

    var since: Date {
        switch self {
        case .day: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        }
    }
}

/// A command joined with its receipt for latency calculation.
struct CommandLatencyRecord: Identifiable {
    let id: UUID
    let action: CommandAction
    let targetChildName: String?
    let issuedAt: Date
    let appliedAt: Date?
    let status: CommandStatus

    var latencySeconds: Double? {
        guard let appliedAt else { return nil }
        let lat = appliedAt.timeIntervalSince(issuedAt)
        return max(0, lat) // Clamp negative (clock skew)
    }

    var latencyBucket: LatencyBucket {
        guard let secs = latencySeconds else { return .noReceipt }
        if secs < 10 { return .fast }
        if secs < 30 { return .good }
        if secs < 60 { return .moderate }
        if secs < 300 { return .slow }
        return .verySlow
    }
}

/// Latency distribution buckets for the histogram.
enum LatencyBucket: String, CaseIterable, Identifiable {
    case fast = "< 10s"
    case good = "10–30s"
    case moderate = "30s–1m"
    case slow = "1–5m"
    case verySlow = "5m+"
    case noReceipt = "Pending"

    var id: String { rawValue }

    var sortOrder: Int {
        switch self {
        case .fast: 0
        case .good: 1
        case .moderate: 2
        case .slow: 3
        case .verySlow: 4
        case .noReceipt: 5
        }
    }
}

/// Per-child aggregate insights.
struct ChildInsightsSummary: Identifiable {
    let id: ChildProfileID
    let childName: String
    let commandCount: Int
    let successRate: Double
    let avgLatency: Double?
    let medianLatency: Double?
    let latencyRecords: [CommandLatencyRecord]
    let eventCounts: [EventType: Int]
    let deviceSnapshots: [DeviceSnapshot]
}

/// Per-device health snapshot from heartbeat data.
struct DeviceSnapshot: Identifiable {
    let id: DeviceID
    let displayName: String
    let lastHeartbeat: Date?
    let isOnline: Bool
    let currentMode: LockMode
    let batteryLevel: Double?
    let lastCommandProcessedAt: Date?
    let enforcementError: String?
    let appBuildNumber: Int?
}

/// Family-level aggregate summary.
struct FamilySummary {
    let totalCommands: Int
    let successCount: Int
    let failCount: Int
    let pendingCount: Int
    let avgLatency: Double?
    let medianLatency: Double?
    let p95Latency: Double?
    let onlineDevices: Int
    let totalDevices: Int
    let unlockRequestCount: Int
    let selfUnlockCount: Int
}

/// Bucket count for the histogram chart.
struct BucketCount: Identifiable {
    let bucket: LatencyBucket
    let count: Int
    var id: String { bucket.id }
}

/// Tracks how precisely a temporary unlock re-locked on time.
struct LockPrecisionRecord: Identifiable {
    let id: UUID  // event ID
    let childName: String?
    let expectedDurationSeconds: Int
    let unlockStartedAt: Date
    let lockExpiredAt: Date
    /// Positive = locked late, negative = locked early.
    var driftSeconds: Double {
        let expected = unlockStartedAt.addingTimeInterval(Double(expectedDurationSeconds))
        return lockExpiredAt.timeIntervalSince(expected)
    }
}

/// Tracks drift between scheduled free window start/end and actual enforcement.
struct ScheduleTransitionRecord: Identifiable {
    let id: UUID
    let childName: String?
    let transitionType: TransitionType
    let scheduledTime: Date
    let actualTime: Date

    /// Positive = late, negative = early.
    var driftSeconds: Double {
        actualTime.timeIntervalSince(scheduledTime)
    }

    enum TransitionType: String {
        case unlock = "Unlock"
        case lock = "Lock"
    }
}
