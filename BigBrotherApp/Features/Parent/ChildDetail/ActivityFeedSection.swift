import SwiftUI
import BigBrotherCore

/// Compact activity feed showing recent events for a child.
struct ActivityFeedSection: View {
    let entries: [TimelineEntry]
    let limit: Int
    let child: ChildProfile
    let devices: [ChildDevice]
    let heartbeats: [DeviceHeartbeat]
    let cloudKit: (any CloudKitServiceProtocol)?
    let onLocate: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if entries.isEmpty {
                Text("No recent activity")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(entries.prefix(limit)) { entry in
                    if entry.eventType == .tripCompleted {
                        NavigationLink {
                            LocationMapView(
                                child: child,
                                devices: devices,
                                heartbeats: heartbeats,
                                cloudKit: cloudKit,
                                onLocate: onLocate,
                                focusTripAt: entry.timestamp
                            )
                        } label: {
                            activityRowContent(entry, showChevron: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        activityRowContent(entry, showChevron: false)
                    }
                }
            }
        }
        .padding(12)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
    }

    @ViewBuilder
    private func activityRowContent(_ entry: TimelineEntry, showChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: entry))
                .font(.system(size: 11))
                .foregroundStyle(iconColor(for: entry))
                .frame(width: 16)

            Text(entry.label)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Text(entry.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func iconName(for entry: TimelineEntry) -> String {
        if let type = entry.eventType {
            switch type {
            case .tripCompleted: return "car.fill"
            case .speedingDetected: return "gauge.with.dots.needle.67percent"
            case .phoneWhileDriving: return "iphone.gen3.radiowaves.left.and.right"
            case .hardBrakingDetected: return "exclamationmark.octagon"
            case .namedPlaceArrival: return "figure.walk.arrival"
            case .namedPlaceDeparture: return "figure.walk.departure"
            case .selfUnlockUsed: return "lock.rotation"
            case .sosAlert: return "sos"
            default: break
            }
        }
        let label = entry.label.lowercased()
        if entry.isUnlockRequest { return "hand.raised" }
        if label.contains("self-unlock") || label.contains("Self-Unlock") { return "lock.rotation" }
        if label.contains("unlock") { return "lock.open" }
        if label.contains("lock down") { return "wifi.slash" }
        if label.contains("lock") || label.contains("restrict") { return "lock.fill" }
        if label.contains("block") || label.contains("shield") { return "shield.slash" }
        if label.contains("schedule") { return "calendar" }
        if label.contains("heartbeat") { return "heart.fill" }
        if entry.isCommand { return "arrow.down.circle" }
        return "circle.fill"
    }

    private func iconColor(for entry: TimelineEntry) -> Color {
        if let type = entry.eventType {
            switch type {
            case .tripCompleted: return .green
            case .speedingDetected, .sosAlert: return .red
            case .phoneWhileDriving, .hardBrakingDetected: return .orange
            case .namedPlaceArrival, .namedPlaceDeparture: return .blue
            case .selfUnlockUsed: return .teal
            default: break
            }
        }
        let label = entry.label.lowercased()
        if entry.isUnlockRequest { return .orange }
        if label.contains("self-unlock") || label.contains("Self-Unlock") { return .teal }
        if label.contains("unlock") { return .green }
        if label.contains("lock down") { return .red }
        if label.contains("lock") || label.contains("restrict") { return .blue }
        if label.contains("block") || label.contains("shield") { return .red }
        if label.contains("fail") || label.contains("error") { return .red }
        if entry.isCommand { return .purple }
        return .secondary
    }
}
