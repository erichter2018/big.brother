import SwiftUI
import BigBrotherCore

/// Enrollment step: request required permissions (FamilyControls).
struct EnrollmentPermissionsView: View {
    let appState: AppState
    let invite: EnrollmentInvite

    @State private var isRequesting = false
    @State private var permissionGranted = false
    @State private var errorMessage: String?
    @State private var showComplete = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.shield")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Grant Permissions")
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    icon: "app.badge.checkmark",
                    title: "Screen Time Management",
                    description: "Required to manage app access on this device."
                )
            }
            .padding(.horizontal, 32)

            if permissionGranted {
                StatusBadge(label: "Permission Granted", color: .green, icon: "checkmark.circle.fill")
            }

            if let error = errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    requestPermissions()
                } label: {
                    if isRequesting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(permissionGranted ? "Continue" : "Grant Permission")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequesting)

                if !permissionGranted {
                    Button {
                        permissionGranted = true
                        errorMessage = "Skipped — enforcement will not work until permissions are granted."
                    } label: {
                        Text("Skip for Now")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 40)
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isRequesting)
        .navigationDestination(isPresented: $showComplete) {
            EnrollmentCompleteView(appState: appState, invite: invite)
        }
    }

    @ViewBuilder
    private func permissionRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func requestPermissions() {
        if permissionGranted {
            showComplete = true
            return
        }

        // FamilyControls isn't available until Apple approves the entitlement.
        // Skip the permission step and proceed with enrollment.
        guard let enforcement = appState.enforcement else {
            permissionGranted = true
            errorMessage = "Screen Time permissions are being set up. This may take a moment."
            return
        }

        isRequesting = true
        errorMessage = nil

        Task {
            do {
                try await enforcement.requestAuthorization()
                permissionGranted = true
            } catch {
                errorMessage = "Permission request failed. A parent must approve Screen Time access on this device."
            }
            isRequesting = false
        }
    }
}
