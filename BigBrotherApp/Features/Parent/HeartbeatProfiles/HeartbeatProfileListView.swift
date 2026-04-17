import SwiftUI
import BigBrotherCore

struct HeartbeatProfileListView: View {
    @Bindable var viewModel: HeartbeatProfileListViewModel
    @State private var showPresetPicker = false
    @State private var editingProfile: HeartbeatProfile?

    var body: some View {
        List {
            if viewModel.profiles.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "No Monitoring Profiles",
                    systemImage: "heart.text.clipboard",
                    description: Text("Add a profile to control when devices are monitored.")
                )
            }

            ForEach(viewModel.profiles) { profile in
                NavigationLink {
                    HeartbeatProfileEditorView(
                        viewModel: viewModel,
                        profile: profile
                    )
                } label: {
                    profileRow(profile)
                }
            }
            .onDelete { indexSet in
                let toDelete = indexSet.compactMap { viewModel.profiles[safe: $0] }
                for profile in toDelete {
                    Task { await viewModel.delete(profile) }
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .navigationTitle("Monitoring Profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Custom Profile") {
                        editingProfile = HeartbeatProfile(
                            familyID: viewModel.appState.parentState?.familyID ?? FamilyID(rawValue: ""),
                            name: "",
                            activeWindows: [],
                            maxHeartbeatGap: 7200
                        )
                    }

                    if let familyID = viewModel.appState.parentState?.familyID {
                        Divider()
                        ForEach(HeartbeatProfile.presets(familyID: familyID)) { preset in
                            Button(preset.name) {
                                Task { await viewModel.addPreset(preset) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await withDeadline(3) { await viewModel.refresh() }
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                HeartbeatProfileEditorView(
                    viewModel: viewModel,
                    profile: profile
                )
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: HeartbeatProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profile.name)
                    .fontWeight(.medium)
                if profile.isDefault {
                    Text("DEFAULT")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 12) {
                Label("\(profile.activeWindows.count) window\(profile.activeWindows.count == 1 ? "" : "s")",
                      systemImage: "clock")
                Label(formatGap(profile.maxHeartbeatGap), systemImage: "timer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatGap(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m gap" }
        if hours > 0 { return "\(hours)h gap" }
        return "\(minutes)m gap"
    }
}

// Safe subscript provided by BigBrotherCore Collection+Safe extension.
