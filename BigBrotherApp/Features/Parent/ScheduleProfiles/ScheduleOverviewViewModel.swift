import Foundation
import Observation
import BigBrotherCore

@Observable
final class ScheduleOverviewViewModel {
    let appState: AppState

    var isLoading = false
    var errorMessage: String?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Derived Data

    struct ChildScheduleInfo: Identifiable {
        let child: ChildProfile
        let schedule: ScheduleProfile?
        var id: ChildProfileID { child.id }
    }

    var childrenWithSchedule: [ChildScheduleInfo] {
        appState.orderedChildProfiles.compactMap { child in
            let profileID = scheduleProfileID(for: child)
            guard let profileID,
                  let profile = appState.scheduleProfiles.first(where: { $0.id == profileID })
            else { return nil }
            return ChildScheduleInfo(child: child, schedule: profile)
        }
    }

    var childrenWithoutSchedule: [ChildProfile] {
        appState.orderedChildProfiles.filter { child in
            scheduleProfileID(for: child) == nil
        }
    }

    // MARK: - Actions

    func refresh() async {
        guard let familyID = appState.parentState?.familyID,
              let cloudKit = appState.cloudKit else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            async let profiles = cloudKit.fetchScheduleProfiles(familyID: familyID)
            async let devices = cloudKit.fetchDevices(familyID: familyID)
            async let children = cloudKit.fetchChildProfiles(familyID: familyID)

            appState.scheduleProfiles = try await profiles
            appState.childDevices = try await devices
            appState.childProfiles = try await children
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var successMessage: String?

    func assignSchedule(_ profile: ScheduleProfile, to child: ChildProfile) async {
        errorMessage = nil
        successMessage = nil

        let devices = appState.childDevices.filter { $0.childProfileID == child.id }
        if devices.isEmpty {
            errorMessage = "\(child.name) has no enrolled devices. Enroll a device first."
            return
        }
        do {
            let versionDate = profile.updatedAt ?? Date()
            try await appState.sendCommand(
                target: .child(child.id),
                action: .setScheduleProfile(profileID: profile.id, versionDate: versionDate)
            )
            // Update in-memory immediately for responsive UI.
            for device in devices {
                if let idx = appState.childDevices.firstIndex(where: { $0.id == device.id }) {
                    appState.childDevices[idx].scheduleProfileID = profile.id
                    appState.childDevices[idx].scheduleProfileVersion = profile.updatedAt
                }
            }
            successMessage = "Assigned \(profile.name) to \(child.name)"
        } catch {
            errorMessage = "Failed to assign schedule: \(error.localizedDescription)"
        }
    }

    func removeSchedule(from child: ChildProfile) async {
        errorMessage = nil
        successMessage = nil

        do {
            try await appState.sendCommand(
                target: .child(child.id),
                action: .clearScheduleProfile
            )
            let devices = appState.childDevices.filter { $0.childProfileID == child.id }
            for device in devices {
                if let idx = appState.childDevices.firstIndex(where: { $0.id == device.id }) {
                    appState.childDevices[idx].scheduleProfileID = nil
                    appState.childDevices[idx].scheduleProfileVersion = nil
                }
            }
        } catch {
            errorMessage = "Failed to remove schedule: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// Returns the schedule profile ID for a child by checking their devices.
    /// If multiple devices have different schedules, returns the first non-nil one.
    private func scheduleProfileID(for child: ChildProfile) -> UUID? {
        appState.childDevices
            .filter { $0.childProfileID == child.id }
            .compactMap(\.scheduleProfileID)
            .first
    }
}
