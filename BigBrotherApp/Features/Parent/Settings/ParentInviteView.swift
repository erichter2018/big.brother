import SwiftUI
import BigBrotherCore

/// Generates a parent invite code so a second parent can join the family.
/// Uses the existing EnrollmentInvite infrastructure with a sentinel childProfileID.
struct ParentInviteView: View {
    let appState: AppState

    @State private var invite: EnrollmentInvite?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.2.badge.key")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Invite Another Parent")
                .font(.title3)
                .fontWeight(.bold)

            if let invite {
                VStack(spacing: 12) {
                    Text("Enter this code on the other parent's device:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(invite.code)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .padding()
                        .background(.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text("Code expires in 30 minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("1. Open Big Brother on the other device\n2. Choose \"Join as Parent\"\n3. Enter the code above\n4. Set up a PIN")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal)
                }
            } else if isGenerating {
                ProgressView("Generating code...")
            } else if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.subheadline)

                Button("Retry") { generateCode() }
                    .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Invite Parent")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            generateCode()
        }
    }

    private func generateCode() {
        guard let enrollment = appState.enrollment,
              let familyID = appState.parentState?.familyID else { return }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                // Use a sentinel childProfileID to mark this as a parent invite.
                invite = try await enrollment.createInvite(
                    for: ChildProfileID(rawValue: "__parent_invite__"),
                    familyID: familyID
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }
}
