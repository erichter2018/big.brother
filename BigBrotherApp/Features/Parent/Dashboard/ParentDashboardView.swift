import SwiftUI
import BigBrotherCore

/// Parent dashboard — overview of all children with inline controls.
struct ParentDashboardView: View {
    @Bindable var viewModel: ParentDashboardViewModel
    /// b462: "Pause All" is destructive — it sends setMode(.lockedDown) to
    /// every child device, which activates the tunnel's DNS blackhole and
    /// knocks the kids offline. Parent reported accidentally hitting it
    /// and losing internet for a kid. A `.confirmationDialog` forces a
    /// deliberate tap before the command fires.
    @State private var showPauseConfirmation: Bool = false

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
            if viewModel.familyPauseEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if viewModel.isFamilyPaused {
                            // Unpausing just releases the family lockdown —
                            // no confirmation needed, it's a relief action.
                            Task { await viewModel.unpauseAll() }
                        } else {
                            // Pausing puts every kid into lockedDown mode,
                            // which activates the DNS blackhole and cuts
                            // all their internet. Confirm before firing.
                            showPauseConfirmation = true
                        }
                    } label: {
                        Text(viewModel.isFamilyPaused ? "Unpause" : "Pause All")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(viewModel.isFamilyPaused ? .green : .red)
                    }
                    .disabled(viewModel.isSendingCommand)
                }
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
                viewModel: viewModel.appState.childDetailViewModel(forID: nav.child.id),
                dominantMode: nav.mode
            )
        }
        .confirmationDialog(
            "Pause All and lock down every child device?",
            isPresented: $showPauseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Pause All (1 hour)", role: .destructive) {
                Task { await viewModel.pauseAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This immediately locks every child's device and cuts their internet for 1 hour. Use Unpause to release early.")
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
        // Read expectedModes directly so @Observable tracks the dependency.
        // dominantMode(for:) is a function call — SwiftUI doesn't observe
        // property reads inside function calls, only direct property access
        // during body evaluation.
        let _ = viewModel.appState.expectedModes[child.id]
        let dominant = viewModel.dominantMode(for: child)

        ChildSummaryCard(
            child: child,
            devices: devs,
            heartbeats: viewModel.latestHeartbeats,
            dominantMode: dominant.mode,
            isSending: viewModel.isSendingCommand,
            countdown: viewModel.countdownString(for: child),
            lockDownCountdown: {
                guard let expiry = viewModel.lockDownExpiries[child.id] else { return nil }
                let secs = max(0, Int(expiry.timeIntervalSince(viewModel.now)))
                guard secs > 0 else { return nil }
                let h = secs / 3600; let m = (secs % 3600) / 60; let s = secs % 60
                return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
            }(),
            remainingSeconds: viewModel.remainingSeconds(for: child),
            penaltyTimer: viewModel.penaltyTimerString(for: child),
            isPenaltyRunning: viewModel.penaltyTimer(for: child)?.isActivelyRunning ?? false,
            selfUnlocksUsed: viewModel.selfUnlocksUsedToday(for: child),
            selfUnlockBudget: viewModel.selfUnlockBudget(for: child),
            avatarHexColor: viewModel.penaltyTimer(for: child)?.avatarColor,
            avatarImageUrl: viewModel.penaltyTimer(for: child)?.avatarUrl,
            unlockOrigin: viewModel.unlockOrigin(for: child),
            isHeartbeatConfirmed: dominant.confirmed,
            mismatchedDeviceTypes: dominant.mismatchedDeviceTypes,
            isInPenaltyPhase: viewModel.isInPenaltyPhase(for: child),
            penaltyWindowCountdown: viewModel.penaltyWindowCountdown(for: child),
            isScheduleActive: viewModel.isScheduleActive(for: child),
            scheduleLabel: viewModel.scheduleLabel(for: child),
            scheduleStatus: viewModel.scheduleStatus(for: child)?.label,
            scheduleStatusIsFree: viewModel.scheduleStatus(for: child)?.isFree ?? false,
            onLock: { duration in Task { await viewModel.restrictChild(child, duration: duration) } },
            onUnlock: { seconds in Task { await viewModel.unlockChild(child, seconds: seconds) } },
            onUnlockWithTimer: viewModel.appState.timerService != nil
                ? { seconds in Task { await viewModel.unlockChildWithTimer(child, seconds: seconds) } }
                : nil,
            onSchedule: { Task { await viewModel.scheduleChild(child) } },
            hasPendingRequests: viewModel.appState.childrenWithPendingRequests.contains(child.id),
            debugMode: viewModel.appState.debugMode,
            namedPlaces: viewModel.namedPlaces
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
        let _ = viewModel.remainingSeconds(for: child) != nil

        // Quick +15 (always additive)
        Button { Task { await viewModel.unlockChild(child, seconds: 15 * 60) } } label: {
            Label("+15 minutes", systemImage: "plus.circle")
        }
        // More unlock options
        Menu {
            Button { Task { await viewModel.unlockChild(child, seconds: 15 * 60) } } label: {
                Label("15 minutes", systemImage: "clock")
            }
            Button { Task { await viewModel.unlockChild(child, seconds: 3600) } } label: {
                Label("1 hour", systemImage: "clock")
            }
            Button { Task { await viewModel.unlockChild(child, seconds: 2 * 3600) } } label: {
                Label("2 hours", systemImage: "clock")
            }
            Button { Task { await viewModel.unlockChild(child, seconds: Date.secondsUntilMidnight) } } label: {
                Label("Until midnight", systemImage: "moon.fill")
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
        } label: {
            Label("Unlock...", systemImage: "lock.open")
        }
        Divider()
        Button { Task { await viewModel.restrictChild(child, duration: .indefinite) } } label: {
            Label("Restrict", systemImage: "lock.fill")
        }
        Button { Task { await viewModel.lockChild(child) } } label: {
            Label("Lock", systemImage: "shield.fill")
        }
        Divider()
        Button { Task { await viewModel.lockDownChild(child, seconds: 900) } } label: {
            Label("Lock Down 15 min", systemImage: "wifi.slash")
        }
        Menu {
            Button { Task { await viewModel.lockDownChild(child, seconds: 1800) } } label: {
                Label("30 minutes", systemImage: "wifi.slash")
            }
            Button { Task { await viewModel.lockDownChild(child, seconds: 3600) } } label: {
                Label("1 hour", systemImage: "wifi.slash")
            }
            Divider()
            Button { Task { await viewModel.lockDownChild(child) } } label: {
                Label("Indefinite", systemImage: "wifi.slash")
            }
        } label: {
            Label("Lock Down...", systemImage: "wifi.slash")
        }
        Divider()
        Button { Task { await viewModel.scheduleChild(child) } } label: {
            Label("Return to Schedule", systemImage: "calendar.badge.clock")
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
