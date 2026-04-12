import Foundation
import ManagedSettingsUI
import ManagedSettings
import BigBrotherCore
import notify

/// ShieldConfiguration extension — uses default iOS shield UI.
///
/// Still writes app identity to Keychain for ShieldAction to read,
/// but does not customize the shield appearance.
class BigBrotherShieldExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        UserDefaults.appGroup?
            .set(AppConstants.appBuildNumber, forKey: "shieldBuildNumber")
        cacheAppIdentity(application: application)
        detectGhostShield(application: application, viaCategory: false)
        if let config = forceCloseShieldConfig { return config }
        if let config = timeLimitShieldConfig(application: application) { return config }
        if let config = pendingReviewShieldConfig(application: application) { return config }
        return defaultShieldConfig(application: application)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        cacheAppIdentity(application: application)
        detectGhostShield(application: application, viaCategory: true)
        if let config = forceCloseShieldConfig { return config }
        if let config = timeLimitShieldConfig(application: application) { return config }
        if let config = pendingReviewShieldConfig(application: application) { return config }
        return defaultShieldConfig(application: application)
    }

    /// b431: Detect when the OS renders a shield for an app that, according to
    /// our current policy, should NOT be shielded. This is the smoking gun for
    /// an external writer (Apple iCloud Screen Time sync from a Family Sharing
    /// parent device, or stale local Screen Time settings) — our store says
    /// "let this app through" but the daemon's merged state still blocks it.
    ///
    /// Writes the detection to App Group UserDefaults; main app reads on next
    /// heartbeat and reports `ghostShieldsDetected: true` to the parent dashboard.
    private func detectGhostShield(application: Application, viaCategory: Bool) {
        let storage = AppGroupStorage()
        let resolution = ModeStackResolver.resolve(storage: storage)
        let mode = resolution.mode
        let isTempUnlock = resolution.isTemporary && mode == .unlocked

        // Skip detection in locked/lockedDown mode — every shield is expected.
        if mode == .locked || mode == .lockedDown { return }

        // Only proceed if we have a token to check.
        guard let appToken = application.token,
              let tokenData = try? JSONEncoder().encode(appToken) else { return }
        let fp = TokenFingerprint.fingerprint(for: tokenData)

        // Skip detection during recent mode transitions — the daemon may not
        // have processed our most recent write yet, so a "ghost" shield could
        // just be lag. Check BOTH the main app's apply timestamp and the
        // Monitor extension's confirmation timestamp; either writer may have
        // recently changed the state.
        let defaults = UserDefaults.appGroup
        let lastMainApplyAt = defaults?.double(forKey: "mainAppEnforcementAt") ?? 0
        let lastMonitorConfirmAt = defaults?.double(forKey: "monitorEnforcementConfirmedAt") ?? 0
        let lastAnyApplyAt = max(lastMainApplyAt, lastMonitorConfirmAt)
        let now = Date().timeIntervalSince1970
        if now - lastAnyApplyAt < 30 { return }

        // b432: BEFORE checking the policy, suppress detection for apps that
        // have a legitimate non-policy reason to be shielded:
        //   1. Time-exhausted apps for today (timeLimitShieldConfig handles these)
        //   2. Pending review apps (pendingReviewShieldConfig handles these)
        //   3. force-close shield active (forceCloseShieldConfig handles all apps)
        // Without this, detectGhostShield would falsely flag any of these as
        // ghost shields. The order in `configuration(shielding:)` runs
        // detectGhostShield BEFORE the time-limit/pending-review checks, so we
        // need to mirror that logic here.
        let today = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let exhaustedToday = storage.readTimeLimitExhaustedApps()
            .filter { $0.dateString == today }
            .contains { $0.fingerprint == fp }
        if exhaustedToday { return }

        // Check pending reviews — same JSON file the pendingReviewShieldConfig reads.
        if let prData = storage.readRawData(forKey: "pending_review_local.json"),
           let reviews = try? JSONDecoder().decode([PendingAppReview].self, from: prData),
           reviews.contains(where: { $0.appFingerprint == fp }) {
            return
        }

        // Force-close shield is global (applies to all apps regardless of token).
        if defaults?.bool(forKey: "forceCloseWebBlocked") == true { return }

        // Decide if THIS app should be shielded according to our policy.
        let isAllowedByPolicy: Bool = {
            if mode == .unlocked || isTempUnlock {
                // Everything is allowed in unlocked or temp unlock — any shield
                // is unexpected.
                return true
            }
            // Restricted mode — check if app is in always-allowed list.
            if let allowedData = storage.readRawData(forKey: StorageKeys.allowedAppTokens) {
                if let decoded = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: allowedData) {
                    for t in decoded {
                        if let td = try? JSONEncoder().encode(t),
                           TokenFingerprint.fingerprint(for: td) == fp {
                            return true
                        }
                    }
                }
            }
            // Restricted mode — check if app is in temporary-allowed list.
            for entry in storage.readTemporaryAllowedApps() where entry.isValid {
                if TokenFingerprint.fingerprint(for: entry.tokenData) == fp {
                    return true
                }
            }
            return false
        }()

        guard isAllowedByPolicy else { return }

        // Suppress duplicate evidence of the same fingerprint within 5 minutes —
        // the OS calls ShieldConfiguration repeatedly and we don't need 100x
        // identical entries.
        let lastFP = defaults?.string(forKey: "ghostShieldLastFingerprint") ?? ""
        let lastFPAt = defaults?.double(forKey: "ghostShieldLastFingerprintAt") ?? 0
        if lastFP == fp && (now - lastFPAt) < 300 {
            // Still bump the "lastSeenAt" so the heartbeat reports it as fresh,
            // but don't increment the counter or log a new diagnostic.
            defaults?.set(now, forKey: "ghostShieldsDetectedAt")
            return
        }

        // Record the ghost shield evidence.
        let count = (defaults?.integer(forKey: "ghostShieldsDetectedCount") ?? 0) + 1
        defaults?.set(true, forKey: "ghostShieldsDetected")
        defaults?.set(now, forKey: "ghostShieldsDetectedAt")
        defaults?.set(count, forKey: "ghostShieldsDetectedCount")
        defaults?.set(fp, forKey: "ghostShieldLastFingerprint")
        defaults?.set(now, forKey: "ghostShieldLastFingerprintAt")
        let appName = application.localizedDisplayName ?? application.bundleIdentifier ?? "unknown"
        let reason = "mode=\(mode.rawValue) tempUnlock=\(isTempUnlock) viaCategory=\(viaCategory) app=\(appName) fp=\(fp) count=\(count)"
        defaults?.set(reason, forKey: "ghostShieldsDetectedReason")
    }

    /// Standard shield for blocked apps — clean, user-friendly.
    private func defaultShieldConfig(application: Application) -> ShieldConfiguration {
        let storage = AppGroupStorage()
        let shieldConfig = storage.readShieldConfiguration()
        let title = shieldConfig?.title ?? "App Blocked"
        let message = shieldConfig?.message ?? "This app is not available right now."

        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(text: title, color: .black),
            subtitle: ShieldConfiguration.Label(text: message, color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue,
            secondaryButtonLabel: ShieldConfiguration.Label(text: "Ask for Access", color: .systemBlue)
        )
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        return forceCloseShieldConfig ?? webShieldConfig
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        return forceCloseShieldConfig ?? webShieldConfig
    }

    private var webShieldConfig: ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(text: "Website Blocked", color: .black),
            subtitle: ShieldConfiguration.Label(text: "Web browsing is not available right now.", color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue
        )
    }

    /// Custom shield for apps that exhausted their daily time limit.
    /// Shows "Time's Up" with a "Request More Time" button.
    private func timeLimitShieldConfig(application: Application) -> ShieldConfiguration? {
        guard let appToken = application.token,
              let tokenData = try? JSONEncoder().encode(appToken) else { return nil }

        let fp = TokenFingerprint.fingerprint(for: tokenData)
        let storage = AppGroupStorage()
        let today = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let exhaustedApps = storage.readTimeLimitExhaustedApps().filter { $0.dateString == today }

        // Match by fingerprint — tokenData encoding can differ between processes.
        guard exhaustedApps.contains(where: { $0.fingerprint == fp }) else { return nil }

        let appName = application.localizedDisplayName ?? "This app"

        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(text: "Time's Up", color: .orange),
            subtitle: ShieldConfiguration.Label(text: "\(appName)'s daily limit has been reached.", color: .black),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .gray,
            secondaryButtonLabel: ShieldConfiguration.Label(text: "Request More Time", color: .systemBlue)
        )
    }

    /// Custom shield for apps the child selected that are pending parent review.
    /// Prominently shows the app name so the child knows the request was sent.
    private func pendingReviewShieldConfig(application: Application) -> ShieldConfiguration? {
        guard let appToken = application.token,
              let tokenData = try? JSONEncoder().encode(appToken) else { return nil }

        let fp = TokenFingerprint.fingerprint(for: tokenData)
        let storage = AppGroupStorage()

        // Check local pending reviews (unresolved ones stay local until shield captures their name).
        guard let data = storage.readRawData(forKey: "pending_review_local.json"),
              let reviews = try? JSONDecoder().decode([PendingAppReview].self, from: data),
              reviews.contains(where: { $0.appFingerprint == fp }) else { return nil }

        let appName = application.localizedDisplayName ?? "This app"

        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(text: appName, color: .black),
            subtitle: ShieldConfiguration.Label(text: "Sent to parent for review", color: .systemBlue),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue
        )
    }

    /// Custom shield config shown when web is blocked due to force-close.
    private var forceCloseShieldConfig: ShieldConfiguration? {
        let defaults = UserDefaults.appGroup
        guard defaults?.bool(forKey: "forceCloseWebBlocked") == true else { return nil }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(text: "Apps Paused", color: .orange),
            subtitle: ShieldConfiguration.Label(text: "Open Big Brother to restore access.", color: .white),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .gray
        )
    }

    /// Cache app identity via Darwin notification state (notifyd).
    /// Keychain (-25291), App Group files, and UserDefaults (cfprefsd) are ALL blocked.
    /// Darwin notify_set_state uses notifyd which is a separate IPC channel.
    /// Each slot carries 8 bytes; we chain slots to pass the full name.
    private func cacheAppIdentity(application: Application) {
        let resolvedName = application.localizedDisplayName ?? application.bundleIdentifier ?? "App"
        let bundleID = application.bundleIdentifier ?? ""

        // Encode name into 8-byte chunks via Darwin notification state slots.
        // notify_set_state stores a UInt64 per notification name.
        let nameData = Array(resolvedName.utf8)
        let prefix = "group.fr.bigbrother.shared.shield"

        // Store name length + timestamp indicator
        setNotifyState("\(prefix).meta", value: UInt64(nameData.count) | (UInt64(UInt32(Date().timeIntervalSince1970)) << 32))

        // Store name in 8-byte chunks (supports up to 32 chars = 4 slots)
        for i in 0..<4 {
            let start = i * 8
            guard start < nameData.count else {
                setNotifyState("\(prefix).n\(i)", value: 0)
                continue
            }
            let end = min(start + 8, nameData.count)
            var val: UInt64 = 0
            for j in start..<end {
                val |= UInt64(nameData[j]) << (UInt64(j - start) * 8)
            }
            setNotifyState("\(prefix).n\(i)", value: val)
        }

        // Store bundleID length + first 8 bytes
        let bidData = Array(bundleID.utf8)
        setNotifyState("\(prefix).bid", value: UInt64(bidData.count))
        if !bidData.isEmpty {
            var val: UInt64 = 0
            for j in 0..<min(8, bidData.count) {
                val |= UInt64(bidData[j]) << (UInt64(j) * 8)
            }
            setNotifyState("\(prefix).bid0", value: val)
        }

        // Post a signal so listeners know new data is available
        notify_post("\(prefix).updated")
    }

    private func setNotifyState(_ name: String, value: UInt64) {
        var token: Int32 = 0
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return }
        notify_set_state(token, value)
        notify_cancel(token)
    }
}
