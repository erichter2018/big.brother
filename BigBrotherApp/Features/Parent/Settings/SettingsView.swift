import SwiftUI
import UIKit
import CloudKit
import BigBrotherCore

struct SettingsView: View {
    let appState: AppState
    @State private var showNukeConfirm = false
    @State private var nukeStatus: String?
    @State private var isNuking = false
    @State private var showPaywall = false
    @State private var expectedChildCount: Int
    @State private var isExporting = false
    @State private var exportedFileURL: URL?
    @State private var exportError: String?
    @State private var showDashboardLayout = false
    @State private var isCopyingLog = false
    @State private var logCopyStatus: String?

    init(appState: AppState) {
        self.appState = appState
        self._expectedChildCount = State(initialValue: UserDefaults.standard.integer(forKey: "expectedChildCount"))
    }

    var body: some View {
        List {
            Section {
                Button {
                    showDashboardLayout = true
                } label: {
                    Label("Dashboard Layout", systemImage: "square.grid.2x2")
                }
            }

            Section("Security") {
                NavigationLink {
                    SecuritySettingsView(appState: appState)
                } label: {
                    Label("PIN & Authentication", systemImage: "lock.shield")
                }
            }

            Section("Family") {
                HStack {
                    Text("Family Code")
                    Spacer()
                    Text(appState.parentState?.familyID.rawValue.prefix(8) ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Children")
                    Spacer()
                    Text("\(appState.childProfiles.count)")
                        .foregroundStyle(.secondary)
                }

                Stepper("Expected Children: \(expectedChildCount == 0 ? "—" : "\(expectedChildCount)")",
                        value: $expectedChildCount, in: 0...20)
                    .onChange(of: expectedChildCount) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "expectedChildCount")
                    }
                    .font(.subheadline)

                HStack {
                    Text("Devices")
                    Spacer()
                    Text("\(appState.childDevices.count)")
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    ManageChildrenView(appState: appState)
                } label: {
                    Label("Remove Children", systemImage: "person.badge.minus")
                }

                NavigationLink {
                    ParentInviteView(appState: appState)
                } label: {
                    Label("Invite Parent", systemImage: "person.2.badge.key")
                }

                if appState.parentState?.isPrimaryParent == true {
                    NavigationLink {
                        ManageParentsView(appState: appState)
                    } label: {
                        Label("Manage Parent Access", systemImage: "person.badge.minus")
                    }
                }
            }

            Section("Monitoring") {
                NavigationLink {
                    HeartbeatProfileListView(
                        viewModel: HeartbeatProfileListViewModel(appState: appState)
                    )
                } label: {
                    Label("Monitoring Profiles", systemImage: "heart.text.clipboard")
                }
            }

            Section("Integrations") {
                NavigationLink {
                    TimerIntegrationSettingsView(appState: appState)
                } label: {
                    Label("AllowanceTracker Timers", systemImage: "timer")
                }
            }

            Section("System") {
                Button {
                    Task { await exportData() }
                } label: {
                    Label(isExporting ? "Exporting..." : "Export Family Data", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)

                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await copyEnforcementLog() }
                } label: {
                    Label(isCopyingLog ? "Fetching..." : "Copy Enforcement Log", systemImage: "doc.on.clipboard")
                }
                .disabled(isCopyingLog)

                if let logCopyStatus {
                    Text(logCopyStatus)
                        .font(.caption)
                        .foregroundStyle(logCopyStatus.contains("Copied") ? .green : .red)
                }

                Button {
                    showNukeConfirm = true
                } label: {
                    Label("Delete All Data & Reset", systemImage: "trash.circle")
                        .foregroundStyle(.red)
                }

                if let nukeStatus {
                    Text(nukeStatus)
                        .font(.caption)
                        .foregroundStyle(nukeStatus.contains("Error") ? .red : .green)
                }

                if appState.debugMode {
                    NavigationLink {
                        DiagnosticsView(viewModel: DiagnosticsViewModel(appState: appState))
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }

                    NavigationLink {
                        cloudKitStatusView
                    } label: {
                        Label("CloudKit Status", systemImage: "icloud")
                    }
                }
            }

