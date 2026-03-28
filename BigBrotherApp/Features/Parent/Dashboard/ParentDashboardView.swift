import SwiftUI
import BigBrotherCore

/// Parent dashboard — overview of all children with inline controls.
struct ParentDashboardView: View {
    @Bindable var viewModel: ParentDashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Top chrome (offline banner + action buttons)
            VStack(spacing: 8) {
                if !viewModel.appState.networkMonitor.isConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                        Text("Offline — showing cached data")
                            .font(.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Device is offline. Showing cached data.")
                }

                GlobalActionsBar(viewModel: viewModel)
            }
            .padding(.horizontal)
            .padding(.top, 4)

            // Grid fills remaining space
            switch viewModel.loadingState {
            case .idle, .loading:
                gridBody {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonChildCard()
                    }
                }

            case .loaded:
                gridBody {
                    ForEach(viewModel.childProfiles) { child in
                        childCard(child)
                    }
                }

            case .empty:
                ScrollView {
                    VStack(spacing: 20) {
                        ContentUnavailableView {
                            Label("Welcome!", systemImage: "figure.2.and.child.holdinghands")
                        } description: {
                            Text("Get started by adding your first child.")
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            stepRow(number: 1, text: "Add a child profile", done: false)
                            stepRow(number: 2, text: "Generate an enrollment code", done: false)
                            stepRow(number: 3, text: "Enter the code on the child\u{2019}s device", done: false)
                            stepRow(number: 4, text: "Set a schedule", done: false)
                        }
                        .padding(.horizontal, 32)

                        NavigationLink("Add Your First Child") {
                            AddChildView(appState: viewModel.appState)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 20)
                    .padding(.horizontal)
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

            if let feedback = viewModel.commandFeedback {
                CommandFeedbackBanner(
                    message: feedback,
                    isError: viewModel.isCommandError
                )
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: viewModel.commandFeedback)
                .padding(.horizontal)
                .accessibilityLabel(viewModel.isCommandError ? "Error: \(feedback)" : feedback)
            }
        }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    Task { await viewModel.pingAllDevices() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Dashboard")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.primary)
                        if viewModel.appState.debugMode {
                            Text("b\(AppConstants.appBuildNumber)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dashboard. Tap to ping all devices.")
            }
            if showAddChild {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        AddChildView(appState: viewModel.appState)
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Add Child")
                }
            }
        }
        .navigationDestination(item: $selectedChild) { nav in
            ChildDetailView(
                viewModel: ChildDetailViewModel(
                    appState: viewModel.appState,
                    child: nav.child
                ),
                dominantMode: nav.mode
            )
        }
        .refreshable {
            await viewModel.loadDashboard()
        }
        .task {
            await viewModel.loadDashboard()
            viewModel.startCountdownTimer()
        }
    }

    // MARK: - Grid Layout

    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    /// Full-height grid that stretches tiles to fill remaining screen space.
    @ViewBuilder
    private func gridBody<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { geo in
            let childCount = max(viewModel.childProfiles.count, 2)
            let rows = CGFloat((childCount + 1) / 2)
            let spacing: CGFloat = 10
            // Reserve equal spacing at top (below action buttons) and bottom (above tab bar)
            let verticalInset: CGFloat = spacing
            let availableHeight = geo.size.height - verticalInset * 2
            let tileHeight = max((availableHeight - (rows - 1) * spacing) / rows, 130)

            LazyVGrid(columns: gridColumns, spacing: spacing) {
                content()
                    .frame(height: tileHeight)
            }
            .padding(.horizontal)
            .padding(.vertical, verticalInset)
        }
    }

    // MARK: - Add Child Visibility

    private var showAddChild: Bool {
        let expected = UserDefaults.standard.integer(forKey: "expectedChildCount")
        // Show button if no limit set (0) or haven't reached the limit yet.
        return expected == 0 || viewModel.childProfiles.count < expected
    }

    @ViewBuilder
    private func childCard(_ child: ChildProfile) -> some View {
        let devs = viewModel.devices(for: child)
        let dominant = viewModel.dominantMode(for: child)

        ChildSummaryCard(
            child: child,
            devices: devs,
            heartbeats: viewModel.latestHeartbeats,
            dominantMode: dominant.mode,
            isSending: viewModel.isSendingCommand,
            countdown: viewModel.countdownString(for: child),
            remainingSeconds: viewModel.remainingSeconds(for: child),
            penaltyTimer: viewModel.penaltyTimerString(for: child),
            isPenaltyRunning: viewModel.penaltyTimer(for: child)?.isActivelyRunning ?? false,
            selfUnlocksUsed: viewModel.selfUnlocksUsedToday(for: child),
            selfUnlockBudget: viewModel.selfUnlockBudget(for: child),
            avatarHexColor: viewModel.penaltyTimer(for: child)?.avatarColor,
            avatarImageUrl: viewModel.penaltyTimer(for: child)?.avatarUrl,
            unlockOrigin: viewModel.unlockOrigin(for: child),
            isHeartbeatConfirmed: dominant.confirmed,
            isInPenaltyPhase: viewModel.isInPenaltyPhase(for: child),
            isScheduleActive: viewModel.isScheduleActive(for: child),
            scheduleLabel: viewModel.scheduleLabel(for: child),
            scheduleStatus: viewModel.scheduleStatus(for: child)?.label,
            scheduleStatusIsFree: viewModel.scheduleStatus(for: child)?.isFree ?? false,
            onLock: { duration in Task { await viewModel.lockChild(child, duration: duration) } },
            onUnlock: { seconds in Task { await viewModel.unlockChild(child, seconds: seconds) } },
            onUnlockWithTimer: viewModel.appState.timerService != nil
                ? { seconds in Task { await viewModel.unlockChildWithTimer(child, seconds: seconds) } }
                : nil,
            onSchedule: { Task { await viewModel.scheduleChild(child) } },
            debugMode: viewModel.appState.debugMode
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .contextMenu { childContextMenu(child) }
        .onTapGesture {
            selectedChild = ChildDetailNavigation(child: child, mode: dominant.mode)
        }
    }

    /// Navigation state for programmatic child detail push.
    struct ChildDetailNavigation: Equatable, Hashable, Identifiable {
        let child: ChildProfile
        let mode: LockMode
        var id: ChildProfileID { child.id }
    }

    @State private var selectedChild: ChildDetailNavigation?

    @ViewBuilder
    private func childContextMenu(_ child: ChildProfile) -> some View {
        let dominant = viewModel.dominantMode(for: child)
        let remaining = viewModel.remainingSeconds(for: child)
        let isUnlocked = dominant.mode == .unlocked

        if isUnlocked {
            if let remaining, remaining > 0 {
                Button { Task { await viewModel.unlockChild(child, seconds: remaining + 15 * 60) } } label: {
                    Label("+15 minutes", systemImage: "plus.circle")
                }
                Button { Task { await viewModel.unlockChild(child, seconds: remaining + 30 * 60) } } label: {
                    Label("+30 minutes", systemImage: "plus.circle")
                }
                Button { Task { await viewModel.unlockChild(child, seconds: remaining + 3600) } } label: {
                    Label("+1 hour", systemImage: "plus.circle")
                }
                Divider()
            }
            Button { Task { await viewModel.lockChild(child, duration: .indefinite) } } label: {
                Label("Lock", systemImage: "lock.fill")
            }
            Button { Task { await viewModel.lockChild(child, duration: .returnToSchedule) } } label: {
                Label("Back to schedule", systemImage: "calendar.badge.clock")
            }
        } else {
            Button { Task { await viewModel.unlockChild(child, seconds: 15 * 60) } } label: {
                Label("Unlock 15 min", systemImage: "clock")
            }
            Button { Task { await viewModel.unlockChild(child, seconds: 3600) } } label: {
                Label("Unlock 1 hour", systemImage: "clock")
            }
            Button { Task { await viewModel.unlockChild(child, seconds: 5400) } } label: {
                Label("Unlock 1.5 hours", systemImage: "clock")
            }
            Button { Task { await viewModel.unlockChild(child, seconds: 2 * 3600) } } label: {
                Label("Unlock 2 hours", systemImage: "clock")
            }
            Divider()
            Button { Task { await viewModel.unlockChild(child, seconds: Date.secondsUntilMidnight) } } label: {
                Label("Until midnight", systemImage: "moon.fill")
            }
            Button { Task { await viewModel.unlockChild(child, seconds: 24 * 3600) } } label: {
                Label("24 hours", systemImage: "clock.badge.checkmark")
            }
            if viewModel.appState.timerService != nil {
                Divider()
                Button { Task { await viewModel.unlockChildWithTimer(child, seconds: 3600) } } label: {
                    Label("1 hour + timer", systemImage: "timer")
                }
                Button { Task { await viewModel.unlockChildWithTimer(child, seconds: 2 * 3600) } } label: {
                    Label("2 hours + timer", systemImage: "timer")
                }
            }
            Divider()
            Button { Task { await viewModel.lockChild(child, duration: .returnToSchedule) } } label: {
                Label("Back to schedule", systemImage: "calendar.badge.clock")
            }
        }
    }

    // MARK: - Step Row

    @ViewBuilder
    private func stepRow(number: Int, text: String, done: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.blue.opacity(0.15))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(done ? .secondary : .primary)
        }
    }
}
