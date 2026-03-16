import SwiftUI
import BigBrotherCore

/// Compact child card for the parent dashboard.
/// Avatar + name on left, mode + countdown center, action icons right.
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
    let isScheduleActive: Bool
    let scheduleLabel: String?
    let onLock: (LockDuration) -> Void
    let onUnlock: (Int) -> Void
    let onUnlockWithTimer: ((Int) -> Void)?
    let onSchedule: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            avatar

            // Name + mode
            VStack(alignment: .leading, spacing: 2) {
                Text(child.name)
                    .font(.headline)
                    .lineLimit(1)

                if let countdown {
                    // Unlocked with countdown — show on one line
                    HStack(spacing: 4) {
                        let label = (isScheduleActive && dominantMode == .unlocked) ? "Self-unlocked" : dominantMode.displayName
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(countdown)
                            .font(.caption.monospacedDigit())
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                    }
                } else if let scheduleLabel, isScheduleActive {
                    Text(scheduleLabel)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text(dominantMode.displayName)
                        .font(.caption)
                        .foregroundStyle(modeColor)
                }

                HStack(spacing: 8) {
                    if let penaltyTimer {
                        Label(penaltyTimer, systemImage: isPenaltyRunning ? "timer" : "hourglass")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.red)
                    }

                    if let used = selfUnlocksUsed, let budget = selfUnlockBudget, budget > 0 {
                        let remaining = max(0, budget - used)
                        Label("\(remaining)/\(budget) SU", systemImage: "lock.open.rotation")
                            .font(.caption2)
                            .foregroundStyle(.teal)
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                unlockButton
                lockButton
                scheduleButton(action: onSchedule)
            }
            .disabled(isSending)
            .opacity(isSending ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatar: some View {
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
        let index = abs(child.name.hashValue) % colors.count
        let pair = colors[index]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var unlockButton: some View {
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
            Button { onUnlock(24 * 3600) } label: { Label("24 hours", systemImage: "clock.badge.checkmark") }
            if let onUnlockWithTimer {
                Divider()
                Button { onUnlockWithTimer(1 * 3600) } label: { Label("1 hour + timer", systemImage: "timer") }
                Button { onUnlockWithTimer(2 * 3600) } label: { Label("2 hours + timer", systemImage: "timer") }
            }
        } label: {
            actionIconLabel("lock.open.fill", color: .green, active: isUnlocked)
        } primaryAction: {
            onUnlock(15 * 60)
        }
    }

    private var isUnlocked: Bool {
        dominantMode == .unlocked && !isScheduleActive
    }

    private var isLocked: Bool {
        (dominantMode == .dailyMode || dominantMode == .essentialOnly) && !isScheduleActive
    }

    @ViewBuilder
    private var lockButton: some View {
        Menu {
            Button { onLock(.returnToSchedule) } label: {
                Label("Return to Schedule", systemImage: "calendar.badge.clock")
            }
            Divider()
            Button { onLock(.untilMidnight) } label: {
                Label("Until Midnight", systemImage: "moon.fill")
            }
            Button { onLock(.indefinite) } label: {
                Label("Indefinite", systemImage: "lock.fill")
            }
            Divider()
            Button { onLock(.hours(1)) } label: {
                Label("1 hour", systemImage: "clock")
            }
            Button { onLock(.hours(2)) } label: {
                Label("2 hours", systemImage: "clock")
            }
            Button { onLock(.hours(4)) } label: {
                Label("4 hours", systemImage: "clock")
            }
        } label: {
            actionIconLabel("lock.fill", color: .blue, active: isLocked)
        } primaryAction: {
            onLock(.untilMidnight)
        }
    }

    @ViewBuilder
    private func scheduleButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "calendar.badge.clock")
                .font(.body)
                .frame(width: 40, height: 40)
                .background(Color.orange.opacity(isScheduleActive ? 0.3 : 0.15))
                .foregroundStyle(.orange)
                .clipShape(Circle())
                .shadow(color: isScheduleActive ? Color.orange.opacity(0.6) : .clear, radius: 8)
        }
    }

    @ViewBuilder
    private func actionIcon(_ icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionIconLabel(icon, color: color)
        }
    }

    @ViewBuilder
    private func actionIconLabel(_ icon: String, color: Color, active: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.body)
            .frame(width: 40, height: 40)
            .background(color.opacity(active ? 0.3 : 0.15))
            .foregroundStyle(color)
            .clipShape(Circle())
            .shadow(color: active ? color.opacity(0.6) : .clear, radius: 8)
    }

    // MARK: - Styling

    private var modeColor: Color {
        switch dominantMode {
        case .unlocked: return .green
        case .dailyMode: return .blue
        case .essentialOnly: return .purple
        }
    }

    private var cardBackground: some ShapeStyle {
        .regularMaterial
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
