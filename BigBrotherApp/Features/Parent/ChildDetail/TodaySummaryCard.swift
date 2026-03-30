import SwiftUI
import BigBrotherCore

/// At-a-glance summary card showing key stats for today.
struct TodaySummaryCard: View {
    let screenTimeMinutes: Int?
    let screenUnlockCount: Int?
    let batteryLevel: Double?
    let isCharging: Bool
    let lastHeartbeat: Date?
    let heartbeatSource: String?
    let scheduleStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Screen time + Battery
            HStack(spacing: 0) {
                statCell(
                    icon: "hourglass",
                    iconColor: .orange,
                    value: screenTimeText,
                    label: "Screen Time"
                )
                Divider().frame(height: 30)
                statCell(
                    icon: "lock.open",
                    iconColor: .blue,
                    value: unlockCountText,
                    label: "Unlocks"
                )
                Divider().frame(height: 30)
                statCell(
                    icon: batteryIcon,
                    iconColor: batteryColor,
                    value: batteryText,
                    label: isCharging ? "Charging" : "Battery"
                )
                Divider().frame(height: 30)
                statCell(
                    icon: heartbeatSource == "vpnTunnel" ? "shield.fill" : "heart.fill",
                    iconColor: .pink,
                    value: lastSeenText,
                    label: "Last Seen"
                )
            }
            .padding(.vertical, 10)

            // Row 2: Schedule status (if active)
            if let scheduleStatus {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(scheduleStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
    }

    @ViewBuilder
    private func statCell(icon: String, iconColor: Color, value: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(iconColor)
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var unlockCountText: String {
        guard let count = screenUnlockCount else { return "--" }
        return "\(count)"
    }

    private var screenTimeText: String {
        guard let minutes = screenTimeMinutes else { return "--" }
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var batteryText: String {
        guard let level = batteryLevel else { return "--" }
        return "\(Int(level * 100))%"
    }

    private var batteryIcon: String {
        guard let level = batteryLevel else { return "battery.0" }
        if isCharging { return "battery.100.bolt" }
        if level > 0.75 { return "battery.100" }
        if level > 0.5 { return "battery.75" }
        if level > 0.25 { return "battery.50" }
        return "battery.25"
    }

    private var batteryColor: Color {
        guard let level = batteryLevel else { return .secondary }
        if isCharging { return .green }
        return level < 0.2 ? .red : .green
    }

    private var lastSeenText: String {
        guard let ts = lastHeartbeat else { return "--" }
        let age = -ts.timeIntervalSinceNow
        if age < 60 { return "now" }
        if age < 3600 { return "\(Int(age / 60))m" }
        if age < 86400 { return "\(Int(age / 3600))h" }
        return "\(Int(age / 86400))d"
    }
}
