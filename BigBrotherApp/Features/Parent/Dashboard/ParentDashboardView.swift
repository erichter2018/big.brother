import SwiftUI
import BigBrotherCore

/// Parent dashboard — overview of all children with inline controls.
struct ParentDashboardView: View {
    @Bindable var viewModel: ParentDashboardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                GlobalActionsBar(viewModel: viewModel)

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

                if let feedback = viewModel.commandFeedback {
                    CommandFeedbackBanner(
                        message: feedback,
                        isError: viewModel.isCommandError
                    )
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.5), value: viewModel.commandFeedback)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle("Big Brother Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Big Brother Dashboard")
                            .font(.system(size: 24, weight: .semibold))
                        Text("b\(AppConstants.appBuildNumber)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    deviceSummaryLine
                }
            }
            if showAddChild {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        AddChildView(appState: viewModel.appState)
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
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
    }

    // MARK: - Add Child Visibility

    private var showAddChild: Bool {
        let expected = UserDefaults.standard.integer(forKey: "expectedChildCount")
        // Show button if no limit set (0) or haven't reached the limit yet.
        return expected == 0 || viewModel.childProfiles.count < expected
    }

    // MARK: - Device Summary

    @ViewBuilder
    private var deviceSummaryLine: some View {
        let totalDevices = viewModel.childDevices.count
        let onlineCount = viewModel.latestHeartbeats.filter {
            Date().timeIntervalSince($0.timestamp) < 60
        }.count
        let lockedCount = viewModel.childProfiles.filter {
            viewModel.dominantMode(for: $0).mode != .unlocked
        }.count

        Text("\(totalDevices) Devices \u{00B7} \(onlineCount) Online \u{00B7} \(lockedCount) Locked")
            .font(.caption)
            .foregroundStyle(.secondary)
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
                ),
                dominantMode: dominant.mode
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
                onSchedule: { Task { await viewModel.scheduleChild(child) } }
            )
        }
        .buttonStyle(.plain)
    }
}
