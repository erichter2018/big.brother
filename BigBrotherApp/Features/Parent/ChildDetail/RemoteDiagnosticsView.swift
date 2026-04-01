import SwiftUI
import BigBrotherCore

/// Parent view to request and display diagnostic reports from child devices.
/// Supports per-device targeting and retains only the 5 most recent reports per device.
struct RemoteDiagnosticsView: View {
    let appState: AppState
    let child: ChildProfile
    let devices: [ChildDevice]

    @State private var reports: [DiagnosticReport] = []
    @State private var isLoading = false
    @State private var isRequesting = false
    @State private var requestingDeviceID: DeviceID?
    @State private var copyFeedback = false

    var body: some View {
        List {
            // Per-device request buttons
            Section {
                // Request from all devices
                Button {
                    Task { await requestDiagnostics(target: .child(child.id)) }
                } label: {
                    HStack {
                        Label(isRequesting && requestingDeviceID == nil
                              ? "Requesting..." : "All Devices",
                              systemImage: "stethoscope")
                        Spacer()
                        if isRequesting && requestingDeviceID == nil {
                            ProgressView()
                        }
                    }
                }
                .disabled(isRequesting)

                // Per-device buttons
                ForEach(devices, id: \.id) { device in
                    Button {
                        Task { await requestDiagnostics(target: .device(device.id), deviceID: device.id) }
                    } label: {
                        HStack {
                            let name = DeviceIcon.displayName(for: device.modelIdentifier)
                            let icon = device.modelIdentifier.lowercased().contains("ipad") ? "ipad" : "iphone"
                            Label(isRequesting && requestingDeviceID == device.id
                                  ? "Requesting..." : name,
                                  systemImage: icon)
                            Spacer()
                            if isRequesting && requestingDeviceID == device.id {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRequesting)
                }

                Button {
                    Task { await loadReports() }
                } label: {
                    Label("Refresh Reports", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Request Diagnostic")
            } footer: {
                Text("Request from a specific device or all at once. Reports appear once the device processes the command.")
            }

            // Reports
            if isLoading && reports.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading reports...")
                        Spacer()
                    }
                }
            } else if reports.isEmpty {
                Section {
                    Text("No diagnostic reports yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(reports) { report in
                    reportSection(report)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .task { await loadReports() }
    }

    // MARK: - Report Display

    @ViewBuilder
    private func reportSection(_ report: DiagnosticReport) -> some View {
        let age = formatAge(Date().timeIntervalSince(report.timestamp))

        Section {
            // Header — show device name so multi-device kids are clear
            HStack {
                let deviceName = devices.first(where: { $0.id == report.deviceID })
                    .map { DeviceIcon.displayName(for: $0.modelIdentifier) } ?? report.deviceID.rawValue
                Text(deviceName)
                    .font(.subheadline.weight(.medium))
                Text("b\(report.appBuildNumber)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(age)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Copy All button
            Button {
                UIPasteboard.general.string = formatReportAsText(report)
                copyFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copyFeedback = false }
            } label: {
                Label(copyFeedback ? "Copied!" : "Copy Full Report", systemImage: "doc.on.doc")
            }

            // State summary
            Group {
                diagRow("Mode", report.currentMode)
                diagRow("Shields Active", report.shieldsActive ? "Yes" : "No")
                diagRow("Shield Apps", "\(report.shieldedAppCount)")
                diagRow("Category Active", report.shieldCategoryActive ? "Yes" : "No")
                diagRow("Shield Reason", report.lastShieldChangeReason ?? "none")
            }

            Group {
                diagRow("Location Mode", report.locationMode)
                diagRow("CoreMotion Available", report.coreMotionAvailable ? "Yes" : "No")
                diagRow("Is Moving", report.isMoving ? "Yes" : "No")
                diagRow("Is Driving", report.isDriving ? "Yes" : "No")
                diagRow("VPN Tunnel", report.vpnTunnelStatus)
                diagRow("FC Auth", report.familyControlsAuth)
            }

            // Flags
            DisclosureGroup("Flags (\(report.flags.count))") {
                ForEach(report.flags.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    diagRow(key, value)
                }
            }

            // Recent logs
            DisclosureGroup("Logs (\(report.recentLogs.count))") {
                ForEach(report.recentLogs.suffix(20).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.category.rawValue)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.blue)
                            Spacer()
                            Text(formatTime(entry.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.caption)
                        if let details = entry.details {
                            Text(details)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text(formatTimestamp(report.timestamp))
        }
    }

    @ViewBuilder
    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - Actions

    private func requestDiagnostics(target: CommandTarget, deviceID: DeviceID? = nil) async {
        isRequesting = true
        requestingDeviceID = deviceID
        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else {
            isRequesting = false
            requestingDeviceID = nil
            return
        }

        let command = RemoteCommand(
            familyID: familyID,
            target: target,
            action: .requestDiagnostics,
            issuedBy: "Parent"
        )
        try? await cloudKit.pushCommand(command)

        // Wait then refresh
        try? await Task.sleep(for: .seconds(5))
        await loadReports()
        isRequesting = false
        requestingDeviceID = nil
    }

    private func loadReports() async {
        isLoading = true
        guard let cloudKit = appState.cloudKit else {
            isLoading = false
            return
        }

        var allReports: [DiagnosticReport] = []
        for device in devices {
            if let deviceReports = try? await cloudKit.fetchDiagnosticReports(deviceID: device.id) {
                // Keep only the 5 most recent per device
                let sorted = deviceReports.sorted { $0.timestamp > $1.timestamp }
                allReports.append(contentsOf: sorted.prefix(5))

                // Delete older reports from CloudKit
                if sorted.count > 5 {
                    let staleIDs = sorted.dropFirst(5).map { $0.id.uuidString }
                    for staleID in staleIDs {
                        let predicate = NSPredicate(format: "recordID.recordName == %@",
                                                    "BBDiagnosticReport_\(staleID)")
                        _ = try? await cloudKit.deleteRecords(
                            type: "BBDiagnosticReport",
                            predicate: predicate,
                            limit: 1
                        )
                    }
                }
            }
        }
        reports = allReports.sorted { $0.timestamp > $1.timestamp }
        isLoading = false
    }

    // MARK: - Formatting

    private func formatAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }

    private func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f.string(from: date)
    }

    /// Format the entire report as plain text for clipboard.
    private func formatReportAsText(_ r: DiagnosticReport) -> String {
        var lines: [String] = []
        lines.append("=== DIAGNOSTIC REPORT ===")
        lines.append("Time: \(formatTimestamp(r.timestamp))")
        lines.append("Build: b\(r.appBuildNumber)")
        lines.append("Device: \(r.deviceID.rawValue)")
        lines.append("")
        lines.append("--- STATE ---")
        lines.append("Mode: \(r.currentMode)")
        lines.append("Shields Active: \(r.shieldsActive)")
        lines.append("Shielded Apps: \(r.shieldedAppCount)")
        lines.append("Category Active: \(r.shieldCategoryActive)")
        lines.append("Shield Reason: \(r.lastShieldChangeReason ?? "none")")
        lines.append("Location Mode: \(r.locationMode)")
        lines.append("CoreMotion Available: \(r.coreMotionAvailable)")
        lines.append("Is Moving: \(r.isMoving)")
        lines.append("Is Driving: \(r.isDriving)")
        lines.append("VPN Tunnel: \(r.vpnTunnelStatus)")
        lines.append("FC Auth: \(r.familyControlsAuth)")
        lines.append("")
        lines.append("--- FLAGS ---")
        for (key, value) in r.flags.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("--- LOGS (last \(r.recentLogs.count)) ---")
        for entry in r.recentLogs {
            let time = formatTime(entry.timestamp)
            var line = "[\(time)] [\(entry.category.rawValue)] \(entry.message)"
            if let details = entry.details {
                line += " | \(details)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
