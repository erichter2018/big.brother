import SwiftUI
import MapKit
import CoreLocation
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
    @State private var showAvatarPicker = false
    @State private var showNamedPlaceEditor = false
    @State private var permissionsFeedback: String?
    @State private var sectionOrder: [ChildDetailSection] = ChildDetailSection.defaultOrder
    @State private var hiddenSections: Set<ChildDetailSection> = []

    @State private var showFullActivity = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 1. Mode controls (most used — always at top)
                ModeActionButtons(
                    onSetMode: { mode in Task { await viewModel.setMode(mode) } },
                    onTemporaryUnlock: { seconds in Task { await viewModel.temporaryUnlock(seconds: seconds) } },
                    onLockWithDuration: { duration in Task { await viewModel.lockWithDuration(duration) } },
                    onLockDown: { seconds in Task { await viewModel.lockDown(seconds: seconds) } },
                    disabled: viewModel.isSendingCommand,
                    remainingSeconds: viewModel.remainingUnlockSeconds
                )

                // Issue alert — only visible when there's a problem
                if !viewModel.deviceIssues.isEmpty {
                    deviceIssuePanel
                }

                // Dynamic sections in user-configured order
                ForEach(sectionOrder.filter { !hiddenSections.contains($0) }) { section in
                    sectionView(for: section)
                }

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
                    Button { showAvatarPicker = true } label: {
                        Label("Change Avatar", systemImage: "person.crop.circle")
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
        .sheet(isPresented: $showAvatarPicker) {
            AvatarPickerSheet(child: viewModel.child) { updated in
                await viewModel.saveProfile(updated)
            }
        }
        .navigationDestination(isPresented: $showDiagnostics) {
            RemoteDiagnosticsView(
                appState: viewModel.appState,
                child: viewModel.child,
                devices: viewModel.devices
            )
        }
        .refreshable { await viewModel.refresh() }
        .onAppear {
            sectionOrder = ChildDetailSection.loadOrder(for: viewModel.child.id)
            hiddenSections = ChildDetailSection.loadHidden(for: viewModel.child.id)
            if let raw = UserDefaults.standard.string(forKey: "locationMode.\(viewModel.child.id.rawValue)"),
               let mode = LocationTrackingMode(rawValue: raw) {
                locationMode = mode
            } else if viewModel.heartbeats.contains(where: { $0.latitude != nil }) {
                locationMode = .continuous
                UserDefaults.standard.set("continuous", forKey: "locationMode.\(viewModel.child.id.rawValue)")
            }
            viewModel.startAutoRefresh()
        }
        .task {
            await viewModel.loadNamedPlaces()
        }
        .onDisappear { viewModel.stopAutoRefresh() }
    }

    // MARK: - Auth Type Badge

    @ViewBuilder
    private func authTypeBadge(heartbeat hb: DeviceHeartbeat?) -> some View {
        if let authType = hb?.familyControlsAuthType {
            let isChild = authType == "child"
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Image(systemName: isChild ? "lock.shield.fill" : "exclamationmark.shield")
                        .font(.system(size: 8))
                    Text(isChild ? "Family Auth" : "Individual Auth")
                        .font(.caption2)
                }
                .foregroundStyle(isChild ? .green : .orange)

                if !isChild {
                    if let reason = hb?.childAuthFailReason {
                        Text(reason)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("Weaker — kid can revoke in Settings with device passcode")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }


    // MARK: - Device Issue Panel

    @ViewBuilder
    private var deviceIssuePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("DEVICE ISSUES")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }

            ForEach(viewModel.deviceIssues) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: issue.isIPad ? "ipad" : "iphone")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(issue.deviceName)
                            .font(.caption.weight(.semibold))

                        Spacer()

                        if issue.shieldsDown {
                            Label("Shields Down", systemImage: "shield.slash.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                        if issue.internetBlocked {
                            Label("No Internet", systemImage: "wifi.slash")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(issue.reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Mini Map

    @State private var navigateToMap = false

    @ViewBuilder
    private func sectionView(for section: ChildDetailSection) -> some View {
        switch section {
        case .miniMap:
            miniMapSection
        case .todaySummary:
            todaySummary
        case .screenTimeTrend:
            ScreenTimeTrendChart(dailyMinutes: viewModel.weeklyScreenTime)
        case .screenTimeTimeline:
            ScreenTimeTimelineSection(slotsByDay: viewModel.screenTimeByDay, weeklyScreenTime: viewModel.weeklyScreenTime)
        case .bedtimeCompliance:
            BedtimeComplianceSection(compliance: viewModel.bedtimeCompliance, weeklyScreenTime: viewModel.weeklyScreenTime)
        case .appUsage:
            AppUsageSection(activity: viewModel.onlineActivity, weekActivity: viewModel.onlineActivityWeek, dailySnapshots: viewModel.onlineActivityByDay)
        case .appTimeLimits:
            AppTimeLimitsSection(viewModel: viewModel)
        case .onlineActivity:
            OnlineActivitySection(activity: viewModel.onlineActivity, weekActivity: viewModel.onlineActivityWeek, dailySnapshots: viewModel.onlineActivityByDay, showFlagged: false)
        case .flaggedActivity:
            let flagSource = viewModel.onlineActivityWeek ?? viewModel.onlineActivity
            if let activity = flagSource, !activity.flaggedDomains.isEmpty {
                DisclosureGroup("Flagged Activity (\(activity.flaggedDomains.count))") {
                    OnlineActivitySection(activity: activity, showFlagged: true, flaggedOnly: true)
                }
            }
        case .recentActivity:
            VStack(alignment: .leading, spacing: 0) {
                ActivityFeedSection(
                    entries: viewModel.timeline,
                    limit: 5,
                    child: viewModel.child,
                    devices: viewModel.devices,
                    heartbeats: viewModel.heartbeats,
                    cloudKit: viewModel.appState.cloudKit,
                    onLocate: { await viewModel.requestLocation() }
                )
                if viewModel.timeline.count > 5 {
                    NavigationLink(destination: fullActivityList) {
                        HStack {
                            Spacer()
                            Text("See All Activity")
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            Spacer()
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }
                }
            }
        case .devices:
            devicesSection
        }
    }

    @ViewBuilder
    private var miniMapSection: some View {
        let hbWithLoc = viewModel.heartbeats.first(where: { $0.latitude != nil })
        if let lat = hbWithLoc?.latitude, let lng = hbWithLoc?.longitude {
            let homeCoord = homeCoordinate
            let isHome = isAtHome(lat: lat, lng: lng)
            NavigationLink {
                LocationMapView(
                    child: viewModel.child,
                    devices: viewModel.devices,
                    heartbeats: viewModel.heartbeats,
                    cloudKit: viewModel.appState.cloudKit,
                    onLocate: { await viewModel.requestLocation() }
                )
            } label: {
                let placeName = resolvedPlaceName(lat: lat, lng: lng, fallback: hbWithLoc?.locationAddress)
                MiniMapCard(
                    latitude: lat,
                    longitude: lng,
                    address: placeName,
                    timestamp: hbWithLoc?.locationTimestamp,
                    isAtHome: isHome,
                    homeCoordinate: homeCoord,
                    isDriving: hbWithLoc?.isDriving == true,
                    speedMph: {
                        guard let speed = hbWithLoc?.currentSpeed, speed > 0 else { return nil }
                        return Int(speed * 2.237) // m/s to mph
                    }()
                )
            }
            .buttonStyle(.plain)
        } else if locationMode != .off {
            MiniMapPlaceholder()
        }
    }

    private var homeCoordinate: CLLocationCoordinate2D? {
        let defaults = UserDefaults.standard
        // Check per-device keys (parent stores as homeLatitude.<deviceID>)
        for device in viewModel.devices {
            let latKey = "homeLatitude.\(device.id.rawValue)"
            let lonKey = "homeLongitude.\(device.id.rawValue)"
            if let lat = defaults.object(forKey: latKey) as? Double,
               let lon = defaults.object(forKey: lonKey) as? Double {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        // Fallback: plain keys (child side / App Group)
        if let lat = defaults.object(forKey: "homeLatitude") as? Double,
           let lon = defaults.object(forKey: "homeLongitude") as? Double {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    /// Resolve lat/lng to a named place (Home, School, etc.) or fall back to address.
    private func resolvedPlaceName(lat: Double, lng: Double, fallback: String?) -> String? {
        let loc = CLLocation(latitude: lat, longitude: lng)

        // Check home first
        if let home = homeCoordinate {
            let homeLoc = CLLocation(latitude: home.latitude, longitude: home.longitude)
            if loc.distance(from: homeLoc) < 150 { return "Home" }
        }

        // Check named places
        for place in viewModel.namedPlaces {
            let placeLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
            if loc.distance(from: placeLoc) < Double(place.radiusMeters) {
                return place.name
            }
        }

        return fallback
    }

    private func isAtHome(lat: Double, lng: Double) -> Bool {
        guard let home = homeCoordinate else { return false }
        let childLoc = CLLocation(latitude: lat, longitude: lng)
        let homeLoc = CLLocation(latitude: home.latitude, longitude: home.longitude)
        return childLoc.distance(from: homeLoc) < 150
    }

    // MARK: - Today Summary

    @ViewBuilder
    private var todaySummary: some View {
        let hb = viewModel.heartbeats.first
        let screenMins = hb?.screenTimeMinutes
        let unlockCount = hb?.screenUnlockCount

        // Schedule status
        let schedStatus: String? = {
            guard let profile = viewModel.appState.storage.readActiveScheduleProfile() else { return nil }
            // Check across all child devices
            for device in viewModel.devices {
                if let deviceSchedule = viewModel.appState.childDevices.first(where: { $0.id == device.id })?.scheduleProfileID {
                    let _ = deviceSchedule // schedule is assigned
                }
            }
            let mode = profile.resolvedMode(at: Date())
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            if let next = profile.nextTransitionTime(from: Date()) {
                return "\(profile.name) · \(mode.displayName) until \(formatter.string(from: next))"
            }
            return "\(profile.name) · \(mode.displayName)"
        }()

        TodaySummaryCard(
            screenTimeMinutes: screenMins,
            screenUnlockCount: unlockCount,
            batteryLevel: hb?.batteryLevel,
            isCharging: hb?.isCharging ?? false,
            lastHeartbeat: hb?.timestamp,
            heartbeatSource: hb?.heartbeatSource,
            scheduleStatus: schedStatus
        )
    }

    // MARK: - Full Activity List

    @ViewBuilder
    private var fullActivityList: some View {
        List {
            ForEach(viewModel.timeline) { entry in
                if entry.eventType == .tripCompleted {
                    NavigationLink {
                        LocationMapView(
                            child: viewModel.child,
                            devices: viewModel.devices,
                            heartbeats: viewModel.heartbeats,
                            cloudKit: viewModel.appState.cloudKit,
                            onLocate: { await viewModel.requestLocation() },
                            focusTripAt: entry.timestamp
                        )
                    } label: {
                        activityListRow(entry)
                    }
                } else {
                    activityListRow(entry)
                }
            }
        }
        .navigationTitle("Activity")
    }

    @ViewBuilder
    private func activityListRow(_ entry: TimelineEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.eventType == .tripCompleted ? Color.green : (entry.isCommand ? Color.purple : .blue))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.subheadline)
                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Devices (Collapsible)

    @State private var expandedDevices: Set<DeviceID> = []

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
                    collapsibleDeviceCard(device)
                }
            }
        }
    }

    @ViewBuilder
    private func collapsibleDeviceCard(_ device: ChildDevice) -> some View {
        let hb = viewModel.heartbeat(for: device)
        let isExpanded = expandedDevices.contains(device.id)

        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedDevices.remove(device.id)
                    } else {
                        expandedDevices.insert(device.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    // Online indicator
                    Circle()
                        .fill(deviceOnlineColor(heartbeat: hb))
                        .frame(width: 8, height: 8)

                    DeviceIcon(modelIdentifier: device.modelIdentifier, size: .caption)
                    Text(DeviceIcon.displayName(for: device.modelIdentifier))
                        .font(.caption)
                        .fontWeight(.medium)

                    Spacer()

                    if let mode = dominantMode ?? device.confirmedMode {
                        // Grey clock if heartbeat doesn't confirm the expected mode
                        if let hbMode = hb?.currentMode, hbMode != mode {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                                .foregroundStyle(.gray)
                        }
                        ModeBadge(mode: mode)
                    }

                    if let battery = hb?.batteryLevel {
                        HStack(spacing: 2) {
                            Image(systemName: hb?.isCharging == true ? "battery.100.bolt" : "battery.50")
                                .font(.system(size: 10))
                            Text("\(Int(battery * 100))%")
                                .font(.caption2)
                        }
                        .foregroundStyle(battery < 0.2 ? .red : .secondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .padding(10)

            // Expanded details
            if isExpanded {
                Divider().padding(.horizontal, 10)
                deviceExpandedContent(device, hb: hb)
                    .padding(10)
            }
        }
        .if_iOS26GlassEffect(fallbackMaterial: .regularMaterial, borderColor: .secondary)
    }

    @ViewBuilder
    private func deviceExpandedContent(_ device: ChildDevice, hb: DeviceHeartbeat?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Stats row
            HStack(spacing: 8) {
                Text("iOS \(device.osVersion)")
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

            // Screen time + heartbeat
            HStack(spacing: 8) {
                if let hb, let minutes = hb.screenTimeMinutes,
                   hb.timestamp >= Calendar.current.startOfDay(for: Date()),
                   hb.heartbeatSource != "vpnTunnel" {
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
                buildBadge(childBuild: hb?.appBuildNumber, heartbeat: hb)
                authTypeBadge(heartbeat: hb)
            }
            .font(.caption2)

            // Shield diagnostics
            if let hb {
                shieldDiagnosticRow(hb)
            }

            // Permissions
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
    }

    private func deviceOnlineColor(heartbeat: DeviceHeartbeat?) -> Color {
        guard let ts = heartbeat?.timestamp else { return .gray }
        let age = -ts.timeIntervalSinceNow
        if age < 300 { return .green }  // < 5 min
        if age < 900 { return .yellow } // < 15 min
        return .red
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
                   hb.heartbeatSource != "vpnTunnel" {
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
                buildBadge(childBuild: hb?.appBuildNumber, heartbeat: hb)
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

    // MARK: - Dashboard Layout Section

    @ViewBuilder
    private var dashboardLayoutSection: some View {
        Section {
            ForEach(sectionOrder, id: \.self) { section in
                HStack(spacing: 12) {
                    Image(systemName: section.icon)
                        .font(.system(size: 14))
                        .foregroundColor(hiddenSections.contains(section) ? .gray.opacity(0.4) : .blue)
                        .frame(width: 22)

                    Text(section.displayName)
                        .font(.subheadline)
                        .foregroundStyle(hiddenSections.contains(section) ? .secondary : .primary)

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { !hiddenSections.contains(section) },
                        set: { visible in
                            if visible {
                                hiddenSections.remove(section)
                            } else {
                                hiddenSections.insert(section)
                            }
                            ChildDetailSection.saveHidden(hiddenSections, for: viewModel.child.id)
                        }
                    ))
                    .labelsHidden()
                    .tint(.blue)
                }
            }
            .onMove { from, to in
                sectionOrder.move(fromOffsets: from, toOffset: to)
                ChildDetailSection.saveOrder(sectionOrder, for: viewModel.child.id)
            }
        } header: {
            Text("Dashboard Layout")
        } footer: {
            Text("Drag to reorder. Toggle to show or hide sections.")
        }
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Settings Sheet (Restrictions + Web Filter + Location Mode + Permissions)

    @ViewBuilder
    private var settingsSheet: some View {
        NavigationStack {
            List {
                // Dashboard Layout
                dashboardLayoutSection

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
                    restrictionToggle("Block Web Games", icon: "gamecontroller",
                                      isOn: viewModel.restrictions.denyWebGamesWhenRestricted,
                                      toggle: { viewModel.toggleRestriction(\.denyWebGamesWhenRestricted) })
                    if viewModel.restrictions.denyWebGamesWhenRestricted {
                        Text("Blocks browser gaming sites (coolmathgames, poki, .io games, etc.) when device is restricted or locked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Safe Search (DNS-based via VPN tunnel)
                Section("Safe Search") {
                    Toggle(isOn: $viewModel.safeSearchEnabled) {
                        Label("Force Safe Search", systemImage: "magnifyingglass.circle")
                    }
                    .onChange(of: viewModel.safeSearchEnabled) { _, enabled in
                        Task { await viewModel.sendSafeSearch(enabled: enabled) }
                    }
                    Text("Enforces safe search on Google, Bing, and DuckDuckGo. Forces YouTube Restricted Mode (strict). Blocks adult content at the DNS level via CleanBrowsing Family Filter.")
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
                Section {
                    Toggle(isOn: $viewModel.drivingSettings.isDriver) {
                        Label("Is a Driver", systemImage: "car.fill")
                    }
                    if viewModel.drivingSettings.isDriver {
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
                    }
                    Button("Save Driving Settings") {
                        Task { await viewModel.sendDrivingSettings() }
                    }
                    .disabled(viewModel.isSendingCommand)
                } header: {
                    Text("Driving Safety")
                } footer: {
                    if !viewModel.drivingSettings.isDriver {
                        Text("Trips are still tracked when this child is a passenger.")
                    }
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

                        Button(role: .destructive) {
                            deviceToRevokeAll = device
                        } label: {
                            Label("Revoke All Allowed Apps", systemImage: "xmark.circle")
                        }

                        // Re-authorize as .child if currently .individual
                        if let hb = viewModel.heartbeat(for: device),
                           hb.familyControlsAuthType != "child" {
                            Button {
                                Task { await viewModel.requestReauthorization(for: device) }
                            } label: {
                                Label("Upgrade to Family Auth", systemImage: "lock.shield")
                            }
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
        // Compare the child's reported schedule mode against what the parent's schedule
        // says RIGHT NOW (not at heartbeat send time, which can be stale).
        // This detects if the child has a different/stale schedule profile.
        let childScheduleMode: LockMode? = hb.scheduleResolvedMode.flatMap { detail in
            let raw = detail.components(separatedBy: " ").first ?? detail
            return LockMode.from(raw)
        }
        // Parent's schedule computed fresh for comparison
        let parentScheduleMode: LockMode? = viewModel.scheduleProfile.map { $0.resolvedMode(at: Date()) }
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

                if hb.heartbeatSource == "vpnTunnel" {
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

            // Row 2b: Child schedule data mismatch (child's local schedule disagrees with parent's
            // schedule computed NOW — not at heartbeat time, which can be stale)
            if let childMode = childScheduleMode, let parentMode = parentScheduleMode,
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
        case "essentialWindowStart": return "locked mode started"
        case "essentialWindowEnd": return "locked mode ended"
        default: return reason
        }
    }

    @ViewBuilder
    private func buildBadge(childBuild: Int?, heartbeat hb: DeviceHeartbeat? = nil) -> some View {
        if viewModel.appState.debugMode, let childBuild {
            let isTunnel = hb?.heartbeatSource == "vpnTunnel"
            let appBuild = hb?.mainAppLastLaunchedBuild
            let tunnelBuild = childBuild  // appBuildNumber = sender's build

            // Show split view when tunnel and app have different builds
            if isTunnel, let appBuild, appBuild != tunnelBuild {
                HStack(spacing: 3) {
                    HStack(spacing: 1) {
                        Image(systemName: "iphone").font(.system(size: 7))
                        Text("b\(appBuild)")
                    }
                    .foregroundStyle(appBuild == AppConstants.appBuildNumber ? Color.secondary : Color.orange)
                    HStack(spacing: 1) {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 7))
                        Text("b\(tunnelBuild)")
                    }
                    .foregroundStyle(tunnelBuild == AppConstants.appBuildNumber ? Color.secondary : Color.orange)
                }
                .font(.caption2)
            } else {
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
