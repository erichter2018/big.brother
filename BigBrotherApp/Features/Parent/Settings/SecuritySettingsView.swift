import SwiftUI
import BigBrotherCore

struct SecuritySettingsView: View {
    let appState: AppState
    @State private var showChangePIN = false
    @State private var showRemoveConfirmation = false
    @State private var feedback: String?
    @State private var authEnabled: Bool

    init(appState: AppState) {
        self.appState = appState
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
        // Default to true if never set.
        let enabled = defaults.object(forKey: StorageKeys.parentAuthEnabled) == nil
            ? true
            : defaults.bool(forKey: StorageKeys.parentAuthEnabled)
        self._authEnabled = State(initialValue: enabled)
    }

    private var hasPIN: Bool {
        (try? appState.keychain.getData(forKey: StorageKeys.parentPINHash)) != nil
    }

    var body: some View {
        List {
            Section(footer: Text("When off, the app relies on device-level protection (Face ID / passcode) instead.")) {
                Toggle("Require Authentication", isOn: $authEnabled)
                    .onChange(of: authEnabled) { _, newValue in
                        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
                        defaults.set(newValue, forKey: StorageKeys.parentAuthEnabled)
                    }
            }

            if authEnabled {
                Section("PIN") {
                    HStack {
                        Label("Parent PIN", systemImage: "lock")
                        Spacer()
                        Text(hasPIN ? "Configured" : "Not Set")
                            .foregroundStyle(hasPIN ? .green : .secondary)
                    }

                    if hasPIN {
                        Button("Change PIN") {
                            showChangePIN = true
                        }

                        Button("Remove PIN", role: .destructive) {
                            showRemoveConfirmation = true
                        }
                    } else {
                        Button("Set Up PIN") {
                            showChangePIN = true
                        }
                    }
                }
            }

            if let feedback {
                Section {
                    Text(feedback)
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Security")
        .sheet(isPresented: $showChangePIN) {
            NavigationStack {
                ParentPINSetupView(appState: appState, isInitialSetup: false)
            }
        }
        .alert("Remove PIN?", isPresented: $showRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                try? appState.keychain.delete(forKey: StorageKeys.parentPINHash)
                feedback = "PIN removed. App relies on device lock for security."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app will no longer require a PIN. Your device passcode / Face ID is the only protection.")
        }
    }
}
