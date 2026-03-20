import SwiftUI
import BigBrotherCore

/// Compact child card for the parent dashboard.
/// Glassmorphic card with avatar ring, status lines, and single contextual pill button.
struct ChildSummaryCard: View {
    let child: ChildProfile
    let devices: [ChildDevice]
    let heartbeats: [DeviceHeartbeat]
    let dominantMode: LockMode
    let isSending: Bool
    let countdown: String?
    let remainingSeconds: Int?
    let penaltyTimer: String?
    let isPenaltyRunning: Bool
    let selfUnlocksUsed: Int?
    let selfUnlockBudget: Int?
    let avatarHexColor: String?
    let avatarImageUrl: String?
    let unlockOrigin: TemporaryUnlockOrigin?
    let isHeartbeatConfirmed: Bool
    let isInPenaltyPhase: Bool
    let isScheduleActive: Bool
    let scheduleLabel: String?      // e.g. "Middle School Schedule"
    let scheduleStatus: String?     // e.g. "Locked until 3:00 PM"
    let scheduleStatusIsFree: Bool
    let onLock: (LockDuration) -> Void
    let onUnlock: (Int) -> Void
    let onUnlockWithTimer: ((Int) -> Void)?
    let onSchedule: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Avatar with mode ring
            avatarWithRing

            // Name + status lines
            VStack(alignment: .leading, spacing: 2) {
                Text(child.name + (isOnOldBuild ? "…" : ""))
                    .font(.headline)
                    .lineLimit(1)

                statusLine

                tertiaryLine
            }

            Spacer(minLength: 0)

