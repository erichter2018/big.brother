import SwiftUI
import BigBrotherCore

/// Reusable row of mode-change buttons used in child detail and device detail.
///
/// Unlock: tap = +15 min, long-press shows duration options.
/// Restrict: tap = indefinite, long-press shows duration + schedule options.
/// Lock: tap = lock, long-press shows lock down options.
struct ModeActionButtons: View {
    let onSetMode: (LockMode) -> Void
    let onTemporaryUnlock: (Int) -> Void
    var onLockWithDuration: ((LockDuration) -> Void)? = nil
    var onLockDown: ((Int?) -> Void)? = nil
    var disabled: Bool = false
    var remainingSeconds: Int? = nil

    var activeMode: LockMode? = nil
    var isTemporaryUnlock: Bool = false
    var isScheduleDriven: Bool = false
    var scheduleNextTransition: Date? = nil

    var body: some View {
        HStack(spacing: 8) {
            unlockButton
            restrictButton
            lockButton
        }
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
    }

    private var isUnlockActive: Bool { activeMode == .unlocked }
    private var isRestrictActive: Bool { activeMode == .restricted }
    private var isLockActive: Bool { activeMode == .locked || activeMode == .lockedDown }

    private func statusText(for mode: LockMode) -> String? {
        guard activeMode == mode || (mode == .locked && activeMode == .lockedDown) else { return nil }

        if isTemporaryUnlock, mode == .unlocked, let secs = remainingSeconds, secs > 0 {
            return formatDuration(secs)
        }

        if isScheduleDriven, let next = scheduleNextTransition {
            let secs = Int(next.timeIntervalSinceNow)
            if secs > 0 && secs < 86400 {
                return "until " + formatTime(next)
            }
        }

        switch mode {
        case .unlocked: return "Unlocked"
        case .restricted: return "Restricted"
        case .locked: return "Locked"
        case .lockedDown: return "Locked"
        }
    }

    // MARK: - Unlock Button

    private var unlockButton: some View {
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
            modeButtonLabel("Unlock", icon: "lock.open", color: .green,
                            isActive: isUnlockActive,
                            status: statusText(for: .unlocked))
        } primaryAction: {
            if let remaining = remainingSeconds, remaining > 0 {
                onTemporaryUnlock(remaining + 15 * 60)
            } else {
                onTemporaryUnlock(15 * 60)
            }
        }
    }

    // MARK: - Restrict Button

    private var restrictButton: some View {
        Group {
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
                    modeButtonLabel("Restrict", icon: "lock.fill", color: .blue,
                                    isActive: isRestrictActive,
                                    status: statusText(for: .restricted))
                } primaryAction: {
                    onLockWithDuration(.indefinite)
                }
            } else {
                Button { onSetMode(.restricted) } label: {
                    modeButtonLabel("Restrict", icon: "lock.fill", color: .blue,
                                    isActive: isRestrictActive,
                                    status: statusText(for: .restricted))
                }
            }
        }
    }

    // MARK: - Lock Button

    private var lockButton: some View {
        Group {
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
                    modeButtonLabel("Lock", icon: "shield", color: .purple,
                                    isActive: isLockActive,
                                    status: statusText(for: .locked))
                } primaryAction: {
                    onSetMode(.locked)
                }
            } else {
                Button { onSetMode(.locked) } label: {
                    modeButtonLabel("Lock", icon: "shield", color: .purple,
                                    isActive: isLockActive,
                                    status: statusText(for: .locked))
                }
            }
        }
    }

    // MARK: - Button Label

    @ViewBuilder
    private func modeButtonLabel(_ title: String, icon: String, color: Color,
                                  isActive: Bool, status: String?) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.subheadline)
            Text(status ?? title)
                .font(.caption2)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .foregroundStyle(color)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: color)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color, lineWidth: isActive ? 2 : 0)
                .shadow(color: isActive ? color.opacity(0.6) : .clear, radius: 6)
        )
    }

    // MARK: - Formatting

    private func formatDuration(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }

    static var secondsUntilMidnight: Int { Date.secondsUntilMidnight }
}
