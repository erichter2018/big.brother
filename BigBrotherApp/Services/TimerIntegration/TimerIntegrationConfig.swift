import Foundation
import BigBrotherCore

/// Persistent configuration for the AllowanceTracker timer integration.
struct TimerIntegrationConfig: Codable {
    var isEnabled: Bool = false
    /// The Firebase family document ID.
    var firebaseFamilyID: String?
    /// Maps AllowanceTracker kid document IDs to Big.Brother ChildProfileIDs.
    var kidMappings: [KidMapping] = []

    struct KidMapping: Codable, Identifiable {
        /// AllowanceTracker Firestore kid document ID.
        var firestoreKidID: String
        /// AllowanceTracker kid display name (for reference).
        var firestoreKidName: String
        /// Mapped Big.Brother child profile ID.
        var childProfileID: ChildProfileID?

        var id: String { firestoreKidID }
    }

    // MARK: - Persistence

    private static let key = "fr.bigbrother.timerIntegrationConfig"

    static func load() -> TimerIntegrationConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(TimerIntegrationConfig.self, from: data)
        else { return TimerIntegrationConfig() }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
