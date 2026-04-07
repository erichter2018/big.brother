import SwiftUI
import CloudKit
import BigBrotherCore

/// Parent view to add a new child profile.
struct AddChildView: View {
    let appState: AppState

    @State private var childName = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var createdProfile: ChildProfile?
    @State private var showEnrollmentCode = false
    @State private var showPaywall = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Child Information") {
                TextField("Child's Name", text: $childName)
                    .textContentType(.name)
            }

            if let error = errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    createChild()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Create Child Profile")
                    }
                }
                .disabled(childName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }

            if createdProfile != nil {
                Section("Enroll a Device") {
                    Button {
                        showEnrollmentCode = true
                    } label: {
                        Label("Generate Enrollment Code", systemImage: "qrcode")
                    }
                }
            }
        }
        .navigationTitle("Add Child")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEnrollmentCode) {
            if let profile = createdProfile {
                NavigationStack {
                    EnrollmentCodeView(appState: appState, childProfile: profile)
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(subscriptionManager: appState.subscriptionManager) {
                showPaywall = false
            }
        }
    }

    private func createChild() {
        guard let familyID = appState.parentState?.familyID,
              let cloudKit = appState.cloudKit else { return }

        let name = childName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        // Freemium gate: show paywall if adding beyond free limit.
        if !appState.subscriptionManager.canAddChild(currentChildCount: appState.childProfiles.count) {
            showPaywall = true
            return
        }

        isSaving = true
        errorMessage = nil

        Task {
            do {
                // Ensure CloudKit schema exists before saving.
                let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase
                await CloudKitSchemaBootstrap.bootstrapIfNeeded(database: db)

                let profile = ChildProfile(
                    id: ChildProfileID.generate(),
                    familyID: familyID,
                    name: name,
                    alwaysAllowedCategories: []
                )
                try await cloudKit.saveChildProfile(profile)
                createdProfile = profile
                // Refresh dashboard but don't block on failure.
                try? await appState.refreshDashboard()
            } catch {
                errorMessage = "CloudKit error: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
