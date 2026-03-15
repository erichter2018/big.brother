import Foundation
import BigBrotherCore

#if canImport(FamilyControls)
import FamilyControls
import ManagedSettings
#endif

/// Stores and retrieves FamilyActivitySelection for app blocking.
/// Uses App Group storage so extensions can also read the selection.
final class AppBlockingStore {
    private let storage: any SharedStorageProtocol

    init(storage: any SharedStorageProtocol) {
        self.storage = storage
    }

    #if canImport(FamilyControls)
    /// Save a FamilyActivitySelection from the picker.
    func saveSelection(_ selection: FamilyActivitySelection) throws {
        let data = try JSONEncoder().encode(selection)
        try storage.writeRawData(data, forKey: StorageKeys.familyActivitySelection)

        var sanitizedCache = storage.readAllCachedAppNames().filter { _, value in
            Self.isUsefulAppName(value)
        }
        let selectedApplications = Self.applicationsByTokenKey(from: selection)
        var tokenSamples: [String] = []
        var cachedCount = 0
        var pickerDiagnostics: [String] = []

        pickerDiagnostics.append(
            "picker saveSelection counts: applicationTokens=\(selection.applicationTokens.count) applications=\(selection.applications.count) categoryTokens=\(selection.categoryTokens.count)"
        )

        for application in selection.applications.prefix(12) {
            let tokenFingerprint: String
            if let token = application.token,
               let tokenData = try? JSONEncoder().encode(token) {
                tokenFingerprint = Self.tokenFingerprint(for: tokenData)
            } else {
                tokenFingerprint = "none"
            }

            let localized = application.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleID = application.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = Self.displayName(for: application)
            pickerDiagnostics.append(
                "picker application: token=\(String(tokenFingerprint.prefix(8))) localized=\(localized ?? "nil") bundleID=\(bundleID ?? "nil") resolved=\(resolvedName)"
            )
        }

        for token in selection.applicationTokens {
            guard let tokenData = try? JSONEncoder().encode(token) else { continue }
            let tokenKey = tokenData.base64EncodedString()
            let displayName = Self.displayName(
                for: token,
                preferredApplication: selectedApplications[tokenKey]
            )
            if Self.isUsefulAppName(displayName) {
                sanitizedCache[tokenKey] = displayName
                cachedCount += 1
            }
            let matchedApplication = selectedApplications[tokenKey] != nil
            pickerDiagnostics.append(
                "picker token: token=\(String(Self.tokenFingerprint(for: tokenData).prefix(8))) matchedApplication=\(matchedApplication) cachedName=\(displayName)"
            )
            if tokenSamples.count < 12 {
                tokenSamples.append("\(displayName)=\(Self.tokenFingerprint(forBase64: tokenKey))")
            }
        }
        try storage.writeCachedAppNames(sanitizedCache)
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .tokenNameResearch,
            message: "picker saveSelection: cached \(cachedCount)/\(selection.applicationTokens.count) app names from \(selectedApplications.count) explicit app selections"
        ))
        for line in pickerDiagnostics.prefix(40) {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .tokenNameResearch,
                message: line
            ))
        }

        // Extract human-readable names from tokens.
        let appNames = Self.extractAppNames(from: selection)
        let categoryNames = Self.extractCategoryNames(from: selection)

        // Update the summary config including names.
        let config = AppBlockingConfig(
            blockedCategoryCount: selection.categoryTokens.count,
            allowedAppCount: selection.applicationTokens.count,
            isConfigured: true,
            blockedAppNames: appNames,
            blockedCategoryNames: categoryNames
        )
        try storage.writeAppBlockingConfig(config)

        #if DEBUG
        print("[BigBrother] Saved FamilyActivitySelection: \(selection.applicationTokens.count) app tokens, \(selection.categoryTokens.count) category tokens")
        if !tokenSamples.isEmpty {
            print("[BigBrother] Selection token sample: \(tokenSamples.joined(separator: " | "))")
        }
        #endif
    }

    /// Extract human-readable app names from a FamilyActivitySelection.
    static func extractAppNames(from selection: FamilyActivitySelection) -> [String] {
        let selectedApplications = applicationsByTokenKey(from: selection)
        return selection.applicationTokens.map { token in
            guard let tokenData = try? JSONEncoder().encode(token) else {
                return "Blocked App"
            }
            return displayName(
                for: token,
                preferredApplication: selectedApplications[tokenData.base64EncodedString()]
            )
        }.sorted()
    }

    /// Extract human-readable category names from a FamilyActivitySelection.
    static func extractCategoryNames(from selection: FamilyActivitySelection) -> [String] {
        selection.categoryTokens.map { token in
            let description = String(describing: token)
            return Self.cleanTokenDescription(description)
        }.sorted()
    }

    /// Attempt to clean up a token description string.
    /// If the description matches known wrapper patterns, extract the inner value.
    private static func cleanTokenDescription(_ description: String) -> String {
        if let range = description.range(of: "bundleIdentifier: ") {
            let rest = description[range.upperBound...]
            let identifier = rest.prefix(while: { $0 != ")" && $0 != "," })
            if let last = identifier.split(separator: ".").last {
                return prettifyIdentifierComponent(String(last))
            }
        }

        // Some tokens describe themselves as "ApplicationToken(...)" —
        // strip the wrapper if present.
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Unknown" }
        return trimmed
    }

    private static func displayName(
        for token: ApplicationToken,
        preferredApplication: Application? = nil
    ) -> String {
        guard let tokenData = try? JSONEncoder().encode(token) else {
            return "Blocked App"
        }
        let app = preferredApplication ?? Application(token: token)
        return displayName(for: app, fallbackData: tokenData)
    }

    static func displayName(for application: Application, fallbackData: Data? = nil) -> String {
        if let localizedName = application.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUsefulAppName(localizedName) {
            return localizedName
        }
        if let bundleIdentifier = application.bundleIdentifier?.split(separator: ".").last {
            let candidate = prettifyIdentifierComponent(String(bundleIdentifier))
            if isUsefulAppName(candidate) {
                return candidate
            }
        }
        if let fallbackData {
            return fallbackDisplayName(for: fallbackData)
        }
        return "Blocked App"
    }

    private static func applicationsByTokenKey(from selection: FamilyActivitySelection) -> [String: Application] {
        var result: [String: Application] = [:]
        for application in selection.applications {
            guard let token = application.token,
                  let tokenData = try? JSONEncoder().encode(token) else { continue }
            result[tokenData.base64EncodedString()] = application
        }
        return result
    }

    private static func isUsefulAppName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.contains("token(") &&
            !normalized.contains("data:") &&
            !normalized.contains("bytes)")
    }

    private static func prettifyIdentifierComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized
    }

    private static func tokenFingerprint(forBase64 base64: String) -> String {
        TokenFingerprint.fingerprint(forBase64: base64)
    }

    private static func tokenFingerprint(for data: Data) -> String {
        TokenFingerprint.fingerprint(for: data)
    }

    private static func fallbackDisplayName(for tokenData: Data) -> String {
        let fingerprint = tokenFingerprint(for: tokenData)
        return "Blocked App \(fingerprint.prefix(8))"
    }

    /// Load the saved selection.
    func loadSelection() -> FamilyActivitySelection? {
        guard let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection) else {
            return nil
        }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }
    #endif

    /// Clear saved selection.
    func clearSelection() throws {
        try storage.writeRawData(nil, forKey: StorageKeys.familyActivitySelection)
        try storage.writeAppBlockingConfig(AppBlockingConfig())
    }

    /// Load the summary config (available without FamilyControls).
    func loadConfig() -> AppBlockingConfig? {
        storage.readAppBlockingConfig()
    }
}
