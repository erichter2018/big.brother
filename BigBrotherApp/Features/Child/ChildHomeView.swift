import SwiftUI
import BigBrotherCore

/// Child device home screen — shows current enforcement state.
struct ChildHomeView: View {
    @Bindable var viewModel: ChildHomeViewModel
    @State private var showUnlock = false
    @State private var showAppBlockingSetup = false
    @State private var showUnlockRequestPicker = false
    @State private var showNameMyApps = false
    @State private var showShieldAppTest = false
    @State private var showAlwaysAllowedSetup = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusHeader

                    // Temporary unlock card
                    if viewModel.isTemporaryUnlock, let state = viewModel.temporaryUnlockState {
                        TemporaryUnlockCard(state: state, now: viewModel.now)
                    }

                    currentModeCard

                    // Request app access
                    #if canImport(FamilyControls)
                    if viewModel.currentMode != .unlocked {
                        Button {
                            showUnlockRequestPicker = true
                        } label: {
                            Label("Request App Access", systemImage: "hand.raised")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }

                    Button {
                        showNameMyApps = true
                    } label: {
                        Label("Name My Apps", systemImage: "character.cursor.ibeam")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)

                    #if DEBUG
                    Button {
                        showShieldAppTest = true
                    } label: {
                        Label("Test shield.applications", systemImage: "ant")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    #endif
                    #endif

                    // App blocking status
                    if viewModel.appState.familyControlsAvailable, let config = viewModel.appBlockingConfig, config.isConfigured {
                        appBlockingStatus(config)
                    }

                    // Recognized apps learned from explicit picker selections.
                    if !viewModel.resolvedAppNames.isEmpty {
                        recognizedAppsCard
                    }

                    // Authorization status
                    if viewModel.needsReauthorization {
                        authorizationCard
                    }

                    WarningBanner(warnings: viewModel.warnings)

                    // Last update
                    if let lastUpdate = viewModel.lastReconciliation {
                        HStack {
                            Text("Last enforcement update")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(lastUpdate, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 40)

                    Button {
                        showUnlock = true
                    } label: {
                        Label("Parent Unlock", systemImage: "lock.open")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }
                .padding()
            }
            .navigationTitle("Big Brother")
            .sheet(isPresented: $showUnlock) {
                LocalUnlockView(
                    viewModel: LocalParentUnlockViewModel(appState: viewModel.appState)
                )
            }
            #if canImport(FamilyControls)
            .sheet(isPresented: $showAppBlockingSetup) {
                AppBlockingSetupView(appState: viewModel.appState)
            }
            .sheet(isPresented: $showUnlockRequestPicker) {
                UnlockRequestPickerView(appState: viewModel.appState)
            }
            .sheet(isPresented: $showNameMyApps) {
                NameMyAppsView(appState: viewModel.appState)
            }
            #if DEBUG
            .sheet(isPresented: $showShieldAppTest) {
                ShieldApplicationsTestView()
            }
            #endif
            .onChange(of: viewModel.appState.showAppConfigurationRequest) { _, newValue in
                if newValue {
                    showAppBlockingSetup = true
                    viewModel.appState.showAppConfigurationRequest = false
                }
            }
            .onChange(of: viewModel.appState.showAlwaysAllowedSetup) { _, newValue in
                if newValue {
                    showAlwaysAllowedSetup = true
                    viewModel.appState.showAlwaysAllowedSetup = false
                }
            }
            .sheet(isPresented: $showAlwaysAllowedSetup) {
                AlwaysAllowedSetupView(appState: viewModel.appState)
            }
            #endif
            .onAppear {
                viewModel.startTimer()
                viewModel.cleanupShieldCacheFile()
                viewModel.purgeUploadedEvents()
                checkUnlockPickerPending()
                viewModel.refreshNameResolutionState(reason: "onAppear")
                // Sync events immediately so unlock requests reach CloudKit ASAP.
                viewModel.syncEventsNow()
            }
            .onDisappear {
                viewModel.stopTimer()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    checkUnlockPickerPending()
                    viewModel.refreshNameResolutionState(reason: "foreground")
                    // Sync events immediately on foreground — unlock requests from
                    // ShieldAction may be sitting in the queue.
                    viewModel.syncEventsNow()
                }
            }
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.child")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("This device is managed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }

    @ViewBuilder
    private var currentModeCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Current Mode")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Image(systemName: modeIcon)
                    .font(.title)
                    .foregroundStyle(modeColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.currentMode.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(modeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var modeIcon: String {
        switch viewModel.currentMode {
        case .unlocked: "lock.open"
        case .dailyMode: "calendar"
        case .essentialOnly: "shield"
        }
    }

    private var modeColor: Color {
        switch viewModel.currentMode {
        case .unlocked: .green
        case .dailyMode: .blue
        case .essentialOnly: .purple
        }
    }

    private var modeDescription: String {
        switch viewModel.currentMode {
        case .unlocked: "All apps are accessible."
        case .dailyMode: "Only allowed apps are available."
        case .essentialOnly: "Only essential apps are available."
        }
    }

    @ViewBuilder
    private func appBlockingStatus(_ config: AppBlockingConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "app.badge.checkmark")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("App Restrictions Active")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("\(config.allowedAppCount) apps, \(config.blockedCategoryCount) categories configured by parent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var authorizationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Time Authorization Required")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("App restrictions cannot be enforced without Screen Time permission. This may happen after an iOS update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await viewModel.requestAuthorization() }
            } label: {
                HStack {
                    if viewModel.isRequestingAuth {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.isRequestingAuth ? "Requesting..." : "Authorize Screen Time")
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(viewModel.isRequestingAuth)

            if let feedback = viewModel.authFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(feedback.contains("authorized") ? .green : .red)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Current status: \(viewModel.authStatusDescription)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text("If the button above doesn't work:")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text("1. Delete and reinstall Big Brother")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("2. Or: Settings > Screen Time > Turn OFF, then ON")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("3. Come back to this app and tap the button")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }


    @ViewBuilder
    private var recognizedAppsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.blue)
                Text("Recognized Apps")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(viewModel.resolvedAppNames.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            WrappingHStack(items: Array(viewModel.resolvedAppNames.prefix(20)), spacing: 6) { name in
                Text(name)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())
            }

            if viewModel.resolvedAppNames.count > 20 {
                Text("+\(viewModel.resolvedAppNames.count - 20) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func checkUnlockPickerPending() {
        #if canImport(FamilyControls)
        guard viewModel.currentMode != .unlocked else { return }
        viewModel.logNameResolution("checkUnlockPickerPending: evaluating pending flag")
        if let requestedAt = viewModel.appState.storage.readUnlockPickerPendingDate(),
           -requestedAt.timeIntervalSinceNow < 300 {
            // Must use the picker — it provides fresh in-memory tokens that
            // actually work with ManagedSettings. Cached/serialized tokens
            // from UserDefaults fail silently when used with .all(except:).
            viewModel.logNameResolution("checkUnlockPickerPending: opening picker age=\(Int(-requestedAt.timeIntervalSinceNow))s")
            showUnlockRequestPicker = true
            try? viewModel.appState.storage.clearUnlockPickerPending()
        } else {
            viewModel.logNameResolution("checkUnlockPickerPending: no recent pending flag")
        }
        #endif
    }
}
