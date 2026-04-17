import SwiftUI
import BigBrotherCore

/// Allows the primary parent to see and revoke access for invited parents.
struct ManageParentsView: View {
    let appState: AppState

    @State private var invites: [EnrollmentInvite] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var revokeTarget: EnrollmentInvite?

    private var usedInvites: [EnrollmentInvite] {
        invites.filter { $0.used && !$0.revoked }
    }

    private var revokedInvites: [EnrollmentInvite] {
        invites.filter { $0.revoked }
    }

    var body: some View {
        List {
            if isLoading {
                Section {
                    ProgressView("Loading...")
                }
            } else if usedInvites.isEmpty && revokedInvites.isEmpty {
                Section {
                    Text("No other parents have joined yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                if !usedInvites.isEmpty {
                    Section("Active Parents") {
                        ForEach(usedInvites, id: \.code) { invite in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Joined \(invite.createdAt, style: .date)")
                                        .font(.subheadline)
                                    Text("Code: \(invite.code)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Revoke") {
                                    revokeTarget = invite
                                }
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                }

                if !revokedInvites.isEmpty {
                    Section("Revoked") {
                        ForEach(revokedInvites, id: \.code) { invite in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Joined \(invite.createdAt, style: .date)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text("Code: \(invite.code)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text("Revoked")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Manage Parents")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInvites() }
        .refreshable { await withDeadline(30) { await loadInvites() } }
        .alert("Revoke Parent Access?", isPresented: .init(
            get: { revokeTarget != nil },
            set: { if !$0 { revokeTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { revokeTarget = nil }
            Button("Revoke", role: .destructive) {
                if let invite = revokeTarget {
                    Task { await revokeInvite(invite) }
                }
            }
        } message: {
            Text("This parent will be locked out of the app on their next refresh. This cannot be undone.")
        }
    }

    private func loadInvites() async {
        guard let familyID = appState.parentState?.familyID,
              let cloudKit = appState.cloudKit else { return }
        isLoading = true
        errorMessage = nil
        do {
            invites = try await cloudKit.fetchParentInvites(familyID: familyID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func revokeInvite(_ invite: EnrollmentInvite) async {
        guard let cloudKit = appState.cloudKit else { return }
        do {
            try await cloudKit.revokeInvite(code: invite.code)
            await loadInvites()
        } catch {
            errorMessage = "Failed to revoke: \(error.localizedDescription)"
        }
        revokeTarget = nil
    }
}
