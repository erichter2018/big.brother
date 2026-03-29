import SwiftUI
import BigBrotherCore

struct ModeBadge: View {
    let mode: LockMode
    var isTemporaryUnlock: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption2)
            Text(isTemporaryUnlock ? "Temp Unlock" : mode.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor.opacity(0.15))
        .foregroundStyle(backgroundColor)
        .clipShape(Capsule())
    }

    private var iconName: String {
        if isTemporaryUnlock { return "clock.badge.checkmark" }
        switch mode {
        case .unlocked: return "lock.open"
        case .dailyMode: return "calendar"
        case .essentialOnly: return "shield"
        case .lockedDown: return "wifi.slash"
        }
    }

    private var backgroundColor: Color {
        if isTemporaryUnlock { return .orange }
        switch mode {
        case .unlocked: return .green
        case .dailyMode: return .blue
        case .essentialOnly: return .purple
        case .lockedDown: return .red
        }
    }
}
