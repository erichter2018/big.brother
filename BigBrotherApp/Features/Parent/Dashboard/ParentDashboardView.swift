import SwiftUI
import BigBrotherCore

/// Parent dashboard — overview of all children and their devices.
struct ParentDashboardView: View {
    @Bindable var viewModel: ParentDashboardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
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
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.childProfiles) { child in
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
                                    devices: viewModel.devices(for: child),
                                    heartbeats: viewModel.latestHeartbeats
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
            .padding()
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
        }
    }
}
