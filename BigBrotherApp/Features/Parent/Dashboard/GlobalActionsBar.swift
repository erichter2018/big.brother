import SwiftUI

/// Quick global actions for all devices — Lock All and Unlock All.
struct GlobalActionsBar: View {
    let viewModel: ParentDashboardViewModel

    /// Minimum remaining seconds across all children with active countdowns.
    private var minRemaining: Int? {
        let values = viewModel.childProfiles.compactMap { viewModel.remainingSeconds(for: $0) }
        return values.min()
    }

    var body: some View {
        HStack(spacing: 10) {
            // Lock All
            Button {
                Task { await viewModel.lockAll() }
            } label: {
                Label("Lock All", systemImage: "lock.fill")
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
            } label: {
                Label("Unlock All", systemImage: "lock.open")
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.12))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } primaryAction: {
                Task { await viewModel.unlockAll(seconds: 15 * 60) }
            }
        }
        .disabled(viewModel.isSendingCommand)
        .opacity(viewModel.isSendingCommand ? 0.6 : 1)
    }
}
