import SwiftUI
import CoreLocation
import BigBrotherCore

/// Child device home screen — informational only.
/// Shows current mode, temporary unlock countdown, and authorization status.
/// Parent-triggered pickers (always allowed, app config) open via remote commands.
struct ChildHomeView: View {
    @Bindable var viewModel: ChildHomeViewModel
    @State private var showAppBlockingSetup = false
    @State private var showAlwaysAllowedSetup = false
    @State private var showPINUnlock = false
    @State private var pinUnlockViewModel: LocalParentUnlockViewModel?
    @State private var showSOSConfirmation = false
    @State private var showPermissionFixer = false
    @State private var sosSent = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // Background gradient based on mode
            modeGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 20)

                    // Mode icon + status
                    modeHeader

                    // Parent messages
                    ForEach(viewModel.undismissedMessages) { message in
                        parentMessageCard(message)
                    }

                    // Info cards
                    infoCards

                    // Authorization warning (only when needed)
                    if viewModel.needsReauthorization {
                        authorizationCard
                    }

                    // Location permission warning
                    if viewModel.needsLocationPermission {
                        locationPermissionCard
                    }

                    Spacer(minLength: 40)

                    // PIN Unlock button
                    if viewModel.isPINConfigured {
                        HStack {
                            Spacer()
                            Button {
                                pinUnlockViewModel = LocalParentUnlockViewModel(appState: viewModel.appState)
                                showPINUnlock = true
                            } label: {
                                Label("PIN Unlock", systemImage: "lock.open")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .accessibilityLabel("Unlock with parent PIN")
                        }
                    }

                    // Subtle footer
                    Text("Managed by parent")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding()
            }
        }
        .overlay(alignment: .bottomLeading) {
            sosButton
                .padding(.leading, 16)
                .padding(.bottom, 16)
        }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.hasPermissionIssues {
                Button {
                    showPermissionFixer = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                        Text("Permissions")
                            .font(.subheadline.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.orange)
                    .clipShape(Capsule())
                    .shadow(color: .orange.opacity(0.4), radius: 8, y: 4)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
                .accessibilityLabel("Fix permissions. Some permissions are missing.")
            }
        }
        .sheet(isPresented: $showPermissionFixer) {
            PermissionFixerView(appState: viewModel.appState)
        }
        .sheet(isPresented: $showPINUnlock, onDismiss: {
            pinUnlockViewModel = nil
        }) {
            if let vm = pinUnlockViewModel {
                LocalUnlockView(viewModel: vm)
            }
        }
        #if canImport(FamilyControls)
        .sheet(isPresented: $showAppBlockingSetup) {
            AppBlockingSetupView(appState: viewModel.appState)
        }
        .sheet(isPresented: $showAlwaysAllowedSetup) {
            AlwaysAllowedSetupView(appState: viewModel.appState)
        }
        .onChange(of: viewModel.appState.showAppConfigurationRequest) { _, newValue in
            if newValue {
                showAppBlockingSetup = true
                viewModel.appState.showAppConfigurationRequest = false
            }
        }
        .onChange(of: viewModel.appState.showAlwaysAllowedSetup) { _, newValue in
            if newValue {
                showAlwaysAllowedSetup = true
                viewModel.appState.showAlwaysAllowedSetup = false
            }
        }
        #endif
        .onAppear {
            viewModel.startTimer()
        }
        .onDisappear {
            viewModel.stopTimer()
        }
    }

    // MARK: - Mode Header

    // MARK: - SOS Button

    @ViewBuilder
    private var sosButton: some View {
        Button {
            showSOSConfirmation = true
        } label: {
            Image(systemName: "sos")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(sosSent ? Color.gray : Color.red.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(sosSent)
        .alert("Send SOS Alert?", isPresented: $showSOSConfirmation) {
            Button("Send SOS", role: .destructive) {
                Task { await sendSOS() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will immediately alert your parents with your current location.")
        }
    }

    private func sendSOS() async {
        sosSent = true
        // Get current location
        let loc = viewModel.appState.locationService?.lastLocation
        var details = "SOS triggered"
        if let loc {
            let lat = String(format: "%.4f", loc.coordinate.latitude)
            let lon = String(format: "%.4f", loc.coordinate.longitude)
            details = "SOS at \(lat), \(lon)"
            // Reverse geocode for address
            if let placemarks = try? await CLGeocoder().reverseGeocodeLocation(loc),
               let pm = placemarks.first {
                let parts = [pm.thoroughfare, pm.locality].compactMap { $0 }
                if !parts.isEmpty {
                    details = "SOS at \(parts.joined(separator: ", "))"
                }
            }
        }

        viewModel.appState.eventLogger?.log(.sosAlert, details: details)
        try? await viewModel.appState.eventLogger?.syncPendingEvents()

        // Force immediate heartbeat with fresh location
        viewModel.appState.locationService?.lastBreadcrumbSaveAt = nil
        try? await viewModel.appState.heartbeatService?.sendNow(force: true)

        // Reset after 60 seconds so they can send again if needed
        Task {
            try? await Task.sleep(for: .seconds(60))
            await MainActor.run { sosSent = false }
        }
    }

    @ViewBuilder
    private var modeHeader: some View {
        VStack(spacing: 16) {
            Image(systemName: modeIcon)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10)
                .accessibilityHidden(true)

            Text(viewModel.currentMode.displayName)
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.white)

            Text(modeDescription)
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            if viewModel.hasPermissionIssues && viewModel.currentMode != .unlocked {
                VStack(spacing: 4) {
                    Text("Permissions Required")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                    Text("This device will stay locked until all permissions are granted. Tap the orange button below to fix.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
            } else if let reason = viewModel.lockReasonText {
                Text(reason)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(lockReasonColor(reason))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 30)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(viewModel.currentMode.displayName): \(modeDescription)")
    }

    // MARK: - Info Cards (adaptive layout)

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    @ViewBuilder
    private var infoCards: some View {
        let layout = isIPad
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(spacing: 16))

        layout {
            // Schedule card
            if let profile = viewModel.activeScheduleProfile {
                scheduleCard(profile: profile)
                    .frame(maxWidth: .infinity)
            }

            // Self-unlock card (full, with button)
            if viewModel.canShowSelfUnlock, let state = viewModel.selfUnlockState {
                selfUnlockCard(state: state)
                    .frame(maxWidth: .infinity)
            }

            // Countdown cards — wrapped in TimelineView so Date() is captured
            // once per tick and Text(timerInterval:) rebuilds with a fresh start.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                countdownCards(now: now)
            }

            // Self-unlock compact indicator (when full card is hidden)
            if let state = viewModel.selfUnlockState, state.budget > 0,
               !viewModel.canShowSelfUnlock {
                HStack(spacing: 8) {
                    Image(systemName: "lock.open.rotation")
                        .foregroundStyle(.white.opacity(0.7))
                    Text("\(state.remaining)/\(state.budget) self-unlocks left")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .background(.teal.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    /// All countdown-dependent cards. `now` comes from TimelineView so it's
    /// consistent within a single render and refreshes every second.
    @ViewBuilder
    private func countdownCards(now: Date) -> some View {
        // Timed unlock with penalty offset
        if let info = viewModel.timedUnlockInfo {
            if now < info.unlockAt {
                liveCountdownCard(
                    title: "Penalty Time",
                    end: info.unlockAt,
                    now: now,
                    subtitle: "Device unlocks when penalty ends",
                    color: .red
                )
                .frame(maxWidth: .infinity)
            } else if now < info.lockAt {
                liveCountdownCard(
                    title: "Free Time",
                    end: info.lockAt,
                    now: now,
                    subtitle: "remaining",
                    color: .green
                )
                .frame(maxWidth: .infinity)
            }
        }
        // Regular temporary unlock countdown
        else if viewModel.isTemporaryUnlock, let state = viewModel.temporaryUnlockState,
                state.expiresAt > now {
            liveCountdownCard(
                title: "Temporary Unlock",
                end: state.expiresAt,
                now: now,
                subtitle: "remaining",
                color: .white
            )
            .frame(maxWidth: .infinity)
        }

        // Internet block countdown (Lock Down mode)
        if viewModel.currentMode == .lockedDown, let blockedUntil = viewModel.internetBlockedUntil,
           blockedUntil > now {
            liveCountdownCard(
                title: "Internet Disabled",
                end: blockedUntil,
                now: now,
                subtitle: "remaining",
                color: .red
            )
            .frame(maxWidth: .infinity)
        }

        // Penalty timer — suppress when timed unlock is active (same penalty, already shown above).
        if viewModel.timedUnlockInfo == nil {
            if let end = viewModel.penaltyTimerEndTime, end > now {
                // Running penalty countdown
                liveCountdownCard(
                    title: "Screen Time Penalty",
                    end: end,
                    now: now,
                    subtitle: "counting down",
                    color: .red
                )
                .frame(maxWidth: .infinity)
            } else if let secs = viewModel.penaltySeconds, secs > 0 {
                // Banked penalty (static)
                bankedPenaltyCard(seconds: secs)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Live Countdown Card (uses Text(timerInterval:) — ticks automatically)

    @ViewBuilder
    private func liveCountdownCard(title: String, end: Date, now: Date, subtitle: String, color: Color) -> some View {
        // Clamp end to at least now to prevent invalid ClosedRange crash.
        let safeEnd = max(now, end)
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: color == .red ? "hourglass" : "clock")
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text(timerInterval: now...safeEnd, countsDown: true)
                .font(.system(size: 48, weight: .thin, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color == .white ? .white : color)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 30)
        .background((color == .white ? Color.white : color).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Banked Penalty Card (static, not counting down)

    @ViewBuilder
    private func bankedPenaltyCard(seconds: Int) -> some View {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        let display = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityHidden(true)
                Text("Screen Time Penalty")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text(display)
                .font(.system(size: 48, weight: .thin, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.red)

            Text("banked")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 30)
        .background(.red.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Self Unlock Card

    @ViewBuilder
    private func selfUnlockCard(state: SelfUnlockState) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.open.rotation")
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityHidden(true)
                Text("Self Unlocks")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text("\(state.remaining) of \(state.budget)")
                .font(.system(size: 36, weight: .thin, design: .rounded))
                .foregroundStyle(.white)

            Text("remaining today")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))

            Button {
                viewModel.useSelfUnlock()
            } label: {
                Text("Unlock for 15 min")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green.opacity(0.8))
            .disabled(!viewModel.canUseSelfUnlock)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 30)
        .background(.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Schedule Card

    @ViewBuilder
    private func scheduleCard(profile: ScheduleProfile) -> some View {
        let active = viewModel.isScheduleDriving

        VStack(spacing: active ? 12 : 8) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundStyle(.white.opacity(active ? 0.8 : 0.3))
                    .accessibilityHidden(true)
                Text(profile.name)
                    .font(active ? .subheadline : .caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(active ? 0.8 : 0.3))
                if !active {
                    Text("(paused)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.25))
                }
            }

            if active, let status = viewModel.scheduleStatusText {
                Text(status)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }

            let windows = viewModel.todaysFreeWindows
            if !windows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today's free time:")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(active ? 0.5 : 0.2))
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        Text("\(window.start) – \(window.end)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(active ? 0.7 : 0.25))
                    }
                }
            }
        }
        .padding(.vertical, active ? 20 : 12)
        .padding(.horizontal, active ? 30 : 20)
        .background(Color.orange.opacity(active ? 0.12 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Authorization Card

    @ViewBuilder
    private var authorizationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text("Authorization Required")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }

            Text("Screen Time permission is needed for app management.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Button {
                Task { await viewModel.requestAuthorization() }
            } label: {
                Text(viewModel.isRequestingAuth ? "Requesting..." : "Authorize")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.2))
            .disabled(viewModel.isRequestingAuth)

            if let feedback = viewModel.authFeedback {
                Text(feedback)
                    .font(.caption2)
                    .foregroundStyle(feedback.contains("authorized") ? .green : .red)
            }
        }
        .padding()
        .background(.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Location Permission Card

    @ViewBuilder
    private var locationPermissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "location.slash.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Location Permission Needed")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }

            Text("Your parent has enabled location tracking but this device hasn't granted permission. A parent can enable this in Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Button {
                viewModel.openAppSettings()
            } label: {
                Text("Open Settings")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.2))
        }
        .padding()
        .background(.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Parent Message Card

    @ViewBuilder
    private func parentMessageCard(_ message: ParentMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(.white.opacity(0.8))
                Text("From \(message.sentBy)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(message.sentAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(message.text)
                .font(.body)
                .foregroundStyle(.white)
            Button {
                viewModel.dismissMessage(message.id)
            } label: {
                Text("Dismiss")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding()
        .background(.blue.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Styling

    private func lockReasonColor(_ reason: String) -> Color {
        if reason.hasPrefix("Free") { return .green }
        if reason.hasPrefix("Locked Down") { return .red }
        if reason.hasPrefix("Locked") { return .purple }
        if reason.hasPrefix("Restricted") { return .blue }
        return .white.opacity(0.6)
    }

    private var modeIcon: String {
        switch viewModel.currentMode {
        case .unlocked: return "lock.open"
        case .restricted: return "lock"
        case .locked: return "shield"
        case .lockedDown: return "wifi.slash"
        }
    }

    private var modeDescription: String {
        switch viewModel.currentMode {
        case .unlocked: return "All apps are accessible"
        case .restricted: return "Only allowed apps are available"
        case .locked: return "Only essential apps are available"
        case .lockedDown: return "Only essential apps, no internet"
        }
    }

    private var modeGradient: LinearGradient {
        switch viewModel.currentMode {
        case .unlocked:
            return LinearGradient(
                colors: [Color(red: 0.1, green: 0.4, blue: 0.3), Color(red: 0.05, green: 0.2, blue: 0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .restricted:
            return LinearGradient(
                colors: [Color(red: 0.1, green: 0.2, blue: 0.45), Color(red: 0.05, green: 0.1, blue: 0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .locked:
            return LinearGradient(
                colors: [Color(red: 0.3, green: 0.1, blue: 0.35), Color(red: 0.15, green: 0.05, blue: 0.2)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .lockedDown:
            return LinearGradient(
                colors: [Color(red: 0.4, green: 0.05, blue: 0.05), Color(red: 0.2, green: 0.02, blue: 0.02)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}
