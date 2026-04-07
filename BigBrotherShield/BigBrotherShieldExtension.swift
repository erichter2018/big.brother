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
        cacheAppIdentity(application: application)
        if let config = forceCloseShieldConfig { return config }
        if let config = timeLimitShieldConfig(application: application) { return config }
        // Temporary diagnostic: show build marker + name to verify extension binary is updated
        let name = application.localizedDisplayName ?? "nil"
        let hasToken = application.token != nil
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(text: name, color: .black),
            subtitle: ShieldConfiguration.Label(text: "b310 | token:\(hasToken)", color: .gray),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue
        )
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        cacheAppIdentity(application: application)
        if let config = forceCloseShieldConfig { return config }
        if let config = timeLimitShieldConfig(application: application) { return config }
        let name = application.localizedDisplayName ?? "nil"
        let hasToken = application.token != nil
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(text: name, color: .black),
            subtitle: ShieldConfiguration.Label(text: "b310-cat | token:\(hasToken)", color: .gray),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue
        )
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        return forceCloseShieldConfig ?? ShieldConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        return forceCloseShieldConfig ?? ShieldConfiguration()
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
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
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
