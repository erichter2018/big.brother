import SwiftUI
import BigBrotherCore

#if canImport(FamilyControls)
import FamilyControls
import ManagedSettings

/// View for configuring which apps/categories to block in Locked mode.
/// Shows Apple's FamilyActivityPicker. Must run on the child device.
/// Requires parent PIN before allowing access to prevent child tampering.
struct AppBlockingSetupView: View {
    let appState: AppState

    /// Skip PIN gate if no PIN hash exists on this device (child devices won't have it).
    /// The parent already authenticated to send the remote command that triggers this view.
    @State private var isAuthenticated: Bool

    init(appState: AppState) {
        self.appState = appState
        // Check if a PIN hash exists in the local Keychain.
        let hasPIN = (try? appState.keychain.getData(forKey: StorageKeys.parentPINHash)) != nil
        self._isAuthenticated = State(initialValue: !hasPIN)
    }
    @State private var pinEntry = ""
    @State private var pinError: String?
    @State private var selection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var isSaving = false
    @State private var feedbackMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if isAuthenticated {
                pickerView
            } else {
                pinGateView
            }
        }
    }

    // MARK: - PIN Gate

    @ViewBuilder
    private var pinGateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Parent Authentication Required")
                .font(.headline)

            Text("Enter your parent PIN to configure app blocking.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Parent PIN", text: $pinEntry)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            if let error = pinError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Verify") {
                verifyPIN()
            }
            .buttonStyle(.borderedProminent)
            .disabled(pinEntry.isEmpty)
        }
        .padding()
        .navigationTitle("Configure Blocked Apps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func verifyPIN() {
        guard let auth = appState.auth else {
            // No auth service — skip PIN (e.g., no PIN configured)
            isAuthenticated = true
            return
        }

        // The PIN hash is stored in the local Keychain, which is only on the device
        // where the parent set it up. On the child device, the hash won't exist.
        // Since this picker is only triggered by a remote command (parent already
        // authenticated to send it), skip the PIN gate if no hash is stored locally.
        let result = auth.validatePIN(pinEntry)
        switch result {
        case .success:
            isAuthenticated = true
            pinError = nil
        case .failure(let remaining):
            pinError = remaining > 0
                ? "Incorrect PIN (\(remaining) attempts remaining)"
                : "Too many attempts. Try again later."
            pinEntry = ""
        case .lockedOut(let until):
            let formatter = RelativeDateTimeFormatter()
            let relative = formatter.localizedString(for: until, relativeTo: Date())
            pinError = "Locked out. Try again \(relative)."
            pinEntry = ""
        }
    }

    // MARK: - Picker

    /// iOS enforces a global 50-token limit on shield.applications.
    /// Apps beyond 50 are still blocked via the category catch-all,
    /// but per-app unlock from the shield only works for the first 50.
    private static let maxPerAppTokens = 50

    private var tokenCount: Int { selection.applicationTokens.count }
    private var overLimit: Bool { tokenCount > Self.maxPerAppTokens }

    @ViewBuilder
    private var pickerView: some View {
        VStack(spacing: 16) {
            Text("Select up to \(Self.maxPerAppTokens) apps for per-app unlock. Additional apps are still blocked but use the picker flow.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            FamilyActivityPicker(selection: $selection)

            HStack {
                Text("\(tokenCount) app\(tokenCount == 1 ? "" : "s") selected")
                    .font(.caption)
                    .foregroundStyle(overLimit ? .orange : .secondary)
                if overLimit {
                    Text("(\(tokenCount - Self.maxPerAppTokens) over limit — those use picker flow)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let feedback = feedbackMessage {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(feedback.hasPrefix("Failed") ? .red : .green)
            }
        }
        .navigationTitle("Configure Blocked Apps")
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

    private func loadExisting() {
        // Start fresh so a previously saved category-only selection does not
        // overwrite the includeEntireCategory behavior of a new picker session.
        selection = FamilyActivitySelection(includeEntireCategory: true)
    }

    private func saveSelection() {
        isSaving = true
        let store = AppBlockingStore(storage: appState.storage)
        do {
            try store.saveSelection(selection)
            feedbackMessage = "Saved: \(selection.applicationTokens.count) apps, \(selection.categoryTokens.count) categories"
            // Re-apply enforcement so per-app blocking takes effect immediately.
            if let policy = appState.currentEffectivePolicy,
               policy.resolvedMode != .unlocked {
                try? appState.enforcement?.apply(policy)
            }
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
