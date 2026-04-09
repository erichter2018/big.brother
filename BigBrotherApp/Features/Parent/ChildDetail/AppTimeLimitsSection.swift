import SwiftUI
import BigBrotherCore

/// Parent UI for managing allowed apps — pending review, time-limited, and always-allowed.
struct AppTimeLimitsSection: View {
    @Bindable var viewModel: ChildDetailViewModel

    @State private var renameConfig: TimeLimitConfig?
    @State private var renameText: String = ""
    @State private var customLimitConfig: TimeLimitConfig?
    @State private var customLimitText: String = ""
    @State private var revokeConfig: TimeLimitConfig?
    @State private var timeLimitsExpanded = true
    @State private var alwaysAllowedExpanded = true

    private var timeLimitedApps: [TimeLimitConfig] {
        viewModel.timeLimitConfigs.filter { $0.isActive && $0.dailyLimitMinutes > 0 }
    }

    private var alwaysAllowedApps: [TimeLimitConfig] {
        viewModel.timeLimitConfigs.filter { $0.isActive && $0.dailyLimitMinutes == 0 }
    }

    /// Group configs by category, sorted alphabetically. "Other" goes last.
    private func grouped(_ configs: [TimeLimitConfig]) -> [(category: String, apps: [TimeLimitConfig])] {
        let dict = Dictionary(grouping: configs) { $0.appCategory ?? "Other" }
        return dict.sorted { lhs, rhs in
            if lhs.key == "Other" { return false }
            if rhs.key == "Other" { return true }
            return lhs.key < rhs.key
        }.map { (category: $0.key, apps: $0.value.sorted { $0.appName < $1.appName }) }
    }

