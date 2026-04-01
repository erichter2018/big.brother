import SwiftUI
import BigBrotherCore

/// Parent UI for managing per-app time limits on a child's device.
/// Shows configured limits with DNS-estimated usage progress bars.
struct AppTimeLimitsSection: View {
    @Bindable var viewModel: ChildDetailViewModel

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
    }

    @ViewBuilder
    private func timeLimitRow(_ config: TimeLimitConfig) -> some View {
        let usage = viewModel.estimatedAppUsage(for: config.appName)
        let progress = config.dailyLimitMinutes > 0 ? min(1.0, usage / Double(config.dailyLimitMinutes)) : 0
        let exhausted = usage >= Double(config.dailyLimitMinutes) && config.dailyLimitMinutes > 0

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(config.appName)
                    .font(.subheadline.weight(.medium))
                Spacer()

                // Editable limit
                Menu {
                    ForEach([15, 30, 45, 60, 90, 120, 180, 240], id: \.self) { minutes in
                        Button {
                            Task { await viewModel.setTimeLimit(config: config, minutes: minutes) }
                        } label: {
                            Text(formatMinutes(minutes))
                            if config.dailyLimitMinutes == minutes {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    Text(config.dailyLimitMinutes > 0 ? formatMinutes(config.dailyLimitMinutes) : "Set limit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(config.dailyLimitMinutes > 0 ? Color.primary : Color.blue)
                }
            }

            if config.dailyLimitMinutes > 0 {
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(exhausted ? .red : progress > 0.75 ? .orange : .green)
                            .frame(width: geo.size.width * progress, height: 6)
                    }
                }
                .frame(height: 6)

                HStack {
                    Text("~\(formatMinutes(Int(usage))) used")
                        .font(.caption2)
                        .foregroundStyle(exhausted ? .red : .secondary)
                    Spacer()
                    Text("\(formatMinutes(config.dailyLimitMinutes)) limit")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
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
