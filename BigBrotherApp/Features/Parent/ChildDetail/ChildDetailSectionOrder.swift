import Foundation
import BigBrotherCore

/// Identifiers for reorderable sections in the child detail view.
enum ChildDetailSection: String, Codable, CaseIterable, Identifiable {
    case miniMap = "miniMap"
    case todaySummary = "todaySummary"
    case screenTimeTrend = "screenTimeTrend"
    case screenTimeTimeline = "screenTimeTimeline"
    case onlineActivity = "onlineActivity"
    case flaggedActivity = "flaggedActivity"
    case recentActivity = "recentActivity"
    case devices = "devices"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .miniMap: return "Map"
        case .todaySummary: return "Today's Summary"
        case .screenTimeTrend: return "Screen Time Trend"
        case .screenTimeTimeline: return "Screen Time Timeline"
        case .onlineActivity: return "Online Activity"
        case .flaggedActivity: return "Flagged Activity"
        case .recentActivity: return "Recent Activity"
        case .devices: return "Devices"
        }
    }

    var icon: String {
        switch self {
        case .miniMap: return "map"
        case .todaySummary: return "chart.bar"
        case .screenTimeTrend: return "clock"
        case .screenTimeTimeline: return "chart.bar.xaxis"
        case .onlineActivity: return "globe"
        case .flaggedActivity: return "exclamationmark.triangle"
        case .recentActivity: return "bell"
        case .devices: return "ipad.and.iphone"
        }
    }

    /// Default section order.
    static let defaultOrder: [ChildDetailSection] = [
        .miniMap, .todaySummary, .screenTimeTrend, .screenTimeTimeline,
        .flaggedActivity, .onlineActivity, .recentActivity,
        .devices
    ]

    /// Load saved order for a child, falling back to default.
    static func loadOrder(for childID: ChildProfileID) -> [ChildDetailSection] {
        let key = "sectionOrder.\(childID.rawValue)"
        guard let raw = UserDefaults.standard.stringArray(forKey: key),
              !raw.isEmpty else {
            return defaultOrder
        }
        var result = raw.compactMap { ChildDetailSection(rawValue: $0) }
        // Append any new sections not in saved order
        for section in defaultOrder where !result.contains(section) {
            result.append(section)
        }
        return result
    }

    /// Save section order for a child.
    static func saveOrder(_ order: [ChildDetailSection], for childID: ChildProfileID) {
        let key = "sectionOrder.\(childID.rawValue)"
        UserDefaults.standard.set(order.map(\.rawValue), forKey: key)
    }

    /// Load hidden sections for a child.
    static func loadHidden(for childID: ChildProfileID) -> Set<ChildDetailSection> {
        let key = "sectionHidden.\(childID.rawValue)"
        guard let raw = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return Set(raw.compactMap { ChildDetailSection(rawValue: $0) })
    }

    /// Save hidden sections for a child.
    static func saveHidden(_ hidden: Set<ChildDetailSection>, for childID: ChildProfileID) {
        let key = "sectionHidden.\(childID.rawValue)"
        UserDefaults.standard.set(hidden.map(\.rawValue), forKey: key)
    }
}
