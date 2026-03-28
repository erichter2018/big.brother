import SwiftUI
import BigBrotherCore

struct SecuritySettingsView: View {
    let appState: AppState
    @State private var showChangePIN = false
    @State private var showRemoveConfirmation = false
    @State private var feedback: String?
    @State private var authEnabled: Bool

    // PIN re-auth for destructive actions
    @State private var showPINChallenge = false
    @State private var pendingAction: PendingAction?
    @State private var challengePIN = ""
    @State private var challengeError: String?

    private enum PendingAction {
        case removePIN
        case disableAuth
    }

    init(appState: AppState) {
        self.appState = appState
        // Read from Keychain (tamper-resistant).
        let enabled: Bool
        if let data = try? appState.keychain.getData(forKey: StorageKeys.parentAuthEnabled),
           let value = String(data: data, encoding: .utf8) {
            enabled = value == "1"
        } else {
            enabled = true // Default to enabled
        }
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
                        // Skip if this change came from completing a PIN challenge.
                        guard pendingAction == nil else { return }
                        if !newValue && hasPIN {
                            // Turning off auth requires PIN verification first.
                            authEnabled = true // revert toggle
                            pendingAction = .disableAuth
                            showPINChallenge = true
                        } else {
                            let keyData = Data((newValue ? "1" : "0").utf8)
                            try? appState.keychain.setData(keyData, forKey: StorageKeys.parentAuthEnabled)
                        }
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
                            pendingAction = .removePIN
                            showPINChallenge = true
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
        .alert("Enter PIN", isPresented: $showPINChallenge) {
            SecureField("Parent PIN", text: $challengePIN)
                .keyboardType(.numberPad)
            Button("Verify") {
                verifyChallengeAndExecute()
            }
            Button("Cancel", role: .cancel) {
                challengePIN = ""
                challengeError = nil
                pendingAction = nil
            }
        } message: {
            if let challengeError {
                Text(challengeError)
            } else {
                Text("Enter your current PIN to continue.")
            }
        }
    }

    private func verifyChallengeAndExecute() {
        guard let auth = appState.auth else { return }
        let result = auth.validatePIN(challengePIN)
        challengePIN = ""

        switch result {
        case .success:
            challengeError = nil
            switch pendingAction {
            case .removePIN:
                try? appState.keychain.delete(forKey: StorageKeys.parentPINHash)
                feedback = "PIN removed. App relies on device lock for security."
            case .disableAuth:
                authEnabled = false
                try? appState.keychain.setData(Data("0".utf8), forKey: StorageKeys.parentAuthEnabled)
                feedback = "Authentication disabled."
            case .none:
                break
            }
            pendingAction = nil
        case .failure(let remaining):
            challengeError = remaining > 0
                ? "Incorrect PIN (\(remaining) attempts remaining)"
                : "Too many attempts."
            // Re-show the challenge after a brief delay so SwiftUI re-presents the alert
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                showPINChallenge = true
            }
        case .lockedOut(let until):
            let formatter = RelativeDateTimeFormatter()
            challengeError = "Locked out. Try again \(formatter.localizedString(for: until, relativeTo: Date()))."
            pendingAction = nil
        }
    }
}
