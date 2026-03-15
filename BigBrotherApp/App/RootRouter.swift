import SwiftUI
import BigBrotherCore

/// Top-level router that shows the correct root view based on device role.
///
/// Routing logic:
///   .unconfigured → OnboardingView (choose parent or child setup)
///   .parent       → ParentGate → ParentTabView
///   .child        → ChildHomeView (no auth needed)
struct RootRouter: View {
    let appState: AppState

    var body: some View {
        Group {
            switch appState.deviceRole {
            case .unconfigured:
                OnboardingView(appState: appState)

            case .parent:
                ParentGate(appState: appState) {
                    ParentTabView(appState: appState)
                }

            case .child:
                ChildHomeView(viewModel: ChildHomeViewModel(appState: appState))
            }
        }
    }
}

/// Parent-mode tab navigation.
struct ParentTabView: View {
    let appState: AppState
    @State private var dashboardViewModel: ParentDashboardViewModel
    @State private var navigationPath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    init(appState: AppState) {
        self.appState = appState
        self._dashboardViewModel = State(initialValue: ParentDashboardViewModel(appState: appState))
    }

    var body: some View {
        TabView {
            NavigationStack(path: $navigationPath) {
                ParentDashboardView(viewModel: dashboardViewModel)
                    .navigationDestination(for: ChildProfileID.self) { childID in
                        if let child = appState.childProfiles.first(where: { $0.id == childID }) {
                            ChildDetailView(
                                viewModel: ChildDetailViewModel(
                                    appState: appState,
                                    child: child
                                )
                            )
                        }
                    }
            }
            .onChange(of: appState.pendingChildNavigation) { _, childID in
                if let childID {
                    navigationPath.append(childID)
                    appState.pendingChildNavigation = nil
                }
            }
            .tabItem {
                Label("Dashboard", systemImage: "house")
            }

            NavigationStack {
                ScheduleProfileListView(
                    viewModel: ScheduleProfileListViewModel(appState: appState)
                )
            }
            .tabItem {
                Label("Schedules", systemImage: "calendar.badge.clock")
            }

            NavigationStack {
                SettingsView(appState: appState)
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                appState.checkForUnlockRequestsNow()
            }
        }
    }
}
