import SwiftUI
import BigBrotherCore

struct ScheduleListView: View {
    let appState: AppState
    @State private var schedules: [Schedule] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedChild: ChildProfile?
    @State private var showEditor = false

    var body: some View {
        Group {
            if isLoading && schedules.isEmpty {
                ProgressView("Loading schedules...")
            } else if schedules.isEmpty {
                ContentUnavailableView(
                    "No Schedules",
                    systemImage: "calendar.badge.clock",
                    description: Text("Tap + to create a schedule for a child.")
                )
            } else {
                List {
                    ForEach(groupedByChild, id: \.0.id) { child, childSchedules in
                        Section(child.name) {
                            ForEach(childSchedules) { schedule in
                                NavigationLink {
                                    ScheduleEditorView(
                                        viewModel: ScheduleEditorViewModel(
                                            appState: appState,
                                            childProfileID: schedule.childProfileID,
                                            schedule: schedule
                                        )
                                    )
                                } label: {
                                    scheduleRow(schedule)
                                }
                            }
                            .onDelete { offsets in
                                deleteSchedules(childSchedules, at: offsets)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Schedules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(appState.childProfiles) { child in
                        Button(child.name) {
                            selectedChild = child
                            showEditor = true
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(appState.childProfiles.isEmpty)
            }
        }
        .sheet(isPresented: $showEditor, onDismiss: { Task { await loadSchedules() } }) {
            if let child = selectedChild {
                NavigationStack {
                    ScheduleEditorView(
                        viewModel: ScheduleEditorViewModel(
                            appState: appState,
                            childProfileID: child.id
                        )
                    )
                }
            }
        }
        .refreshable { await withDeadline(3) { await loadSchedules() } }
        .task { await loadSchedules() }
    }

    private var groupedByChild: [(ChildProfile, [Schedule])] {
        let childMap = Dictionary(uniqueKeysWithValues: appState.childProfiles.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: schedules) { $0.childProfileID }
        return grouped.compactMap { key, value in
            guard let child = childMap[key] else { return nil }
            return (child, value.sorted { $0.name < $1.name })
        }.sorted { $0.0.name < $1.0.name }
    }

    private func loadSchedules() async {
        guard let familyID = appState.parentState?.familyID,
              let cloudKit = appState.cloudKit else { return }
        isLoading = true
        do {
            schedules = try await cloudKit.fetchSchedules(familyID: familyID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteSchedules(_ childSchedules: [Schedule], at offsets: IndexSet) {
        guard let familyID = appState.parentState?.familyID,
              let cloudKit = appState.cloudKit else { return }
        for index in offsets {
            let schedule = childSchedules[index]
            Task {
                try? await cloudKit.deleteSchedule(schedule.id, familyID: familyID)
                await loadSchedules()
            }
        }
    }

    @ViewBuilder
    private func scheduleRow(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(schedule.name)
                    .fontWeight(.medium)
                Spacer()
                if !schedule.isActive {
                    Text("OFF")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                ModeBadge(mode: schedule.mode)
            }

            HStack(spacing: 4) {
                Text(ScheduleFormatting.daysText(schedule.daysOfWeek))
                Text("•")
                Text(ScheduleFormatting.timeRange(schedule.startTime, schedule.endTime))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

}
