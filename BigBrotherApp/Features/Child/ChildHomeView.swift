import SwiftUI
import CoreLocation
import CloudKit
import BigBrotherCore
#if canImport(FamilyControls)
import FamilyControls
import ManagedSettings
#endif

/// Child device home screen — informational only.
/// Shows current mode, temporary unlock countdown, and authorization status.
/// Parent-triggered pickers (always allowed, app config) open via remote commands.
struct ChildHomeView: View {
    @Bindable var viewModel: ChildHomeViewModel
    @State private var showAppBlockingSetup = false
    @State private var showAlwaysAllowedSetup = false
    @State private var showTimeLimitSetup = false
    @State private var showChildAppPick = false
    #if canImport(FamilyControls)
    @State private var showSingleAppPick = false
    @State private var singleAppSelection = FamilyActivitySelection()
    @State private var singleAppToken: ApplicationToken?
    @State private var singleAppName = ""
    @State private var singleAppSaving = false
    /// Hint shown above the picker when triggered by the shield's "ask for
    /// access" flow. Carries the app name resolved by ShieldConfiguration.
    @State private var singleAppPromptHint: String?
    #endif
    @State private var showPINUnlock = false
    @State private var pinUnlockViewModel: LocalParentUnlockViewModel?
    @State private var showSOSConfirmation = false
    @State private var showAppVerification = false
    @State private var showPermissionFixer = false
    @State private var showWelcome = false
    @State private var launchGracePeriod = true
    @State private var sosSent = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // Background gradient based on mode
            modeGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Confirmation banner (e.g. "Doodle Buddy — extra time granted!")
                    if let msg = viewModel.appState.childConfirmationMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(msg)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer(minLength: 20)

                    // Mode icon + status
                    modeHeader

                    // Internet block / enforcement status banner
                    internetStatusBanner

                    // Web & internet status card (non-unlocked modes)
                    webStatusCard

                    // Parent messages
                    ForEach(viewModel.undismissedMessages) { message in
                        parentMessageCard(message)
                    }

                    // Info cards
                    infoCards

                    // Pending app reviews
                    pendingReviewsCard

