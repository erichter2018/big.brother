import SwiftUI
import BigBrotherCore

/// Child device home screen — shows current enforcement state.
struct ChildHomeView: View {
    @Bindable var viewModel: ChildHomeViewModel
    @State private var showUnlock = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Status header
                    statusHeader

                    // Temporary unlock card
                    if viewModel.isTemporaryUnlock, let state = viewModel.temporaryUnlockState {
                        TemporaryUnlockCard(state: state, now: viewModel.now)
                    }

                    // Mode card
                    currentModeCard

                    // Authorization status
                    if !viewModel.authorizationHealthy {
                        authorizationCard
                    }

                    // Warnings
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

                    // Parent unlock button
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
            .onAppear {
                viewModel.startTimer()
            }
            .onDisappear {
                viewModel.stopTimer()
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
        case .fullLockdown: "lock.fill"
        case .essentialOnly: "shield"
        }
    }

    private var modeColor: Color {
        switch viewModel.currentMode {
        case .unlocked: .green
        case .dailyMode: .blue
        case .fullLockdown: .red
        case .essentialOnly: .purple
        }
    }

    private var modeDescription: String {
        switch viewModel.currentMode {
        case .unlocked: "All apps are accessible."
        case .dailyMode: "Only allowed apps are available."
        case .fullLockdown: "This device is disabled."
        case .essentialOnly: "Only essential apps are available."
        }
    }

    @ViewBuilder
    private var authorizationCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Time permissions needed")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Ask a parent to re-enable Screen Time access in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
