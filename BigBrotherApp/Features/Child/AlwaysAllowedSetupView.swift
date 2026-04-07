#if canImport(FamilyControls)
import SwiftUI
import FamilyControls
import ManagedSettings
import BigBrotherCore

/// Picker for selecting apps that are always allowed in daily mode.
/// Triggered remotely by the parent via requestAlwaysAllowedSetup command.
/// Selected tokens are saved to allowedAppTokens and enforcement is reapplied.
/// Uses the sheet-style picker which includes Apple's built-in search bar.
struct AlwaysAllowedSetupView: View {
    let appState: AppState
    @State private var selection = FamilyActivitySelection()
    @State private var showingPicker = false
    @State private var isSaving = false
    @State private var feedbackMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Select apps that should always be available in Restricted mode. These apps will NOT be blocked.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    showingPicker = true
                } label: {
                    Label("Choose Apps", systemImage: "app.badge.checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .if_iOS26GlassEffect(fallbackMaterial: .regularMaterial, borderColor: .blue)
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
            .padding(.top, 8)
            .familyActivityPicker(
                isPresented: $showingPicker,
                selection: $selection
            )
            .onChange(of: selection) { _, newSelection in
                AppNameHarvester.harvest(from: newSelection)
            }
            .navigationTitle("Always Allowed Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveSelection() }
                        .disabled(isSaving || selection.applicationTokens.isEmpty)
                }
            }
            .onAppear {
                loadExisting()
                // Auto-open picker on first appearance.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showingPicker = true
                }
            }
        }
    }

    private func loadExisting() {
        // Pre-populate with currently allowed tokens so the picker shows
        // previously selected apps as already checked. New picks are additive.
        if let data = appState.storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
            selection.applicationTokens = tokens
        }
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

            isSaving = false
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