            // Single contextual pill button
            pillButton
                .disabled(isSending)
                .opacity(isSending ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 16,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                    .fill(mutedModeColor.opacity(0.4))
                    .frame(width: 2)
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Avatar with Glow

    @ViewBuilder
    private var avatarWithRing: some View {
        avatarContent
            .background(
                Circle()
                    .fill(modeColor.opacity(0.5))
                    .blur(radius: 14)
                    .scaleEffect(1.25)
            )
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let base64 = avatarImageUrl,
           let data = Data(base64Encoded: base64),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    @ViewBuilder
    private var avatarFallback: some View {
        let initials = String(child.name.prefix(1)).uppercased()
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: 56, height: 56)
            Text(initials)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
    }

    private var avatarGradient: LinearGradient {
        if let hex = avatarHexColor, let color = Color(hex: hex) {
            return LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let colors: [(Color, Color)] = [
            (.blue, .cyan), (.purple, .pink), (.green, .mint),
            (.orange, .yellow), (.indigo, .purple), (.teal, .green)
        ]
        let index = abs(child.id.rawValue.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }) % colors.count
        let pair = colors[index]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Status Line (Line 2)

    @ViewBuilder
    private var statusLine: some View {
        if isInPenaltyPhase {
            HStack(spacing: 3) {
                if !isHeartbeatConfirmed {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                Text("Locked \u{00B7} pending timer")
                    .font(.caption)
                    .foregroundStyle(Self.mutedBlue)
            }
        } else if let countdown {
            HStack(spacing: 4) {
                if !isHeartbeatConfirmed {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                let label: String = {
                    switch unlockOrigin {
                    case .selfUnlock: return "Self-unlocked"
                    case .localPINUnlock: return "PIN unlocked"
                    case .remoteCommand: return "Unlocked"
                    case .none: return "Unlocked"
                    }
                }()
                Text("\(label) \u{00B7} \(countdown) left")
                    .font(.caption)
                    .foregroundStyle(Self.mutedGreen)
            }
        } else if let scheduleLabel, isScheduleActive {
            HStack(spacing: 3) {
                if !isHeartbeatConfirmed {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(scheduleLabel)
                        .font(.caption)
                        .foregroundStyle(Self.mutedOrange)
                        .lineLimit(1)
                    if let scheduleStatus {
                        Text(scheduleStatus)
                            .font(.caption)
                            .foregroundStyle(scheduleStatusIsFree ? Self.mutedGreen : scheduleStatus.hasPrefix("Essential") ? Self.mutedPurple : Self.mutedBlue)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            HStack(spacing: 3) {
                if !isHeartbeatConfirmed {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                Text(dominantMode.displayName)
                    .font(.caption)
                    .foregroundStyle(mutedModeColor)
            }
        }
    }

    // MARK: - Tertiary Line (Line 3)

    @ViewBuilder
    private var tertiaryLine: some View {
        HStack(spacing: 4) {
            if let penaltyTimer {
                Image(systemName: isPenaltyRunning ? "timer" : "hourglass")
                    .foregroundStyle(Self.mutedRed)
                Text(penaltyTimer)
                    .foregroundStyle(Self.mutedRed)
            }

            if let used = selfUnlocksUsed, let budget = selfUnlockBudget, budget > 0 {
                let remaining = max(0, budget - used)
                if penaltyTimer != nil {
                    Text("\u{00B7}")
                        .foregroundStyle(.secondary)
                }
                Text("\(remaining)/\(budget) SU")
                    .foregroundStyle(Self.mutedTeal)
            }

            // Online indicator from heartbeats
            if let lastSeen = latestHeartbeatAge {
                if penaltyTimer != nil || (selfUnlocksUsed != nil && selfUnlockBudget != nil) {
                    Text("\u{00B7}")
                        .foregroundStyle(.secondary)
                }
                if lastSeen < 30 {
                    HStack(spacing: 2) {
                        Circle().fill(Self.mutedGreen).frame(width: 5, height: 5)
                        Text("online")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 2) {
                        Circle().fill(Self.mutedRed).frame(width: 5, height: 5)
                        Text(formatAge(lastSeen))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption2.monospacedDigit())
    }

    /// Seconds since latest heartbeat, preferring iPhone over iPad.
    /// The `devices` array is pre-sorted with iPhones first by the view model.
    private var latestHeartbeatAge: TimeInterval? {
        // Prefer the first device's (iPhone if available) heartbeat.
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }) {
                return Date().timeIntervalSince(hb.timestamp)
            }
        }
        return nil
    }

    private func formatAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }

    // MARK: - Pill Button

    @ViewBuilder
    private var pillButton: some View {
        if isUnlocked {
            // Show "Lock" button with extend options
            Menu {
                if let remaining = remainingSeconds, remaining > 0 {
                    Button { onUnlock(remaining + 15 * 60) } label: {
                        Label("+15 minutes", systemImage: "plus.circle")
                    }
                    Button { onUnlock(remaining + 30 * 60) } label: {
                        Label("+30 minutes", systemImage: "plus.circle")
                    }
                    Button { onUnlock(remaining + 3600) } label: {
                        Label("+1 hour", systemImage: "plus.circle")
                    }
                    Divider()
                }
                Button { onLock(.indefinite) } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                Button { onLock(.returnToSchedule) } label: {
                    Label("Return to Schedule", systemImage: "calendar.badge.clock")
                }
            } label: {
                pillLabel("Lock", icon: "lock.fill")
            } primaryAction: {
                onLock(.indefinite)
            }
        } else {
            // Show "Unlock" button
            Menu {
                if let remaining = remainingSeconds, remaining > 0 {
                    Button { onUnlock(remaining + 15 * 60) } label: {
                        Label("+15 minutes", systemImage: "plus.circle")
                    }
                    Divider()
                }
                Button { onUnlock(15 * 60) } label: { Label("15 minutes", systemImage: "clock") }
                Button { onUnlock(1 * 3600) } label: { Label("1 hour", systemImage: "clock") }
                Button { onUnlock(5400) } label: { Label("1.5 hours", systemImage: "clock") }
                Button { onUnlock(2 * 3600) } label: { Label("2 hours", systemImage: "clock") }
                Divider()
                Button { onUnlock(Self.secondsUntilMidnight) } label: { Label("Until midnight", systemImage: "moon.fill") }
                Button { onUnlock(24 * 3600) } label: { Label("24 hours", systemImage: "clock.badge.checkmark") }
                if let onUnlockWithTimer {
                    Divider()
                    Button { onUnlockWithTimer(1 * 3600) } label: { Label("1 hour + timer", systemImage: "timer") }
                    Button { onUnlockWithTimer(2 * 3600) } label: { Label("2 hours + timer", systemImage: "timer") }
                }
                Divider()
                Button { onLock(.returnToSchedule) } label: {
                    Label("Return to Schedule", systemImage: "calendar.badge.clock")
                }
            } label: {
                pillLabel("Unlock", icon: "lock.open.fill")
            } primaryAction: {
                if let remaining = remainingSeconds, remaining > 0 {
                    onUnlock(remaining + 15 * 60)
                } else {
                    onUnlock(15 * 60)
                }
            }
        }
    }

    @ViewBuilder
    private func pillLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
        .clipShape(Capsule())
    }

    // MARK: - Helpers

    private var isUnlocked: Bool {
        dominantMode == .unlocked
    }

    /// True if ANY of this child's devices is running an older build than current.
    private var isOnOldBuild: Bool {
        let deviceIDs = Set(devices.map(\.id))
        let builds = heartbeats
            .filter { deviceIDs.contains($0.deviceID) }
            .compactMap(\.appBuildNumber)
        guard !builds.isEmpty else { return false }
        // Worst case: if any device is old, show the indicator.
        return builds.min()! < AppConstants.appBuildNumber
    }

    /// Vivid color — used only for avatar glow.
    private var modeColor: Color {
        switch dominantMode {
        case .unlocked: return .green
        case .dailyMode: return .blue
        case .essentialOnly: return .purple
        }
    }

    /// Muted color — used for text, pill buttons, left border.
    private var mutedModeColor: Color {
        switch dominantMode {
        case .unlocked: return Color(.systemGreen).opacity(0.7)
        case .dailyMode: return Color(.systemBlue).opacity(0.7)
        case .essentialOnly: return Color(.systemPurple).opacity(0.7)
        }
    }

    private static let mutedGreen = Color(.systemGreen).opacity(0.7)
    private static let mutedBlue = Color(.systemBlue).opacity(0.7)
    private static let mutedPurple = Color(.systemPurple).opacity(0.7)
    private static let mutedOrange = Color(.systemOrange).opacity(0.7)
    private static let mutedTeal = Color(.systemTeal).opacity(0.7)
    private static let mutedRed = Color(red: 1.0, green: 0.45, blue: 0.4).opacity(0.8)

    static var secondsUntilMidnight: Int {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        return max(60, Int(midnight.timeIntervalSince(now)))
    }
}

// MARK: - Color from Hex

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
