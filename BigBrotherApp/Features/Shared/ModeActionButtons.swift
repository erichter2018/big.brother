import SwiftUI
import BigBrotherCore

/// Reusable row of mode-change buttons used in child detail and device detail.
struct ModeActionButtons: View {
    let onSetMode: (LockMode) -> Void
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            modeButton("Unlock", icon: "lock.open", color: .green, mode: .unlocked)
            modeButton("Lock", icon: "lock.fill", color: .blue, mode: .dailyMode)
            modeButton("Essential", icon: "shield", color: .purple, mode: .essentialOnly)
            modeButton("Disable", icon: "xmark.circle", color: .red, mode: .fullLockdown)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
    }

    @ViewBuilder
    private func modeButton(_ title: String, icon: String, color: Color, mode: LockMode) -> some View {
        Button { onSetMode(mode) } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.subheadline)
                Text(title).font(.caption2).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
