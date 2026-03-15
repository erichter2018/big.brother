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
    let onLock: () -> Void
    let onUnlock: (Int) -> Void
    let onEssential: () -> Void

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
                    Text(countdown)
                        .font(.caption.monospacedDigit())
                        .fontWeight(.bold)
                        .foregroundStyle(.orange)
                } else {
                    Text(dominantMode.displayName)
                        .font(.caption)
                        .foregroundStyle(modeColor)
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                unlockButton
                actionIcon("lock.fill", color: .blue, action: onLock)
                actionIcon("shield.fill", color: .purple, action: onEssential)
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
        let initials = String(child.name.prefix(1)).uppercased()
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: 48, height: 48)
            Text(initials)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
    }

    private var avatarGradient: LinearGradient {
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
        } label: {
            actionIconLabel("lock.open.fill", color: .green)
        } primaryAction: {
            onUnlock(15 * 60)
        }
    }

    @ViewBuilder
    private func actionIcon(_ icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionIconLabel(icon, color: color)
        }
    }

    @ViewBuilder
    private func actionIconLabel(_ icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.body)
            .frame(width: 40, height: 40)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Circle())
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
