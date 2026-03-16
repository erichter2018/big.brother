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
        appState.childProfiles.compactMap { child in
            let profileID = scheduleProfileID(for: child)
            guard let profileID,
                  let profile = appState.scheduleProfiles.first(where: { $0.id == profileID })
            else { return nil }
            return ChildScheduleInfo(child: child, schedule: profile)
        }
    }

    var childrenWithoutSchedule: [ChildProfile] {
        appState.childProfiles.filter { child in
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

    func assignSchedule(_ profile: ScheduleProfile, to child: ChildProfile) async {
        guard let cloudKit = appState.cloudKit else { return }

        let devices = appState.childDevices.filter { $0.childProfileID == child.id }
        do {
            for var device in devices {
                device.scheduleProfileID = profile.id
                device.scheduleProfileVersion = profile.updatedAt
                try await cloudKit.saveDevice(device)
                if let idx = appState.childDevices.firstIndex(where: { $0.id == device.id }) {
                    appState.childDevices[idx].scheduleProfileID = profile.id
                    appState.childDevices[idx].scheduleProfileVersion = profile.updatedAt
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSchedule(from child: ChildProfile) async {
        guard let cloudKit = appState.cloudKit else { return }

        let devices = appState.childDevices.filter { $0.childProfileID == child.id }
        do {
            for var device in devices {
                device.scheduleProfileID = nil
                device.scheduleProfileVersion = nil
                try await cloudKit.saveDevice(device)
                if let idx = appState.childDevices.firstIndex(where: { $0.id == device.id }) {
                    appState.childDevices[idx].scheduleProfileID = nil
                    appState.childDevices[idx].scheduleProfileVersion = nil
                }
            }
        } catch {
            errorMessage = error.localizedDescription
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
