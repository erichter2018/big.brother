import SwiftUI

/// Quick global actions for all devices — Lock All and Unlock All.
/// Glassmorphic capsule chip style.
struct GlobalActionsBar: View {
    let viewModel: ParentDashboardViewModel
    /// Minimum remaining seconds across all children with active countdowns.
    private var minRemaining: Int? {
        let values = viewModel.childProfiles.compactMap { viewModel.remainingSeconds(for: $0) }
        return values.min()
    }

    var body: some View {
        HStack(spacing: 8) {
            // Unlock All (tap = 15m, menu = duration options + extend)
            Menu {
                if let remaining = minRemaining, remaining > 0 {
                    Button {
                        Task { await viewModel.unlockAll(seconds: remaining + 15 * 60) }
                    } label: {
                        Label("+15 minutes", systemImage: "plus.circle")
                    }
                    Divider()
                }
                Button { Task { await viewModel.unlockAll(seconds: 15 * 60) } } label: {
                    Label("15 minutes", systemImage: "clock")
                }
                Button { Task { await viewModel.unlockAll(seconds: 1 * 3600) } } label: {
                    Label("1 hour", systemImage: "clock")
                }
                Button { Task { await viewModel.unlockAll(seconds: 5400) } } label: {
                    Label("1.5 hours", systemImage: "clock")
                }
                Button { Task { await viewModel.unlockAll(seconds: 2 * 3600) } } label: {
                    Label("2 hours", systemImage: "clock")
                }
                Divider()
                Button { Task { await viewModel.unlockAll(seconds: Self.secondsUntilMidnight) } } label: {
                    Label("Until midnight", systemImage: "moon.fill")
                }
                Button { Task { await viewModel.unlockAll(seconds: 24 * 3600) } } label: {
                    Label("24 hours", systemImage: "clock.badge.checkmark")
                }
                if viewModel.appState.timerService != nil {
                    Divider()
                    Button { Task { await viewModel.unlockAllWithTimer(seconds: 1 * 3600) } } label: {
                        Label("1 hour + timer", systemImage: "timer")
                    }
                    Button { Task { await viewModel.unlockAllWithTimer(seconds: 2 * 3600) } } label: {
                        Label("2 hours + timer", systemImage: "timer")
                    }
                }
            } label: {
                chipLabel("Unlock All", icon: "lock.open", color: Color(.systemGreen).opacity(0.7))
            } primaryAction: {
                if let remaining = minRemaining, remaining > 0 {
                    Task { await viewModel.unlockAll(seconds: remaining + 15 * 60) }
                } else {
                    Task { await viewModel.unlockAll(seconds: 15 * 60) }
                }
            }
            .accessibilityLabel("Unlock All Devices")
            .accessibilityHint("Unlocks all children's devices. Long press for more options.")

            // Lock All (tap = until midnight, menu = duration options)
            Menu {
                Button { Task { await viewModel.restrictAll(duration: .untilMidnight) } } label: {
                    Label("Until Midnight", systemImage: "moon.fill")
                }
                Button { Task { await viewModel.restrictAll(duration: .indefinite) } } label: {
                    Label("Until I unlock", systemImage: "lock.fill")
                }
                Divider()
                Button { Task { await viewModel.restrictAll(duration: .hours(1)) } } label: {
                    Label("1 hour", systemImage: "clock")
                }
                Button { Task { await viewModel.restrictAll(duration: .hours(2)) } } label: {
                    Label("2 hours", systemImage: "clock")
                }
                Button { Task { await viewModel.restrictAll(duration: .hours(4)) } } label: {
                    Label("4 hours", systemImage: "clock")
                }
                Divider()
                Button { Task { await viewModel.lockAll() } } label: {
                    Label("Lock All", systemImage: "shield.fill")
                }
                Divider()
                Button { Task { await viewModel.lockDownAll() } } label: {
                    Label("Lock Down All", systemImage: "wifi.slash")
                }
                Button { Task { await viewModel.lockDownAll(seconds: 900) } } label: {
                    Label("15 min Lock Down", systemImage: "wifi.slash")
                }
                Button { Task { await viewModel.lockDownAll(seconds: 1800) } } label: {
                    Label("30 min Lock Down", systemImage: "wifi.slash")
                }
                Button { Task { await viewModel.lockDownAll(seconds: 3600) } } label: {
                    Label("1 hour Lock Down", systemImage: "wifi.slash")
                }
            } label: {
                chipLabel("Restrict All", icon: "lock.fill", color: Color(.systemBlue).opacity(0.7))
            } primaryAction: {
                Task { await viewModel.restrictAll(duration: .untilMidnight) }
            }
            .accessibilityLabel("Restrict All Devices")
            .accessibilityHint("Restricts all children's devices. Long press for more options.")

            // Schedule All
            Button {
                Task { await viewModel.scheduleAll() }
            } label: {
                chipLabel("Schedule", icon: "calendar.badge.clock", color: Color(.systemOrange).opacity(0.7))
            }
            .accessibilityLabel("Return All Devices to Schedule")
        }
        .disabled(viewModel.isSendingCommand)
        .opacity(viewModel.isSendingCommand ? 0.6 : 1)
    }

    @ViewBuilder
    private func chipLabel(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(color)
            .if_iOS26GlassCapsule(fallbackMaterial: .ultraThinMaterial, borderColor: color)
    }

    static var secondsUntilMidnight: Int { Date.secondsUntilMidnight }
}
