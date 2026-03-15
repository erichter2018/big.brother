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

                // Feedback
                if let feedback = viewModel.commandFeedback {
                    CommandFeedbackBanner(
                        message: feedback,
                        isError: viewModel.isCommandError
                    )
                }

                // Heartbeat info
                heartbeatSection

                // Schedule profile
                scheduleProfileSection

                // Monitoring profile
                monitoringProfileSection

                // Approved apps
                if !viewModel.approvedAppsForDevice.isEmpty && viewModel.managedApps.isEmpty {
                    approvedAppsSection
                }

                // App blocking (summary + request button)
                appBlockingSection

                // Authorization health
                authorizationSection

                // Danger zone
                deviceManagementSection
            }
            .padding()
        }
        .navigationTitle(viewModel.device.displayName)
        .refreshable {
            await viewModel.refresh()
        }
        .alert("Remove Device", isPresented: $showDeleteConfirmation) {
            Button("Unenroll & Delete", role: .destructive) {
                Task {
                    await viewModel.unenrollAndDeleteDevice()
                    dismiss()
                }
            }
            Button("Delete Record Only", role: .destructive) {
                Task {
                    await viewModel.deleteDevice()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Unenroll sends a command to clear the device's local restrictions first. Delete Record Only removes it from your dashboard without notifying the device.")
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

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
                onTemporaryUnlock: { seconds in Task { await viewModel.temporaryUnlock(seconds: seconds) } },
                disabled: viewModel.isSendingCommand
            )

            Button {
                Task { await viewModel.requestHeartbeat() }
            } label: {
                Label("Ping", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .disabled(viewModel.isSendingCommand)
    }

    @ViewBuilder
    private var scheduleProfileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Schedule Profile").font(.subheadline).fontWeight(.semibold)

            let profiles = viewModel.appState.scheduleProfiles
            let selectedID = viewModel.device.scheduleProfileID

            Picker("Schedule", selection: Binding<UUID?>(
                get: { selectedID },
                set: { newID in Task { await viewModel.assignScheduleProfile(newID) } }
            )) {
                Text("None (manual only)").tag(UUID?.none)
                ForEach(profiles) { profile in
                    Text(profile.name).tag(UUID?.some(profile.id))
                }
            }
            .pickerStyle(.menu)

            if let profileID = selectedID,
               let profile = profiles.first(where: { $0.id == profileID }) {
                HStack(spacing: 12) {
                    Label("\(profile.freeWindows.count) free window\(profile.freeWindows.count == 1 ? "" : "s")",
                          systemImage: "clock")
                    Label("Locked: \(profile.lockedMode.displayName)", systemImage: "lock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Device mode is controlled manually via commands only.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var monitoringProfileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Monitoring Profile").font(.subheadline).fontWeight(.semibold)

            let profiles = viewModel.appState.heartbeatProfiles
            let selectedID = viewModel.device.heartbeatProfileID

            Picker("Profile", selection: Binding<UUID?>(
                get: { selectedID },
                set: { newID in Task { await viewModel.assignProfile(newID) } }
            )) {
                Text("None").tag(UUID?.none)
                ForEach(profiles) { profile in
                    Text(profile.name).tag(UUID?.some(profile.id))
                }
            }
            .pickerStyle(.menu)

            if let profileID = selectedID,
               let profile = profiles.first(where: { $0.id == profileID }) {
                HStack(spacing: 12) {
                    Label("\(profile.activeWindows.count) window\(profile.activeWindows.count == 1 ? "" : "s")",
                          systemImage: "clock")
                    Label(formatGap(profile.maxHeartbeatGap), systemImage: "timer")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Uses default profile or built-in fallback.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatGap(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m gap" }
        if hours > 0 { return "\(hours)h gap" }
        return "\(minutes)m gap"
    }

    @ViewBuilder
    private var approvedAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allowed Apps", systemImage: "checkmark.shield")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.green)

            ForEach(viewModel.approvedAppsForDevice) { app in
                HStack {
                    Image(systemName: "app.badge.checkmark")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.appName)
                            .font(.caption)
                        Text("Approved \(app.approvedAt, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await viewModel.revokeApp(app) }
                    } label: {
                        Label("Revoke", systemImage: "xmark.circle")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.green.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var appBlockingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App Blocking").font(.subheadline).fontWeight(.semibold)

            if let hb = viewModel.heartbeat, hb.appBlockingConfigured == true {
                HStack {
                    infoRow("Status", Text("Configured").foregroundStyle(.green))
                }

                HStack(spacing: 16) {
                    if let apps = hb.blockedAppCount, apps > 0 {
                        Label("\(apps) apps", systemImage: "app.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let cats = hb.blockedCategoryCount, cats > 0 {
                        Label("\(cats) categories", systemImage: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                infoRow("Status", Text("Not configured").foregroundStyle(.secondary))
            }

            if !viewModel.managedApps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Discovered Apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("These apps are learned automatically as the child opens blocked apps. You can allow or block them individually once discovered.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    ForEach(viewModel.managedApps) { app in
                        managedAppRow(app)
                    }
                }
            } else if viewModel.heartbeat?.appBlockingConfigured == true {
                Text("Waiting for named apps from the child's latest heartbeat. After the child saves the picker, tap Ping or pull to refresh.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task { await viewModel.requestAppConfiguration() }
            } label: {
                Label("Configure Managed Apps", systemImage: "app.badge")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(viewModel.isSendingCommand)

            Text("Opens the app picker on the child's device. Once the selection is saved, you can allow or block individual apps from this screen.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func managedAppRow(_ app: ManagedAppControl) -> some View {
        HStack(spacing: 10) {
            Image(systemName: app.isAllowed ? "checkmark.circle.fill" : "shield.fill")
                .foregroundStyle(app.isAllowed ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.caption)
                Text(app.isAllowed ? "Currently allowed" : "Currently blocked")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    if app.isAllowed {
                        await viewModel.blockManagedApp(named: app.appName)
                    } else {
                        await viewModel.allowManagedApp(named: app.appName)
                    }
                }
            } label: {
                Label(app.isAllowed ? "Block" : "Allow",
                      systemImage: app.isAllowed ? "xmark.circle" : "checkmark.circle")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .tint(app.isAllowed ? .red : .green)
            .controlSize(.small)
            .disabled(viewModel.isSendingCommand)
        }
        .padding(8)
        .background((app.isAllowed ? Color.green : Color.orange).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
    private var deviceManagementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Device Management").font(.subheadline).fontWeight(.semibold)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Remove Device", systemImage: "trash")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
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
