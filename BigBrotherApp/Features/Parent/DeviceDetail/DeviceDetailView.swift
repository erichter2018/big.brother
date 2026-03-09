import SwiftUI
import BigBrotherCore

/// Device detail screen with real backend state.
struct DeviceDetailView: View {
    @Bindable var viewModel: DeviceDetailViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Device info header
                deviceInfoSection

                // Mode actions
                modeActionsSection

                // Heartbeat info
                heartbeatSection

                // Authorization health
                authorizationSection

                // Feedback
                if let feedback = viewModel.commandFeedback {
                    CommandFeedbackBanner(
                        message: feedback,
                        isError: viewModel.isCommandError
                    )
                }

                // Diagnostics link
                NavigationLink {
                    DiagnosticsView(viewModel: DiagnosticsViewModel(appState: viewModel.appState))
                } label: {
                    Label("View Diagnostics", systemImage: "stethoscope")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle(viewModel.device.displayName)
        .refreshable {
            await viewModel.refresh()
        }
    }

    @ViewBuilder
    private var deviceInfoSection: some View {
        VStack(spacing: 10) {
            DeviceIcon.large(for: viewModel.device.modelIdentifier)
                .foregroundStyle(.blue)

            Text(viewModel.device.displayName)
                .font(.title3)
                .fontWeight(.semibold)

            HStack(spacing: 12) {
                if let mode = viewModel.device.confirmedMode {
                    ModeBadge(mode: mode)
                }
                if viewModel.device.isOnline {
                    StatusBadge.online()
                } else {
                    StatusBadge.offline()
                }
            }

            Text("Model: \(viewModel.device.modelIdentifier) | iOS \(viewModel.device.osVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let version = viewModel.device.confirmedPolicyVersion {
                Text("Policy v\(version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var modeActionsSection: some View {
        VStack(spacing: 8) {
            Text("Device Actions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ModeActionButtons(
                onSetMode: { mode in Task { await viewModel.setMode(mode) } },
                disabled: viewModel.isSendingCommand
            )

            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.temporaryUnlock() }
                } label: {
                    Label("Temp Unlock", systemImage: "clock.badge.checkmark")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange)

                Button {
                    Task { await viewModel.requestHeartbeat() }
                } label: {
                    Label("Ping", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(viewModel.isSendingCommand)
    }

    @ViewBuilder
    private var heartbeatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heartbeat").font(.subheadline).fontWeight(.semibold)
            if let hb = viewModel.heartbeat {
                infoRow("Last seen", Text(hb.timestamp, style: .relative) + Text(" ago"))
                infoRow("Battery", Text(hb.batteryLevel.map { "\(Int($0 * 100))%" } ?? "Unknown"))
                infoRow("Charging", Text(hb.isCharging == true ? "Yes" : "No"))
            } else {
                Text("No heartbeat received yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var authorizationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Authorization").font(.subheadline).fontWeight(.semibold)
            infoRow("FamilyControls",
                     Text(viewModel.device.familyControlsAuthorized ? "Authorized" : "Not Authorized")
                        .foregroundStyle(viewModel.device.familyControlsAuthorized ? .green : .red))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: Text) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            value.font(.caption)
        }
    }
}
