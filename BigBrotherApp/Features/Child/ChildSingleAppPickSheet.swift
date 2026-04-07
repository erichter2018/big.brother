#if canImport(FamilyControls)
import SwiftUI
import FamilyControls
import ManagedSettings
import BigBrotherCore

/// Child picks ONE app via inline picker. As soon as one app is selected,
/// the picker disappears and the naming view appears with Label(token) + text field.
/// Same visual style as the parent naming sheet.
struct ChildSingleAppPickSheet: View {
    let appState: AppState
    let onSubmit: (ApplicationToken, String) -> Void

    @State private var selection = FamilyActivitySelection()
    @State private var pickedToken: ApplicationToken?
    @State private var enteredName = ""
    @State private var nameFromCloudKit = false
    @State private var isSaving = false
    @State private var alreadyConfiguredMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let token = pickedToken {
                    namingView(token: token)
                } else {
                    pickerView
                }
            }
            .navigationTitle("Request an App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var pickerView: some View {
        VStack(spacing: 8) {
            Text("Select the app you want")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top)

            if let msg = alreadyConfiguredMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            FamilyActivityPicker(selection: $selection)
                .onChange(of: selection) { _, newValue in
                    if let token = newValue.applicationTokens.first {
                        // Check if already submitted or configured
                        if isAlreadyConfigured(token: token) {
                            alreadyConfiguredMessage = "This app is already configured or pending review."
                            return
                        }
                        pickedToken = token
                        lookupExistingName(token: token)
                    }
                }
        }
    }

    @ViewBuilder
    private func namingView(token: ApplicationToken) -> some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Text("Type the name of the app you selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Name This App") {
                    HStack(spacing: 12) {
                        Label(token)
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .frame(minWidth: 80, alignment: .leading)
                            .lineLimit(1)

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        if nameFromCloudKit {
                            Text(enteredName)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        } else {
                            TextField("Type name", text: $enteredName)
                                .textFieldStyle(.roundedBorder)
                                .font(.subheadline)
                                .autocorrectionDisabled()
                        }
                    }
                }
            }

            Button {
                let name = enteredName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                isSaving = true
                onSubmit(token, name)
                dismiss()
            } label: {
                Text("Submit for Review")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(enteredName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            .padding()
        }
    }

    /// Check if this token is already submitted, pending, or configured.
    private func isAlreadyConfigured(token: ApplicationToken) -> Bool {
        let storage = AppGroupStorage()
        guard let tokenData = try? JSONEncoder().encode(token) else { return false }
        let fingerprint = TokenFingerprint.fingerprint(for: tokenData)

        // In picker selection (already submitted)
        if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
           let existing = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data),
           existing.applicationTokens.contains(token) {
            return true
        }
        // In pending review
        if let data = storage.readRawData(forKey: "pending_review_local.json"),
           let pending = try? JSONDecoder().decode([PendingAppReview].self, from: data),
           pending.contains(where: { $0.appFingerprint == fingerprint }) {
            return true
        }
        // Has time limit
        if storage.readAppTimeLimits().contains(where: { $0.fingerprint == fingerprint }) {
            return true
        }
        // In allowed tokens
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let allowed = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data),
           allowed.contains(token) {
            return true
        }
        return false
    }

    /// Check CloudKit for an existing name for this token fingerprint.
    /// If found (from a previous add/remove cycle), auto-populate and lock the field.
    private func lookupExistingName(token: ApplicationToken) {
        guard let tokenData = try? JSONEncoder().encode(token) else { return }
        let fp = TokenFingerprint.fingerprint(for: tokenData)

        // Check local cache first (App Group storage)
        let storage = AppGroupStorage()
        let nameCache = storage.readAllCachedAppNames()
        let tokenKey = tokenData.base64EncodedString()
        if let cached = nameCache[tokenKey], !cached.hasPrefix("App "), !cached.hasPrefix("Temporary") {
            enteredName = cached
            nameFromCloudKit = true
            return
        }

        // Check CloudKit TimeLimitConfigs (includes inactive/revoked ones with preserved names)
        guard let cloudKit = appState.cloudKit,
              let enrollment = try? KeychainManager().get(
                  ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
              ) else { return }

        Task {
            if let configs = try? await cloudKit.fetchTimeLimitConfigs(childProfileID: enrollment.childProfileID) {
                if let match = configs.first(where: { $0.appFingerprint == fp }) {
                    await MainActor.run {
                        enteredName = match.appName
                        nameFromCloudKit = true
                    }
                }
            }
        }
    }
}
#endif
