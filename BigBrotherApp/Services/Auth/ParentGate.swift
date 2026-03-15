import SwiftUI
import BigBrotherCore

/// Authentication gate for parent mode.
///
/// Shows biometric prompt on appear, falls back to PIN entry.
/// Re-authenticates after inactivity timeout.
struct ParentGate<Content: View>: View {
    let appState: AppState
    @ViewBuilder let content: () -> Content

    @State private var isAuthenticated = false
    @State private var lastAuthTime: Date?
    @State private var showPINEntry = false
    @State private var authError: String?
    @State private var isAuthenticating = false

    private let timeoutSeconds: TimeInterval = 300

    @Environment(\.scenePhase) private var scenePhase

    private var authEnabled: Bool {
        // Default to true if key has never been set (backward compatible).
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
        if defaults.object(forKey: StorageKeys.parentAuthEnabled) == nil { return true }
        return defaults.bool(forKey: StorageKeys.parentAuthEnabled)
    }

    var body: some View {
        if !isPINConfigured || !authEnabled {
            // No PIN set or auth disabled — skip authentication.
            content()
        } else if isAuthenticated && !isTimedOut {
            content()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active && isTimedOut {
                        isAuthenticated = false
                    }
                }
        } else {
            authScreen
                .onAppear {
                    if !isAuthenticated {
                        attemptBiometric()
                    }
                }
        }
    }

    private var isTimedOut: Bool {
        guard let last = lastAuthTime else { return true }
        return Date().timeIntervalSince(last) > timeoutSeconds
    }

    @ViewBuilder
    private var authScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Parent Authentication")
                .font(.title2)
                .fontWeight(.bold)

            Text("Verify your identity to access parent controls.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let error = authError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if isAuthenticating {
                ProgressView()
            } else {
                VStack(spacing: 12) {
                    if appState.auth?.isBiometricAvailable == true {
                        Button {
                            attemptBiometric()
                        } label: {
                            Label("Use Face ID / Touch ID", systemImage: "faceid")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button {
                        showPINEntry = true
                    } label: {
                        Text(isPINConfigured ? "Enter PIN" : "Set Up PIN")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 40)
            }

            Spacer()
        }
        .sheet(isPresented: $showPINEntry) {
            if isPINConfigured {
                ParentPINEntryView(appState: appState) { success in
                    if success {
                        grantAccess()
                    }
                    showPINEntry = false
                }
            } else {
                ParentPINSetupView(appState: appState) {
                    showPINEntry = false
                }
            }
        }
    }

    private var isPINConfigured: Bool {
        (try? appState.keychain.getData(forKey: StorageKeys.parentPINHash)) != nil
    }

    private func attemptBiometric() {
        guard let auth = appState.auth else { return }
        isAuthenticating = true
        authError = nil

        Task {
            do {
                let success = try await auth.authenticateParent()
                if success {
                    grantAccess()
                } else {
                    authError = "Biometric authentication failed. Use PIN instead."
                }
            } catch {
                authError = error.localizedDescription
            }
            isAuthenticating = false
        }
    }

    private func grantAccess() {
        isAuthenticated = true
        lastAuthTime = Date()
        authError = nil
    }
}

