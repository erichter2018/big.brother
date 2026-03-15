import Foundation
import DeviceActivity
import ManagedSettings
import UserNotifications
import BigBrotherCore

/// DeviceActivityMonitor extension.
///
/// Triggered by the system when registered DeviceActivitySchedule
/// intervals start or end. Guaranteed to run even if the main app
/// is not running.
///
/// Responsibilities:
/// - Read PolicySnapshot from App Group storage
/// - Apply/clear ManagedSettings restrictions on the "schedule" store
/// - Append event log entries to App Group storage
///
/// Constraints:
/// - Cannot make network calls
/// - Cannot present UI
/// - Very limited memory and execution time
/// - Must read all state from App Group shared storage
class BigBrotherMonitorExtension: DeviceActivityMonitor {

    private let storage = AppGroupStorage()
    private let store = ManagedSettingsStore(named: .init(AppConstants.managedSettingsStoreSchedule))

    /// Prefix used by ScheduleRegistrar for free-window activities.
    private let scheduleProfilePrefix = "bigbrother.scheduleprofile."

    override func intervalDidStart(for activity: DeviceActivityName) {
        // Reconciliation schedule — verify enforcement matches snapshot.
        if activity.rawValue == "bigbrother.reconciliation" {
            reconcile()
            return
        }

        // Schedule profile free window — unlock if today matches.
        if activity.rawValue.hasPrefix(scheduleProfilePrefix) {
            handleFreeWindowStart(activity)
            return
        }

        // Legacy / other schedule activity — apply current policy mode.
        let mode: LockMode
        let policy: EffectivePolicy?
        if let extState = storage.readExtensionSharedState() {
            mode = extState.currentMode
            policy = storage.readPolicySnapshot()?.effectivePolicy
        } else if let snapshot = storage.readPolicySnapshot() {
            mode = snapshot.effectivePolicy.resolvedMode
            policy = snapshot.effectivePolicy
        } else {
            return
        }

        applyShielding(mode: mode, policy: policy)
        logEvent(.scheduleTriggered, details: "Schedule started: \(activity.rawValue)")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        if activity.rawValue == "bigbrother.reconciliation" { return }

        // Schedule profile free window ended — re-lock.
        if activity.rawValue.hasPrefix(scheduleProfilePrefix) {
            handleFreeWindowEnd(activity)
            return
        }

        // Legacy / other schedule — clear schedule store.
        store.clearAllSettings()
        logEvent(.scheduleEnded, details: "Schedule ended: \(activity.rawValue)")
    }

    // MARK: - Schedule Profile Handling

    /// Free window started: check if today is a valid day, then unlock.
    private func handleFreeWindowStart(_ activity: DeviceActivityName) {
        guard let profile = storage.readActiveScheduleProfile() else { return }

        let windowID = String(activity.rawValue.dropFirst(scheduleProfilePrefix.count))
        guard let window = profile.freeWindows.first(where: { $0.id.uuidString == windowID }) else {
            return
        }

        // Check if today matches one of this window's active days.
        let today = Calendar.current.component(.weekday, from: Date())
        guard let day = DayOfWeek(rawValue: today), window.daysOfWeek.contains(day) else {
            // Not a matching day — keep locked.
            return
        }

        // Unlock: clear the schedule store restrictions.
        store.clearAllSettings()
        logEvent(.scheduleTriggered, details: "Free window started: \(activity.rawValue)")
        sendModeNotification(title: "Free Time Started", body: "All apps are now accessible.")
    }

    /// Free window ended: re-apply the profile's locked mode.
    private func handleFreeWindowEnd(_ activity: DeviceActivityName) {
        guard let profile = storage.readActiveScheduleProfile() else { return }

        // Check if we're currently inside another free window.
        // If so, don't lock — the device should stay free.
        if profile.isInFreeWindow(at: Date()) {
            return
        }

        // Re-lock using the profile's locked mode.
        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShielding(mode: profile.lockedMode, policy: policy)
        logEvent(.scheduleEnded, details: "Free window ended, locked to \(profile.lockedMode.rawValue)")
        sendModeNotification(
            title: "Free Time Ended",
            body: "Device locked — \(profile.lockedMode.displayName) mode active."
        )
    }

    // MARK: - Reconciliation

    /// Verify enforcement matches the current policy snapshot.
    /// If the extension shared state indicates a mode that requires shielding,
    /// reapply it in case the schedule store was cleared unexpectedly.
    private func reconcile() {
        guard let extState = storage.readExtensionSharedState() else { return }

        // If temporary unlock is active and not expired, ensure store is clear.
        if extState.isTemporaryUnlock,
           let expires = extState.temporaryUnlockExpiresAt, expires > Date() {
            store.clearAllSettings()
            return
        }

        // If enforcement is degraded, nothing we can do from the extension.
        if extState.enforcementDegraded { return }

        let policy = storage.readPolicySnapshot()?.effectivePolicy
        applyShielding(mode: extState.currentMode, policy: policy)
        logEvent(.policyReconciled, details: "Reconciliation check from extension")
    }

    // MARK: - Shielding

    private func applyShielding(mode: LockMode, policy: EffectivePolicy?) {
        switch mode {
        case .unlocked:
            store.clearAllSettings()

        case .dailyMode, .essentialOnly:
            // Read allowed tokens from App Group (same source as main app).
            let allowedTokens = collectAllowedTokens()
            if allowedTokens.isEmpty {
                store.shield.applicationCategories = .all()
            } else {
                store.shield.applicationCategories = .all(except: allowedTokens)
            }
            store.shield.webDomainCategories = .all()
        }
    }

    /// Collect parent-approved tokens from App Group storage.
    /// Mirrors EnforcementServiceImpl.collectAllowedTokens().
    private func collectAllowedTokens() -> Set<ApplicationToken> {
        let decoder = JSONDecoder()
        var tokens = Set<ApplicationToken>()

        // Permanently allowed apps.
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let allowed = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            tokens.formUnion(allowed)
        }

        // Temporarily allowed apps (non-expired only).
        let tempEntries = storage.readTemporaryAllowedApps()
        for entry in tempEntries where entry.isValid {
            if let token = try? decoder.decode(ApplicationToken.self, from: entry.tokenData) {
                tokens.insert(token)
            }
        }

        return tokens
    }

    // MARK: - Notifications

    private func sendModeNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "SCHEDULE_CHANGE"

        let request = UNNotificationRequest(
            identifier: "schedule-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func logEvent(_ type: EventType, details: String?) {
        // Read enrollment state to get deviceID and familyID.
        // If unavailable, skip logging (device may not be enrolled).
        let keychain = KeychainManager()
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        let entry = EventLogEntry(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            eventType: type,
            details: details
        )
        try? storage.appendEventLog(entry)
    }
}
