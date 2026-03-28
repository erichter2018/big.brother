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
                if appState.isParentRevoked {
                    revokedParentView
                } else {
                    ParentGate(appState: appState) {
                        SubscriptionGate(subscriptionManager: appState.subscriptionManager, debugMode: appState.debugMode) {
                            ParentTabView(appState: appState)
                        }
                    }
                }

            case .child:
                ChildHomeView(viewModel: ChildHomeViewModel(appState: appState))
            }
        }
    }

    @ViewBuilder
    private var revokedParentView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.badge.minus")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Access Revoked")
                .font(.title2.weight(.bold))
            Text("Your parent access to this family has been revoked by the primary parent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

/// Parent-mode tab navigation.
struct ParentTabView: View {
    let appState: AppState
    @State private var dashboardViewModel: ParentDashboardViewModel
    @State private var activityViewModel: ActivityFeedViewModel
    @State private var navigationPath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    init(appState: AppState) {
        self.appState = appState
        self._dashboardViewModel = State(initialValue: ParentDashboardViewModel(appState: appState))
        self._activityViewModel = State(initialValue: ActivityFeedViewModel(appState: appState))
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
                ScheduleOverviewView(
                    viewModel: ScheduleOverviewViewModel(appState: appState)
                )
            }
            .tabItem {
                Label("Schedules", systemImage: "calendar.badge.clock")
            }

            NavigationStack {
                ActivityFeedView(viewModel: activityViewModel)
            }
            .tabItem {
                Label("Activity", systemImage: "bell.badge")
            }

            #if DEBUG
            if appState.locationService != nil {
                NavigationStack {
                    MyDrivingDebugView(appState: appState)
                }
                .tabItem {
                    Label("My Driving", systemImage: "car.fill")
                }
            }
            #endif

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