            Section("Subscription") {
                HStack {
                    Label("Status", systemImage: "creditcard")
                    Spacer()
                    Text(appState.subscriptionManager.statusDisplayText)
                        .foregroundStyle(subscriptionStatusColor)
                }
                if let expires = appState.subscriptionManager.expirationDate {
                    HStack {
                        Text(appState.subscriptionManager.subscriptionStatus == .trial ? "Trial ends" : "Renews")
                        Spacer()
                        Text(expires, style: .date)
                            .foregroundStyle(.secondary)
                    }
                }
                if appState.subscriptionManager.subscriptionStatus == .grace {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("We're retrying your payment. Check Apple ID settings if this persists.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    showPaywall = true
                } label: {
                    Label("Manage Subscription", systemImage: "star.circle")
                }
                // TODO: Remove before App Store submission
                Toggle(isOn: Binding(
                    get: { appState.subscriptionManager.debugOverride == .subscribed },
                    set: { appState.subscriptionManager.debugOverride = $0 ? .subscribed : .expired }
                )) {
                    Label("Dev: Force Subscribed", systemImage: "ant")
                }
                .tint(.orange)
            }

            #if DEBUG
            Section("My Driving (Debug)") {
                if let profile = appState.debugChildProfile,
                   let device = appState.debugChildDevice {
                    NavigationLink {
                        LocationMapView(
                            child: profile,
                            devices: [device],
                            heartbeats: [],
                            cloudKit: appState.cloudKit,
                            onLocate: {
                                let _ = await appState.locationService?.requestCurrentLocation()
                            }
                        )
                    } label: {
                        Label("Map & Trips", systemImage: "map")
                    }
                }

                HStack {
                    Text("CoreMotion")
                    Spacer()
                    Text(appState.locationService?.motionMonitoringActive == true ? "Active" : "Inactive")
                        .foregroundStyle(appState.locationService?.motionMonitoringActive == true ? .green : .secondary)
                }
                HStack {
                    Text("Moving")
                    Spacer()
                    Text(appState.locationService?.isMoving == true ? "Yes" : "No")
                        .foregroundStyle(appState.locationService?.isMoving == true ? .green : .secondary)
                }
                HStack {
                    Text("Driving")
                    Spacer()
                    Text(appState.drivingMonitor?.isDriving == true ? "Yes" : "No")
                        .foregroundStyle(appState.drivingMonitor?.isDriving == true ? .orange : .secondary)
                }
                if let speed = appState.locationService?.lastLocation?.speed, speed >= 0 {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text("\(Int(speed * 2.237)) mph")
                            .foregroundStyle(.primary)
                    }
                }
                HStack {
                    Text("Tracking")
                    Spacer()
                    Text(appState.locationService?.activeTrackingStartedAt != nil ? "High-frequency" : "Passive")
                        .foregroundStyle(appState.locationService?.activeTrackingStartedAt != nil ? .blue : .secondary)
                }
            }
            #endif

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Build")
                    Spacer()
                    Text("\(AppConstants.appBuildNumber)")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Developer Mode", isOn: Binding(
                    get: { appState.debugMode },
                    set: { appState.debugMode = $0 }
                ))
            } footer: {
                Text("Shows build numbers, diagnostics, and the Insights tab.")
            }
        }
        .navigationTitle("Settings")
        .disabled(isNuking)
        .sheet(isPresented: $showDashboardLayout) {
            DashboardLayoutView(appState: appState)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(subscriptionManager: appState.subscriptionManager) {
                showPaywall = false
            }
        }
        .sheet(isPresented: Binding(
            get: { exportedFileURL != nil },
            set: { if !$0 { exportedFileURL = nil } }
        )) {
            if let url = exportedFileURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Purge All CloudKit Data?", isPresented: $showNukeConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Purge Everything", role: .destructive) {
                Task { await nukeCloudKit() }
            }
        } message: {
            Text("This deletes ALL commands, receipts, events, heartbeats, devices, and policies. Only your family record and schedule templates are kept. You'll need to re-enroll all devices.")
        }
    }

    private func nukeCloudKit() async {
        guard let cloudKit = appState.cloudKit as? CloudKitServiceImpl,
              let familyID = appState.parentState?.familyID else {
            nukeStatus = "Error: CloudKit unavailable"
            return
        }
        isNuking = true
        nukeStatus = "Purging..."

        let allPredicate = NSPredicate(format: "%K == %@", "familyID", familyID.rawValue)
        let truePredicate = NSPredicate(value: true)
        var total = 0

        let typesToDelete = [
            CKRecordType.remoteCommand,
            CKRecordType.commandReceipt,
            CKRecordType.eventLog,
            CKRecordType.heartbeat,
            CKRecordType.childDevice,
            CKRecordType.policy,
            CKRecordType.enrollmentInvite,
            CKRecordType.schedule,
        ]

        for type in typesToDelete {
            do {
                // Try familyID filter first, fall back to true predicate.
                let count = try await cloudKit.deleteRecords(type: type, predicate: allPredicate)
                total += count
                nukeStatus = "Purging... \(total) deleted"
            } catch {
                // Some record types might not have familyID field indexed.
                let count = (try? await cloudKit.deleteRecords(type: type, predicate: truePredicate)) ?? 0
                total += count
            }
        }

        // Clear local state.
        appState.childProfiles = []
        appState.childDevices = []
        appState.latestHeartbeats = []
        appState.approvedApps = []

        nukeStatus = "Done — \(total) records deleted"
        isNuking = false
    }

    private func exportData() async {
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else {
            exportError = "CloudKit unavailable"
            return
        }
        isExporting = true
        exportError = nil
        do {
            let data = try await FamilyDataExporter.exportAllData(cloudKit: cloudKit, familyID: familyID)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("BigBrother-Export-\(Date().ISO8601Format()).json")
            try data.write(to: url)
            exportedFileURL = url
        } catch {
            exportError = CloudKitErrorHelper.userMessage(for: error)
        }
        isExporting = false
    }

    private func copyEnforcementLog() async {
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else {
            logCopyStatus = "CloudKit unavailable"
            return
        }
        isCopyingLog = true
        logCopyStatus = nil
        do {
            let since = Calendar.current.startOfDay(for: Date())
            let records = try await cloudKit.fetchEnforcementLogs(familyID: familyID, since: since)

            // Build device name map from child devices
            let deviceNames: [String: String] = Dictionary(
                appState.childDevices.map { ($0.id.rawValue, $0.displayName) },
                uniquingKeysWith: { first, _ in first }
            )

            // Format as text
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm:ss a"

            let sorted = records.sorted { r1, r2 in
                let t1 = (r1[CKFieldName.timestamp] as? Date) ?? .distantPast
                let t2 = (r2[CKFieldName.timestamp] as? Date) ?? .distantPast
                return t1 < t2
            }

            var lines: [String] = ["=== Enforcement Log \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)) ===\n"]
            for record in sorted {
                let deviceID = record[CKFieldName.deviceID] as? String ?? "?"
                let name = deviceNames[deviceID] ?? deviceID.prefix(8).description
                let time = formatter.string(from: (record[CKFieldName.timestamp] as? Date) ?? Date())
                let cat = record[CKFieldName.enfCategory] as? String ?? ""
                let msg = record[CKFieldName.enfMessage] as? String ?? ""
                let details = record[CKFieldName.enfDetails] as? String
                let build = record[CKFieldName.enfBuild] as? Int ?? 0
                let detail = details.map { " | \($0)" } ?? ""
                lines.append("[\(name)] \(time) [\(cat)] \(msg)\(detail) (b\(build))")
            }

            let text = lines.joined(separator: "\n")
            UIPasteboard.general.string = text
            logCopyStatus = "Copied \(records.count) entries"
        } catch {
            logCopyStatus = "Failed: \(error.localizedDescription)"
        }
        isCopyingLog = false
    }

    private var subscriptionStatusColor: Color {
        switch appState.subscriptionManager.subscriptionStatus {
        case .subscribed: return .green
        case .trial: return appState.subscriptionManager.isTrialEndingSoon ? .orange : .blue
        case .grace: return .orange
        case .expired, .revoked: return .red
        case .unknown: return .secondary
        }
    }

    @ViewBuilder
    private var cloudKitStatusView: some View {
        List {
            Section("CloudKit Container") {
                HStack {
                    Text("Container")
                    Spacer()
                    Text(AppConstants.cloudKitContainerIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Database")
                    Spacer()
                    Text("Public")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Account Status")
                    Spacer()
                    if let status = appState.cloudKitStatusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Available")
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Sync") {
                HStack {
                    Text("Children synced")
                    Spacer()
                    Text("\(appState.childProfiles.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Devices synced")
                    Spacer()
                    Text("\(appState.childDevices.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("CloudKit Status")
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
