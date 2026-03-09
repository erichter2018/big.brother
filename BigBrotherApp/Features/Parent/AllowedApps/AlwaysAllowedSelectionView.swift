import SwiftUI
import FamilyControls
import BigBrotherCore

/// Wraps FamilyActivitySelection for picking always-allowed apps.
///
/// FamilyActivityPicker requires FamilyControls import, which is only
/// in the app target (not BigBrotherCore). The selected tokens are
/// serialized to Data for storage in the ChildProfile.
struct AlwaysAllowedSelectionView: View {
    let appState: AppState
    let childProfile: ChildProfile
    @State private var selection = FamilyActivitySelection()
    @State private var isSaving = false
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Select apps that should always be allowed in Daily Mode for \(childProfile.name).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            FamilyActivityPicker(selection: $selection)

            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(feedback.contains("Error") ? .red : .green)
            }

            Button {
                Task { await saveSelection() }
            } label: {
                Text("Save Selection")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
            .padding(.horizontal)
        }
        .navigationTitle("Allowed Apps")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadExistingSelection() }
    }

    private func loadExistingSelection() {
        // Decode existing tokens if available.
        if let data = childProfile.alwaysAllowedTokensData {
            if let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
                selection = decoded
            }
        }
    }

    private func saveSelection() async {
        isSaving = true
        defer { isSaving = false }

        guard let cloudKit = appState.cloudKit else {
            feedback = "Error: CloudKit not available"
            return
        }

        // Serialize the selection to Data for storage.
        guard let data = try? JSONEncoder().encode(selection) else {
            feedback = "Error: Could not encode selection"
            return
        }

        var updated = childProfile
        updated.alwaysAllowedTokensData = data
        updated.updatedAt = Date()

        do {
            try await cloudKit.saveChildProfile(updated)
            feedback = "Saved"
            // Update local cache.
            if let idx = appState.childProfiles.firstIndex(where: { $0.id == childProfile.id }) {
                appState.childProfiles[idx] = updated
            }
        } catch {
            feedback = "Error: \(error.localizedDescription)"
        }
    }
}
