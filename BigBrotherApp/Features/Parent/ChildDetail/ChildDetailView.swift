import SwiftUI
import BigBrotherCore

/// Detail view for a child profile — devices, mode controls, approved apps.
struct ChildDetailView: View {
    @Bindable var viewModel: ChildDetailViewModel
    var dominantMode: LockMode?

    @State private var locationMode: LocationTrackingMode = .off
    @State private var showRevokeAllConfirmation = false
    @State private var deviceToRevokeAll: ChildDevice?
    @State private var deviceToUnenroll: ChildDevice?
    @State private var showMessageComposer = false
    @State private var messageText = ""
    @State private var showSettings = false
    @State private var showApprovedApps = false
    @State private var showDiagnostics = false
    @State private var showNamedPlaceEditor = false
    @State private var permissionsFeedback: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 1. Mode controls (most used — always at top)
                ModeActionButtons(
                    onSetMode: { mode in Task { await viewModel.setMode(mode) } },
                    onTemporaryUnlock: { seconds in Task { await viewModel.temporaryUnlock(seconds: seconds) } },
                    onLockWithDuration: { duration in Task { await viewModel.lockWithDuration(duration) } },
                    disabled: viewModel.isSendingCommand,
                    remainingSeconds: viewModel.remainingUnlockSeconds
                )

                // 2. Devices — status focused, actions in menus
                devicesSection

                // 3. Location — show if mode is set OR any heartbeat has location data
                if locationMode != .off || viewModel.heartbeats.contains(where: { $0.latitude != nil }) {
                    locationCard
                }

                if !viewModel.temporaryAllowedAppsForChild.isEmpty {
                    temporaryAppsRow
                }

