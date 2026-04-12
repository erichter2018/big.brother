import SwiftUI
import BigBrotherCore

/// Reusable row of mode-change buttons used in child detail and device detail.
///
/// Unlock: tap = +15 min, long-press shows duration options.
/// Restrict: tap = indefinite, long-press shows duration + schedule options.
/// Lock: tap = lock, long-press shows lock down options.
struct ModeActionButtons: View {
    let onSetMode: (LockMode) -> Void
    let onTemporaryUnlock: (Int) -> Void  // duration in seconds
    var onLockWithDuration: ((LockDuration) -> Void)? = nil
    var onLockDown: ((Int?) -> Void)? = nil
    var disabled: Bool = false
    var remainingSeconds: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            // Unlock: tap = +15 min, long-press = duration menu
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
                Button { onSetMode(.unlocked) } label: {
                    Label("Indefinite (until I restrict)", systemImage: "lock.open.fill")
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "lock.open").font(.subheadline)
                    Text("Unlock").font(.caption2).fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(.green)
                .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .green)
            } primaryAction: {
                if let remaining = remainingSeconds, remaining > 0 {
                    onTemporaryUnlock(remaining + 15 * 60)
                } else {
                    onTemporaryUnlock(15 * 60)
                }
            }

            // Restrict: tap = indefinite, long-press = duration + schedule
            if let onLockWithDuration {
                Menu {
                    Button { onLockWithDuration(.untilMidnight) } label: {
                        Label("Until midnight", systemImage: "moon.fill")
                    }
                    Button { onLockWithDuration(.indefinite) } label: {
                        Label("Until I unlock", systemImage: "lock.fill")
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
                    Divider()
                    Button { onLockWithDuration(.returnToSchedule) } label: {
                        Label("Return to Schedule", systemImage: "calendar.badge.clock")
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "lock.fill").font(.subheadline)
                        Text("Restrict").font(.caption2).fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(.blue)
                    .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .blue)
                } primaryAction: {
                    onLockWithDuration(.indefinite)
                }
            } else {
                modeButton("Restrict", icon: "lock.fill", color: .blue, mode: .restricted)
            }

            // Lock: tap = lock, long-press = lock down options
            if let onLockDown {
                Menu {
                    Button { onSetMode(.locked) } label: {
                        Label("Lock", systemImage: "shield.fill")
                    }
                    Divider()
                    Button { onLockDown(900) } label: {
                        Label("Lock Down 15 min", systemImage: "wifi.slash")
                    }
                    Menu {
                        Button { onLockDown(1800) } label: {
                            Label("30 minutes", systemImage: "wifi.slash")
                        }
                        Button { onLockDown(3600) } label: {
                            Label("1 hour", systemImage: "wifi.slash")
                        }
                        Divider()
                        Button { onLockDown(nil) } label: {
                            Label("Indefinite", systemImage: "wifi.slash")
                        }
                    } label: {
                        Label("Lock Down...", systemImage: "wifi.slash")
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "shield").font(.subheadline)
                        Text("Lock").font(.caption2).fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(.purple)
                    .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .purple)
                } primaryAction: {
                    onSetMode(.locked)
                }
            } else {
                modeButton("Lock", icon: "shield", color: .purple, mode: .locked)
            }
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
            .foregroundStyle(color)
            .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: color)
        }
    }

    static var secondsUntilMidnight: Int { Date.secondsUntilMidnight }
}
