import Foundation
import Observation
import BigBrotherCore

@Observable
final class HeartbeatProfileListViewModel {
    let appState: AppState

    var profiles: [HeartbeatProfile] { appState.heartbeatProfiles }
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
            appState.heartbeatProfiles = try await cloudKit.fetchHeartbeatProfiles(familyID: familyID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPreset(_ preset: HeartbeatProfile) async {
        guard let cloudKit = appState.cloudKit else { return }

        do {
            try await cloudKit.saveHeartbeatProfile(preset)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ profile: HeartbeatProfile) async {
        guard let cloudKit = appState.cloudKit else { return }

        do {
            try await cloudKit.deleteHeartbeatProfile(profile.id)
            appState.heartbeatProfiles.removeAll { $0.id == profile.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ profile: HeartbeatProfile) async {
        guard let cloudKit = appState.cloudKit else { return }

        do {
            try await cloudKit.saveHeartbeatProfile(profile)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
