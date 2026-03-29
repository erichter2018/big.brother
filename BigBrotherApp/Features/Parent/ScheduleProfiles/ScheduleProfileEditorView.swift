import SwiftUI
import BigBrotherCore

struct ScheduleProfileEditorView: View {
    let viewModel: ScheduleProfileListViewModel
    @State private var profile: ScheduleProfile
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var newExceptionDate = Date()

    private let isNew: Bool

    init(viewModel: ScheduleProfileListViewModel, profile: ScheduleProfile) {
        self.viewModel = viewModel
        self._profile = State(initialValue: profile)
        self.isNew = profile.name.isEmpty
    }

    var body: some View {
        Form {
            if isNew {
                Section("Start from Template") {
                    ForEach(ScheduleProfile.presets(familyID: profile.familyID), id: \.name) { preset in
                        Button {
                            profile.name = preset.name
                            profile.freeWindows = preset.freeWindows
                            profile.essentialWindows = preset.essentialWindows
                            profile.lockedMode = preset.lockedMode
                        } label: {
                            Label(preset.name, systemImage: "doc.on.doc")
                        }
                    }
                }
            }

            Section("Profile Name") {
                TextField("e.g. School Day", text: $profile.name)
            }

            Section("Locked Mode") {
                Picker("Mode outside free windows", selection: $profile.lockedMode) {
                    Text("Restricted").tag(LockMode.dailyMode)
                    Text("Locked").tag(LockMode.essentialOnly)
                }
                .pickerStyle(.segmented)

                Text("Applied when the device is NOT in a free window.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Toggle("Default Profile", isOn: $profile.isDefault)

                Text("Applied to devices without an assigned schedule profile.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Free Windows") {
                Text("During these windows, the device is fully unlocked.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                ForEach($profile.freeWindows) { $window in
                    windowEditor(window: $window, tint: .green)
                }
                .onDelete { indexSet in
                    profile.freeWindows.remove(atOffsets: indexSet)
                }

                Button {
                    profile.freeWindows.append(
                        ActiveWindow(
                            daysOfWeek: DayOfWeek.weekdays,
                            startTime: DayTime(hour: 15, minute: 0),
                            endTime: DayTime(hour: 20, minute: 0)
                        )
                    )
                } label: {
                    Label("Add Free Window", systemImage: "plus.circle")
                }
            }

            Section("Essential Windows") {
                Text("During these windows, only essential apps (Phone, Messages) are available. Use for bedtime or overnight.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                ForEach($profile.essentialWindows) { $window in
                    windowEditor(window: $window, tint: .purple)
                }
                .onDelete { indexSet in
                    profile.essentialWindows.remove(atOffsets: indexSet)
                }

                Button {
                    profile.essentialWindows.append(
                        ActiveWindow(
                            daysOfWeek: Set(DayOfWeek.allCases),
                            startTime: DayTime(hour: 21, minute: 30),
                            endTime: DayTime(hour: 7, minute: 0)
                        )
                    )
                } label: {
                    Label("Add Essential Window", systemImage: "plus.circle")
                }
            }

            Section("Exception Dates") {
                Text("On these dates the schedule is suspended and the device stays unlocked all day.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                ForEach(profile.exceptionDates.sorted(), id: \.self) { date in
                    Text(date, style: .date)
                }
                .onDelete { indexSet in
                    let sorted = profile.exceptionDates.sorted()
                    let toRemove = indexSet.map { sorted[$0] }
                    profile.exceptionDates.removeAll { d in toRemove.contains(where: { Calendar.current.isDate($0, inSameDayAs: d) }) }
                }

                HStack {
                    DatePicker("Date", selection: $newExceptionDate, displayedComponents: .date)
                        .labelsHidden()
                    Spacer()
                    Button {
                        let startOfDay = Calendar.current.startOfDay(for: newExceptionDate)
                        guard !profile.exceptionDates.contains(where: { Calendar.current.isDate($0, inSameDayAs: startOfDay) }) else { return }
                        profile.exceptionDates.append(startOfDay)
                    } label: {
                        Label("Add", systemImage: "plus.circle")
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New Schedule" : "Edit Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
    }

    @ViewBuilder
    private func windowEditor(window: Binding<ActiveWindow>, tint: Color = .accentColor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Day selector circles
            HStack(spacing: 4) {
                ForEach(DayOfWeek.allCases, id: \.self) { day in
                    let selected = window.wrappedValue.daysOfWeek.contains(day)
                    Button {
                        if selected {
                            window.wrappedValue.daysOfWeek.remove(day)
                        } else {
                            window.wrappedValue.daysOfWeek.insert(day)
                        }
                    } label: {
                        Text(day.initial)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .frame(width: 32, height: 32)
                            .background(selected ? tint : Color.secondary.opacity(0.15))
                            .foregroundStyle(selected ? .white : .primary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Button("Weekdays") { window.wrappedValue.daysOfWeek = DayOfWeek.weekdays }
                    .font(.caption2).buttonStyle(.bordered)
                Button("Weekend") { window.wrappedValue.daysOfWeek = DayOfWeek.weekend }
                    .font(.caption2).buttonStyle(.bordered)
                Button("All") { window.wrappedValue.daysOfWeek = Set(DayOfWeek.allCases) }
                    .font(.caption2).buttonStyle(.bordered)
            }

            // Time pickers
            DatePicker("Unlock at", selection: startTimeBinding(for: window), displayedComponents: .hourAndMinute)
                .font(.caption)
            DatePicker("Lock at", selection: endTimeBinding(for: window), displayedComponents: .hourAndMinute)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Date <-> DayTime Bridge

    private func startTimeBinding(for window: Binding<ActiveWindow>) -> Binding<Date> {
        Binding<Date>(
            get: { dayTimeToDate(window.wrappedValue.startTime) },
            set: { window.wrappedValue.startTime = dateToDayTime($0) }
        )
    }

    private func endTimeBinding(for window: Binding<ActiveWindow>) -> Binding<Date> {
        Binding<Date>(
            get: { dayTimeToDate(window.wrappedValue.endTime) },
            set: { window.wrappedValue.endTime = dateToDayTime($0) }
        )
    }

    private func dayTimeToDate(_ dt: DayTime) -> Date {
        Calendar.current.date(from: DateComponents(hour: dt.hour, minute: dt.minute)) ?? Date()
    }

    private func dateToDayTime(_ date: Date) -> DayTime {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return DayTime(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        // Purge past exception dates (keep today and future).
        let todayStart = Calendar.current.startOfDay(for: Date())
        profile.exceptionDates = profile.exceptionDates.filter { $0 >= todayStart }

        profile.updatedAt = Date()
        await viewModel.save(profile)
        dismiss()
    }
}
