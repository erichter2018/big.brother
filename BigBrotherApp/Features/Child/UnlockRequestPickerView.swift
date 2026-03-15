import SwiftUI
import BigBrotherCore

#if canImport(FamilyControls)
import FamilyControls
import ManagedSettings

/// Child-facing view for selecting which app to request access to.
/// Shown when the child taps "Ask for More Time" on a blocked app's shield,
/// then opens the BigBrother app.
struct UnlockRequestPickerView: View {
    let appState: AppState
    @State private var selection = FamilyActivitySelection()
    @State private var isSending = false
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Select the app you'd like to use, then tap Send Request. Your parent will be notified.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                FamilyActivityPicker(selection: $selection)

                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedback.hasPrefix("Sent") ? .green : .orange)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Request App Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send Request") { sendRequests() }
                        .disabled(selection.applicationTokens.isEmpty || isSending)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func sendRequests() {
        isSending = true

        let tokens = selection.applicationTokens
        guard !tokens.isEmpty else { return }
        let selectedApplications = applicationsByTokenKey()
        try? appState.storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .tokenNameResearch,
            message: "unlock picker: preparing \(tokens.count) request(s) from \(selectedApplications.count) explicit app selection(s)"
        ))

        var requestCount = 0
        for token in tokens {
            guard let tokenData = try? JSONEncoder().encode(token) else { continue }
            let tokenBase64 = tokenData.base64EncodedString()
            let selectedApp = selectedApplications[tokenBase64]
            let appName = Self.displayName(
                for: selectedApp ?? Application(token: token),
                fallbackToken: token
            )

            #if DEBUG
            print("[BigBrother] Picker token: displayName=\(selectedApp?.localizedDisplayName ?? "nil") bundleID=\(selectedApp?.bundleIdentifier ?? "nil")")
            #endif

            appState.storage.cacheAppName(appName, forTokenKey: tokenBase64)
            try? appState.storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .tokenNameResearch,
                message: "unlock picker: cached \(appName) [\(Self.tokenFingerprint(for: tokenData).prefix(8))]"
            ))

            let requestID = UUID()
            let details = "Requesting access to \(appName)\nTOKEN:\(tokenBase64)"

            // Store the pending request locally (so CommandProcessor can find the token).
            let pendingRequest = PendingUnlockRequest(
                id: requestID,
                appName: appName,
                tokenData: tokenData,
                requestedAt: Date()
            )
            try? appState.storage.appendPendingUnlockRequest(pendingRequest)

            // Keep the CloudKit-visible event ID aligned with the pending request ID.
            if let enrollment = appState.enrollmentState {
                let event = EventLogEntry(
                    id: requestID,
                    deviceID: enrollment.deviceID,
                    familyID: enrollment.familyID,
                    eventType: .unlockRequested,
                    details: details
                )
                try? appState.storage.appendEventLog(event)
            } else {
                appState.eventLogger?.log(.unlockRequested, details: details)
            }

            requestCount += 1
        }

        try? appState.storage.clearUnlockPickerPending()

        if let policy = appState.currentEffectivePolicy,
           policy.resolvedMode != .unlocked {
            try? appState.enforcement?.apply(policy)
        }

        if requestCount > 0 {
            feedback = "Sent \(requestCount) request\(requestCount == 1 ? "" : "s") to your parent"
            // Trigger immediate sync so the parent sees the request quickly.
            Task {
                try? await appState.eventLogger?.syncPendingEvents()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                dismiss()
            }
        } else {
            feedback = "Could not send request. Try again."
            isSending = false
        }
    }

    private func applicationsByTokenKey() -> [String: Application] {
        var result: [String: Application] = [:]
        for application in selection.applications {
            guard let token = application.token,
                  let tokenData = try? JSONEncoder().encode(token) else { continue }
            result[tokenData.base64EncodedString()] = application
        }
        return result
    }

    private static func displayName(for application: Application, fallbackToken: ApplicationToken) -> String {
        if let localizedName = application.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUsefulAppName(localizedName) {
            return localizedName
        }
        if let bundleIdentifier = application.bundleIdentifier?.split(separator: ".").last {
            let candidate = String(bundleIdentifier)
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .capitalized
            if isUsefulAppName(candidate) {
                return candidate
            }
        }
        let tokenDescription = String(describing: fallbackToken)
        if let extracted = extractName(from: tokenDescription),
           isUsefulAppName(extracted) {
            return extracted
        }
        if let tokenData = try? JSONEncoder().encode(fallbackToken) {
            return "Blocked App \(tokenFingerprint(for: tokenData).prefix(8))"
        }
        return "Blocked App"
    }

    private static func extractName(from description: String) -> String? {
        if let range = description.range(of: "bundleIdentifier: ") {
            let rest = description[range.upperBound...]
            let id = rest.prefix(while: { $0 != ")" && $0 != "," })
            if let last = id.split(separator: ".").last {
                return String(last)
            }
        }
        return nil
    }

    private static func isUsefulAppName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.contains("token(") &&
            !normalized.contains("data:") &&
            !normalized.contains("bytes)")
    }

    private static func tokenFingerprint(for data: Data) -> String {
        TokenFingerprint.fingerprint(for: data)
    }
}
#endif
