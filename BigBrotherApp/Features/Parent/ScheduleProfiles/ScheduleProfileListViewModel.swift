import Foundation
import Observation
import CloudKit
import BigBrotherCore

@Observable
@MainActor
final class ScheduleProfileListViewModel {
    let appState: AppState

    var profiles: [ScheduleProfile] { appState.scheduleProfiles }
    var isLoading = false
    var errorMessage: String?

    init(appState: AppState) {
        self.appState = appState
    }

    func refresh() async {
        guard let familyID = appState.parentState?.familyID,
              let cloudKit = appState.cloudKit else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            appState.scheduleProfiles = try await cloudKit.fetchScheduleProfiles(familyID: familyID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPreset(_ preset: ScheduleProfile) async {
        guard let cloudKit = appState.cloudKit else { return }

        do {
            try await cloudKit.saveScheduleProfile(preset)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ profile: ScheduleProfile) async {
        guard let cloudKit = appState.cloudKit else { return }

        do {
            try await cloudKit.deleteScheduleProfile(profile.id)
            appState.scheduleProfiles.removeAll { $0.id == profile.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ profile: ScheduleProfile) async {
        guard let cloudKit = appState.cloudKit else { return }

        do {
            try await cloudKit.saveScheduleProfile(profile)

            // Bump scheduleProfileVersion on all devices using this profile so
            // child devices detect the change and re-fetch. Without this, edits
            // to window times are invisible to children (version check skips fetch).
            let affectedDevices = appState.childDevices.filter { $0.scheduleProfileID == profile.id }
            for device in affectedDevices {
                try? await cloudKit.updateDeviceFields(
                    deviceID: device.id,
                    fields: [
                        CKFieldName.scheduleProfileVersion: profile.updatedAt as CKRecordValue
                    ]
                )
            }

            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
