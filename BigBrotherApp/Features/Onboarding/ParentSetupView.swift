import SwiftUI
import CloudKit
import BigBrotherCore

/// Parent device initial setup. Creates familyID, stores ParentState, sets role.
struct ParentSetupView: View {
    let appState: AppState

    @State private var isSettingUp = false
    @State private var errorMessage: String?
    @State private var showPINSetup = false
    @State private var setupComplete = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Parent Setup")
                .font(.title2)
                .fontWeight(.bold)

            Text("This device will be the parent controller. You'll manage your children's devices from here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let error = errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button {
                performSetup()
            } label: {
                if isSettingUp {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Create Family")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSettingUp)
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 40)
        .navigationBarBackButtonHidden(isSettingUp)
        .sheet(isPresented: $showPINSetup) {
            ParentPINSetupView(appState: appState) {
                showPINSetup = false
            }
        }
    }

    private func performSetup() {
        isSettingUp = true
        errorMessage = nil

        Task {
            do {
                let familyID = FamilyID.generate()
                let parentState = ParentState(familyID: familyID)

                try appState.setRole(.parent)
                try appState.setParentState(parentState)

                // Generate ED25519 keypair for command signing.
                if (try? appState.keychain.getData(forKey: StorageKeys.commandSigningPrivateKey)) == nil {
                    let (privateKey, publicKey) = CommandSigner.generateKeyPair()
                    try? appState.keychain.setData(privateKey, forKey: StorageKeys.commandSigningPrivateKey)
                    try? appState.keychain.setData(publicKey, forKey: StorageKeys.commandSigningPublicKey)
                }

                // Configure services now that role is set.
                appState.configureServices()

                // Bootstrap CloudKit schema before any queries.
                let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase
                await CloudKitSchemaBootstrap.bootstrapIfNeeded(database: db)

                // Prompt PIN setup.
                showPINSetup = true
            } catch {
                errorMessage = "Setup failed: \(CloudKitErrorHelper.userMessage(for: error))"
            }
            isSettingUp = false
        }
    }
}
