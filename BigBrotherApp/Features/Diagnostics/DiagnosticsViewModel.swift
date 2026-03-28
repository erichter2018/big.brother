import Foundation
import Observation
import BigBrotherCore

@Observable
@MainActor
final class DiagnosticsViewModel {
    let appState: AppState

    var selectedCategory: DiagnosticCategory?
    var diagnosticEntries: [DiagnosticEntry] = []
    var snapshotHistory: [SnapshotTransition] = []
    var authorizationHealth: AuthorizationHealth?
    var heartbeatStatus: HeartbeatStatus?
    var currentSnapshot: PolicySnapshot?
    var extensionSharedState: ExtensionSharedState?

    init(appState: AppState) {
        self.appState = appState
    }

    func load() {
        diagnosticEntries = appState.storage.readDiagnosticEntries(category: selectedCategory)
        snapshotHistory = appState.storage.readSnapshotHistory()
        authorizationHealth = appState.storage.readAuthorizationHealth()
        heartbeatStatus = appState.storage.readHeartbeatStatus()
        currentSnapshot = appState.snapshotStore?.loadCurrentSnapshot()
        extensionSharedState = appState.storage.readExtensionSharedState()
    }

    func filterByCategory(_ category: DiagnosticCategory?) {
        selectedCategory = category
        diagnosticEntries = appState.storage.readDiagnosticEntries(category: category)
    }
}
