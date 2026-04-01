#if canImport(FamilyControls)
import SwiftUI
import FamilyControls
import ManagedSettings
import BigBrotherCore

/// Picker for selecting apps to track with time limits.
/// Triggered remotely by the parent via requestTimeLimitSetup command.
/// Selected tokens are stored as AppTimeLimit entries with fingerprints.
/// The parent then sets daily minutes via the parent UI + CloudKit.
struct TimeLimitSetupView: View {
    let appState: AppState
    @State private var selection = FamilyActivitySelection()
    @State private var showingPicker = false
    @State private var isSaving = false
    @State private var feedbackMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Select apps to set daily time limits on. The parent will configure the allowed minutes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    showingPicker = true
                } label: {
                    Label("Choose Apps", systemImage: "timer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                if !selection.applicationTokens.isEmpty {
                    Text("\(selection.applicationTokens.count) app\(selection.applicationTokens.count == 1 ? "" : "s") selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let feedback = feedbackMessage {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedback.hasPrefix("Failed") ? .red : .green)
                }

                Spacer()
            }
            .padding(.top, 24)
            .familyActivityPicker(isPresented: $showingPicker, selection: $selection)
            .onChange(of: selection) { _, newSelection in
                if !newSelection.applicationTokens.isEmpty {
                    Task { await save(newSelection) }
                }
            }
            .navigationTitle("App Time Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                // Load existing time limit tokens into the selection.
                loadExisting()
                // Auto-open picker.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingPicker = true
                }
            }
        }
    }

    private func loadExisting() {
        let storage = AppGroupStorage()
        let existing = storage.readAppTimeLimits()
        let decoder = JSONDecoder()
        var tokens = Set<ApplicationToken>()
        for limit in existing {
            if let token = try? decoder.decode(ApplicationToken.self, from: limit.tokenData) {
                tokens.insert(token)
            }
        }
        if !tokens.isEmpty {
            selection.applicationTokens = tokens
        }
    }

    private func save(_ newSelection: FamilyActivitySelection) async {
        isSaving = true
        let storage = AppGroupStorage()
        let encoder = JSONEncoder()
        var existing = storage.readAppTimeLimits()
        let existingFingerprints = Set(existing.map(\.fingerprint))

        var newCount = 0
        for token in newSelection.applicationTokens {
            guard let data = try? encoder.encode(token) else { continue }
            let fingerprint = TokenFingerprint.fingerprint(for: data)
            guard !existingFingerprints.contains(fingerprint) else { continue }

            // Resolve name
            let app = Application(token: token)
            let name = app.localizedDisplayName ?? app.bundleIdentifier ?? "App"

            let limit = AppTimeLimit(
                appName: name,
                tokenData: data,
                bundleID: app.bundleIdentifier,
                fingerprint: fingerprint,
                dailyLimitMinutes: 0 // Parent will set this
            )
            existing.append(limit)
            newCount += 1

            // Cache app name for other components
            let base64 = data.base64EncodedString()
            storage.cacheAppName(name, forTokenKey: base64)
        }

        // Remove tokens that were deselected
        let selectedFingerprints: Set<String> = Set(newSelection.applicationTokens.compactMap {
            guard let data = try? encoder.encode($0) else { return nil }
            return TokenFingerprint.fingerprint(for: data)
        })
        existing.removeAll { !selectedFingerprints.contains($0.fingerprint) }

        try? storage.writeAppTimeLimits(existing)

        // Auto-add time-limited apps to the always-allowed list so they work
        // until the limit fires. Uses the same token — no extra slots.
        if let allowedData = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           var allowedTokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: allowedData) {
            for token in newSelection.applicationTokens {
                allowedTokens.insert(token)
            }
            if let encoded = try? JSONEncoder().encode(allowedTokens) {
                try? storage.writeRawData(encoded, forKey: StorageKeys.allowedAppTokens)
            }
        } else {
            // No existing allowed list — create one with just these tokens.
            if let encoded = try? JSONEncoder().encode(newSelection.applicationTokens) {
                try? storage.writeRawData(encoded, forKey: StorageKeys.allowedAppTokens)
            }
        }

        // Log event so parent sees the setup completed
        if let enrollment = try? KeychainManager().get(ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState) {
            let names = existing.map(\.appName).joined(separator: ", ")
            let entry = EventLogEntry(
                deviceID: enrollment.deviceID,
                familyID: enrollment.familyID,
                eventType: .timeLimitSetupCompleted,
                details: "Time limit apps configured: \(names) (\(existing.count) total)"
            )
            try? storage.appendEventLog(entry)
        }

        feedbackMessage = "\(existing.count) app\(existing.count == 1 ? "" : "s") configured"
        isSaving = false

        // Dismiss after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dismiss()
        }
    }
}
#endif
