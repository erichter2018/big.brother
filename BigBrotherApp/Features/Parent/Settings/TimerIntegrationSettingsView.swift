import SwiftUI
import BigBrotherCore

/// Settings view for configuring AllowanceTracker timer integration.
struct TimerIntegrationSettingsView: View {
    let appState: AppState
    @State private var config = TimerIntegrationConfig.load()
    @State private var email = ""
    @State private var password = ""
    @State private var isDiscovering = false
    @State private var discoveryError: String?

    private var timerService: TimerIntegrationService? { appState.timerService }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Timer Integration", isOn: $config.isEnabled)
                    .onChange(of: config.isEnabled) { _, enabled in
                        config.save()
                        if enabled {
                            if appState.timerService == nil {
                                appState.initializeTimerServiceIfNeeded()
                            }
                            if appState.timerService?.isSignedIn == true, let fid = config.firebaseFamilyID {
                                appState.timerService?.startListening(familyID: fid)
                            }
                        } else {
                            appState.timerService?.stopListening()
                        }
                    }
            } footer: {
                Text("Connect to AllowanceTracker to show penalty timers on the dashboard and control them from Big.Brother.")
            }

            if config.isEnabled {
                firebaseAuthSection
                if timerService?.isSignedIn == true {
                    familySection
                    kidMappingSection
                }
            }
        }
        .navigationTitle("Timer Integration")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Firebase Auth

    @ViewBuilder
    private var firebaseAuthSection: some View {
        Section("Firebase Account") {
            if timerService?.isSignedIn == true {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Signed In")
                    Spacer()
                    Button("Sign Out") {
                        timerService?.signOut()
                        config.firebaseFamilyID = nil
                        config.kidMappings = []
                        config.save()
                    }
                    .foregroundStyle(.red)
                }
            } else {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                    .textContentType(.password)

                Button {
                    Task {
                        await timerService?.signIn(email: email, password: password)
                        password = ""
                    }
                } label: {
                    if timerService?.isSigningIn == true {
                        ProgressView()
                    } else {
                        Text("Sign In")
                    }
                }
                .disabled(email.isEmpty || password.isEmpty || timerService?.isSigningIn == true)

                if let error = timerService?.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Family Discovery

    @ViewBuilder
    private var familySection: some View {
        Section("AllowanceTracker Family") {
            if let familyID = config.firebaseFamilyID {
                HStack {
                    Text("Family ID")
                    Spacer()
                    Text(familyID.prefix(12) + "...")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await discoverFamily() }
            } label: {
                if isDiscovering {
                    ProgressView()
                } else {
                    Text(config.firebaseFamilyID == nil ? "Discover Family" : "Refresh")
                }
            }
            .disabled(isDiscovering)

            if let error = discoveryError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Kid Mapping

    @ViewBuilder
    private var kidMappingSection: some View {
        if !config.kidMappings.isEmpty {
            Section {
                ForEach($config.kidMappings) { $mapping in
                    HStack {
                        Text(mapping.firestoreKidName)
                            .fontWeight(.medium)
                        Spacer()
                        Picker("", selection: $mapping.childProfileID) {
                            Text("None").tag(ChildProfileID?.none)
                            ForEach(appState.childProfiles) { child in
                                Text(child.name).tag(ChildProfileID?.some(child.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
                .onChange(of: config.kidMappings.map(\.childProfileID)) { _, _ in
                    config.save()
                }
                Button {
                    Task { await discoverFamily() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Rescan & Reassign")
                    }
                }
                .disabled(isDiscovering)
            } header: {
                Text("Map Kids to Children")
            } footer: {
                Text("Match each AllowanceTracker kid to the corresponding Big.Brother child profile. Rescan after adding or renaming children.")
            }
        }
    }

    // MARK: - Discovery

    private func discoverFamily() async {
        guard let service = timerService else { return }
        isDiscovering = true
        discoveryError = nil
        defer { isDiscovering = false }

        do {
            let (familyID, kids) = try await service.discoverFamily()
            config.firebaseFamilyID = familyID

            // Preserve existing mappings, add new kids, remove stale ones.
            let existingByID = Dictionary(uniqueKeysWithValues: config.kidMappings.map { ($0.firestoreKidID, $0) })
            config.kidMappings = kids.map { kid in
                if var existing = existingByID[kid.id] {
                    existing.firestoreKidName = kid.name
                    return existing
                }
                // Auto-match by name.
                let autoMatch = appState.childProfiles.first {
                    $0.name.localizedCaseInsensitiveCompare(kid.name) == .orderedSame
                }
                return TimerIntegrationConfig.KidMapping(
                    firestoreKidID: kid.id,
                    firestoreKidName: kid.name,
                    childProfileID: autoMatch?.id
                )
            }
            config.save()

            service.startListening(familyID: familyID)
        } catch {
            discoveryError = error.localizedDescription
        }
    }
}
