import SwiftUI
import BigBrotherCore

/// Parent UI for managing per-app time limits on a child's device.
/// Shows configured limits with DNS-estimated usage progress bars.
struct AppTimeLimitsSection: View {
    @Bindable var viewModel: ChildDetailViewModel

    @State private var renameConfig: TimeLimitConfig?
    @State private var renameText: String = ""
    @State private var customLimitConfig: TimeLimitConfig?
    @State private var customLimitText: String = ""

    var body: some View {
        Section {
            if viewModel.timeLimitConfigs.isEmpty {
                Text("No app time limits configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.timeLimitConfigs) { config in
                    timeLimitRow(config)
                }
                .onDelete { indices in
                    Task { await deleteConfigs(at: indices) }
                }
            }

            // Add limit button — triggers picker on child device
            Menu {
                ForEach(viewModel.devices, id: \.id) { device in
                    Button {
                        Task { await viewModel.requestTimeLimitSetup(for: device) }
                    } label: {
                        let name = DeviceIcon.displayName(for: device.modelIdentifier)
                        Label(name, systemImage: device.modelIdentifier.lowercased().contains("ipad") ? "ipad" : "iphone")
                    }
                }
            } label: {
                Label("Add App Time Limit", systemImage: "timer")
            }
        } header: {
            HStack {
                Text("App Time Limits")
                Spacer()
                if !viewModel.timeLimitConfigs.isEmpty {
                    Text("\(viewModel.timeLimitConfigs.count) app\(viewModel.timeLimitConfigs.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Set daily time budgets per app. When time runs out, the app is blocked until midnight. Usage estimates are approximate (based on network activity).")
        }
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
            Button("Cancel", role: .cancel) {
                renameConfig = nil
            }
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
            Button("Cancel", role: .cancel) {
                customLimitConfig = nil
            }
        } message: {
            Text("Enter the daily time limit in minutes.")
        }
    }

    @ViewBuilder
    private func timeLimitRow(_ config: TimeLimitConfig) -> some View {
        let usage = viewModel.estimatedAppUsage(for: config.appName)
        let progress = config.dailyLimitMinutes > 0 ? min(1.0, usage / Double(config.dailyLimitMinutes)) : 0
        let exhausted = usage >= Double(config.dailyLimitMinutes) && config.dailyLimitMinutes > 0

        HStack(spacing: 8) {
            Text(config.appName)
                .font(.subheadline)
                .lineLimit(1)

            if config.dailyLimitMinutes > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.quaternary)
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(exhausted ? .red : progress > 0.75 ? .orange : .green)
                            .frame(width: geo.size.width * progress, height: 4)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 4)

                Text("\(formatMinutes(Int(usage))) / \(formatMinutes(config.dailyLimitMinutes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Spacer()
                Text("No limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Divider()

            Button {
                Task { await viewModel.blockAppForToday(config: config) }
            } label: {
                Label("Block for Today", systemImage: "clock.badge.xmark")
            }

            Button(role: .destructive) {
                Task { await viewModel.removeTimeLimit(config: config) }
            } label: {
                Label("Remove & Block", systemImage: "trash")
            }
        }
    }

    private func deleteConfigs(at indices: IndexSet) async {
        for index in indices {
            let config = viewModel.timeLimitConfigs[index]
            await viewModel.removeTimeLimit(config: config)
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
}
