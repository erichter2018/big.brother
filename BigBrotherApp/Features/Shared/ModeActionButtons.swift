import SwiftUI
import BigBrotherCore

/// Reusable row of mode-change buttons used in child detail and device detail.
///
/// Unlock is a Menu: tap = 24h, long-press shows 1h / 1.5h / 2h / 24h / delayed.
struct ModeActionButtons: View {
    let onSetMode: (LockMode) -> Void
    let onTemporaryUnlock: (Int) -> Void  // duration in seconds
    var disabled: Bool = false
    var remainingSeconds: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            // Unlock: tap = 24h, long-press = duration menu
            Menu {
                if let remaining = remainingSeconds, remaining > 0 {
                    Button { onTemporaryUnlock(remaining + 15 * 60) } label: {
                        Label("+15 minutes", systemImage: "plus.circle")
                    }
                    Divider()
                }
                Button { onTemporaryUnlock(15 * 60) } label: {
                    Label("15 minutes", systemImage: "clock")
                }
                Button { onTemporaryUnlock(1 * 3600) } label: {
                    Label("1 hour", systemImage: "clock")
                }
                Button { onTemporaryUnlock(5400) } label: {
                    Label("1.5 hours", systemImage: "clock")
                }
                Button { onTemporaryUnlock(2 * 3600) } label: {
                    Label("2 hours", systemImage: "clock")
                }
                Divider()
                Button { onTemporaryUnlock(24 * 3600) } label: {
                    Label("24 hours", systemImage: "clock.badge.checkmark")
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "lock.open").font(.subheadline)
                    Text("Unlock").font(.caption2).fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.12))
                .foregroundStyle(.green)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } primaryAction: {
                onTemporaryUnlock(15 * 60)
            }

            modeButton("Lock", icon: "lock.fill", color: .blue, mode: .dailyMode)
            modeButton("Essential", icon: "shield", color: .purple, mode: .essentialOnly)
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
