import SwiftUI
import BigBrotherCore

/// Detail view for a child profile — shows devices, actions, events.
struct ChildDetailView: View {
    @Bindable var viewModel: ChildDetailViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Child Action Panel
                childActionPanel

                // Devices
                devicesSection

                // Always Allowed Summary
                if let tokensData = viewModel.child.alwaysAllowedTokensData, !tokensData.isEmpty {
                    infoRow(icon: "app.badge.checkmark", title: "Always Allowed Apps", value: "Configured")
                } else {
                    infoRow(icon: "app.badge.checkmark", title: "Always Allowed Apps", value: "Not configured")
                }

                // Recent Events
                if !viewModel.recentEvents.isEmpty {
                    recentEventsSection
                }

                // Feedback
                if let feedback = viewModel.commandFeedback {
                    CommandFeedbackBanner(
                        message: feedback,
                        isError: viewModel.isCommandError
                    )
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.child.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    EnrollmentCodeView(
                        appState: viewModel.appState,
                        childProfile: viewModel.child
                    )
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.loadEvents()
        }
    }

    @ViewBuilder
    private var childActionPanel: some View {
        VStack(spacing: 8) {
            Text("Set Mode")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ModeActionButtons(
                onSetMode: { mode in Task { await viewModel.setMode(mode) } },
                disabled: viewModel.isSendingCommand
            )

            Button {
                Task { await viewModel.temporaryUnlock() }
            } label: {
                Label("Temporary Unlock (15 min)", systemImage: "clock.badge.checkmark")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(viewModel.isSendingCommand)
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices")
                .font(.subheadline)
                .fontWeight(.semibold)

            if viewModel.devices.isEmpty {
                Text("No devices enrolled for this child.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.devices) { device in
                    NavigationLink {
                        DeviceDetailView(
                            viewModel: DeviceDetailViewModel(
                                appState: viewModel.appState,
                                device: device
                            )
                        )
                    } label: {
                        deviceRow(device)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: ChildDevice) -> some View {
        HStack {
            DeviceIcon(modelIdentifier: device.modelIdentifier)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.subheadline)
                Text(device.osVersion).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let mode = device.confirmedMode {
                ModeBadge(mode: mode)
            }
            if device.isOnline {
                StatusBadge.online()
            } else {
                StatusBadge.offline()
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var recentEventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Events (24h)")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(viewModel.recentEvents.prefix(10)) { event in
                HStack {
                    Text(event.eventType.displayName)
                        .font(.caption)
                    Spacer()
                    Text(event.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
