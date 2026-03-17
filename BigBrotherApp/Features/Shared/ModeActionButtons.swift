import SwiftUI
import BigBrotherCore

/// Reusable row of mode-change buttons used in child detail and device detail.
///
/// Unlock is a Menu: tap = 24h, long-press shows 1h / 1.5h / 2h / 24h / delayed.
/// Lock is a Menu: tap = until midnight, long-press shows duration options.
struct ModeActionButtons: View {
    let onSetMode: (LockMode) -> Void
    let onTemporaryUnlock: (Int) -> Void  // duration in seconds
    var onLockWithDuration: ((LockDuration) -> Void)? = nil
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
                Button { onTemporaryUnlock(Self.secondsUntilMidnight) } label: {
                    Label("Until midnight", systemImage: "moon.fill")
                }
                Button { onTemporaryUnlock(24 * 3600) } label: {
                    Label("24 hours", systemImage: "clock.badge.checkmark")
                }
                Divider()
                Button { onTemporaryUnlock(7 * 24 * 3600) } label: {
                    Label("Indefinitely", systemImage: "infinity")
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
                if let remaining = remainingSeconds, remaining > 0 {
                    onTemporaryUnlock(remaining + 15 * 60)
                } else {
                    onTemporaryUnlock(15 * 60)
                }
            }

            // Lock: tap = until midnight, long-press = duration menu
            if let onLockWithDuration {
                Menu {
                    Button { onLockWithDuration(.returnToSchedule) } label: {
                        Label("Return to Schedule", systemImage: "calendar.badge.clock")
                    }
                    Divider()
                    Button { onLockWithDuration(.untilMidnight) } label: {
                        Label("Until Midnight", systemImage: "moon.fill")
                    }
                    Button { onLockWithDuration(.indefinite) } label: {
                        Label("Indefinite", systemImage: "lock.fill")
                    }
                    Divider()
                    Button { onLockWithDuration(.hours(1)) } label: {
                        Label("1 hour", systemImage: "clock")
                    }
                    Button { onLockWithDuration(.hours(2)) } label: {
                        Label("2 hours", systemImage: "clock")
                    }
                    Button { onLockWithDuration(.hours(4)) } label: {
                        Label("4 hours", systemImage: "clock")
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "lock.fill").font(.subheadline)
                        Text("Lock").font(.caption2).fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } primaryAction: {
                    onLockWithDuration(.untilMidnight)
                }
            } else {
                modeButton("Lock", icon: "lock.fill", color: .blue, mode: .dailyMode)
            }
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

    static var secondsUntilMidnight: Int {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        return max(60, Int(midnight.timeIntervalSince(now)))
    }
}
