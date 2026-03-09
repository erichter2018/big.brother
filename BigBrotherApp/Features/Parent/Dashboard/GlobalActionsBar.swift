import SwiftUI

/// Quick global actions for all devices.
struct GlobalActionsBar: View {
    let viewModel: ParentDashboardViewModel

    var body: some View {
        VStack(spacing: 8) {
            Text("Quick Actions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                actionButton(
                    title: "Lock All",
                    icon: "lock.fill",
                    color: .blue
                ) {
                    Task { await viewModel.lockAll() }
                }

                // Tap: unlock indefinitely. Long-press: time options.
                Menu {
                    Button {
                        Task { await viewModel.unlockAll(duration: .indefinite) }
                    } label: {
                        Label("Unlock (no limit)", systemImage: "lock.open")
                    }
                    Button {
                        Task { await viewModel.unlockAll(duration: .hours(1)) }
                    } label: {
                        Label("Unlock for 1 hour", systemImage: "clock")
                    }
                    Button {
                        Task { await viewModel.unlockAll(duration: .hours(2)) }
                    } label: {
                        Label("Unlock for 2 hours", systemImage: "clock")
                    }
                    Button {
                        Task { await viewModel.unlockAll(duration: .delayed) }
                    } label: {
                        Label("Delayed unlock...", systemImage: "clock.arrow.2.circlepath")
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "lock.open")
                            .font(.title3)
                        Text("Unlock All")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.12))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } primaryAction: {
                    Task { await viewModel.unlockAll(duration: .indefinite) }
                }

                actionButton(
                    title: "Essential",
                    icon: "shield",
                    color: .purple
                ) {
                    Task { await viewModel.essentialOnlyAll() }
                }
            }
            .disabled(viewModel.isSendingCommand)
            .opacity(viewModel.isSendingCommand ? 0.6 : 1)
        }
    }

    @ViewBuilder
    private func actionButton(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
