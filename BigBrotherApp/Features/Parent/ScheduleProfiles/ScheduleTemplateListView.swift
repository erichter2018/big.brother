import SwiftUI
import BigBrotherCore

/// Manage schedule templates: create, edit, delete.
/// Accessed via "Manage Templates" from ScheduleOverviewView.
struct ScheduleTemplateListView: View {
    @Bindable var viewModel: ScheduleProfileListViewModel
    @State private var editingProfile: ScheduleProfile?

    var body: some View {
        List {
            if viewModel.profiles.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "No Schedule Templates",
                    systemImage: "calendar.badge.clock",
                    description: Text("Create a template to define unlock windows for your kids.")
                )
            }

            ForEach(viewModel.profiles) { profile in
                NavigationLink {
                    ScheduleProfileEditorView(
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
        .navigationTitle("Schedule Templates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Custom Template") {
                        editingProfile = ScheduleProfile(
                            familyID: viewModel.appState.parentState?.familyID ?? FamilyID(rawValue: ""),
                            name: "",
                            freeWindows: []
                        )
                    }

                    if let familyID = viewModel.appState.parentState?.familyID {
                        Divider()
                        ForEach(ScheduleProfile.presets(familyID: familyID)) { preset in
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
            await viewModel.refresh()
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                ScheduleProfileEditorView(
                    viewModel: viewModel,
                    profile: profile
                )
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: ScheduleProfile) -> some View {
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
                Label("\(profile.freeWindows.count) free", systemImage: "clock")
                if !profile.essentialWindows.isEmpty {
                    Label("\(profile.essentialWindows.count) essential", systemImage: "shield")
                        .foregroundStyle(.purple)
                }
                Label("Locked: \(profile.lockedMode.displayName)", systemImage: "lock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// Safe subscript provided by BigBrotherCore Collection+Safe extension.
