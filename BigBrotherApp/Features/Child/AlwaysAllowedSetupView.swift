#if canImport(FamilyControls)
import SwiftUI
import FamilyControls
import ManagedSettings
import BigBrotherCore

/// Picker for selecting apps that are always allowed in daily mode.
/// Triggered remotely by the parent via requestAlwaysAllowedSetup command.
/// Selected tokens are saved to allowedAppTokens and enforcement is reapplied.
struct AlwaysAllowedSetupView: View {
    let appState: AppState
    @State private var selection = FamilyActivitySelection()
    @State private var isSaving = false
    @State private var feedbackMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Select apps that should always be available in Daily Mode. These apps will NOT be blocked.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                FamilyActivityPicker(selection: $selection)

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
            }
            .navigationTitle("Always Allowed Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveSelection() }
                        .disabled(isSaving)
                }
            }
            .onAppear { loadExisting() }
        }
    }

    private func loadExisting() {
        // Load current allowed tokens and build a selection from them.
        // Start fresh — the parent will select all apps they want allowed.
        selection = FamilyActivitySelection()
    }

    private func saveSelection() {
        isSaving = true

        do {
            // Encode the selected tokens and save as allowedAppTokens.
            let tokens = selection.applicationTokens
            let data = try JSONEncoder().encode(tokens)
            try appState.storage.writeRawData(data, forKey: StorageKeys.allowedAppTokens)

            // Cache names from the picker for display.
            for application in selection.applications {
                guard let token = application.token,
                      let tokenData = try? JSONEncoder().encode(token) else { continue }
                let key = tokenData.base64EncodedString()
                let name = application.localizedDisplayName
                    ?? application.bundleIdentifier?.split(separator: ".").last.map(String.init)
                    ?? "App"
                appState.storage.cacheAppName(name, forTokenKey: key)
            }

            feedbackMessage = "Saved: \(tokens.count) always-allowed apps"

            // Reapply enforcement so exemptions take effect immediately.
            if let policy = appState.currentEffectivePolicy,
               policy.resolvedMode != .unlocked {
                try? appState.enforcement?.apply(policy)
            }

            #if DEBUG
            print("[BigBrother] Saved \(tokens.count) always-allowed app tokens")
            #endif

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                dismiss()
            }
        } catch {
            feedbackMessage = "Failed to save: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
#endif
