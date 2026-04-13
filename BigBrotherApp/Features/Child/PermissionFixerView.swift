import SwiftUI
import CoreMotion
import CoreLocation
@preconcurrency import UserNotifications
import BigBrotherCore

/// Step-by-step permission wizard for child devices.
/// Guides the child (or parent holding the device) through granting all required permissions.
struct PermissionFixerView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0
    @State private var permissionsToFix: [PermissionItem] = []
    @State private var waitingForReturn = false
    /// True while the system FamilyControls prompt is showing + Apple's
    /// daemon finishes negotiation. The await can take 5-10s on real
    /// devices (Apple-side, not ours), so we show a blocking spinner with
    /// explanatory text so the kid doesn't think the app hung.
    @State private var isGrantingFamilyControls = false

    var body: some View {
        NavigationView {
            ZStack {
                VStack(spacing: 0) {
                    if permissionsToFix.isEmpty {
                        allDoneView
                    } else if currentStep < permissionsToFix.count {
                        stepView(permissionsToFix[currentStep])
                    } else {
                        allDoneView
                    }
                }

                if isGrantingFamilyControls {
                    familyControlsLoadingOverlay
                }
            }
            .navigationTitle("Fix Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        completeOnboarding()
                        dismiss()
                    }
                    .disabled(isGrantingFamilyControls)
                }
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if waitingForReturn {
                waitingForReturn = false
                refreshPermissions()
            }
        }
    }

    /// Loading overlay shown during the FamilyControls authorization call.
    /// That call can take 5-10 seconds on real devices while Apple's daemon
    /// negotiates with iCloud and Family Sharing — without this, the UI
    /// looks hung after the kid taps "Continue" on the system prompt.
    private var familyControlsLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("Connecting to Screen Time…")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("This can take several seconds.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(32)
            .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.7)))
        }
        .transition(.opacity)
    }

    // MARK: - Step View

    @ViewBuilder
    private func stepView(_ item: PermissionItem) -> some View {
        VStack(spacing: 20) {
            Spacer()

            // Icon
            Image(systemName: item.icon)
                .font(.system(size: 60))
                .foregroundStyle(item.color)
                .padding(.bottom, 8)

            // Title
            Text(item.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            // Why it's needed
            Text(item.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Instructions (for Settings-only permissions)
            if let instructions = item.instructions {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(instructions.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1).")
                                .font(.subheadline.bold())
                                .foregroundStyle(item.color)
                                .frame(width: 20)
                            Text(step)
                                .font(.subheadline)
                        }
                    }
                }
                .padding()
                .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
                .padding(.horizontal, 24)
            }

            Spacer()

            // Progress
            HStack(spacing: 6) {
                ForEach(0..<permissionsToFix.count, id: \.self) { i in
                    Circle()
                        .fill(i == currentStep ? item.color : Color(.systemGray4))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 8)

            // Action button
            Button {
                handleAction(item)
            } label: {
                Text(item.buttonLabel)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(item.color)
            .padding(.horizontal, 24)

            // Skip button
            Button("Skip for now") {
                advanceStep()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
        }
    }

    // MARK: - All Done

    private var allDoneView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
            Text("All Set!")
                .font(.title.bold())
            Text("All permissions are granted. The device will enforce your parent's rules.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button("Done") {
                completeOnboarding()
                dismiss()
            }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
        }
    }

    private func completeOnboarding() {
        let defaults = UserDefaults.appGroup
        defaults?.removeObject(forKey: "showPermissionFixerOnNextLaunch")

        let allGranted = permissionsToFix.isEmpty
        if allGranted {
            defaults?.set(true, forKey: "permissionFixerCompletedOnce")
        }

        let enforcement = appState.enforcement
        let storage = appState.storage
        Task.detached {
            if let snapshot = storage.readPolicySnapshot() {
                try? enforcement?.apply(snapshot.effectivePolicy)
            }
        }

        // Restart location/motion now that suppression flag is cleared
        appState.locationService?.setMode(appState.locationService?.mode ?? .continuous)
    }

    // MARK: - Permission Checking

    private func refreshPermissions() {
        var items: [PermissionItem] = []

        // 1. FamilyControls
        if appState.familyControlsAvailable,
           appState.enforcement?.authorizationStatus != .authorized {
            items.append(.familyControls)
        }

        // 2. Location — need "Always"
        if let locService = appState.locationService {
            let status = locService.authorizationStatus
            if status != .authorizedAlways {
                items.append(.locationAlways(current: status))
            }
        }

        // 3. CoreMotion
        if CMMotionActivityManager.isActivityAvailable(),
           CMMotionActivityManager.authorizationStatus() != .authorized {
            items.append(.motion)
        }

        // 4. Notifications
        // Check synchronously from cached value or assume needed
        let notifCenter = UNUserNotificationCenter.current()
        Task {
            let settings = await notifCenter.notificationSettings()
            await MainActor.run {
                if settings.authorizationStatus != .authorized {
                    items.append(.notifications(status: settings.authorizationStatus))
                }
                // 5. VPN
                if let vpn = appState.vpnManager {
                    Task {
                        let configured = await vpn.isConfigured()
                        await MainActor.run {
                            if !configured {
                                items.append(.vpn)
                            }
                            self.permissionsToFix = items
                            // Reset step if permissions changed
                            if currentStep >= items.count {
                                currentStep = 0
                            }
                        }
                    }
                } else {
                    self.permissionsToFix = items
                    if currentStep >= items.count {
                        currentStep = 0
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func handleAction(_ item: PermissionItem) {
        switch item {
        case .familyControls:
            isGrantingFamilyControls = true
            Task {
                let startedAt = Date()
                try? await appState.enforcement?.requestAuthorization()
                let elapsed = Date().timeIntervalSince(startedAt)
                NSLog("[PermissionFixer] FC auth round-trip: \(String(format: "%.2f", elapsed))s")
                await MainActor.run {
                    isGrantingFamilyControls = false
                    refreshPermissions()
                }
            }

        case .locationAlways(let current):
            if current == .notDetermined {
                // Can request directly
                appState.locationService?.requestAlwaysAuthorization()
                waitingForReturn = true
            } else {
                // Must go to Settings
                openSettings()
            }

        case .motion:
            let motionStatus = CMMotionActivityManager.authorizationStatus()
            if motionStatus == .notDetermined {
                let manager = CMMotionActivityManager()
                manager.startActivityUpdates(to: .main) { _ in }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    manager.stopActivityUpdates()
                    refreshPermissions()
                }
            } else if motionStatus == .authorized {
                refreshPermissions()
            } else {
                openSettings()
            }

        case .notifications(let status):
            if status == .notDetermined {
                Task {
                    let center = UNUserNotificationCenter.current()
                    _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                    await MainActor.run { refreshPermissions() }
                }
            } else {
                openSettings()
            }

        case .vpn:
            Task {
                try? await appState.vpnManager?.installAndStart()
                await MainActor.run { refreshPermissions() }
            }
        }
    }

    private func advanceStep() {
        if currentStep < permissionsToFix.count - 1 {
            withAnimation { currentStep += 1 }
        } else {
            dismiss()
        }
    }

    private func openSettings() {
        waitingForReturn = true
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Permission Item

enum PermissionItem: Identifiable {
    case familyControls
    case locationAlways(current: CLAuthorizationStatus)
    case motion
    case notifications(status: UNAuthorizationStatus)
    case vpn

    var id: String {
        switch self {
        case .familyControls: return "fc"
        case .locationAlways: return "loc"
        case .motion: return "motion"
        case .notifications: return "notif"
        case .vpn: return "vpn"
        }
    }

    var icon: String {
        switch self {
        case .familyControls: return "shield.checkered"
        case .locationAlways: return "location.fill"
        case .motion: return "figure.walk.motion"
        case .notifications: return "bell.badge.fill"
        case .vpn: return "network.badge.shield.half.filled"
        }
    }

    var color: Color {
        switch self {
        case .familyControls: return .blue
        case .locationAlways: return .green
        case .motion: return .orange
        case .notifications: return .red
        case .vpn: return .purple
        }
    }

    var title: String {
        switch self {
        case .familyControls: return "Screen Time Access"
        case .locationAlways: return "Location — Always"
        case .motion: return "Motion & Fitness"
        case .notifications: return "Notifications"
        case .vpn: return "VPN Protection"
        }
    }

    var explanation: String {
        switch self {
        case .familyControls:
            return "Required to manage which apps are available. Without this, no app blocking works."
        case .locationAlways(let current):
            if current == .notDetermined {
                return "Your parent needs to know where you are. Location must be set to \"Always\" for background tracking."
            }
            return "Location is currently set to \"\(current == .denied ? "Never" : "While Using")\". It needs to be \"Always\" so your parent can see where you are even when the app is in the background."
        case .motion:
            return "Detects when you're driving so safety features work. Without this, driving detection is disabled."
        case .notifications:
            return "Allows the app to alert you about schedule changes, unlock approvals, and important messages from your parent."
        case .vpn:
            return "Keeps the app running in the background to maintain protection. Without this, heartbeats stop when the app is closed."
        }
    }

    var instructions: [String]? {
        switch self {
        case .locationAlways(let current):
            if current == .notDetermined { return nil } // system dialog will show
            return [
                "Tap \"Location\" in the settings page that opens",
                "Select \"Always\"",
                "Come back to this app"
            ]
        case .motion:
            if CMMotionActivityManager.authorizationStatus() == .notDetermined { return nil }
            return [
                "Tap \"Motion & Fitness\" in the settings page",
                "Turn on the switch for Big Brother",
                "Come back to this app"
            ]
        case .notifications(let status):
            if status == .notDetermined { return nil }
            return [
                "Tap \"Notifications\" in the settings page",
                "Turn on \"Allow Notifications\"",
                "Come back to this app"
            ]
        default:
            return nil
        }
    }

    var buttonLabel: String {
        if instructions != nil {
            return "Open Settings"
        }
        switch self {
        case .familyControls: return "Grant Access"
        case .locationAlways: return "Allow Location"
        case .motion: return "Allow Motion"
        case .notifications: return "Allow Notifications"
        case .vpn: return "Install VPN"
        }
    }
}
