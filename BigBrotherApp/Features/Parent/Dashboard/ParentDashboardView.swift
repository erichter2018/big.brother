import SwiftUI
import BigBrotherCore

/// Parent dashboard — overview of all children with inline controls.
struct ParentDashboardView: View {
    @Bindable var viewModel: ParentDashboardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                GlobalActionsBar(viewModel: viewModel)

                if let feedback = viewModel.commandFeedback {
                    CommandFeedbackBanner(
                        message: feedback,
                        isError: viewModel.isCommandError
                    )
                }

                switch viewModel.loadingState {
                case .idle, .loading:
                    ProgressView("Loading dashboard...")
                        .padding(.top, 40)

                case .loaded:
                    ForEach(viewModel.childProfiles) { child in
                        childCard(child)
                    }

                case .empty(let msg):
                    ContentUnavailableView {
                        Label(msg, systemImage: "person.2.slash")
                    } actions: {
                        NavigationLink("Add Child") {
                            AddChildView(appState: viewModel.appState)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                case .error(let msg):
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(msg)
                    } actions: {
                        Button("Retry") {
                            Task { await viewModel.loadDashboard() }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    AddChildView(appState: viewModel.appState)
                } label: {
                    Image(systemName: "person.badge.plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.loadDashboard() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable {
            await viewModel.loadDashboard()
        }
        .task {
            await viewModel.loadDashboard()
            viewModel.startCountdownTimer()
        }
        .onDisappear {
            viewModel.stopCountdownTimer()
        }
    }

    @ViewBuilder
    private func childCard(_ child: ChildProfile) -> some View {
        let devs = viewModel.devices(for: child)
        let dominant = viewModel.dominantMode(for: child)

        NavigationLink {
            ChildDetailView(
                viewModel: ChildDetailViewModel(
                    appState: viewModel.appState,
                    child: child
                )
            )
        } label: {
            ChildSummaryCard(
                child: child,
                devices: devs,
                heartbeats: viewModel.latestHeartbeats,
                dominantMode: dominant.mode,
                isSending: viewModel.isSendingCommand,
                countdown: viewModel.countdownString(for: child),
                remainingSeconds: viewModel.remainingSeconds(for: child),
                onLock: { Task { await viewModel.lockChild(child) } },
                onUnlock: { seconds in Task { await viewModel.unlockChild(child, seconds: seconds) } },
                onEssential: { Task { await viewModel.essentialChild(child) } }
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { await viewModel.deleteChild(child) }
            } label: {
                Label("Delete Child", systemImage: "trash")
            }
        }
    }
}