    var body: some View {
        // Pending review — PendingAppReviewSection handles its own visibility
        PendingAppReviewSection(viewModel: viewModel)

        // Time-limited apps (collapsible, two-column grid grouped by category)
        Section(isExpanded: $timeLimitsExpanded) {
            if timeLimitedApps.isEmpty {
                Text("No time-limited apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let groups = grouped(timeLimitedApps)
                twoColumnCategories(groups: groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        if groups.count > 1 || group.category != "Other" {
                            Text(group.category)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group.apps) { config in
                            timeLimitCompactRow(config)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Time-Limited Apps")
                Image(systemName: timeLimitsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Spacer()
                if !timeLimitedApps.isEmpty {
                    Text("\(timeLimitedApps.count)")
                        .font(.caption2)
                }
            }
            .onTapGesture { withAnimation { timeLimitsExpanded.toggle() } }
        }

        // Always-allowed apps (collapsible, CloudKit-backed, category: app1, app2 format)
        Section(isExpanded: $alwaysAllowedExpanded) {
            if alwaysAllowedApps.isEmpty {
                Text("No always-allowed apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let groups = grouped(alwaysAllowedApps)
                twoColumnCategories(groups: groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.category)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(group.apps.map(\.appName).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.primary.opacity(0.7))
                        }
                        .contextMenu {
                            ForEach(group.apps) { config in
                                Menu(config.appName) {
                                    Button {
                                        renameText = config.appName
                                        renameConfig = config
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Menu {
                                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { mins in
                                            Button("\(mins >= 60 ? "\(mins/60)h\(mins % 60 > 0 ? " \(mins%60)m" : "")" : "\(mins)m") / day") {
                                                Task { await viewModel.convertToTimeLimited(config: config, minutes: mins) }
                                            }
                                        }
                                    } label: {
                                        Label("Set Time Limit", systemImage: "clock")
                                    }
                                    Button(role: .destructive) {
                                        revokeConfig = config
                                    } label: {
                                        Label("Revoke Access", systemImage: "xmark.circle")
                                    }
                                }
                            }
                        }
                    }
                }
        } header: {
            HStack {
                Text("Always Allowed")
                Image(systemName: alwaysAllowedExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Spacer()
                if !alwaysAllowedApps.isEmpty {
                    Text("\(alwaysAllowedApps.count)")
                        .font(.caption2)
                }
            }
            .onTapGesture { withAnimation { alwaysAllowedExpanded.toggle() } }
        }

        // Add apps button
        Section {
            Menu {
                ForEach(viewModel.devices, id: \.id) { device in
                    let name = DeviceIcon.displayName(for: device.modelIdentifier)
                    let icon = device.modelIdentifier.lowercased().contains("ipad") ? "ipad" : "iphone"
                    Menu {
                        Button {
                            Task { await viewModel.requestTimeLimitSetup(for: device) }
                        } label: {
                            Label("Parent on child's device", systemImage: "hand.tap")
                        }
                        Button {
                            Task { await viewModel.requestChildAppPick(for: device) }
                        } label: {
                            Label("Child picks apps", systemImage: "person.crop.circle.badge.plus")
                        }
                    } label: {
                        Label(name, systemImage: icon)
                    }
                }
            } label: {
                Label("Add Apps", systemImage: "plus.app")
            }
        }

        // Alerts for rename and custom limit
        .alert("Rename App", isPresented: Binding(
            get: { renameConfig != nil },
            set: { if !$0 { renameConfig = nil } }
        )) {
            TextField("App name", text: $renameText)
            Button("Save") {
                if let config = renameConfig, !renameText.isEmpty {
                    Task { await viewModel.renameTimeLimit(config: config, newName: renameText) }
                }
                renameConfig = nil
            }
            Button("Cancel", role: .cancel) { renameConfig = nil }
        } message: {
            Text("Enter a new display name for this app.")
        }
        .alert("Custom Time Limit", isPresented: Binding(
            get: { customLimitConfig != nil },
            set: { if !$0 { customLimitConfig = nil } }
        )) {
            TextField("Minutes", text: $customLimitText)
                .keyboardType(.numberPad)
            Button("Set") {
                if let config = customLimitConfig, let mins = Int(customLimitText), mins > 0 {
                    Task { await viewModel.setTimeLimit(config: config, minutes: mins) }
                }
                customLimitConfig = nil
            }
            Button("Cancel", role: .cancel) { customLimitConfig = nil }
        } message: {
            Text("Enter the daily time limit in minutes.")
        }
        .alert("Revoke Access?", isPresented: Binding(
            get: { revokeConfig != nil },
            set: { if !$0 { revokeConfig = nil } }
        )) {
            Button("Revoke", role: .destructive) {
                if let config = revokeConfig {
                    let isAlwaysAllowed = config.dailyLimitMinutes == 0
                    Task {
                        if isAlwaysAllowed {
                            await viewModel.revokeAlwaysAllowed(config: config)
                        } else {
                            await viewModel.removeTimeLimit(config: config)
                        }
                    }
                }
                revokeConfig = nil
            }
            Button("Cancel", role: .cancel) { revokeConfig = nil }
        } message: {
            if let config = revokeConfig {
                Text("\(config.appName) will be blocked on all devices.")
            }
        }
    }

    // MARK: - Time Limit Compact Row (for grid)

    @ViewBuilder
    private func timeLimitCompactRow(_ config: TimeLimitConfig) -> some View {
        let usage = viewModel.appUsageMinutes(for: config)
        let blocked = viewModel.isAppBlockedForToday(config)
        let extra = viewModel.grantedExtraMinutes[config.appFingerprint] ?? 0
        let effectiveLimit = config.dailyLimitMinutes + extra
        let progress = blocked && extra == 0 ? 1.0 : (effectiveLimit > 0 ? min(1.0, usage / Double(effectiveLimit)) : 0)
        let displayUsage = blocked && extra == 0 ? config.dailyLimitMinutes : Int(usage)
        let hasPendingRequest = viewModel.hasPendingTimeRequest(for: config)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(config.appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(blocked && extra == 0 ? 0.4 : 1.0)
                    .lineLimit(1)
                Spacer()
                Text("\(formatMinutes(displayUsage))/\(formatMinutes(effectiveLimit))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            ProgressView(value: progress)
                .tint(blocked && extra == 0 ? .red.opacity(0.6) : progress > 0.75 ? .orange : .green)
                .scaleEffect(y: 0.5)

            if hasPendingRequest {
                Text("Requesting more time")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
            if extra > 0 {
                Text("+\(formatMinutes(extra)) granted")
                    .font(.system(size: 8))
                    .foregroundStyle(.green)
            }
        }
        .contextMenu {
            Button {
                renameText = config.appName
                renameConfig = config
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Menu {
                ForEach([15, 30, 45, 60, 90, 120, 180, 240], id: \.self) { mins in
                    Button("\(mins >= 60 ? "\(mins/60)h\(mins % 60 > 0 ? " \(mins%60)m" : "")" : "\(mins)m")") {
                        Task { await viewModel.setTimeLimit(config: config, minutes: mins) }
                    }
                }
                Button("Custom...") {
                    customLimitText = config.dailyLimitMinutes > 0 ? "\(config.dailyLimitMinutes)" : ""
                    customLimitConfig = config
                }
            } label: {
                Label("Change Limit", systemImage: "clock")
            }
            Menu {
                Button("+15 min") { Task { await viewModel.grantExtraTime(config: config, minutes: 15) } }
                Button("+30 min") { Task { await viewModel.grantExtraTime(config: config, minutes: 30) } }
                Button("+1 hour") { Task { await viewModel.grantExtraTime(config: config, minutes: 60) } }
            } label: {
                Label("Grant Extra Time", systemImage: "plus.circle")
            }
            Divider()
            Button {
                Task { await viewModel.convertToAlwaysAllowed(config: config) }
            } label: {
                Label("Make Always Allowed", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                revokeConfig = config
            } label: {
                Label("Remove & Block", systemImage: "trash")
            }
        }
    }

    // MARK: - Time Limit Row (legacy full-width)

    @ViewBuilder
    private func timeLimitRow(_ config: TimeLimitConfig) -> some View {
        let usage = viewModel.appUsageMinutes(for: config)
        let blocked = viewModel.isAppBlockedForToday(config)
        let extra = viewModel.grantedExtraMinutes[config.appFingerprint] ?? 0
        let effectiveLimit = config.dailyLimitMinutes + extra
        let progress = blocked && extra == 0 ? 1.0 : (effectiveLimit > 0 ? min(1.0, usage / Double(effectiveLimit)) : 0)
        let displayUsage = blocked && extra == 0 ? config.dailyLimitMinutes : Int(usage)
        let hasPendingRequest = viewModel.hasPendingTimeRequest(for: config)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(config.appName)
                    .font(.subheadline)
                    .italic(blocked && extra == 0)
                    .foregroundStyle(blocked && extra == 0 ? .tertiary : .secondary)
                    .lineLimit(1)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.quaternary)
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(blocked && extra == 0 ? .red.opacity(0.6) : progress > 0.75 ? .orange : .green)
                            .frame(width: geo.size.width * progress, height: 4)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 4)

                Text("\(formatMinutes(displayUsage)) / \(formatMinutes(effectiveLimit))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            // Pending request banner
            if hasPendingRequest {
                HStack(spacing: 4) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("Requesting more time")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        viewModel.denyTimeRequest(for: config)
                    } label: {
                        Text("Deny")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().stroke(.red, lineWidth: 1))
                    }
                    Menu {
                        Button("+15 min") { Task { await viewModel.grantExtraTime(config: config, minutes: 15) } }
                        Button("+30 min") { Task { await viewModel.grantExtraTime(config: config, minutes: 30) } }
                        Button("+1 hour") { Task { await viewModel.grantExtraTime(config: config, minutes: 60) } }
                        Button("Rest of day") {
                            let remaining = max(15, Int(Double(Date.secondsUntilMidnight) / 60.0))
                            Task { await viewModel.grantExtraTime(config: config, minutes: remaining) }
                        }
                    } label: {
                        Text("Grant")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.blue))
                    }
                }
            }

            // Extra time granted indicator
            if extra > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                    Text("+\(formatMinutes(extra)) granted today")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                renameText = config.appName
                renameConfig = config
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Menu {
                ForEach([15, 30, 45, 60, 90, 120, 180, 240], id: \.self) { mins in
                    Button("\(mins >= 60 ? "\(mins/60)h\(mins % 60 > 0 ? " \(mins%60)m" : "")" : "\(mins)m")") {
                        Task { await viewModel.setTimeLimit(config: config, minutes: mins) }
                    }
                }
                Button("Custom...") {
                    customLimitText = config.dailyLimitMinutes > 0 ? "\(config.dailyLimitMinutes)" : ""
                    customLimitConfig = config
                }
            } label: {
                Label("Change Limit", systemImage: "clock")
            }

            Menu {
                Button("+15 min") { Task { await viewModel.grantExtraTime(config: config, minutes: 15) } }
                Button("+30 min") { Task { await viewModel.grantExtraTime(config: config, minutes: 30) } }
                Button("+1 hour") { Task { await viewModel.grantExtraTime(config: config, minutes: 60) } }
                Button("Rest of day") {
                    let remaining = max(15, Int(Double(Date.secondsUntilMidnight) / 60.0))
                    Task { await viewModel.grantExtraTime(config: config, minutes: remaining) }
                }
            } label: {
                Label("Grant Extra Time", systemImage: "plus.circle")
            }

            Divider()

            Button {
                Task { await viewModel.convertToAlwaysAllowed(config: config) }
            } label: {
                Label("Make Always Allowed", systemImage: "checkmark.circle")
            }

            Button {
                Task { await viewModel.blockAppForToday(config: config) }
            } label: {
                Label("Block for Today", systemImage: "clock.badge.xmark")
            }

            Button(role: .destructive) {
                revokeConfig = config
            } label: {
                Label("Remove & Block", systemImage: "trash")
            }
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    /// Two-column layout using plain VStack/HStack — avoids LazyVGrid layout jitter inside List.
    @ViewBuilder
    private func twoColumnCategories(
        groups: [(category: String, apps: [TimeLimitConfig])],
        @ViewBuilder cellContent: @escaping ((category: String, apps: [TimeLimitConfig])) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: groups.count, by: 2).enumerated()), id: \.offset) { _, i in
                HStack(alignment: .top, spacing: 12) {
                    cellContent(groups[i])
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    if i + 1 < groups.count {
                        cellContent(groups[i + 1])
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        Spacer()
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
