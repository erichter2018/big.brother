import SwiftUI
import BigBrotherCore

/// Parent view for real-time device diagnostics.
/// Primary view: structured heartbeat snapshot (instant, no round-trip).
/// Secondary: "Refresh Now" sends requestHeartbeat command + polls for fresh data.
/// Tertiary: full diagnostic report for deep dives.
struct RemoteDiagnosticsView: View {
    let appState: AppState
    let child: ChildProfile
    let devices: [ChildDevice]

    @State private var isRefreshing = false
    @State private var refreshingDeviceID: DeviceID?
    @State private var reports: [DiagnosticReport] = []
    @State private var isLoadingReports = false
    @State private var copyFeedback: DeviceID?

    var body: some View {
        List {
            // Primary: live structured snapshots from heartbeats
            ForEach(devices, id: \.id) { device in
                if let parsed = parsedSnapshot(for: device) {
                    snapshotSection(device: device, snapshot: parsed.snapshot, age: parsed.age)
                } else if let raw = rawSnapshot(for: device) {
                    // Fallback for old builds that send freeform string
                    legacySnapshotSection(device: device, text: raw.text, age: raw.age)
                }
            }

            // Refresh controls
            Section {
                ForEach(devices, id: \.id) { device in
                    Button {
                        Task { await refreshDevice(device) }
                    } label: {
                        HStack {
                            let name = DeviceIcon.displayName(for: device.modelIdentifier)
                            let icon = device.modelIdentifier.lowercased().contains("ipad") ? "ipad" : "iphone"
                            Label(isRefreshing && refreshingDeviceID == device.id
                                  ? "Refreshing..." : "Refresh \(name)",
                                  systemImage: icon)
                            Spacer()
                            if isRefreshing && refreshingDeviceID == device.id {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRefreshing)
                }

                if devices.count > 1 {
                    Button {
                        Task { await refreshAllDevices() }
                    } label: {
                        HStack {
                            Label(isRefreshing && refreshingDeviceID == nil
                                  ? "Refreshing..." : "Refresh All",
                                  systemImage: "arrow.clockwise")
                            Spacer()
                            if isRefreshing && refreshingDeviceID == nil {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRefreshing)
                }
            } header: {
                Text("Quick Refresh")
            } footer: {
                Text("Sends a heartbeat request. Results appear in 2-5 seconds if the app is running.")
            }

            // Deep dive: full diagnostic reports
            Section {
                Button {
                    Task { await requestFullDiagnostics() }
                } label: {
                    HStack {
                        Label(isLoadingReports ? "Requesting..." : "Full Diagnostic Report",
                              systemImage: "stethoscope")
                        Spacer()
                        if isLoadingReports { ProgressView() }
                    }
                }
                .disabled(isLoadingReports)
            } header: {
                Text("Deep Dive")
            } footer: {
                Text("Collects full state dump — slower but more comprehensive than heartbeat.")
            }

            // Show any fetched full reports
            ForEach(reports) { report in
                fullReportSection(report)
            }
        }
        .navigationTitle("Diagnostics")
    }

    // MARK: - Parsed Snapshot

    private struct ParsedResult {
        let snapshot: DiagnosticSnapshot
        let age: TimeInterval
    }

    private func parsedSnapshot(for device: ChildDevice) -> ParsedResult? {
        guard let hb = appState.latestHeartbeats.first(where: { $0.deviceID == device.id }),
              let raw = hb.diagnosticSnapshot, !raw.isEmpty,
              let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(DiagnosticSnapshot.self, from: data) else { return nil }
        return ParsedResult(snapshot: snapshot, age: Date().timeIntervalSince(hb.timestamp))
    }

    private struct RawResult {
        let text: String
        let age: TimeInterval
    }

    private func rawSnapshot(for device: ChildDevice) -> RawResult? {
        guard let hb = appState.latestHeartbeats.first(where: { $0.deviceID == device.id }),
              let raw = hb.diagnosticSnapshot, !raw.isEmpty else { return nil }
        // If JSON parsing failed, it's a legacy freeform string
        if let data = raw.data(using: .utf8),
           (try? JSONDecoder().decode(DiagnosticSnapshot.self, from: data)) != nil {
            return nil // It's JSON, handled by parsedSnapshot
        }
        return RawResult(text: raw, age: Date().timeIntervalSince(hb.timestamp))
    }

    // MARK: - Structured Snapshot View

    @ViewBuilder
    private func snapshotSection(device: ChildDevice, snapshot: DiagnosticSnapshot, age: TimeInterval) -> some View {
        let name = DeviceIcon.displayName(for: device.modelIdentifier)

        Section {
            // Header
            HStack {
                Text(name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(formatAge(age)).font(.caption).foregroundStyle(.tertiary)
                copyButton(device: device, snapshot: snapshot)
            }

            // Mode + Shield Status (the most important info)
            HStack(spacing: 12) {
                modeChip(snapshot.mode)
                Spacer()
                shieldIndicator(up: snapshot.shieldsUp, expected: snapshot.shieldsExpected)
            }
            .padding(.vertical, 2)

            // Authority + Reason
            diagRow("Authority", snapshot.authority)
            diagRow("Reason", snapshot.reason)

            // Temporary state
            if snapshot.isTemporary, let remaining = snapshot.tempUnlockRemaining {
                diagRow("Expires", "\(remaining / 60)m \(remaining % 60)s")
                if let origin = snapshot.tempUnlockOrigin {
                    diagRow("Origin", origin)
                }
            }

            // Shield details
            if snapshot.shieldsUp {
                diagRow("Shielded Apps", "\(snapshot.shieldedAppCount)")
                diagRow("Web Blocked", snapshot.webBlocked ? "Yes" : "No")
            }
            if let reason = snapshot.shieldReason {
                diagRow("Shield Reason", reason)
            }

            // Restrictions & Internet
            if snapshot.denyWebWhenRestricted == true {
                diagRow("denyWebWhenRestricted", "ON")
                    .foregroundStyle(.orange)
            }
            if snapshot.internetBlocked == true {
                diagRow("Internet", "BLOCKED (\(snapshot.internetBlockReason ?? "?"))")
                    .foregroundStyle(.red)
            }
            if let dns = snapshot.dnsBlockedDomains, dns > 0 {
                diagRow("DNS Blocked", "\(dns) domains")
            }

            // Schedule
            if let sched = snapshot.scheduleName {
                diagRow("Schedule", "\(sched)\(snapshot.scheduleDriven ? "" : " (manual)")")
                if let window = snapshot.scheduleWindow {
                    diagRow("Window", window)
                }
            }

            // Component health
            buildsRow(snapshot.builds)
            livenessRow(monitorAge: snapshot.monitorAge, tunnelAge: snapshot.tunnelAge,
                       tunnelConnected: snapshot.tunnelConnected)

            // Transitions — THE KEY DATA
            if !snapshot.transitions.isEmpty {
                DisclosureGroup("Transitions (\(snapshot.transitions.count))") {
                    ForEach(Array(snapshot.transitions.reversed().enumerated()), id: \.offset) { _, t in
                        transitionRow(t)
                    }
                }
            }

            // Recent enforcement logs
            if !snapshot.recentLogs.isEmpty {
                DisclosureGroup("Enforcement Log (\(snapshot.recentLogs.count))") {
                    ForEach(Array(snapshot.recentLogs.reversed().enumerated()), id: \.offset) { _, log in
                        HStack(alignment: .top) {
                            Text(formatTime(log.at))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .frame(width: 75, alignment: .leading)
                            Text(log.msg)
                                .font(.caption2)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    // MARK: - Mode + Shield Chips

    @ViewBuilder
    private func modeChip(_ mode: String) -> some View {
        let color: Color = switch mode {
        case "unlocked": .green
        case "restricted": .orange
        case "locked": .red
        case "lockedDown": .purple
        default: .gray
        }
        Text(mode.uppercased())
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func shieldIndicator(up: Bool, expected: Bool) -> some View {
        let match = up == expected
        HStack(spacing: 4) {
            Image(systemName: up ? "shield.fill" : "shield.slash")
                .font(.caption)
            Text(up ? "UP" : "DOWN")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(match ? (up ? .blue : .green) : .red)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(match ? Color.clear : Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            if !match {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
            }
        }
    }

    // MARK: - Transition Row

    @ViewBuilder
    private func transitionRow(_ t: DiagnosticSnapshot.TransitionEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(formatTime(t.at))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 2) {
                    modeChip(t.from)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    modeChip(t.to)
                }
            }
            HStack {
                Text(t.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let shieldsUp = t.shieldsUp {
                    Text("shields: \(shieldsUp ? "UP" : "DOWN")")
                        .font(.caption2)
                        .foregroundStyle(shieldsUp ? .blue : .green)
                }
            }
            if !t.changes.isEmpty {
                ForEach(t.changes, id: \.self) { change in
                    Text(change)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Builds + Liveness

    @ViewBuilder
    private func buildsRow(_ b: DiagnosticSnapshot.ComponentBuilds) -> some View {
        let allMatch = [b.tunnel, b.monitor, b.shield, b.shieldAction].allSatisfy { $0 == b.app || $0 == 0 }
        HStack {
            Text("Builds")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if allMatch {
                Text("b\(b.app)")
                    .font(.caption.monospaced())
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                Text("app:\(b.app) tun:\(b.tunnel) mon:\(b.monitor) sh:\(b.shield) act:\(b.shieldAction)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func livenessRow(monitorAge: Int?, tunnelAge: Int?, tunnelConnected: Bool?) -> some View {
        HStack {
            Text("Liveness")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 8) {
                livenessChip("Mon", age: monitorAge)
                livenessChip("Tun", age: tunnelAge)
                if tunnelConnected == false {
                    Text("VPN OFF")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func livenessChip(_ label: String, age: Int?) -> some View {
        let color: Color = {
            guard let age else { return .gray }
            if age < 120 { return .green }
            if age < 600 { return .orange }
            return .red
        }()
        HStack(spacing: 2) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
            if let age {
                Text(age < 60 ? "\(age)s" : "\(age / 60)m")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("?")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
    }

    // MARK: - Legacy Snapshot (old builds)

    @ViewBuilder
    private func legacySnapshotSection(device: ChildDevice, text: String, age: TimeInterval) -> some View {
        Section {
            HStack {
                Text(DeviceIcon.displayName(for: device.modelIdentifier))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(formatAge(age)).font(.caption).foregroundStyle(.tertiary)
                Text("(legacy)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    // MARK: - Full Report Section

    @ViewBuilder
    private func fullReportSection(_ report: DiagnosticReport) -> some View {
        Section {
            HStack {
                let deviceName = devices.first(where: { $0.id == report.deviceID })
                    .map { DeviceIcon.displayName(for: $0.modelIdentifier) } ?? report.deviceID.rawValue
                Text(deviceName)
                    .font(.subheadline.weight(.medium))
                Text("b\(report.appBuildNumber)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatAge(Date().timeIntervalSince(report.timestamp)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                UIPasteboard.general.string = formatReportAsText(report)
                copyFeedback = report.deviceID
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copyFeedback = nil }
            } label: {
                Label(copyFeedback == report.deviceID ? "Copied!" : "Copy Full Report",
                      systemImage: "doc.on.doc")
            }

            diagRow("Mode", report.currentMode)
            diagRow("Shields", report.shieldsActive ? "UP" : "DOWN")
            diagRow("Shield Apps", "\(report.shieldedAppCount)")
            diagRow("FC Auth", report.familyControlsAuth)

            DisclosureGroup("Flags (\(report.flags.count))") {
                ForEach(report.flags.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    diagRow(key, value)
                }
            }

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
            Text("Full Report — \(formatTimestamp(report.timestamp))")
        }
    }

    // MARK: - Copy Button

    @ViewBuilder
    private func copyButton(device: ChildDevice, snapshot: DiagnosticSnapshot) -> some View {
        Button {
            UIPasteboard.general.string = formatSnapshotAsText(snapshot, device: device)
            copyFeedback = device.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copyFeedback = nil }
        } label: {
            Image(systemName: copyFeedback == device.id ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copyFeedback == device.id ? .green : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

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
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Actions

    /// Send requestHeartbeat command + poll for fresh heartbeat data.
    private func refreshDevice(_ device: ChildDevice) async {
        isRefreshing = true
        refreshingDeviceID = device.id
        defer { isRefreshing = false; refreshingDeviceID = nil }

        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }

        let command = RemoteCommand(
            familyID: familyID,
            target: .device(device.id),
            action: .requestHeartbeat,
            issuedBy: "Parent"
        )
        try? await cloudKit.pushCommand(command)

        // Progressive poll: check every 2s for up to 12s for a fresh heartbeat.
        let requestedAt = Date()
        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            // Refresh heartbeats from CloudKit
            if let familyID = appState.parentState?.familyID {
                let fresh = try? await cloudKit.fetchLatestHeartbeats(familyID: familyID)
                if let fresh {
                    await MainActor.run { appState.latestHeartbeats = fresh }
                    // Check if we got a heartbeat newer than our request
                    if let hb = fresh.first(where: { $0.deviceID == device.id }),
                       hb.timestamp > requestedAt {
                        return  // Got fresh data
                    }
                }
            }
        }
    }

    private func refreshAllDevices() async {
        isRefreshing = true
        refreshingDeviceID = nil
        defer { isRefreshing = false }

        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }

        let command = RemoteCommand(
            familyID: familyID,
            target: .child(child.id),
            action: .requestHeartbeat,
            issuedBy: "Parent"
        )
        try? await cloudKit.pushCommand(command)

        let requestedAt = Date()
        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            if let fresh = try? await cloudKit.fetchLatestHeartbeats(familyID: familyID) {
                await MainActor.run { appState.latestHeartbeats = fresh }
                let allFresh = devices.allSatisfy { device in
                    fresh.first(where: { $0.deviceID == device.id })?.timestamp ?? .distantPast > requestedAt
                }
                if allFresh { return }
            }
        }
    }

    private func requestFullDiagnostics() async {
        isLoadingReports = true
        defer { isLoadingReports = false }

        guard let cloudKit = appState.cloudKit,
              let familyID = appState.parentState?.familyID else { return }

        let command = RemoteCommand(
            familyID: familyID,
            target: .child(child.id),
            action: .requestDiagnostics,
            issuedBy: "Parent"
        )
        try? await cloudKit.pushCommand(command)

        // Progressive poll for reports
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(2))
            var allReports: [DiagnosticReport] = []
            for device in devices {
                if let deviceReports = try? await cloudKit.fetchDiagnosticReports(deviceID: device.id) {
                    let sorted = deviceReports.sorted { $0.timestamp > $1.timestamp }
                    allReports.append(contentsOf: sorted.prefix(3))
                    // Cleanup old
                    for staleID in sorted.dropFirst(3).map({ $0.id.uuidString }) {
                        let predicate = NSPredicate(format: "recordID.recordName == %@",
                                                    "BBDiagnosticReport_\(staleID)")
                        _ = try? await cloudKit.deleteRecords(type: "BBDiagnosticReport",
                                                              predicate: predicate, limit: 1)
                    }
                }
            }
            if !allReports.isEmpty {
                reports = allReports.sorted { $0.timestamp > $1.timestamp }
                return
            }
        }
    }

    // MARK: - Formatting

    private func formatAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f.string(from: date)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    /// Copy structured snapshot as text for pasting to Claude/chat.
    private func formatSnapshotAsText(_ s: DiagnosticSnapshot, device: ChildDevice) -> String {
        var lines: [String] = []
        let name = DeviceIcon.displayName(for: device.modelIdentifier)
        lines.append("=== \(name) DIAGNOSTIC ===")
        lines.append("Mode: \(s.mode) (\(s.authority))")
        lines.append("Reason: \(s.reason)")
        lines.append("Shields: \(s.shieldsUp ? "UP" : "DOWN") (expected: \(s.shieldsExpected ? "UP" : "DOWN"))")
        if s.shieldsUp {
            lines.append("Shielded Apps: \(s.shieldedAppCount), Web: \(s.webBlocked ? "blocked" : "open")")
        }
        if let reason = s.shieldReason { lines.append("Shield Reason: \(reason)") }
        if let audit = s.shieldAudit { lines.append("Audit: \(audit)") }
        if s.isTemporary, let r = s.tempUnlockRemaining {
            lines.append("Temp Unlock: \(r)s remaining (\(s.tempUnlockOrigin ?? "?"))")
        }
        if let sched = s.scheduleName {
            lines.append("Schedule: \(sched)\(s.scheduleDriven ? "" : " (manual)") — \(s.scheduleWindow ?? "?")")
        }
        if s.denyWebWhenRestricted == true { lines.append("denyWebWhenRestricted: ON") }
        if s.internetBlocked == true { lines.append("Internet: BLOCKED (\(s.internetBlockReason ?? "?"))") }
        if let dns = s.dnsBlockedDomains, dns > 0 { lines.append("DNS Blocked: \(dns) domains") }
        lines.append("Builds: app=b\(s.builds.app) tunnel=b\(s.builds.tunnel) monitor=b\(s.builds.monitor) shield=b\(s.builds.shield) action=b\(s.builds.shieldAction)")
        lines.append("Monitor: \(s.monitorAge.map { "\($0)s ago" } ?? "?"), Tunnel: \(s.tunnelAge.map { "\($0)s ago" } ?? "?")")
        lines.append("LastPush: \(s.lastPushAge.map { "\($0)s ago" } ?? "NEVER"), APNs: \(s.apnsTokenAge.map { "\($0)s ago" } ?? "NEVER")")

        if !s.transitions.isEmpty {
            lines.append("\n--- TRANSITIONS ---")
            for t in s.transitions.reversed() {
                let time = formatTime(t.at)
                lines.append("[\(time)] \(t.from) → \(t.to) (\(t.source))")
                for c in t.changes { lines.append("  \(c)") }
            }
        }

        // Interleave parent-sent commands with child enforcement log.
        // This reveals delivery delays: parent sent at X, child received at Y.
        let parentCmds = appState.sentCommandLog
            .filter { $0.childID == child.id }
            .map { (at: $0.at, line: "[par] SENT: \($0.action)") }

        let childLogs = s.recentLogs.map { (at: $0.at, line: $0.msg) }

        let merged = (parentCmds + childLogs).sorted { $0.at < $1.at }

        if !merged.isEmpty {
            lines.append("\n--- TIMELINE (parent sent + child log) ---")
            for entry in merged.reversed() {
                lines.append("[\(formatTime(entry.at))] \(entry.line)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatReportAsText(_ r: DiagnosticReport) -> String {
        var lines: [String] = []
        lines.append("=== FULL DIAGNOSTIC REPORT ===")
        lines.append("Time: \(formatTimestamp(r.timestamp))")
        lines.append("Build: b\(r.appBuildNumber)")
        lines.append("Mode: \(r.currentMode)")
        lines.append("Shields: \(r.shieldsActive ? "UP" : "DOWN")")
        lines.append("Apps: \(r.shieldedAppCount), Category: \(r.shieldCategoryActive)")
        lines.append("VPN: \(r.vpnTunnelStatus), FC: \(r.familyControlsAuth)")
        lines.append("")
        for (key, value) in r.flags.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        for entry in r.recentLogs {
            let time = formatTime(entry.timestamp)
            var line = "[\(time)] [\(entry.category.rawValue)] \(entry.message)"
            if let details = entry.details { line += " | \(details)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
