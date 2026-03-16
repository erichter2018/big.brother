import SwiftUI

/// Quick global actions for all devices — Lock All and Unlock All.
struct GlobalActionsBar: View {
    let viewModel: ParentDashboardViewModel
    /// Minimum remaining seconds across all children with active countdowns.
    private var minRemaining: Int? {
        let values = viewModel.childProfiles.compactMap { viewModel.remainingSeconds(for: $0) }
        return values.min()
    }

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        let layout = isIPad
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 8))

        layout {
            // Lock All (tap = until midnight, menu = duration options)
            Menu {
                Button { Task { await viewModel.lockAll(duration: .returnToSchedule) } } label: {
                    Label("Return to Schedule", systemImage: "calendar.badge.clock")
                }
                Divider()
                Button { Task { await viewModel.lockAll(duration: .untilMidnight) } } label: {
                    Label("Until Midnight", systemImage: "moon.fill")
                }
                Button { Task { await viewModel.lockAll(duration: .indefinite) } } label: {
                    Label("Indefinite", systemImage: "lock.fill")
                }
                Divider()
                Button { Task { await viewModel.lockAll(duration: .hours(1)) } } label: {
                    Label("1 hour", systemImage: "clock")
                }
                Button { Task { await viewModel.lockAll(duration: .hours(2)) } } label: {
                    Label("2 hours", systemImage: "clock")
                }
                Button { Task { await viewModel.lockAll(duration: .hours(4)) } } label: {
                    Label("4 hours", systemImage: "clock")
                }
            } label: {
                Label("Lock All", systemImage: "lock.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } primaryAction: {
                Task { await viewModel.lockAll(duration: .untilMidnight) }
            }

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
                Label("Unlock All", systemImage: "lock.open")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.green.opacity(0.12))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } primaryAction: {
                Task { await viewModel.unlockAll(seconds: 15 * 60) }
            }

            // Schedule All
            Button {
                Task { await viewModel.scheduleAll() }
            } label: {
                Label("Schedule", systemImage: "calendar.badge.clock")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.orange.opacity(0.12))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .disabled(viewModel.isSendingCommand)
        .opacity(viewModel.isSendingCommand ? 0.6 : 1)
    }
}
