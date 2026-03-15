import Foundation
import BigBrotherCore

/// Parent-side mapping of app fingerprints to human-readable names.
///
/// When the parent sees "Blocked App bedc72d2" in an unlock request,
/// they can rename it to "YouTube". The mapping is stored locally
/// and also sent to the child device via CloudKit command so the
/// child's ShieldAction uses the correct name in future requests.
enum ParentAppNameMapping {

    private static let defaultsKey = "fr.bigbrother.parentAppNames"

    /// Get the display name for an app, applying parent overrides.
    /// If the parent has renamed "Blocked App bedc72d2" to "YouTube",
    /// this returns "YouTube".
    static func resolvedName(for rawName: String) -> String {
        // Extract fingerprint from "Blocked App bedc72d2" format
        if let fingerprint = extractFingerprint(from: rawName),
           let override = loadMapping()[fingerprint] {
            return override
        }
        return rawName
    }

    /// Save a name for a given raw app name (extracts fingerprint automatically).
    static func setName(_ name: String, for rawName: String) {
        guard let fingerprint = extractFingerprint(from: rawName) else { return }
        var mapping = loadMapping()
        mapping[fingerprint] = name
        saveMapping(mapping)
    }

    /// Save a name for a known fingerprint.
    static func setName(_ name: String, forFingerprint fingerprint: String) {
        var mapping = loadMapping()
        mapping[fingerprint] = name
        saveMapping(mapping)
    }

    /// Get the full mapping.
    static func loadMapping() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private static func saveMapping(_ mapping: [String: String]) {
        UserDefaults.standard.set(mapping, forKey: defaultsKey)
    }

    /// Extract the fingerprint from "Blocked App bedc72d2" format.
    static func extractFingerprint(from name: String) -> String? {
        if name.hasPrefix("Blocked App ") {
            return String(name.dropFirst("Blocked App ".count))
        }
        return nil
    }
}
