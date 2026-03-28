import SwiftUI
import BigBrotherCore

/// Final enrollment step: register device and transition into child mode.
struct EnrollmentCompleteView: View {
    let appState: AppState
    let invite: EnrollmentInvite

    @State private var isEnrolling = false
    @State private var enrollmentDone = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if enrollmentDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)

                Text("Enrollment Complete")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("This device is now managed. It will restart in child mode.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)

                Text("Complete Enrollment")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("This will register this device as a managed child device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let error = errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            if !enrollmentDone {
                Button {
                    completeEnrollment()
                } label: {
                    if isEnrolling {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Enroll This Device")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isEnrolling)
                .padding(.horizontal, 32)
            }
        }
        .padding(.bottom, 40)
        .navigationTitle("Enroll")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEnrolling || enrollmentDone)
    }

    private func completeEnrollment() {
        guard let enrollment = appState.enrollment else { return }
        isEnrolling = true
        errorMessage = nil

        Task {
            do {
                let state = try await enrollment.completeEnrollment(
                    invite: invite,
                    deviceDisplayName: EnrollmentServiceImpl.currentDeviceDisplayName,
                    modelIdentifier: EnrollmentServiceImpl.currentModelIdentifier,
                    osVersion: EnrollmentServiceImpl.currentOSVersion
                )
                try appState.setEnrollmentState(state)
                try appState.setRole(.child)
                appState.configureServices()
                appState.performRestoration()
                appState.startChildSync()

                // Set up CloudKit subscriptions for instant command delivery via push.
                try? await appState.cloudKit?.setupSubscriptions(
                    familyID: state.familyID,
                    deviceID: state.deviceID
                )

                enrollmentDone = true
            } catch {
                errorMessage = "Enrollment failed: \(CloudKitErrorHelper.userMessage(for: error))"
            }
            isEnrolling = false
        }
    }
}
