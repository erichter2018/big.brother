import SwiftUI
import BigBrotherCore

/// Detail view for a child profile — devices, mode controls, approved apps.
struct ChildDetailView: View {
    @Bindable var viewModel: ChildDetailViewModel
    @State private var showRevokeAllConfirmation = false
    @State private var deviceToRevokeAll: ChildDevice?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Mode action buttons
                ModeActionButtons(
                    onSetMode: { mode in Task { await viewModel.setMode(mode) } },
                    onTemporaryUnlock: { seconds in Task { await viewModel.temporaryUnlock(seconds: seconds) } },
                    onLockWithDuration: { duration in Task { await viewModel.lockWithDuration(duration) } },
                    disabled: viewModel.isSendingCommand,
                    remainingSeconds: viewModel.remainingUnlockSeconds
                )

                // Configure apps on child devices
                devicesConfigSection

                // Temporarily unlocked apps (from heartbeat)
                if !viewModel.temporaryAllowedAppsForChild.isEmpty {
                    temporaryAllowedAppsSection
                }

                // Approved Apps
                if !viewModel.approvedAppsForChild.isEmpty {
                    approvedAppsSection
                }

                // Self-Unlock Budget
                selfUnlockBudgetSection

                // Device Restrictions (works with both .individual and .child auth — confirmed on device)
                restrictionsSection

                // Feedback
                if let feedback = viewModel.commandFeedback {
                    CommandFeedbackBanner(
                        message: feedback,
                        isError: viewModel.isCommandError
                    )
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.5), value: viewModel.commandFeedback)
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
        .alert("Revoke All Allowed Apps", isPresented: $showRevokeAllConfirmation) {
            Button("Revoke All", role: .destructive) {
                Task { await viewModel.revokeAllApps() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will block all currently allowed apps on all of \(viewModel.child.name)'s devices. This cannot be undone.")
        }
        .alert(
            "Revoke All on Device",
            isPresented: Binding(
                get: { deviceToRevokeAll != nil },
                set: { if !$0 { deviceToRevokeAll = nil } }
            )
        ) {
            Button("Revoke All", role: .destructive) {
                if let device = deviceToRevokeAll {
                    Task { await viewModel.revokeAllApps(for: device) }
                }
                deviceToRevokeAll = nil
            }
            Button("Cancel", role: .cancel) { deviceToRevokeAll = nil }
        } message: {
            Text("This will block all currently allowed apps on \(deviceToRevokeAll?.displayName ?? "this device"). This cannot be undone.")
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.loadEvents()
            viewModel.startAutoRefresh()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
        }
    }

    @ViewBuilder
    private var devicesConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices")
                .font(.subheadline)
                .fontWeight(.semibold)

            if viewModel.devices.isEmpty {
                Text("No devices enrolled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.devices) { device in
                    let hb = viewModel.heartbeat(for: device)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            DeviceIcon(modelIdentifier: device.modelIdentifier, size: .title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(DeviceIcon.displayName(for: device.modelIdentifier))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Text("iOS \(device.osVersion)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    if let battery = hb?.batteryLevel {
                                        HStack(spacing: 2) {
                                            Image(systemName: hb?.isCharging == true ? "battery.100.bolt" : "battery.50")
                                                .font(.caption2)
                                            Text("\(Int(battery * 100))%")
                                                .font(.caption2)
                                        }
                                        .foregroundStyle(battery < 0.2 ? .red : .secondary)
                                    }
                                    if let disk = hb?.availableDiskSpace {
                                        HStack(spacing: 2) {
                                            Image(systemName: "internaldrive")
                                                .font(.caption2)
                                            Text(Self.formatDisk(available: disk, total: hb?.totalDiskSpace))
                                                .font(.caption2)
                                        }
                                        .foregroundStyle(disk < 1_000_000_000 ? .red : .secondary)
                                    }
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let mode = device.confirmedMode {
                                    ModeBadge(mode: mode)
                                }
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(device.isOnline ? Color.green : Color.red.opacity(0.6))
                                        .frame(width: 6, height: 6)
                                    Text(device.isOnline ? "Online" : "Offline")
                                        .font(.caption2)
                                        .foregroundStyle(device.isOnline ? .green : .red)
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Button {
                                Task { await viewModel.requestAlwaysAllowedSetup(for: device) }
                            } label: {
                                Label("Always Allowed", systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                            .controlSize(.small)

                            Button {
                                deviceToRevokeAll = device
                            } label: {
                                Label("Revoke All", systemImage: "xmark.circle")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    @ViewBuilder
    private var temporaryAllowedAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Temporarily Unlocked", systemImage: "clock.badge.checkmark")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)

            ForEach(viewModel.temporaryAllowedAppsForChild, id: \.self) { appName in
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.orange)
                    Text(appName)
                        .font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var selfUnlockBudgetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Self Unlocks", systemImage: "lock.open.rotation")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack {
                Text("Daily budget")
                    .font(.caption)
                Spacer()
                Stepper(
                    "\(viewModel.selfUnlockBudget)",
                    value: Binding(
                        get: { viewModel.selfUnlockBudget },
                        set: { viewModel.selfUnlockBudget = $0 }
                    ),
                    in: 0...10,
                    step: 1
                )
                .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let used = viewModel.selfUnlocksUsedToday, viewModel.selfUnlockBudget > 0 {
                Text("Used today: \(used) of \(viewModel.selfUnlockBudget)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Each self-unlock gives 15 minutes. Resets at midnight.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var restrictionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Device Restrictions", systemImage: "lock.shield")
                .font(.subheadline)
                .fontWeight(.semibold)

            restrictionToggle(
                "Prevent App Deletion",
                icon: "trash.slash",
                isOn: viewModel.restrictions.denyAppRemoval,
                toggle: { viewModel.toggleRestriction(\.denyAppRemoval) }
            )
            restrictionToggle(
                "Block Explicit Content",
                icon: "eye.slash",
                isOn: viewModel.restrictions.denyExplicitContent,
                toggle: { viewModel.toggleRestriction(\.denyExplicitContent) }
            )
            restrictionToggle(
                "Lock Accounts",
                icon: "person.crop.circle.badge.xmark",
                isOn: viewModel.restrictions.lockAccounts,
                toggle: { viewModel.toggleRestriction(\.lockAccounts) }
            )
            restrictionToggle(
                "Force Automatic Date & Time",
                icon: "clock.arrow.circlepath",
                isOn: viewModel.restrictions.requireAutomaticDateAndTime,
                toggle: { viewModel.toggleRestriction(\.requireAutomaticDateAndTime) }
            )
        }
    }

    @ViewBuilder
    private func restrictionToggle(_ title: String, icon: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.caption)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var approvedAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Allowed Apps", systemImage: "checkmark.shield")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
                Spacer()
                Button {
                    showRevokeAllConfirmation = true
                } label: {
                    Text("Revoke All")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.mini)
            }

            ForEach(viewModel.approvedAppsForChild) { app in
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
    }

    // MARK: - Helpers

    private static func formatDisk(available: Int64, total: Int64?) -> String {
        let gb = Double(available) / 1_000_000_000
        let sizeStr = gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
        if let total, total > 0 {
            let pct = Int(Double(available) / Double(total) * 100)
            return "\(sizeStr) (\(pct)%)"
        }
        return sizeStr
    }
}
