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

    init(appState: AppState) {
        self.appState = appState
        self._dashboardViewModel = State(initialValue: ParentDashboardViewModel(appState: appState))
    }

    var body: some View {
        TabView {
            NavigationStack {
                ParentDashboardView(viewModel: dashboardViewModel)
            }
            .tabItem {
                Label("Dashboard", systemImage: "house")
            }

            NavigationStack {
                ScheduleListView(appState: appState)
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
    }
}
