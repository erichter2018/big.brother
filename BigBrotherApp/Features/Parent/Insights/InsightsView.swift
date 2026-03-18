import SwiftUI
import Charts
import BigBrotherCore

/// Command delivery insights and device health analytics.
struct InsightsView: View {
    @Bindable var viewModel: InsightsViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Time range picker
                Picker("Time Range", selection: $viewModel.timeRange) {
                    ForEach(InsightsTimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.timeRange) { _, _ in
                    Task { await viewModel.load() }
                }

                if viewModel.isLoading {
                    ProgressView("Loading insights...")
                        .padding(.top, 40)
                } else if let error = viewModel.errorMessage {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if let summary = viewModel.familySummary {
                    familySummaryCard(summary)
                    if !viewModel.lockPrecisionRecords.isEmpty {
                        lockPrecisionSection
                    }
                    if !viewModel.scheduleTransitionRecords.isEmpty {
                        schedulePrecisionSection
                    }
                    if !viewModel.bucketCounts.isEmpty {
                        latencyHistogram
                    }
                    ForEach(viewModel.childSummaries) { child in
                        childSection(child)
                    }
                    if !viewModel.recentCommands.isEmpty {
                        recentCommandsSection
                    }
                } else {
                    ContentUnavailableView(
                        "No Data",
                        systemImage: "chart.bar",
                        description: Text("Send some commands to see insights.")
                    )
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle("Insights")
        .refreshable {
            await viewModel.load()
        }
        .task {
            await viewModel.load()
        }
    }

    // MARK: - Family Summary

    @ViewBuilder
    private func familySummaryCard(_ summary: FamilySummary) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                // Success rate donut
                ZStack {
                    Chart {
                        SectorMark(angle: .value("Success", summary.successCount), innerRadius: .ratio(0.65))
                            .foregroundStyle(.green)
                        SectorMark(angle: .value("Failed", summary.failCount), innerRadius: .ratio(0.65))
                            .foregroundStyle(.red)
                        SectorMark(angle: .value("Pending", summary.pendingCount), innerRadius: .ratio(0.65))
                            .foregroundStyle(.gray.opacity(0.3))
                    }
                    .chartLegend(.hidden)
                    .frame(width: 80, height: 80)

                    VStack(spacing: 0) {
                        Text(summary.totalCommands > 0
                            ? "\(Int(Double(summary.successCount) / Double(summary.totalCommands) * 100))%"
                            : "—")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("success")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }

                // Stats
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        statLabel("Avg", value: formatLatency(summary.avgLatency))
                        statLabel("Med", value: formatLatency(summary.medianLatency))
                        statLabel("P95", value: formatLatency(summary.p95Latency))
                    }
                    HStack(spacing: 16) {
                        statLabel("Cmds", value: "\(summary.totalCommands)")
                        statLabel("Online", value: "\(summary.onlineDevices)/\(summary.totalDevices)")
                    }
                    if summary.unlockRequestCount > 0 || summary.selfUnlockCount > 0 {
                        HStack(spacing: 16) {
                            if summary.unlockRequestCount > 0 {
                                statLabel("Requests", value: "\(summary.unlockRequestCount)")
                            }
                            if summary.selfUnlockCount > 0 {
                                statLabel("PIN Unlocks", value: "\(summary.selfUnlockCount)")
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func statLabel(_ title: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Latency Histogram

    // MARK: - Lock Precision

    @ViewBuilder
    private var lockPrecisionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lock.badge.clock")
                    .foregroundStyle(.blue)
                Text("Lock Precision")
                    .font(.subheadline.weight(.semibold))
            }

            // Summary stats
            let drifts = viewModel.lockPrecisionRecords.map(\.driftSeconds)
            let avgDrift = drifts.reduce(0, +) / Double(max(1, drifts.count))
            let maxDrift = drifts.max() ?? 0
            let onTime = drifts.filter { abs($0) < 30 }.count

            HStack(spacing: 20) {
                statLabel("On Time", value: "\(onTime)/\(drifts.count)")
                statLabel("Avg Drift", value: formatDrift(avgDrift))
                statLabel("Worst", value: formatDrift(maxDrift))
            }

            // Per-record list
            ForEach(viewModel.lockPrecisionRecords.prefix(10)) { record in
                HStack(spacing: 8) {
                    driftIcon(record.driftSeconds)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if let name = record.childName {
                                Text(name)
                                    .font(.caption.weight(.medium))
                            }
                            Text(formatDuration(record.expectedDurationSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(record.unlockStartedAt, style: .relative)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        + Text(" ago")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text(formatDrift(record.driftSeconds))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(driftColor(record.driftSeconds).opacity(0.15))
                        .foregroundStyle(driftColor(record.driftSeconds))
                        .clipShape(Capsule())
                }
                .padding(.vertical, 2)
            }

            if viewModel.lockPrecisionRecords.isEmpty {
                Text("No temporary unlocks with expiry data yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Schedule Precision

    @ViewBuilder
    private var schedulePrecisionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.orange)
                Text("Schedule Precision")
                    .font(.subheadline.weight(.semibold))
            }

            let drifts = viewModel.scheduleTransitionRecords.map(\.driftSeconds)
            let avgDrift = drifts.reduce(0, +) / Double(max(1, drifts.count))
            let maxDrift = drifts.max() ?? 0
            let onTime = drifts.filter { abs($0) < 30 }.count

            HStack(spacing: 20) {
                statLabel("On Time", value: "\(onTime)/\(drifts.count)")
                statLabel("Avg Drift", value: formatDrift(avgDrift))
                statLabel("Worst", value: formatDrift(maxDrift))
            }

            ForEach(viewModel.scheduleTransitionRecords.prefix(10)) { record in
                HStack(spacing: 8) {
                    driftIcon(record.driftSeconds)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if let name = record.childName {
                                Text(name)
                                    .font(.caption.weight(.medium))
                            }
                            Text(record.transitionType.rawValue)
                                .font(.caption)
                                .foregroundStyle(record.transitionType == .unlock ? .green : .blue)
                        }
                        Text(record.actualTime, style: .relative)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        + Text(" ago")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text(formatDrift(record.driftSeconds))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(driftColor(record.driftSeconds).opacity(0.15))
                        .foregroundStyle(driftColor(record.driftSeconds))
                        .clipShape(Capsule())
                }
                .padding(.vertical, 2)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func formatDrift(_ seconds: Double) -> String {
        let abs = abs(seconds)
        let sign = seconds >= 0 ? "+" : "-"
        if abs < 60 {
            return "\(sign)\(Int(abs))s"
        } else {
            let m = Int(abs) / 60
            let s = Int(abs) % 60
            return "\(sign)\(m)m \(s)s"
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 3600 {
            return "\(seconds / 60)m unlock"
        } else {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return m > 0 ? "\(h)h \(m)m unlock" : "\(h)h unlock"
        }
    }

    @ViewBuilder
    private func driftIcon(_ drift: Double) -> some View {
        let absDrift = abs(drift)
        if absDrift < 30 {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if absDrift < 120 {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
        } else {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func driftColor(_ drift: Double) -> Color {
        let abs = abs(drift)
        if abs < 30 { return .green }
        if abs < 120 { return .yellow }
        return .red
    }

    // MARK: - Latency Histogram

    @ViewBuilder
    private var latencyHistogram: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Latency Distribution")
                .font(.subheadline.weight(.semibold))

            Chart(viewModel.bucketCounts) { item in
                BarMark(
                    x: .value("Latency", item.bucket.rawValue),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(bucketColor(item.bucket))
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 9))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                        .font(.system(size: 9))
                }
            }
            .frame(height: 140)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Per-Child Section

    @ViewBuilder
    private func childSection(_ child: ChildInsightsSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text(child.childName)
                    .font(.headline)
                Spacer()
                if child.commandCount > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(child.successRate >= 0.9 ? .green : child.successRate >= 0.7 ? .yellow : .red)
                            .frame(width: 8, height: 8)
                        Text("\(Int(child.successRate * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(child.commandCount) cmds")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Latency sparkline
            if child.latencyRecords.contains(where: { $0.latencySeconds != nil }) {
                latencySparkline(child.latencyRecords)
            }

            // Device health
            ForEach(child.deviceSnapshots) { device in
                deviceHealthRow(device)
            }

            // Event summary
            if !child.eventCounts.isEmpty {
                eventSummaryRow(child.eventCounts)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func latencySparkline(_ records: [CommandLatencyRecord]) -> some View {
        let withLatency = records.filter { $0.latencySeconds != nil }
            .sorted { $0.issuedAt < $1.issuedAt }
        Chart(withLatency) { record in
            PointMark(
                x: .value("Time", record.issuedAt),
                y: .value("Latency", record.latencySeconds ?? 0)
            )
            .foregroundStyle(latencyColor(record.latencySeconds ?? 0))
            .symbolSize(30)
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 8))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let secs = value.as(Double.self) {
                        Text(formatLatency(secs))
                            .font(.system(size: 8))
                    }
                }
            }
        }
        .frame(height: 80)
    }

    @ViewBuilder
    private func deviceHealthRow(_ device: DeviceSnapshot) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(device.isOnline ? .green : .red.opacity(0.6))
                .frame(width: 6, height: 6)
            Text(device.displayName)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            if let hb = device.lastHeartbeat {
                Image(systemName: "heart.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.pink.opacity(0.6))
                Text(hb, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            if let battery = device.batteryLevel {
                HStack(spacing: 1) {
                    Image(systemName: "battery.50")
                        .font(.system(size: 9))
                    Text("\(Int(battery * 100))%")
                        .font(.system(size: 9))
                }
                .foregroundStyle(battery < 0.2 ? .red : .secondary)
            }

            if let cmdAt = device.lastCommandProcessedAt {
                HStack(spacing: 1) {
                    Image(systemName: "command")
                        .font(.system(size: 8))
                    Text(cmdAt, style: .relative)
                        .font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            }

            if let error = device.enforcementError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .help(error)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func eventSummaryRow(_ counts: [EventType: Int]) -> some View {
        let items: [(String, String, Int)] = [
            ("lock.fill", "Mode", counts[.modeChanged] ?? 0),
            ("shield.slash", "Blocked", counts[.appLaunchBlocked] ?? 0),
            ("lock.open", "Unlocks", (counts[.temporaryUnlockStarted] ?? 0) + (counts[.localPINUnlock] ?? 0)),
            ("bell.badge", "Requests", counts[.unlockRequested] ?? 0),
        ].filter { $0.2 > 0 }

        if !items.isEmpty {
            HStack(spacing: 12) {
                ForEach(items, id: \.0) { icon, label, count in
                    HStack(spacing: 3) {
                        Image(systemName: icon)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("\(count)")
                            .font(.caption2.weight(.medium))
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Recent Commands

    /// Groups consecutive commands with the same action+target into one row.
    private var collapsedRecentCommands: [(record: CommandLatencyRecord, count: Int)] {
        var result: [(record: CommandLatencyRecord, count: Int)] = []
        for record in viewModel.recentCommands {
            if let last = result.last,
               last.record.action.displayDescription == record.action.displayDescription,
               last.record.targetChildName == record.targetChildName,
               last.record.status == record.status {
                result[result.count - 1] = (last.record, last.count + 1)
            } else {
                result.append((record, 1))
            }
        }
        return result
    }

    @ViewBuilder
    private var recentCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Commands")
                .font(.subheadline.weight(.semibold))

            ForEach(Array(collapsedRecentCommands.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    statusIcon(item.record.status)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(item.record.action.displayDescription)
                                .font(.caption)
                                .lineLimit(1)
                            if item.count > 1 {
                                Text("\u{00d7}\(item.count)")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        HStack(spacing: 4) {
                            if let name = item.record.targetChildName {
                                Text(name)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.record.issuedAt, style: .relative)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            + Text(" ago")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    latencyBadge(item.record)
                }
                .padding(.vertical, 3)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func statusIcon(_ status: CommandStatus) -> some View {
        switch status {
        case .applied:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .pending, .delivered:
            Image(systemName: "clock.fill")
                .font(.caption)
                .foregroundStyle(.gray)
        case .expired:
            Image(systemName: "clock.badge.xmark")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func latencyBadge(_ record: CommandLatencyRecord) -> some View {
        if let secs = record.latencySeconds {
            Text(formatLatency(secs))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(latencyColor(secs).opacity(0.15))
                .foregroundStyle(latencyColor(secs))
                .clipShape(Capsule())
        } else if record.status == .pending || record.status == .delivered {
            Text("pending")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
        }
    }

    // MARK: - Helpers

    private func formatLatency(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        } else if seconds < 3600 {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m)m \(s)s"
        } else {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return "\(h)h \(m)m"
        }
    }

    private func latencyColor(_ seconds: Double) -> Color {
        if seconds < 30 { return .green }
        if seconds < 120 { return .yellow }
        return .red
    }

    private func bucketColor(_ bucket: LatencyBucket) -> Color {
        switch bucket {
        case .fast: .green
        case .good: .mint
        case .moderate: .yellow
        case .slow: .orange
        case .verySlow: .red
        case .noReceipt: .gray.opacity(0.4)
        }
    }
}
