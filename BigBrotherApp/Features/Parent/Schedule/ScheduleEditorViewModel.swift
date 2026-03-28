import Foundation
import Observation
import BigBrotherCore

@Observable
@MainActor
final class ScheduleEditorViewModel {
    let appState: AppState
    let childProfileID: ChildProfileID

    /// nil = creating new schedule; non-nil = editing existing.
    private let existingSchedule: Schedule?

    var name: String = ""
    var mode: LockMode = .dailyMode
    var daysOfWeek: Set<DayOfWeek> = DayOfWeek.weekdays
    var startHour: Int = 8
    var startMinute: Int = 0
    var endHour: Int = 15
    var endMinute: Int = 0
    var isActive: Bool = true

    var isSaving = false
    var errorMessage: String?
    var didSave = false

    var isEditing: Bool { existingSchedule != nil }

    init(appState: AppState, childProfileID: ChildProfileID, schedule: Schedule? = nil) {
        self.appState = appState
        self.childProfileID = childProfileID
        self.existingSchedule = schedule
        if let s = schedule {
            name = s.name
            mode = s.mode
            daysOfWeek = s.daysOfWeek
            startHour = s.startTime.hour
            startMinute = s.startTime.minute
            endHour = s.endTime.hour
            endMinute = s.endTime.minute
            isActive = s.isActive
        }
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !daysOfWeek.isEmpty
            && DayTime(hour: startHour, minute: startMinute) < DayTime(hour: endHour, minute: endMinute)
    }

    var startDate: Date {
        get {
            Calendar.current.date(from: DateComponents(hour: startHour, minute: startMinute)) ?? Date()
        }
        set {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            startHour = comps.hour ?? 0
            startMinute = comps.minute ?? 0
        }
    }

    var endDate: Date {
        get {
            Calendar.current.date(from: DateComponents(hour: endHour, minute: endMinute)) ?? Date()
        }
        set {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            endHour = comps.hour ?? 0
            endMinute = comps.minute ?? 0
        }
    }

    func save() async {
        guard let familyID = appState.parentState?.familyID,
              let cloudKit = appState.cloudKit else { return }
        guard isValid else {
            errorMessage = "Please fill in all fields correctly."
            return
        }

        isSaving = true
        errorMessage = nil

        let schedule = Schedule(
            id: existingSchedule?.id ?? UUID(),
            childProfileID: childProfileID,
            familyID: familyID,
            name: name.trimmingCharacters(in: .whitespaces),
            mode: mode,
            daysOfWeek: daysOfWeek,
            startTime: DayTime(hour: startHour, minute: startMinute),
            endTime: DayTime(hour: endHour, minute: endMinute),
            isActive: isActive
        )

        do {
            try await cloudKit.saveSchedule(schedule)
            didSave = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isSaving = false
    }
}
