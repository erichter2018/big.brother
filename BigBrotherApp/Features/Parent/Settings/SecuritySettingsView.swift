import SwiftUI
import BigBrotherCore

struct SecuritySettingsView: View {
    let appState: AppState
    @State private var showChangePIN = false
    @State private var feedback: String?

    var body: some View {
        List {
            Section("Biometric Authentication") {
                HStack {
                    Label("Face ID / Touch ID", systemImage: "faceid")
                    Spacer()
                    Text(appState.auth?.isBiometricAvailable == true ? "Available" : "Not Available")
                        .foregroundStyle(appState.auth?.isBiometricAvailable == true ? .green : .secondary)
                }
            }

            Section("PIN") {
                HStack {
                    Label("Parent PIN", systemImage: "lock")
                    Spacer()
                    let hasPIN = (try? appState.keychain.getData(forKey: StorageKeys.parentPINHash)) != nil
                    Text(hasPIN ? "Configured" : "Not Set")
                        .foregroundStyle(hasPIN ? .green : .red)
                }

                Button("Change PIN") {
                    showChangePIN = true
                }
            }

            if let feedback {
                Section {
                    Text(feedback)
                        .foregroundStyle(.green)
                }
            }

            Section(footer: Text("PIN is stored as a PBKDF2-HMAC-SHA256 hash in the Keychain. It is never stored in plaintext.")) {
                EmptyView()
            }
        }
        .navigationTitle("Security")
        .sheet(isPresented: $showChangePIN) {
            NavigationStack {
                ParentPINSetupView(appState: appState, isInitialSetup: false)
            }
        }
    }
}
