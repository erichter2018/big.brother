import SwiftUI
import BigBrotherCore

/// Parent dashboard — overview of all children with inline controls.
struct ParentDashboardView: View {
    @Bindable var viewModel: ParentDashboardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
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

                switch viewModel.loadingState {
                case .idle, .loading:
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonChildCard()
                    }

                case .loaded:
                    ForEach(viewModel.childProfiles) { child in
                        childCard(child)
                    }

                case .empty:
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
                    .accessibilityLabel(viewModel.isCommandError ? "Error: \(feedback)" : feedback)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    Task { await viewModel.pingAllDevices() }
                } label: {
                    VStack(spacing: 2) {
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
                        deviceSummaryLine
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(totalDevices) devices, \(onlineCount) online, \(lockedCount) locked")
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
                onSchedule: { Task { await viewModel.scheduleChild(child) } },
                debugMode: viewModel.appState.debugMode
            )
        }
        .buttonStyle(.plain)
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
