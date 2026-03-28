import SwiftUI
import BigBrotherCore

/// Shows the enrollment code for a child profile. Parent shows this to the child device.
struct EnrollmentCodeView: View {
    let appState: AppState
    let childProfile: ChildProfile

    @State private var invite: EnrollmentInvite?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Enroll Device for \(childProfile.name)")
                .font(.title3)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            if let invite {
                VStack(spacing: 12) {
                    Text("Enter this code on the child's device:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(invite.code)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .padding()
                        .background(.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Enrollment code: \(invite.code)")

                    Button {
                        UIPasteboard.general.string = invite.code
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { copied = false }
                        }
                    } label: {
                        Label(copied ? "Copied!" : "Copy to Clipboard",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .tint(copied ? .green : .blue)
                    .animation(.easeInOut, value: copied)

                    Text("Code expires in 30 minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("1. Open Big Brother on the child device\n2. Choose \"Enroll as Child Device\"\n3. Enter the code above\n4. Grant permissions when prompted")
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
        .navigationTitle("Enrollment Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            generateCode()
        }
    }

    private func generateCode() {
        guard let enrollment = appState.enrollment,
              let familyID = appState.parentState?.familyID else {
            errorMessage = "Unable to generate code — parent state not available."
            isGenerating = false
            return
        }

        isGenerating = true
        errorMessage = nil

        Task {
            do {
                invite = try await enrollment.createInvite(
                    for: childProfile.id,
                    familyID: familyID
                )
            } catch {
                errorMessage = CloudKitErrorHelper.userMessage(for: error)
            }
            isGenerating = false
        }
    }
}
