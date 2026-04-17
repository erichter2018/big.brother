import SwiftUI
import BigBrotherCore

/// Shown when the child returns to Big Brother after tapping "Ask for More Time" on a shield.
///
/// The token was already captured by ShieldConfiguration/ShieldAction and cached in UserDefaults.
/// This view simply asks the child to type the app name they saw on the shield, pairs it with
/// the cached token, and sends the unlock request.
struct AppNamingPromptView: View {
    let appState: AppState
    @State private var appName = ""
    @State private var isSending = false
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    /// Pre-populate from the cached shield info if we got a useful name.
    private var cachedAppName: String? {
        let defaults = UserDefaults.appGroup
        guard let name = defaults?.string(forKey: AppGroupKeys.lastShieldedAppName),
              isUsefulName(name) else { return nil }
        return name
    }

    private var cachedTokenBase64: String? {
        let defaults = UserDefaults.appGroup
        return defaults?.string(forKey: AppGroupKeys.lastShieldedTokenBase64)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "questionmark.app")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("What app were you trying to open?")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                Text("Type the name you saw on the blocked screen. Your parent will be notified.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                TextField("App name (e.g. YouTube)", text: $appName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal)
                    .onAppear {
                        if let cached = cachedAppName {
                            appName = cached
                        }
                    }

                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedback.hasPrefix("Sent") ? .green : .orange)
                }

                Spacer()
            }
            .navigationTitle("Request App Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send Request") { sendRequest() }
                        .disabled(appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func sendRequest() {
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        isSending = true

        // Cache the name for the token if we have one.
        if let tokenBase64 = cachedTokenBase64 {
            appState.storage.cacheAppName(trimmedName, forTokenKey: tokenBase64)

            // Also update the UserDefaults name map so extensions see it.
            let defaults = UserDefaults.appGroup
            var nameMap = defaults?.dictionary(forKey: AppGroupKeys.tokenToAppName) as? [String: String] ?? [:]
            nameMap[tokenBase64] = trimmedName
            defaults?.set(nameMap, forKey: AppGroupKeys.tokenToAppName)
        }

        let requestID = UUID()
        var details = "Requesting access to \(trimmedName)"
        if let tokenBase64 = cachedTokenBase64 {
            details += "\nTOKEN:\(tokenBase64)"
        }

        // Store pending request locally.
        if let tokenBase64 = cachedTokenBase64,
           let tokenData = Data(base64Encoded: tokenBase64) {
            let pendingRequest = PendingUnlockRequest(
                id: requestID,
                appName: trimmedName,
                tokenData: tokenData,
                requestedAt: Date()
            )
            try? appState.storage.appendPendingUnlockRequest(pendingRequest)
        }

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

        try? appState.storage.clearUnlockPickerPending()

        feedback = "Sent request to your parent"
        isSending = false

        // Trigger immediate sync.
        Task {
            try? await appState.eventLogger?.syncPendingEvents()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dismiss()
        }
    }

    private func isUsefulName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !n.isEmpty && n != "app" && n != "an app" && n != "unknown"
            && !n.hasPrefix("blocked app ") && !n.contains("token(")
    }
}
