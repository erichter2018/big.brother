import SwiftUI
import BigBrotherCore

struct HeartbeatProfileEditorView: View {
    let viewModel: HeartbeatProfileListViewModel
    @State private var profile: HeartbeatProfile
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false

    private let isNew: Bool

    init(viewModel: HeartbeatProfileListViewModel, profile: HeartbeatProfile) {
        self.viewModel = viewModel
        self._profile = State(initialValue: profile)
        self.isNew = profile.name.isEmpty
    }

    static let gapOptions: [(String, TimeInterval)] = [
        ("30 min", 1800),
        ("1 hour", 3600),
        ("2 hours", 7200),
        ("4 hours", 14400),
        ("8 hours", 28800),
        ("12 hours", 43200),
        ("24 hours", 86400),
    ]

    /// Check mode options for the per-window picker.
    /// "Default" = nil (use profile-level gap), "Once per day", or a specific gap.
    private enum WindowCheckOption: Hashable {
        case profileDefault
        case oncePerDay
        case gap(TimeInterval)

        var label: String {
            switch self {
            case .profileDefault: return "Default"
            case .oncePerDay: return "Once per day"
            case .gap(let seconds):
                let hours = Int(seconds) / 3600
                let minutes = (Int(seconds) % 3600) / 60
                if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
                if hours > 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
                return "\(minutes) min"
            }
        }

        static let allOptions: [WindowCheckOption] = [
            .profileDefault,
            .oncePerDay,
            .gap(1800),
            .gap(3600),
            .gap(7200),
            .gap(14400),
            .gap(28800),
            .gap(43200),
            .gap(86400),
        ]
    }

    var body: some View {
        Form {
            Section("Profile Name") {
                TextField("e.g. School Kid Phone", text: $profile.name)
            }

            Section("Default Max Heartbeat Gap") {
                Picker("Gap", selection: $profile.maxHeartbeatGap) {
                    ForEach(Self.gapOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.menu)

                Text("Used when a window doesn't specify its own check mode.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Toggle("Default Profile", isOn: $profile.isDefault)

                Text("Applied to devices without an assigned profile.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Active Windows") {
                ForEach($profile.activeWindows) { $window in
                    windowEditor(window: $window)
                }
                .onDelete { indexSet in
                    profile.activeWindows.remove(atOffsets: indexSet)
                }

                Button {
                    profile.activeWindows.append(
                        ActiveWindow(
                            daysOfWeek: DayOfWeek.weekdays,
                            startTime: DayTime(hour: 7, minute: 0),
                            endTime: DayTime(hour: 21, minute: 0)
                        )
                    )
                } label: {
                    Label("Add Window", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle(isNew ? "New Profile" : "Edit Profile")
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
    private func windowEditor(window: Binding<ActiveWindow>) -> some View {
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
                            .background(selected ? Color.accentColor : Color.secondary.opacity(0.15))
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
            DatePicker("Start", selection: startTimeBinding(for: window), displayedComponents: .hourAndMinute)
                .font(.caption)
            DatePicker("End", selection: endTimeBinding(for: window), displayedComponents: .hourAndMinute)
                .font(.caption)

            // Per-window check mode
            HStack {
                Text("Check Mode").font(.caption)
                Spacer()
                Picker("Check", selection: windowCheckBinding(for: window)) {
                    ForEach(WindowCheckOption.allOptions, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }

            // Explain what the current mode means
            if let mode = window.wrappedValue.checkMode {
                switch mode {
                case .oncePerDay:
                    Text("Alert only if zero heartbeats during this window today.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .gap(let seconds):
                    Text("Alert if no heartbeat for \(Int(seconds / 60)) minutes during this window.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bindings

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

    private func windowCheckBinding(for window: Binding<ActiveWindow>) -> Binding<WindowCheckOption> {
        Binding<WindowCheckOption>(
            get: {
                guard let mode = window.wrappedValue.checkMode else { return .profileDefault }
                switch mode {
                case .oncePerDay: return .oncePerDay
                case .gap(let seconds): return .gap(seconds)
                }
            },
            set: { option in
                switch option {
                case .profileDefault: window.wrappedValue.checkMode = nil
                case .oncePerDay: window.wrappedValue.checkMode = .oncePerDay
                case .gap(let seconds): window.wrappedValue.checkMode = .gap(seconds)
                }
            }
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

        profile.updatedAt = Date()
        await viewModel.save(profile)
        dismiss()
    }
}
