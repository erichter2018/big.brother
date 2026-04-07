import SwiftUI
import UIKit
import CoreLocation
import BigBrotherCore

/// Debug tab for testing driving detection features on the parent device.
/// Shows real-time CoreMotion/GPS status and links to the full map & trips view.
struct MyDrivingDebugView: View {
    let appState: AppState
    @State private var refreshTick = 0
    @State private var timer: Timer?
    @State private var copyFeedback = false

    private var loc: LocationService? { appState.locationService }
    private var driving: DrivingMonitor? { appState.drivingMonitor }

    var body: some View {
        List {
            // Real-time status
            Section("Status") {
                statusRow("CoreMotion", value: loc?.motionMonitoringActive == true ? "Active" : "Inactive",
                          color: loc?.motionMonitoringActive == true ? .green : .red)
                statusRow("Moving", value: loc?.isMoving == true ? "Yes" : "No",
                          color: loc?.isMoving == true ? .green : .secondary)
                statusRow("Driving", value: driving?.isDriving == true ? "Yes" : "No",
                          color: driving?.isDriving == true ? .orange : .secondary)
                statusRow("Tracking", value: loc?.activeTrackingStartedAt != nil ? "High-frequency" : "Passive",
                          color: loc?.activeTrackingStartedAt != nil ? .blue : .secondary)

                if let speed = loc?.lastLocation?.speed, speed >= 0 {
                    let mph = Int(speed * 2.237)
                    let limitStr = driving?.currentSpeedLimitMPH.map { " / \($0) limit" } ?? ""
                    let overLimit = driving?.currentSpeedLimitMPH.map { mph > $0 + 10 } ?? false
                    statusRow("Speed", value: "\(mph) mph\(limitStr)",
                              color: overLimit ? .red : .primary)
                } else {
                    statusRow("Speed", value: "—", color: .secondary)
                }

                if let limit = driving?.currentSpeedLimitMPH {
                    statusRow("Posted Limit", value: "\(limit) mph", color: .blue)
                }

                if let acc = loc?.lastLocation?.horizontalAccuracy {
                    statusRow("GPS Accuracy", value: "\(Int(acc))m", color: acc < 20 ? .green : .orange)
                }

                statusRow("Breadcrumb Interval", value: "\(Int(loc?.breadcrumbInterval ?? 300))s",
                          color: (loc?.breadcrumbInterval ?? 300) <= 60 ? .blue : .secondary)
                statusRow("Location Mode", value: loc?.mode.rawValue ?? "nil", color: .secondary)
            }

            // Map & Trips
            Section {
                #if DEBUG
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
                #endif
            }

            // Copy full report
            Section {
                Button {
                    Task { await copyFullReport() }
                } label: {
                    Label(copyFeedback ? "Copied!" : "Copy Full Driving Report", systemImage: "doc.on.doc")
                }
            }

            // Recent diagnostic log entries
            Section("Recent Logs") {
                let logs = AppGroupStorage().readDiagnosticEntries(category: nil)
                    .filter { $0.message.hasPrefix("[Location]") || $0.message.hasPrefix("[Driving]") }
                    .suffix(15)
                    .reversed()
                if logs.isEmpty {
                    Text("No driving logs yet. Start driving to see entries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(logs), id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.caption)
                            if let details = entry.details {
                                Text(details)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .navigationTitle("My Driving")
        .onAppear { startRefresh() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    @ViewBuilder
    private func statusRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(color)
        }
        .font(.subheadline)
        .id("\(label)-\(refreshTick)")
    }

    private func startRefresh() {
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            refreshTick += 1
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func copyFullReport() async {
        var lines: [String] = []
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm:ss a"

        lines.append("=== MY DRIVING DEBUG REPORT ===")
        lines.append("Time: \(timeFmt.string(from: Date()))")
        lines.append("Build: b\(AppConstants.appBuildNumber)")
        lines.append("")

        // Status
        lines.append("--- STATUS ---")
        lines.append("CoreMotion Active: \(loc?.motionMonitoringActive ?? false)")
        lines.append("Moving: \(loc?.isMoving ?? false)")
        lines.append("Driving: \(driving?.isDriving ?? false)")
        lines.append("Tracking: \(loc?.activeTrackingStartedAt != nil ? "High-frequency" : "Passive")")
        lines.append("Breadcrumb Interval: \(Int(loc?.breadcrumbInterval ?? 300))s")
        lines.append("Location Mode: \(loc?.mode.rawValue ?? "nil")")
        lines.append("Posted Speed Limit: \(driving?.currentSpeedLimitMPH.map { "\($0) mph" } ?? "unknown")")
        if let speed = loc?.lastLocation?.speed, speed >= 0 {
            lines.append("Speed: \(Int(speed * 2.237)) mph")
        }
        if let acc = loc?.lastLocation?.horizontalAccuracy {
            lines.append("GPS Accuracy: \(Int(acc))m")
        }
        lines.append("")

        // Breadcrumbs from CloudKit
        #if DEBUG
        if let cloudKit = appState.cloudKit,
           let debugDevice = appState.debugChildDevice {
            let since = Date().addingTimeInterval(-24 * 3600)
            if let crumbs = try? await cloudKit.fetchLocationBreadcrumbs(deviceID: debugDevice.id, since: since) {
                let sorted = crumbs.sorted { $0.timestamp < $1.timestamp }
                lines.append("--- BREADCRUMBS (last 24h: \(sorted.count) total) ---")
                var prevLoc: CLLocation?
                for (i, c) in sorted.suffix(100).enumerated() {
                    let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    let dist = prevLoc.map { loc.distance(from: $0) } ?? 0
                    let gap: TimeInterval
                    if i > 0, let prev = sorted.suffix(100).dropFirst(i - 1).first {
                        gap = c.timestamp.timeIntervalSince(prev.timestamp)
                    } else {
                        gap = 0
                    }
                    let speedStr = c.speed.map { $0 >= 0 ? "\(Int($0 * 2.237))mph" : "invalid" } ?? "nil"
                    lines.append("\(timeFmt.string(from: c.timestamp)) | \(String(format: "%.4f,%.4f", c.latitude, c.longitude)) | speed=\(speedStr) | dist=\(Int(dist))m | gap=\(Int(gap))s | acc=\(Int(c.horizontalAccuracy))m")
                    prevLoc = loc
                }
            } else {
                lines.append("--- BREADCRUMBS: fetch failed ---")
            }
        }
        #endif
        lines.append("")

        // Diagnostic logs
        let logs = AppGroupStorage().readDiagnosticEntries(category: nil)
            .filter { $0.message.hasPrefix("[Location]") || $0.message.hasPrefix("[Driving]") }
            .suffix(100)
        lines.append("--- DRIVING LOGS (last \(logs.count)) ---")
        for entry in logs {
            var line = "[\(timeFmt.string(from: entry.timestamp))] \(entry.message)"
            if let details = entry.details {
                line += " | \(details)"
            }
            lines.append(line)
        }

        UIPasteboard.general.string = lines.joined(separator: "\n")
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copyFeedback = false }
    }
}
