import SwiftUI
import CloudKit
import BigBrotherCore

/// Child device enrollment: enter the code from the parent.
struct EnrollmentCodeEntryView: View {
    let appState: AppState

    @State private var code = ""
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var validatedInvite: EnrollmentInvite?
    @State private var showPermissions = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "textformat.123")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Enter Setup Code")
                .font(.title2)
                .fontWeight(.bold)

            Text("Enter the code shown on the parent's device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("Enrollment Code", text: $code)
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
                validateCode()
            } label: {
                if isValidating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Continue")
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
        .navigationTitle("Set Up Device")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPermissions) {
            if let invite = validatedInvite {
                EnrollmentPermissionsView(appState: appState, invite: invite)
            }
        }
    }

    private func validateCode() {
        // Ensure services are available — unconfigured devices skip configureServices() at launch.
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
                // Bootstrap CloudKit schema so the invite query can find the record type.
                let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase
                await CloudKitSchemaBootstrap.bootstrapIfNeeded(database: db)

                if let invite = try await enrollment.validateCode(code) {
                    validatedInvite = invite
                    showPermissions = true
                } else {
                    errorMessage = "Invalid or expired code. Please try again."
                }
            } catch {
                errorMessage = "Could not validate code: \(CloudKitErrorHelper.userMessage(for: error))"
            }
            isValidating = false
        }
    }
}