                appsRow

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
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showMessageComposer = true } label: {
                        Label("Send Message", systemImage: "envelope")
                    }
                    NavigationLink {
                        EnrollmentCodeView(appState: viewModel.appState, childProfile: viewModel.child)
                    } label: {
                        Label("Enroll New Device", systemImage: "plus.circle")
                    }
                    Button { showDiagnostics = true } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // Alerts
        .alert("Revoke All Allowed Apps", isPresented: $showRevokeAllConfirmation) {
            Button("Revoke All", role: .destructive) { Task { await viewModel.revokeAllApps() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will block all currently allowed apps on all of \(viewModel.child.name)'s devices.")
        }
        .alert("Revoke All on Device", isPresented: Binding(
            get: { deviceToRevokeAll != nil },
            set: { if !$0 { deviceToRevokeAll = nil } }
        )) {
            Button("Revoke All", role: .destructive) {
                if let d = deviceToRevokeAll { Task { await viewModel.revokeAllApps(for: d) } }
                deviceToRevokeAll = nil
            }
            Button("Cancel", role: .cancel) { deviceToRevokeAll = nil }
        } message: {
            Text("This will block all currently allowed apps on \(deviceToRevokeAll?.displayName ?? "this device").")
        }
        .alert("Unenroll Device", isPresented: Binding(
            get: { deviceToUnenroll != nil },
            set: { if !$0 { deviceToUnenroll = nil } }
        )) {
            Button("Unenroll & Delete", role: .destructive) {
                if let d = deviceToUnenroll { Task { await viewModel.unenrollDevice(d) } }
                deviceToUnenroll = nil
            }
            Button("Cancel", role: .cancel) { deviceToUnenroll = nil }
        } message: {
            Text("This will unenroll \(deviceToUnenroll?.displayName ?? "this device"). You'll need to re-enroll it.")
        }
        // Sheets
        .sheet(isPresented: $showMessageComposer) { messageSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .navigationDestination(isPresented: $showDiagnostics) {
            RemoteDiagnosticsView(
                appState: viewModel.appState,
                child: viewModel.child,
                devices: viewModel.devices
            )
        }
        .refreshable { await viewModel.refresh() }
        .task {
            await viewModel.loadNamedPlaces()
            if let raw = UserDefaults.standard.string(forKey: "locationMode.\(viewModel.child.id.rawValue)"),
               let mode = LocationTrackingMode(rawValue: raw) {
                locationMode = mode
            } else if viewModel.heartbeats.contains(where: { $0.latitude != nil }) {
                // Child is sending location but parent never set the mode — infer it
                locationMode = .continuous
                UserDefaults.standard.set("continuous", forKey: "locationMode.\(viewModel.child.id.rawValue)")
            }
            await viewModel.loadEvents()
            viewModel.startAutoRefresh()
            // Ensure timer cleanup on task cancellation (covers navigation-during-transition).
            await withTaskCancellationHandler {
                await Task.yield()
            } onCancel: {
                Task { @MainActor in viewModel.stopAutoRefresh() }
            }
        }
        .onDisappear { viewModel.stopAutoRefresh() }
    }

    // MARK: - 2. Devices

    @ViewBuilder
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if viewModel.devices.isEmpty {
                Text("No devices enrolled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.devices) { device in
                    deviceCard(device)
                }
            }
        }
    }

    @ViewBuilder
    private func deviceCard(_ device: ChildDevice) -> some View {
        let hb = viewModel.heartbeat(for: device)
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: Device name + mode + status
            HStack {
                DeviceIcon(modelIdentifier: device.modelIdentifier, size: .title3)
                Text(DeviceIcon.displayName(for: device.modelIdentifier))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let mode = dominantMode ?? device.confirmedMode {
                    ModeBadge(mode: mode)
                }
                deviceStatusBadge(device: device, heartbeat: hb)
            }

            // Row 2: Device stats
            HStack(spacing: 8) {
                Text("iOS \(device.osVersion)")
                if let battery = hb?.batteryLevel {
                    HStack(spacing: 2) {
                        Image(systemName: hb?.isCharging == true ? "battery.100.bolt" : "battery.50")
                        Text("\(Int(battery * 100))%")
                    }
                    .foregroundStyle(battery < 0.2 ? .red : .secondary)
                }
                if let disk = hb?.availableDiskSpace {
                    HStack(spacing: 2) {
                        Image(systemName: "internaldrive")
                        Text(Self.formatDisk(available: disk, total: hb?.totalDiskSpace))
                    }
                    .foregroundStyle(disk < 1_000_000_000 ? .red : .secondary)
                }
                Spacer()
                if let count = hb?.allowedAppCount ?? hb?.allowedAppNames?.count, count > 0 {
                    Text("\(count) apps allowed")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // Row 3: Screen time + heartbeat + build
            HStack(spacing: 8) {
                if let hb, let minutes = hb.screenTimeMinutes,
                   hb.timestamp >= Calendar.current.startOfDay(for: Date()),
                   hb.heartbeatSource != "vpnExtension" {
                    let h = minutes / 60, m = minutes % 60
                    HStack(spacing: 2) {
                        Image(systemName: "hourglass")
                        Text(h > 0 ? "\(h)h \(m)m" : "\(m)m")
                    }
                    .foregroundStyle(.secondary)
                }
                if let ts = hb?.timestamp {
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill").font(.system(size: 7))
                        Text(ts, style: .relative) + Text(" ago")
                    }
                    .foregroundStyle(.pink.opacity(0.6))
                }
                buildBadge(childBuild: hb?.appBuildNumber)
            }
            .font(.caption2)

            // Row 4: Shield diagnostics (compact)
            if let hb {
                shieldDiagnosticRow(hb)
            }

            // Row 5: VPN warning (if active)
            if hb?.vpnDetected == true {
                HStack(spacing: 6) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .foregroundStyle(.orange)
                    Text("VPN active")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        UserDefaults.standard.set(true, forKey: "vpnAcknowledged.\(device.id.rawValue)")
                    } label: {
                        Text("Dismiss")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
            }

            // Row 6: Permissions status (collapsible)
            DisclosureGroup {
                PermissionsStatusView(
                    device: device,
                    heartbeat: hb,
                    onRequestPermissions: { await viewModel.requestPermissions(for: device) }
                )
            } label: {
                HStack(spacing: 6) {
                    Text("Permissions")
                    if let hb, hasPermissionIssue(hb) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.caption)
        }
        .padding(10)
        .if_iOS26GlassEffect(fallbackMaterial: .regularMaterial, borderColor: .secondary)
    }

    // MARK: - 3. Location Card

    @ViewBuilder
    private var locationCard: some View {
        let hasLocation = viewModel.heartbeats.contains { $0.latitude != nil }
        let address = viewModel.heartbeats.compactMap(\.locationAddress).first
        let locTime = viewModel.heartbeats.compactMap(\.locationTimestamp).first

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "location.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                if let address, let locTime {
                    Text(address)
                        .font(.caption)
                    Spacer()
                    Text(locTime, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    + Text(" ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Waiting for location...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if let locAuth = viewModel.heartbeats.compactMap(\.locationAuthorization).first,
               locAuth != "always" && locationMode != .off {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Location set to \"\(locAuth.localizedLocationLabel)\" — must be \"Always\" for background tracking.")
                        .foregroundStyle(.orange)
                }
                .font(.caption2)
            } else if !hasLocation && locationMode != .off {
                Text("Permission may be denied. Use Settings to re-request on the child device.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                NavigationLink {
                    LocationMapView(
                        child: viewModel.child,
                        devices: viewModel.devices,
                        heartbeats: viewModel.heartbeats,
                        cloudKit: viewModel.appState.cloudKit,
                        onLocate: { await viewModel.requestLocation() }
                    )
                } label: {
                    Label("Map & Trail", systemImage: "map")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                NavigationLink {
                    LocationMapView(
                        child: viewModel.child,
                        devices: viewModel.devices,
                        heartbeats: viewModel.heartbeats,
                        cloudKit: viewModel.appState.cloudKit,
                        onLocate: { await viewModel.requestLocation() },
                        autoLocate: true
                    )
                } label: {
                    Label("Locate Now", systemImage: "location.circle")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 4. Self-Unlock Row

    @ViewBuilder
    private var selfUnlockRow: some View {
        HStack {
            Image(systemName: "lock.open.rotation")
                .foregroundStyle(.teal)
                .frame(width: 20)
            Text("Self-unlocks")
                .font(.caption)
            if let used = viewModel.selfUnlocksUsedToday, viewModel.selfUnlockBudget > 0 {
                Text("\(used)/\(viewModel.selfUnlockBudget) used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(
                "\(viewModel.selfUnlockBudget)/day",
                value: Binding(
                    get: { viewModel.selfUnlockBudget },
                    set: { viewModel.selfUnlockBudget = $0 }
                ),
                in: 0...10
            )
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .if_iOS26GlassEffect(fallbackMaterial: .regularMaterial, borderColor: .secondary)
    }

    // MARK: - Temporary Apps Row

    @ViewBuilder
    private var temporaryAppsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Temporarily Unlocked")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)
            }
            FlowLayout(spacing: 6) {
                ForEach(viewModel.temporaryAllowedAppsForChild, id: \.self) { name in
                    Text(name)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .if_iOS26GlassEffect(fallbackMaterial: .regularMaterial, borderColor: .secondary)
    }

    // MARK: - Apps Row (Expandable)

    @ViewBuilder
    private var appsRow: some View {
        if !viewModel.approvedAppsForChild.isEmpty {
            DisclosureGroup(isExpanded: $showApprovedApps) {
                VStack(spacing: 4) {
                    ForEach(viewModel.approvedAppsForChild) { app in
                        HStack {
                            Text(app.appName)
                                .font(.caption)
                            Spacer()
                            Button {
                                Task { await viewModel.revokeApp(app) }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.6))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("\(viewModel.approvedAppsForChild.count) Allowed Apps")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                    Button {
                        showRevokeAllConfirmation = true
                    } label: {
                        Text("Revoke All")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(12)
            .if_iOS26GlassEffect(fallbackMaterial: .regularMaterial, borderColor: .secondary)
        }
    }

    // MARK: - 5. Bottom Actions

    @ViewBuilder
    private var bottomActions: some View {
        Button {
            showSettings = true
        } label: {
            HStack {
                Label("Restrictions, Web Filter & Permissions", systemImage: "gear")
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .if_iOS26GlassEffect(fallbackMaterial: .regularMaterial, borderColor: .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message Sheet

    @ViewBuilder
    private var messageSheet: some View {
        NavigationStack {
            Form {
                TextField("Message to \(viewModel.child.name)", text: $messageText, axis: .vertical)
                    .lineLimit(3...6)
            }
            .navigationTitle("Send Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMessageComposer = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        Task { await viewModel.performCommand(.sendMessage(text: text), target: .child(viewModel.child.id)) }
                        messageText = ""
                        showMessageComposer = false
                    }
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Settings Sheet (Restrictions + Web Filter + Location Mode + Permissions)

    @ViewBuilder
    private var settingsSheet: some View {
        NavigationStack {
            List {
                // Location Mode
                Section("Location Tracking") {
                    Picker("Mode", selection: $locationMode) {
                        Text("Off").tag(LocationTrackingMode.off)
                        Text("On Demand").tag(LocationTrackingMode.onDemand)
                        Text("Continuous").tag(LocationTrackingMode.continuous)
                    }
                    .onChange(of: locationMode) { _, newMode in
                        UserDefaults.standard.set(newMode.rawValue, forKey: "locationMode.\(viewModel.child.id.rawValue)")
                        Task { await viewModel.sendLocationMode(newMode) }
                    }

                    // Home geofence — uses child's current location as home.
                    // Geofence triggers app relaunch if child force-closes near home.
                    if let hb = viewModel.heartbeats.first(where: { $0.latitude != nil }),
                       let lat = hb.latitude, let lon = hb.longitude {
                        Button {
                            Task { await viewModel.setHomeLocation(latitude: lat, longitude: lon) }
                        } label: {
                            Label("Set Current Location as Home", systemImage: "house.fill")
                        }
                        if let addr = hb.locationAddress {
                            Text("Current: \(addr)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if viewModel.hasHomeGeofence {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Home geofence active")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                // Self-Unlocks
                Section("Self-Unlocks") {
                    Stepper(
                        "\(viewModel.selfUnlockBudget) per day",
                        value: Binding(
                            get: { viewModel.selfUnlockBudget },
                            set: { viewModel.selfUnlockBudget = $0 }
                        ),
                        in: 0...10
                    )
                    if let used = viewModel.selfUnlocksUsedToday, viewModel.selfUnlockBudget > 0 {
                        Text("\(used) of \(viewModel.selfUnlockBudget) used today")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("How many times per day the child can unlock their own device for 15 minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Restrictions
                Section("Device Restrictions") {
                    restrictionToggle("Prevent App Deletion", icon: "trash.slash",
                                      isOn: viewModel.restrictions.denyAppRemoval,
                                      toggle: { viewModel.toggleRestriction(\.denyAppRemoval) })
                    restrictionToggle("Block Explicit Content", icon: "eye.slash",
                                      isOn: viewModel.restrictions.denyExplicitContent,
                                      toggle: { viewModel.toggleRestriction(\.denyExplicitContent) })
                    restrictionToggle("Lock Accounts", icon: "person.crop.circle.badge.xmark",
                                      isOn: viewModel.restrictions.lockAccounts,
                                      toggle: { viewModel.toggleRestriction(\.lockAccounts) })
                    restrictionToggle("Auto Date & Time", icon: "clock.arrow.circlepath",
                                      isOn: viewModel.restrictions.requireAutomaticDateAndTime,
                                      toggle: { viewModel.toggleRestriction(\.requireAutomaticDateAndTime) })
                    restrictionToggle("Block Web When Locked", icon: "globe.badge.chevron.backward",
                                      isOn: viewModel.restrictions.denyWebWhenLocked,
                                      toggle: { viewModel.toggleRestriction(\.denyWebWhenLocked) })
                }

                // Safe Search (DNS-based via VPN tunnel)
                Section("Safe Search") {
                    Toggle(isOn: $viewModel.safeSearchEnabled) {
                        Label("Force Safe Search", systemImage: "magnifyingglass.circle")
                    }
                    .onChange(of: viewModel.safeSearchEnabled) { _, enabled in
                        Task { await viewModel.sendSafeSearch(enabled: enabled) }
                    }
                    Text("Enforces safe search on Google, Bing, YouTube, and blocks adult content at the DNS level via CleanBrowsing Family Filter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Web Filter
                Section("Web Content Filter") {
                    NavigationLink {
                        WebFilterConfigView(child: viewModel.child) { domains in
                            await viewModel.sendWebFilterDomains(domains)
                        }
                    } label: {
                        Label("Configure Categories", systemImage: "globe.badge.chevron.backward")
                    }
                }

                // Driving Safety
                Section("Driving Safety") {
                    HStack {
                        Label("Speed Limit", systemImage: "gauge.with.dots.needle.67percent")
                        Spacer()
                        Text("\(Int(viewModel.drivingSettings.speedThresholdMPH)) mph")
                            .foregroundStyle(.secondary)
                        Stepper("", value: $viewModel.drivingSettings.speedThresholdMPH, in: 40...100, step: 5)
                            .labelsHidden()
                            .frame(width: 94)
                    }
                    Toggle(isOn: $viewModel.drivingSettings.speedAlertEnabled) {
                        Label("Speed Alerts", systemImage: "exclamationmark.triangle")
                    }
                    Toggle(isOn: $viewModel.drivingSettings.phoneUsageDetectionEnabled) {
                        Label("Phone While Driving", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                    Toggle(isOn: $viewModel.drivingSettings.hardBrakingDetectionEnabled) {
                        Label("Hard Braking", systemImage: "exclamationmark.octagon")
                    }
                    Button("Save Driving Settings") {
                        Task { await viewModel.sendDrivingSettings() }
                    }
                    .disabled(viewModel.isSendingCommand)
                }

                // Named Places
                Section("Named Places") {
                    Button {
                        showNamedPlaceEditor = true
                    } label: {
                        Label("Add Place", systemImage: "plus.circle")
                    }
                    if viewModel.namedPlaces.isEmpty {
                        Text("No places configured. Add school, friends' houses, etc.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.namedPlaces) { place in
                        HStack {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading) {
                                Text(place.name).font(.subheadline)
                                Text("\(Int(place.radiusMeters))m radius")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete { indexSet in
                        Task { await viewModel.deleteNamedPlace(at: indexSet) }
                    }
                }

                // Per-device app configuration (requires child device in hand)
                ForEach(viewModel.devices) { device in
                    Section("\(DeviceIcon.displayName(for: device.modelIdentifier)) — Apps") {
                        Button {
                            Task { await viewModel.requestAlwaysAllowedSetup(for: device) }
                        } label: {
                            Label("Set Always-Allowed Apps", systemImage: "checkmark.circle")
                        }

                        Button {
                            Task { await viewModel.requestAppConfiguration(for: device) }
                        } label: {
                            Label("Configure App Blocking", systemImage: "shield")
                        }

                        Button(role: .destructive) {
                            deviceToRevokeAll = device
                        } label: {
                            Label("Revoke All Allowed Apps", systemImage: "xmark.circle")
                        }

                        Button(role: .destructive) {
                            deviceToUnenroll = device
                        } label: {
                            Label("Unenroll Device", systemImage: "trash")
                        }
                    }
                }

                // Permissions
                Section {
                    Button {
                        Task {
                            await viewModel.requestPermissions()
                            permissionsFeedback = "Command sent — open Big Brother on the child's device and wait ~60 seconds for the prompt"
                            try? await Task.sleep(for: .seconds(8))
                            permissionsFeedback = nil
                        }
                    } label: {
                        Label("Re-request Permissions", systemImage: "hand.raised")
                    }
                    if let permissionsFeedback {
                        Text(permissionsFeedback)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } footer: {
                    Text("Use when holding the child's device to re-authorize Screen Time and Location.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
            .sheet(isPresented: $showNamedPlaceEditor) {
                NamedPlaceEditorView(appState: viewModel.appState) { place in
                    await viewModel.saveNamedPlace(place)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func restrictionToggle(_ title: String, icon: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
            Label(title, systemImage: icon)
        }
    }

    @ViewBuilder
    private func shieldDiagnosticRow(_ hb: DeviceHeartbeat) -> some View {
        let shieldsOK = hb.shieldsActive ?? true
        let reportedMode = hb.currentMode
        // Use the CHILD's reported schedule mode to detect if the child has stale data.
        // If this disagrees with what the parent expects, the child's schedule is wrong.
        let childScheduleMode: LockMode? = hb.scheduleResolvedMode.flatMap { detail in
            // Parse mode from enriched string like "essentialOnly (in essential window)"
            let raw = detail.components(separatedBy: " ").first ?? detail
            return LockMode(rawValue: raw)
        }
        // Use parent's expectation as the canonical "expected" mode
        let expectedMode = dominantMode

        // Don't flag shields-down during active unlocks
        let inTempUnlock = (hb.temporaryUnlockExpiresAt != nil && hb.temporaryUnlockExpiresAt! > Date())
            || dominantMode == .unlocked
        let shouldBeLocked = expectedMode != nil && expectedMode != .unlocked && !inTempUnlock
        let mismatch = shouldBeLocked && !shieldsOK

        VStack(alignment: .leading, spacing: 3) {
            // Row 1: Actual device state
            HStack(spacing: 4) {
                Image(systemName: mismatch ? "shield.slash" : shieldsOK ? "shield.checkered" : "shield.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(mismatch ? .red : shieldsOK ? .green : .secondary)

                if mismatch {
                    Text("SHIELDS DOWN")
                        .fontWeight(.bold)
                        .foregroundStyle(.red)
                } else {
                    Text("Reporting: \(reportedMode.displayName)")
                        .foregroundStyle(shieldsOK ? .green : .secondary)
                }

                if hb.heartbeatSource == "vpnExtension" {
                    Text("(via tunnel)")
                        .foregroundStyle(.orange)
                }
            }

            // Row 2: Expected vs actual (only when device is LESS restrictive than expected)
            // Strictness order: unlocked < dailyMode < essentialOnly
            // A device in a stricter mode than expected is fine — only warn when too permissive.
            if let expected = expectedMode, expected != reportedMode, !inTempUnlock,
               reportedMode.restrictionLevel < expected.restrictionLevel {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("Expected: \(expected.displayName)")
                        .foregroundStyle(.orange)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Actual: \(reportedMode.displayName)")
                        .foregroundStyle(.red)
                    if let reason = hb.lastShieldChangeReason {
                        Text("(\(friendlyShieldReason(reason)))")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let reason = hb.lastShieldChangeReason {
                // No mismatch — just show last shield change reason
                HStack(spacing: 4) {
                    Text("Last change: \(friendlyShieldReason(reason))")
                        .foregroundStyle(.secondary)
                }
            }

            // Row 2b: Child schedule data mismatch (child's local schedule disagrees with parent)
            if let childMode = childScheduleMode, let parentMode = expectedMode,
               childMode != parentMode, !inTempUnlock {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                    Text("Child schedule says: \(childMode.displayName)")
                        .foregroundStyle(.yellow)
                    if let detail = hb.scheduleResolvedMode {
                        Text("(\(detail))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // Row 3: App counts + lock state
            HStack(spacing: 8) {
                if hb.shieldCategoryActive == true {
                    if reportedMode == .locked {
                        // Essential mode: everything blocked, only system essentials allowed
                        Label("All non-essential apps blocked", systemImage: "shield.lefthalf.filled")
                            .foregroundStyle(.secondary)
                    } else if let allowed = hb.allowedAppCount, allowed > 0 {
                        Label("All apps blocked except \(allowed) allowed", systemImage: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("All apps blocked", systemImage: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                    }
                } else if let blocked = hb.shieldedAppCount, blocked > 0 {
                    Label("\(blocked) apps blocked", systemImage: "xmark.app")
                        .foregroundStyle(.secondary)
                } else if !shieldsOK && shouldBeLocked {
                    Label("No apps blocked", systemImage: "xmark.app")
                        .foregroundStyle(.red)
                }

                if let locked = hb.isDeviceLocked {
                    Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                        .foregroundColor(locked ? .secondary : .yellow)
                    Text(locked ? "Screen off" : "Screen on")
                        .foregroundColor(locked ? .secondary : .yellow)
                }
            }
        }
        .font(.caption2.monospacedDigit())
    }

    private func hasPermissionIssue(_ hb: DeviceHeartbeat) -> Bool {
        if !hb.familyControlsAuthorized { return true }
        if hb.locationAuthorization != "always" && hb.locationAuthorization != nil { return true }
        if hb.tunnelConnected == false { return true }
        if hb.motionAuthorized == false { return true }
        if hb.notificationsAuthorized == false { return true }
        return false
    }

    private func friendlyShieldReason(_ reason: String) -> String {
        switch reason {
        case "launchRestore": return "restored on launch"
        case "apply": return "policy applied"
        case "command": return "remote command"
        case "clearAll": return "all cleared"
        case "tempUnlockClear": return "temp unlock ended"
        case "forceCloseNag": return "force-close block"
        case "appClosed": return "app not running"
        case "backgroundRestore": return "background restore"
        case "reconcile": return "auto-reconciled"
        case "freeWindowStart": return "free time started"
        case "freeWindowEnd": return "free time ended"
        case "essentialWindowStart": return "essential mode started"
        case "essentialWindowEnd": return "essential mode ended"
        default: return reason
        }
    }

    @ViewBuilder
    private func buildBadge(childBuild: Int?) -> some View {
        if viewModel.appState.debugMode, let childBuild {
            let matches = childBuild == AppConstants.appBuildNumber
            HStack(spacing: 2) {
                Text("b\(childBuild)")
                if matches {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                }
            }
            .font(.caption2)
            .foregroundStyle(matches ? Color.secondary : Color.orange)
        }
    }

    @ViewBuilder
    private func deviceStatusBadge(device: ChildDevice, heartbeat hb: DeviceHeartbeat?) -> some View {
        if device.isOnline {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Online").font(.caption2).foregroundStyle(.green)
            }
        } else if let hb, isDeviceAppClosed(heartbeat: hb) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(.orange)
                Text("App Not Running").font(.caption2).foregroundStyle(.orange)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.6)).frame(width: 6, height: 6)
                Text("Offline").font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func isDeviceAppClosed(heartbeat hb: DeviceHeartbeat) -> Bool {
        let heartbeatAge = Date().timeIntervalSince(hb.timestamp)
        let threshold: TimeInterval = (dominantMode == .unlocked) ? 7200 : 3600
        guard heartbeatAge > threshold else { return false }
        guard let monitorActive = hb.monitorLastActiveAt else { return false }
        return Date().timeIntervalSince(monitorActive) < 7200
    }

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

// FlowLayout is defined in WrappingHStack.swift

private extension String {
    /// Human-readable label for CLAuthorizationStatus strings from heartbeat.
    var localizedLocationLabel: String {
        switch self {
        case "always": return "Always"
        case "whenInUse": return "While Using"
        case "denied": return "Denied"
        case "restricted": return "Restricted"
        case "notDetermined": return "Not Determined"
        default: return self
        }
    }
}
