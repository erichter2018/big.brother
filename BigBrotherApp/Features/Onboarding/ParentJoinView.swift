import SwiftUI
import CloudKit
import BigBrotherCore

/// Second parent joins an existing family by entering a parent invite code.
/// The code carries the familyID — this device becomes a parent for that family.
struct ParentJoinView: View {
    let appState: AppState

    @State private var code = ""
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var showPINSetup = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.2.badge.key")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Join as Parent")
                .font(.title2)
                .fontWeight(.bold)

            Text("Enter the parent invite code from the other parent device.\n\nGenerate one from Settings → Invite Parent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("Parent Invite Code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospaced())
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.horizontal, 40)

            if let error = errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button {
                joinFamily()
            } label: {
                if isValidating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Join Family")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.count < 6 || isValidating)
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 40)
        .navigationTitle("Join Family")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isValidating)
        .sheet(isPresented: $showPINSetup) {
            ParentPINSetupView(appState: appState) {
                showPINSetup = false
            }
        }
    }

    private func joinFamily() {
        // Ensure CloudKit is available.
        if appState.cloudKit == nil {
            appState.configureServices()
        }
        guard let enrollment = appState.enrollment else {
            errorMessage = "Enrollment service unavailable."
            return
        }

        isValidating = true
        errorMessage = nil

        Task {
            do {
                // Bootstrap CloudKit schema so the invite query works.
                let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase
                await CloudKitSchemaBootstrap.bootstrapIfNeeded(database: db)

                guard let invite = try await enrollment.validateCode(code) else {
                    errorMessage = "Invalid or expired code. Please try again."
                    isValidating = false
                    return
                }

                // Verify this is a parent invite (uses the sentinel profileID).
                guard invite.childProfileID.rawValue == "__parent_invite__" else {
                    errorMessage = "This is a child enrollment code, not a parent invite."
                    isValidating = false
                    return
                }

                // Set up as parent with the existing familyID, storing the invite code for revocation checks.
                let parentState = ParentState(familyID: invite.familyID, inviteCode: invite.code)
                try appState.setRole(.parent)
                try appState.setParentState(parentState)

                // Each parent generates their own signing keypair.
                // Children trust multiple public keys (one per parent device).
                // SECURITY: Private keys never leave the device — never stored in CloudKit.
                if (try? appState.keychain.getData(forKey: StorageKeys.commandSigningPrivateKey)) == nil {
                    let (privateKey, publicKey) = CommandSigner.generateKeyPair()
                    try? appState.keychain.setData(privateKey, forKey: StorageKeys.commandSigningPrivateKey)
                    try? appState.keychain.setData(publicKey, forKey: StorageKeys.commandSigningPublicKey)
                }

                appState.configureServices()

                // Mark the invite as used.
                if let ck = appState.cloudKit {
                    try? await ck.markInviteUsed(code: invite.code, deviceID: DeviceID(rawValue: "parent"))
                }

                // Distribute this parent's public key to all children so they
                // accept commands signed by this device.
                if let pubKeyData = try? appState.keychain.getData(forKey: StorageKeys.commandSigningPublicKey) {
                    let pubKeyBase64 = pubKeyData.base64EncodedString()
                    try? await appState.sendCommand(
                        target: .allDevices,
                        action: .addTrustedSigningKey(publicKeyBase64: pubKeyBase64)
                    )
                }

                // Prompt PIN setup.
                showPINSetup = true
            } catch {
                errorMessage = "Could not join family: \(CloudKitErrorHelper.userMessage(for: error))"
            }
            isValidating = false
        }
    }
}
