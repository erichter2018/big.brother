#if canImport(FamilyControls)
import Foundation
import FamilyControls
import ManagedSettings
import BigBrotherCore

/// Captures app names from FamilyActivityPicker selections.
///
/// `Application.localizedDisplayName` only works during the picker interaction.
/// This harvester should be called from every picker's `.onChange(of: selection)`
/// to build a persistent fingerprint→name database over time.
///
/// Names come from iOS (localizedDisplayName) and are trustworthy — the kid
/// can't fake them. Only the parent can rename apps via the time limits UI.
enum AppNameHarvester {

    /// Harvest all available app names from a picker selection.
    /// Writes to App Group storage (shared across all targets).
    /// Names sync to parent via TimeLimitConfig and heartbeat data.
    static func harvest(from selection: FamilyActivitySelection) {
        let storage = AppGroupStorage()
        let encoder = JSONEncoder()
        var count = 0

        // Persist to the shared fingerprint→name map in UserDefaults (App Group).
        let defaults = UserDefaults.appGroup
        var nameMap = (defaults?.dictionary(forKey: "harvestedAppNames") as? [String: String]) ?? [:]

        for application in selection.applications {
            guard let token = application.token,
                  let tokenData = try? encoder.encode(token) else { continue }

            let name = application.localizedDisplayName ?? application.bundleIdentifier
            guard let name, !name.isEmpty else { continue }

            let fingerprint = TokenFingerprint.fingerprint(for: tokenData)
            let tokenBase64 = tokenData.base64EncodedString()

            storage.cacheAppName(name, forTokenKey: tokenBase64)
            nameMap[fingerprint] = name
            count += 1
        }

        guard count > 0 else { return }
        defaults?.set(nameMap, forKey: "harvestedAppNames")
        NSLog("[AppNameHarvester] Captured \(count) app name(s)")
    }

    /// Look up a harvested name by fingerprint.
    static func name(forFingerprint fingerprint: String) -> String? {
        let defaults = UserDefaults.appGroup
        let nameMap = (defaults?.dictionary(forKey: "harvestedAppNames") as? [String: String]) ?? [:]
        return nameMap[fingerprint]
    }

    /// All harvested names (fingerprint → name).
    static var allNames: [String: String] {
        let defaults = UserDefaults.appGroup
        return (defaults?.dictionary(forKey: "harvestedAppNames") as? [String: String]) ?? [:]
    }
}
#endif
