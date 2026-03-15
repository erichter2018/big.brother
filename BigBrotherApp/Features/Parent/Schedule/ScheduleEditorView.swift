import SwiftUI
import BigBrotherCore

struct ScheduleEditorView: View {
    @Bindable var viewModel: ScheduleEditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Schedule Name") {
                TextField("e.g. School Hours", text: $viewModel.name)
            }

            Section("Mode During Schedule") {
                Picker("Mode", selection: $viewModel.mode) {
                    Text("Daily Mode").tag(LockMode.dailyMode)
                    Text("Essential Only").tag(LockMode.essentialOnly)
                    Text("Unlocked").tag(LockMode.unlocked)
                }
                .pickerStyle(.segmented)
            }

            Section("Days") {
                daySelector
            }

            Section("Time Window") {
                DatePicker("Start", selection: $viewModel.startDate, displayedComponents: .hourAndMinute)
                DatePicker("End", selection: $viewModel.endDate, displayedComponents: .hourAndMinute)
            }

            Section {
                Toggle("Active", isOn: $viewModel.isActive)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(viewModel.isEditing ? "Edit Schedule" : "New Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await viewModel.save() }
                }
                .disabled(!viewModel.isValid || viewModel.isSaving)
            }
        }
        .onChange(of: viewModel.didSave) { _, saved in
            if saved { dismiss() }
        }
    }

    @ViewBuilder
    private var daySelector: some View {
        HStack(spacing: 4) {
            ForEach(DayOfWeek.allCases, id: \.self) { day in
                let selected = viewModel.daysOfWeek.contains(day)
                Button {
                    if selected {
                        viewModel.daysOfWeek.remove(day)
                    } else {
                        viewModel.daysOfWeek.insert(day)
                    }
                } label: {
                    Text(day.initial)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .frame(width: 36, height: 36)
                        .background(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                        .foregroundStyle(selected ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }

        HStack(spacing: 12) {
            Button("Weekdays") { viewModel.daysOfWeek = DayOfWeek.weekdays }
                .font(.caption).buttonStyle(.bordered)
            Button("Weekend") { viewModel.daysOfWeek = DayOfWeek.weekend }
                .font(.caption).buttonStyle(.bordered)
            Button("Every Day") { viewModel.daysOfWeek = Set(DayOfWeek.allCases) }
                .font(.caption).buttonStyle(.bordered)
        }
    }
}
