import SwiftUI
import BigBrotherCore

/// Kid-centric schedule overview. Shows which child has which schedule
/// template assigned, with a compact summary of free windows.
struct ScheduleOverviewView: View {
    var viewModel: ScheduleOverviewViewModel
    @State private var showingAssignSheet = false
    @State private var showingTemplates = false

    var body: some View {
        List {
            if !viewModel.childrenWithSchedule.isEmpty {
                Section("Assigned") {
                    ForEach(viewModel.childrenWithSchedule) { info in
                        childScheduleCard(info)
                    }
                }
            }

            if !viewModel.childrenWithoutSchedule.isEmpty {
                Section("No Schedule") {
                    ForEach(viewModel.childrenWithoutSchedule) { child in
                        unassignedRow(child)
                    }
                }
            }

            if viewModel.childrenWithSchedule.isEmpty && viewModel.childrenWithoutSchedule.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "No Children",
                    systemImage: "person.2",
                    description: Text("Enroll a child device to get started.")
                )
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            if let success = viewModel.successMessage {
                Section {
                    Text(success).foregroundStyle(.green).font(.caption)
                }
            }
        }
        .navigationTitle("Schedules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAssignSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.appState.scheduleProfiles.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingTemplates = true
                } label: {
                    Label("Manage Templates", systemImage: "doc.on.doc")
                }
            }
        }
        .task {
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .sheet(isPresented: $showingAssignSheet) {
            AssignScheduleSheet(viewModel: viewModel)
        }
        .navigationDestination(isPresented: $showingTemplates) {
            ScheduleTemplateListView(
                viewModel: ScheduleProfileListViewModel(appState: viewModel.appState)
            )
        }
    }

    // MARK: - Child Schedule Card

    @ViewBuilder
    private func childScheduleCard(_ info: ScheduleOverviewViewModel.ChildScheduleInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                avatar(for: info.child)
                Text(info.child.name)
                    .font(.headline)
                Spacer()
                scheduleMenu(for: info)
            }

            if let schedule = info.schedule {
                Text(schedule.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                freeWindowSummary(schedule.freeWindows)

                if !schedule.essentialWindows.isEmpty {
                    essentialWindowSummary(schedule.essentialWindows)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func scheduleMenu(for info: ScheduleOverviewViewModel.ChildScheduleInfo) -> some View {
        Menu {
            ForEach(viewModel.appState.scheduleProfiles) { profile in
                Button {
                    Task { await viewModel.assignSchedule(profile, to: info.child) }
                } label: {
                    if profile.id == info.schedule?.id {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                Task { await viewModel.removeSchedule(from: info.child) }
            } label: {
                Label("Remove Schedule", systemImage: "xmark.circle")
            }
        } label: {
            Text("Change")
                .font(.subheadline)
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Unassigned Row

    @ViewBuilder
    private func unassignedRow(_ child: ChildProfile) -> some View {
        HStack {
            avatar(for: child)
            Text(child.name)
                .font(.headline)
            Spacer()
            if !viewModel.appState.scheduleProfiles.isEmpty {
                Menu("Assign") {
                    ForEach(viewModel.appState.scheduleProfiles) { profile in
                        Button(profile.name) {
                            Task { await viewModel.assignSchedule(profile, to: child) }
                        }
                    }
                }
                .font(.subheadline)
            } else {
                Text("No templates")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Avatar

    @ViewBuilder
    private func avatar(for child: ChildProfile) -> some View {
        let initials = String(child.name.prefix(1)).uppercased()
        ZStack {
            Circle()
                .fill(.tint.opacity(0.2))
                .frame(width: 36, height: 36)
            Text(initials)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Free Window Summary

    @ViewBuilder
    private func freeWindowSummary(_ windows: [ActiveWindow]) -> some View {
        let lines = FreeWindowFormatter.format(windows)
        if lines.isEmpty {
            Text("No free windows")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Essential Window Summary

    @ViewBuilder
    private func essentialWindowSummary(_ windows: [ActiveWindow]) -> some View {
        let lines = FreeWindowFormatter.format(windows)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Essential Only")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.purple.opacity(0.7))
                }
            }
        }
    }
}

// MARK: - Assign Schedule Sheet

private struct AssignScheduleSheet: View {
    let viewModel: ScheduleOverviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedChildID: ChildProfileID?
    @State private var selectedProfileID: UUID?
    @State private var isAssigning = false

    var body: some View {
        NavigationStack {
            List {
                Section("Child") {
                    ForEach(viewModel.appState.orderedChildProfiles) { child in
                        Button {
                            selectedChildID = child.id
                        } label: {
                            HStack {
                                Text(child.name)
                                Spacer()
                                if selectedChildID == child.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Section("Schedule Template") {
                    if viewModel.appState.scheduleProfiles.isEmpty {
                        Text("No templates — create one first via Manage Templates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.appState.scheduleProfiles) { profile in
                            Button {
                                selectedProfileID = profile.id
                            } label: {
                                HStack {
                                    Text(profile.name)
                                    Spacer()
                                    if selectedProfileID == profile.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                if let profileID = selectedProfileID,
                   let profile = viewModel.appState.scheduleProfiles.first(where: { $0.id == profileID }) {
                    Section("Preview") {
                        let freeLines = FreeWindowFormatter.format(profile.freeWindows)
                        if freeLines.isEmpty {
                            Text("No free windows defined")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(freeLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        let essentialLines = FreeWindowFormatter.format(profile.essentialWindows)
                        if !essentialLines.isEmpty {
                            Text("Essential Only")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.purple)
                            ForEach(essentialLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.purple.opacity(0.7))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Assign Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Assign") {
                        guard let childID = selectedChildID,
                              let profileID = selectedProfileID,
                              let child = viewModel.appState.orderedChildProfiles.first(where: { $0.id == childID }),
                              let profile = viewModel.appState.scheduleProfiles.first(where: { $0.id == profileID })
                        else { return }
                        isAssigning = true
                        Task {
                            await viewModel.assignSchedule(profile, to: child)
                            dismiss()
                        }
                    }
                    .disabled(selectedChildID == nil || selectedProfileID == nil || isAssigning)
                }
            }
        }
    }
}

// MARK: - Free Window Formatter

enum FreeWindowFormatter {
    /// Groups free windows by day-set and formats them compactly.
    /// Returns lines like "Mon-Fri  3:00-5:00 PM, 7:00-8:00 PM"
    static func format(_ windows: [ActiveWindow]) -> [String] {
        guard !windows.isEmpty else { return [] }

        // Group windows by their day set
        var grouped: [Set<DayOfWeek>: [ActiveWindow]] = [:]
        for window in windows {
            grouped[window.daysOfWeek, default: []].append(window)
        }

        // Sort groups: weekdays first, then weekend, then other
        let sortedGroups = grouped.sorted { a, b in
            daySetOrder(a.key) < daySetOrder(b.key)
        }

        var lines: [String] = []
        for (days, windows) in sortedGroups {
            let dayLabel = formatDaySet(days)
            let timeRanges = windows
                .sorted { $0.startTime < $1.startTime }
                .map { formatTimeRange($0.startTime, $0.endTime) }
                .joined(separator: ", ")
            lines.append("\(dayLabel)  \(timeRanges)")
        }
        return lines
    }

    private static func formatDaySet(_ days: Set<DayOfWeek>) -> String {
        if days == DayOfWeek.weekdays { return "Mon-Fri" }
        if days == DayOfWeek.weekend { return "Sat-Sun" }
        if days == Set(DayOfWeek.allCases) { return "Every day" }

        let sorted = days.sorted()
        if sorted.count <= 2 {
            return sorted.map(\.shortName).joined(separator: ", ")
        }

        // Check if consecutive
        let rawValues = sorted.map(\.rawValue)
        if let first = rawValues.first, let last = rawValues.last,
           let firstDay = sorted.first, let lastDay = sorted.last,
           last - first == rawValues.count - 1 {
            return "\(firstDay.shortName)-\(lastDay.shortName)"
        }

        return sorted.map(\.shortName).joined(separator: ", ")
    }

    private static func formatTimeRange(_ start: DayTime, _ end: DayTime) -> String {
        "\(formatTime(start)) – \(formatTime(end))"
    }

    private static func formatTime(_ time: DayTime) -> String {
        let hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12
        let ampm = time.hour < 12 ? "am" : "pm"
        if time.minute == 0 {
            return "\(hour12)\(ampm)"
        }
        return "\(hour12):\(String(format: "%02d", time.minute))\(ampm)"
    }

    private static func daySetOrder(_ days: Set<DayOfWeek>) -> Int {
        if days == DayOfWeek.weekdays { return 0 }
        if days == DayOfWeek.weekend { return 1 }
        if days == Set(DayOfWeek.allCases) { return -1 }
        return 2
    }
}
