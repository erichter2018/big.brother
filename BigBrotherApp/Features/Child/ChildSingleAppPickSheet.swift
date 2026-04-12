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
    /// Optional hint shown above the picker, e.g. when triggered by the
    /// shield's "ask for access" flow ("Tap Roblox to re-request access").
    let promptHint: String?
    /// Optional starting text for the name field, used when ShieldConfiguration
    /// already resolved the app's name.
    let initialName: String
    let onSubmit: (ApplicationToken, String) -> Void

    init(
        appState: AppState,
        promptHint: String? = nil,
        initialName: String = "",
        onSubmit: @escaping (ApplicationToken, String) -> Void
    ) {
        self.appState = appState
        self.promptHint = promptHint
        self.initialName = initialName
        self.onSubmit = onSubmit
        self._enteredName = State(initialValue: initialName)
    }

    @State private var selection = FamilyActivitySelection()
    @State private var pickedToken: ApplicationToken?
    @State private var enteredName: String
    @State private var nameFromCloudKit = false
    @State private var isSaving = false
    @State private var alreadyConfiguredMessage: String?
    @State private var showNameRequired = false
    @FocusState private var nameFieldFocused: Bool
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
            .navigationTitle(promptHint != nil ? "Re-request Access" : "Request an App")
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
            if let hint = promptHint {
                Text(hint)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top)
            }
            Text("Select the app you want")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, promptHint == nil ? nil : 0)

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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            nameFieldFocused = true
                        }
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
                    if showNameRequired {
                        Text("You must enter the app name before submitting")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
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
                                .focused($nameFieldFocused)
                                .onChange(of: enteredName) { _, _ in
                                    showNameRequired = false
                                }
                        }
                    }
                }
            }

            Button {
                let name = enteredName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    showNameRequired = true
                    nameFieldFocused = true
                    return
                }
                isSaving = true
                onSubmit(token, name)
                dismiss()
            } label: {
                Text("Submit for Review")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
            .padding()
        }
    }

    /// Check if this token is already FULLY configured AND named.
    ///
    /// We block re-pick only if we have a real cached name AND the token is in
    /// allowedAppTokens or appTimeLimits with matching bytes. If the token is
    /// allowed but has no usable cached name (e.g. it was added before we built
    /// the naming flow), the user MUST be able to re-pick so the picker callback
    /// can capture a fresh `Application(token:).localizedDisplayName` and write
    /// it back to the cache. Without this exception, pre-naming-era apps are
    /// permanently stuck as nameless ghosts in the allowed list.
    private func isAlreadyConfigured(token: ApplicationToken) -> Bool {
        let storage = AppGroupStorage()
        guard let tokenData = try? JSONEncoder().encode(token) else { return false }
        let tokenKey = tokenData.base64EncodedString()

        // Look up the cached name. If it's missing or just a placeholder
        // ("App N", "Temporary X"), treat the token as needing re-pick so the
        // user can re-name it during this picker interaction.
        let cachedName = storage.readAllCachedAppNames()[tokenKey]
        let hasUsableName: Bool = {
            guard let name = cachedName?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return false }
            if name.hasPrefix("App ") { return false }
            if name.hasPrefix("Temporary") { return false }
            if name == "App" || name == "Unknown" { return false }
            return true
        }()
        guard hasUsableName else { return false }

        // In allowed tokens — fully working AND named, block re-pick.
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let allowed = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data),
           allowed.contains(token) {
            return true
        }
        // In time-limit list AND we can verify the token bytes match (not just
        // a stale fingerprint from a pre-rotation install).
        for limit in storage.readAppTimeLimits() {
            if limit.tokenData.base64EncodedString() == tokenKey {
                return true
            }
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
        if let cached = nameCache[tokenKey],
           cached != "App", !cached.hasPrefix("App "), !cached.hasPrefix("Temporary"),
           cached.count > 2 {
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
