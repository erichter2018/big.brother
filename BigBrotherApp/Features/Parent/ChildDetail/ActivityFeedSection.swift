import SwiftUI
import BigBrotherCore

/// Compact activity feed showing recent events for a child.
struct ActivityFeedSection: View {
    let entries: [TimelineEntry]
    let limit: Int

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
                    activityRow(entry)
                }
            }
        }
        .padding(12)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
    }

    @ViewBuilder
    private func activityRow(_ entry: TimelineEntry) -> some View {
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
        }
    }

    private func iconName(for entry: TimelineEntry) -> String {
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