                    // Request more apps button + verify button
                    #if canImport(FamilyControls)
                    HStack(spacing: 12) {
                        requestMoreAppsButton
                        Button {
                            showAppVerification = true
                        } label: {
                            Label("Apps", systemImage: "checkmark.shield")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    #else
                    requestMoreAppsButton
                    #endif
                    resetAllAppsButton

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
        .overlay(alignment: .topLeading) {
            sosButton
                .padding(.leading, 16)
                .padding(.top, 16)
        }
        .overlay(alignment: .bottomTrailing) {
            if !launchGracePeriod && viewModel.hasPermissionIssues {
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
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeView {
                showWelcome = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showPermissionFixer = true
                }
            }
        }
        #if canImport(FamilyControls)
        .sheet(isPresented: $showAppVerification) {
            AppVerificationView(appState: viewModel.appState)
        }
        #endif
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
        .sheet(isPresented: $showTimeLimitSetup) {
            TimeLimitSetupView(appState: viewModel.appState)
        }
        .onChange(of: viewModel.appState.showTimeLimitSetup) { _, newValue in
            if newValue {
                showTimeLimitSetup = true
                viewModel.appState.showTimeLimitSetup = false
            }
        }
        .sheet(isPresented: $showChildAppPick) {
            ChildAppPickView(appState: viewModel.appState)
        }
        .onChange(of: viewModel.appState.showChildAppPick) { _, newValue in
            if newValue {
                showChildAppPick = true
                viewModel.appState.showChildAppPick = false
            }
        }
        #endif
        .onAppear {
            viewModel.startTimer()
            // Don't show permissions button for 30s after launch —
            // FC auth, location, VPN all start as "not ready" and settle quickly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                launchGracePeriod = false
            }
            // First-launch flow: show WelcomeView → PermissionFixerView.
            // Flag stays set until PermissionFixerView explicitly clears it
            // on completion — services check it to suppress auto-prompts.
            if UserDefaults.appGroup?.bool(forKey: AppGroupKeys.showPermissionFixerOnNextLaunch) == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showWelcome = true
                }
            }
        }
        .onDisappear {
            viewModel.stopTimer()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Immediately sync with CloudKit when kid opens the app.
                viewModel.appState.performForegroundSync()
                // Start 5-second command poll while app is visible.
                // Push notifications are unreliable — this ensures commands
                // from parent are processed within seconds, always.
                viewModel.appState.startForegroundCommandPoll()
                // Auto-show always-allowed picker if stale tokens detected.
                let defaults = UserDefaults.appGroup
                if defaults?.bool(forKey: "allowedTokensNeedRefresh") == true {
                    defaults?.removeObject(forKey: "allowedTokensNeedRefresh")
                    showAlwaysAllowedSetup = true
                }
                // Auto-show the single-app picker if the kid just tapped
                // "Ask for access" on a category-shielded app. ShieldAction
                // wrote the picker-pending flag because iOS doesn't pass an
                // ApplicationToken for category-only blocks; the kid needs to
                // re-pick the app via the picker so we capture a fresh token,
                // which the parent's reviewApp pipeline can resolve.
                #if canImport(FamilyControls)
                if let pending = viewModel.appState.storage.readUnlockPickerPending(),
                   pending.isRecent {
                    singleAppSelection = FamilyActivitySelection()
                    singleAppToken = nil
                    singleAppName = pending.appName ?? ""
                    singleAppPromptHint = pending.appName.map {
                        "Tap \"\($0)\" in the picker to re-request access."
                    } ?? "Tap the app you wanted to open to re-request access."
                    showSingleAppPick = true
                    try? viewModel.appState.storage.clearUnlockPickerPending()
                }
                #endif
            } else if newPhase == .background {
                viewModel.appState.stopForegroundCommandPoll()
            }
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
    private var internetStatusBanner: some View {
        if viewModel.isTunnelInternetBlocked && viewModel.currentMode == .lockedDown {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.title3)
                        .foregroundStyle(.red)
                    Text("Internet Paused")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                if let reason = viewModel.tunnelInternetBlockedReason {
                    Text(friendlyBlockReason(reason))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(.red.opacity(0.3)))
            .padding(.horizontal)
        }
    }

    private func friendlyBlockReason(_ reason: String) -> String {
        if reason.contains("Schedule enforcement") {
            return "Open this app to restore internet access."
        }
        if reason.contains("Emergency") {
            return "Internet was paused for safety. Open this app to restore access."
        }
        if reason.contains("Locked Down") {
            return "Your parent put the device in lockdown mode."
        }
        if reason.contains("App update") {
            return "An app update needs to finish. Open this app to continue."
        }
        if reason.contains("permissions") || reason.contains("FamilyControls") {
            return "Permissions need to be fixed. Ask your parent for help."
        }
        return reason
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

            if !launchGracePeriod && viewModel.hasPermissionIssues && viewModel.currentMode != .unlocked {
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

    @ViewBuilder
    private var pendingReviewsCard: some View {
        let reviews = viewModel.pendingReviews
        if !reviews.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "clock.badge.questionmark")
                        .foregroundStyle(.orange)
                    Text("Pending Parent Approval")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ForEach(reviews) { review in
                    HStack(spacing: 10) {
                        Image(systemName: "app.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(review.appName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                            Text("Waiting for approval")
                                .font(.caption)
                                .foregroundStyle(.orange.opacity(0.8))
                        }
                        Spacer()
                        Text(review.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .padding(.bottom, 8)
            }
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }

    /// Child can request ONE app at a time. Opens sheet with inline picker,
    /// auto-closes picker when one app selected, then shows naming view.
    @ViewBuilder
    private var requestMoreAppsButton: some View {
        #if canImport(FamilyControls)
        Button {
            singleAppSelection = FamilyActivitySelection()
            singleAppToken = nil
            singleAppName = ""
            singleAppPromptHint = nil
            showSingleAppPick = true
        } label: {
            Label("Request an App", systemImage: "plus.app")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .sheet(isPresented: $showSingleAppPick, onDismiss: {
            singleAppPromptHint = nil
        }) {
            ChildSingleAppPickSheet(
                appState: viewModel.appState,
                promptHint: singleAppPromptHint,
                initialName: singleAppName,
                onSubmit: { token, name in
                    submitSingleApp(token: token, name: name)
                }
            )
        }
        #endif
    }

    #if canImport(FamilyControls)
    private func submitSingleApp(token: ApplicationToken, name: String) {
        guard let enrollment = try? KeychainManager().get(
            ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
        ) else { return }

        let storage = AppGroupStorage()
        let encoder = JSONEncoder()

        guard let tokenData = try? encoder.encode(token) else { return }
        let fingerprint = TokenFingerprint.fingerprint(for: tokenData)

        // Only block submission if this exact token is already in the working
        // allowed set or has a matching time-limit binding AND we already have
        // a usable cached name for it. Pre-naming-era allowed apps with no name
        // (or just "App N") MUST be re-pickable so the user can give them a
        // real name on this pass. Stale picker-selection entries and stale
        // pending reviews never block — those need fresh PendingAppReviews to
        // re-bind rotated tokens.
        let tokenKey = tokenData.base64EncodedString()
        let cachedName = storage.readAllCachedAppNames()[tokenKey]
        let hasUsableCachedName: Bool = {
            guard let n = cachedName?.trimmingCharacters(in: .whitespaces),
                  !n.isEmpty else { return false }
            if n.hasPrefix("App ") { return false }
            if n.hasPrefix("Temporary") { return false }
            if n == "App" || n == "Unknown" { return false }
            return true
        }()
        if hasUsableCachedName {
            if let allowedData = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
               let allowedTokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: allowedData),
               allowedTokens.contains(token) {
                return
            }
            for limit in storage.readAppTimeLimits() {
                if limit.tokenData.base64EncodedString() == tokenKey {
                    return
                }
            }
        }
        // Drop any existing pending review with the same fingerprint — it's stale.
        // We're about to write a fresh one with the current token bytes.
        var existingPending: [PendingAppReview] = {
            guard let data = storage.readRawData(forKey: "pending_review_local.json") else { return [] }
            return (try? JSONDecoder().decode([PendingAppReview].self, from: data)) ?? []
        }()
        existingPending.removeAll { $0.appFingerprint == fingerprint }
        if let encoded = try? JSONEncoder().encode(existingPending) {
            try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
        }

        // Add to picker selection for enforcement
        var pickerSelection: FamilyActivitySelection
        if let data = storage.readRawData(forKey: StorageKeys.familyActivitySelection),
           let existing = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            pickerSelection = existing
        } else {
            pickerSelection = FamilyActivitySelection()
        }
        pickerSelection.applicationTokens.insert(token)
        if let encoded = try? encoder.encode(pickerSelection) {
            try? storage.writeRawData(encoded, forKey: StorageKeys.familyActivitySelection)
        }

        // Cache the name keyed by tokenData base64 so findTokensForAppName can resolve
        // it later when the parent's auto-approve sends allowManagedApp(appName:).
        // Without this, picker-captured names live only in pending_review_local.json
        // and CommandProcessor's name lookup misses them entirely.
        storage.cacheAppName(name, forTokenKey: tokenData.base64EncodedString())

        // Create pending review with the name the child entered
        let review = PendingAppReview(
            familyID: enrollment.familyID,
            childProfileID: enrollment.childProfileID,
            deviceID: enrollment.deviceID,
            appFingerprint: fingerprint,
            appName: name,
            nameResolved: true
        )

        // Create DNS verification watch (child-named = unverified)
        let watch = UnverifiedAppWatch(
            fingerprint: fingerprint,
            childGivenName: name,
            deviceID: enrollment.deviceID,
            childProfileID: enrollment.childProfileID
        )
        var watches: [UnverifiedAppWatch] = {
            guard let d = storage.readRawData(forKey: "unverified_app_watches.json") else { return [] }
            return (try? JSONDecoder().decode([UnverifiedAppWatch].self, from: d)) ?? []
        }()
        watches.append(watch)
        if let encoded = try? JSONEncoder().encode(watches) {
            try? storage.writeRawData(encoded, forKey: "unverified_app_watches.json")
        }

        // Save locally
        var pending: [PendingAppReview] = {
            guard let data = storage.readRawData(forKey: "pending_review_local.json") else { return [] }
            return (try? JSONDecoder().decode([PendingAppReview].self, from: data)) ?? []
        }()
        pending.append(review)
        if let encoded = try? JSONEncoder().encode(pending) {
            try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
        }
        UserDefaults.appGroup?
            .set(Date().timeIntervalSince1970, forKey: "pendingReviewNeedsSync")

        // Refresh pending reviews immediately so card appears
        viewModel.refreshPendingReviews()

        // Re-apply enforcement. b439: MUST dispatch to a detached background
        // task — apply() is synchronous, takes the static applyLock, and can
        // fall into the deep daemon rescue (6+ seconds of Thread.sleep). This
        // runs inside the "Submit for Review" button action on the MainActor,
        // so a direct call freezes the UI and makes the submit look stuck.
        // Some apps (fast apply path) appear to work; others (slow/rescue
        // path) hang for up to a minute. Detaching the apply fixes the hang.
        let enforcementRef = viewModel.appState.enforcement
        let storageRef = viewModel.appState.storage
        Task.detached {
            if let snapshot = storageRef.readPolicySnapshot() {
                try? enforcementRef?.apply(snapshot.effectivePolicy)
            }
        }

        // Push to CloudKit
        Task {
            let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
            let db = container.publicCloudDatabase
            let recordID = CKRecord.ID(recordName: "BBPendingAppReview_\(review.id.uuidString)")
            let record = CKRecord(recordType: "BBPendingAppReview", recordID: recordID)
            record["familyID"] = review.familyID.rawValue
            record["profileID"] = review.childProfileID.rawValue
            record["deviceID"] = review.deviceID.rawValue
            record["appFingerprint"] = review.appFingerprint
            record["appName"] = review.appName
            record["nameResolved"] = 1 as NSNumber
            record["createdAt"] = review.createdAt as NSDate
            record["updatedAt"] = review.updatedAt as NSDate
            let op = CKModifyRecordsOperation(recordsToSave: [record])
            op.savePolicy = .changedKeys
            op.qualityOfService = .userInitiated
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    op.modifyRecordsResultBlock = { result in
                        switch result {
                        case .success: cont.resume()
                        case .failure(let error): cont.resume(throwing: error)
                        }
                    }
                    db.add(op)
                }
            } catch { }
        }
    }
    #endif

    // Reset All Apps button removed from child view — too dangerous.
    // Available only via parent "Revoke All Apps" command.
    @ViewBuilder
    private var resetAllAppsButton: some View {
        EmptyView()
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

    // MARK: - Web & Internet Status Card

    @ViewBuilder
    private var webStatusCard: some View {
        if viewModel.isWebBlocked {
            VStack(spacing: 12) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: viewModel.currentMode == .lockedDown ? "wifi.slash" : "globe")
                        .font(.title3)
                        .foregroundStyle(webStatusColor)
                    Text(webStatusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }

                // Explanation
                Text(viewModel.webStatusExplanation)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Allowed domains list (restricted mode with specific domains)
                let domains = viewModel.allowedWebDomains
                if viewModel.currentMode == .restricted && !domains.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allowed sites:")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                        ForEach(domains.prefix(8), id: \.self) { domain in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green.opacity(0.7))
                                Text(domain)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        if domains.count > 8 {
                            Text("+ \(domains.count - 8) more")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }

                // When it comes back
                if let availableAt = viewModel.webAvailableAt {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(availableAt)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.top, 2)
                }
            }
            .padding(16)
            .background(webStatusColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }

    private var webStatusTitle: String {
        switch viewModel.currentMode {
        case .unlocked: return ""
        case .restricted: return "Web Access Limited"
        case .locked: return "Web Access Paused"
        case .lockedDown: return "Internet Paused"
        }
    }

    private var webStatusColor: Color {
        switch viewModel.currentMode {
        case .unlocked: return .green
        case .restricted: return .blue
        case .locked: return .purple
        case .lockedDown: return .red
        }
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
