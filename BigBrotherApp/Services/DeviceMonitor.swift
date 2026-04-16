import Foundation
import UserNotifications
import BigBrotherCore

/// Monitors child device heartbeats on the parent device and fires local
/// notifications for tampering signals: FamilyControls revocation, VPN usage,
/// location disabled, and time zone changes.
///
/// **Runs only on the parent device.**
///
/// Offline detection (device stopped heartbeating) is NOT handled here.
/// Force-close is caught by the Monitor extension, which blocks all apps
/// and internet until the child reopens Big Brother.
@MainActor
final class DeviceMonitor {

    // MARK: - Configuration

    /// How often to check device status (seconds).
    private static let checkIntervalSeconds: TimeInterval = 60

    /// How often to auto-refresh dashboard data (seconds).
    private static let dashboardRefreshIntervalSeconds: TimeInterval = 120

    // MARK: - State

    private let appState: AppState

    /// Timer that fires the tampering-signal check.
    private var checkTask: Task<Void, Never>?

    /// Timer that periodically refreshes dashboard data from CloudKit.
    private var refreshTask: Task<Void, Never>?

    /// Tracks devices that have an active FamilyControls revocation alert.
    private var notifiedTamperDevices: Set<String> = []

    /// Tracks the last-known time zone per device for change detection.
    private var lastKnownTimeZones: [DeviceID: String] = [:]

    /// Tracks the last time a throttled notification was sent, keyed by
    /// notification identifier.
    private var lastNotificationTimes: [String: Date] = [:]

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        requestNotificationPermission()

        // Periodic tampering-signal check.
        let checkInterval = Self.checkIntervalSeconds
        checkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(checkInterval))
                } catch { return }
                self?.checkDeviceStatus()
            }
        }

        // Periodic dashboard refresh so heartbeat data stays current.
        let refreshInterval = Self.dashboardRefreshIntervalSeconds
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(refreshInterval))
                } catch { return }
                guard let self else { return }
                do {
                    try await self.appState.refreshDashboard()
                    #if DEBUG
                    print("[DeviceMonitor] Dashboard refreshed (\(self.appState.childDevices.count) devices)")
                    #endif
                } catch {
                    #if DEBUG
                    print("[DeviceMonitor] Dashboard refresh failed: \(error.localizedDescription)")
                    #endif
                }
            }
        }

        // Run an initial check right now.
        checkDeviceStatus()

        #if DEBUG
        print("[DeviceMonitor] Started monitoring \(appState.childDevices.count) devices")
        #endif
    }

    func stopMonitoring() {
        checkTask?.cancel()
        checkTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        notifiedTamperDevices.removeAll()

        #if DEBUG
        print("[DeviceMonitor] Stopped monitoring")
        #endif
    }

    // MARK: - Core Logic

    private func checkDeviceStatus() {
        let knownChildIDs = Set(appState.childProfiles.map(\.id))
        for device in appState.childDevices {
            guard knownChildIDs.contains(device.childProfileID) else { continue }

            let key = device.id.rawValue
            let heartbeat = appState.latestHeartbeats.first { $0.deviceID == device.id }

            // --- FamilyControls Revocation (tampering) ---
            if let hb = heartbeat, !hb.familyControlsAuthorized {
                if !notifiedTamperDevices.contains(key) {
                    notifiedTamperDevices.insert(key)
                    sendTamperNotification(device: device, heartbeat: hb)
                }
            } else if notifiedTamperDevices.contains(key) {
                // FamilyControls restored — clear the alert.
                notifiedTamperDevices.remove(key)
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: ["tamper-\(key)"]
                )
            }

            // VPN detection: still tracked in heartbeat data but no longer triggers
            // a notification. Third-party VPNs (school, etc.) don't affect shield
            // enforcement — only DNS-based features (safe search, domain logging).

            // --- VPN Tunnel Disconnect Detection ---
            // Only alert if the child has been on a VPN-capable build (167+) for at least 10 minutes.
            // This avoids false alerts during first deploy before the VPN has installed.
            if let hb = heartbeat, hb.tunnelConnected == false,
               let build = hb.appBuildNumber, build >= 167,
               Date().timeIntervalSince(hb.timestamp) < AppConstants.onlineThresholdSeconds {
                // Give the VPN 10 minutes to install after app launch
                let lastLaunch = hb.monitorLastActiveAt ?? hb.timestamp
                if Date().timeIntervalSince(lastLaunch) > 600 {
                    let name = childName(for: device)
                    sendThrottledNotification(
                        id: "tunnel-off-\(key)",
                        title: "Protection Tunnel Disabled",
                        body: "\(name)'s \(device.displayName) has the Big Brother tunnel disconnected. Monitoring may be limited.",
                        throttleHours: 1
                    )
                }
            }

            // Location authorization is visible in device detail view.
            // No notification — location denied is not tampering and not urgent.

            // --- Time Zone Change Detection ---
            if let hb = heartbeat, let tz = hb.timeZoneIdentifier {
                if let lastTZ = lastKnownTimeZones[device.id], lastTZ != tz {
                    let name = childName(for: device)
                    sendThrottledNotification(
                        id: "tz-\(key)",
                        title: "Time Zone Changed",
                        body: "\(name)'s \(device.displayName) changed time zone from \(lastTZ) to \(tz).",
                        throttleHours: 1
                    )
                }
                lastKnownTimeZones[device.id] = tz
            }

            // --- Shield Mismatch Detection ---
            // Skip if device is locked (screen off) — shields are still enforced by
            // ManagedSettingsStore even if the app isn't running. Only alert when the
            // kid is actually using the device (screen unlocked, recent heartbeat).
            if let hb = heartbeat,
               Date().timeIntervalSince(hb.timestamp) < AppConstants.onlineThresholdSeconds,
               hb.isDeviceLocked != true {
                let shouldBeShielded = hb.currentMode != .unlocked
                let shieldsDown = shouldBeShielded && hb.shieldsActive == false && hb.shieldCategoryActive != true
                // Skip if temp unlock is still active
                let hasTempUnlock = hb.temporaryUnlockExpiresAt.map { $0 > Date() } ?? false
                if shieldsDown && !hasTempUnlock {
                    let name = childName(for: device)
                    sendThrottledNotification(
                        id: "shields-\(key)",
                        title: "\(name) — Shields Down",
                        body: "\(name)'s \(device.displayName) should be in \(hb.currentMode.rawValue) mode but shields are not active.",
                        throttleHours: 2
                    )
                }
            }

            // --- Notification Authorization Detection ---
            if let hb = heartbeat, hb.notificationsAuthorized == false,
               Date().timeIntervalSince(hb.timestamp) < AppConstants.onlineThresholdSeconds {
                let name = childName(for: device)
                sendThrottledNotification(
                    id: "notif-off-\(key)",
                    title: "\(name) — Notifications Disabled",
                    body: "\(name)'s \(device.displayName) has Big Brother notifications disabled. Nag screens and alerts won't work.",
                    throttleHours: 24
                )
            }

            // Auth type degradation (individual auth) is visible in device detail view.
            // No notification — it's informational, not actionable from the parent's phone.

            // --- Device Offline Detection + Auto-Ping ---
            if let hb = heartbeat {
                let age = Date().timeIntervalSince(hb.timestamp)
                // Alert if heartbeat is stale (>30 min) and device is expected to be active.
                // 15 min was too aggressive — idle/sleeping devices always trigger this.
                // Only alert during daytime hours (7am-11pm) to avoid nighttime spam.
                let hour = Calendar.current.component(.hour, from: Date())
                let isDaytime = hour >= 7 && hour < 23
                if age > 1800 && isDaytime {
                    let name = childName(for: device)
                    sendThrottledNotification(
                        id: "offline-\(key)",
                        title: "\(name) — Device Offline",
                        body: "\(name)'s \(device.displayName) hasn't reported in \(Self.humanReadableDuration(age)).",
                        throttleHours: 4
                    )
                    let pingKey = "ping-\(key)"
                    if lastNotificationTimes[pingKey] == nil ||
                       Date().timeIntervalSince(lastNotificationTimes[pingKey]!) > 900 {
                        lastNotificationTimes[pingKey] = Date()
                        Task {
                            try? await appState.sendCommand(
                                target: .device(device.id),
                                action: .requestHeartbeat
                            )
                        }
                    }
                }

                if age > 7200 && isDaytime {
                    let battery = hb.batteryLevel ?? 0
                    let wasCharging = hb.isCharging ?? false
                    if battery > 0.2 || wasCharging {
                        let name = childName(for: device)
                        sendThrottledNotification(
                            id: "maybe-deleted-\(key)",
                            title: "\(name) — App May Be Removed",
                            body: "\(name)'s \(device.displayName) had \(Int(battery * 100))% battery but hasn't reported in \(Self.humanReadableDuration(age)). The app may have been deleted.",
                            throttleHours: 12
                        )
                    }
                }
            }
        }

        // --- Safety Event Notifications (C4 fix) ---
        // Check CloudKit events for all children, not just when Activity Feed is open.
        checkSafetyEvents()
    }

    /// Check CloudKit events and trigger safety notifications.
    /// Previously only ran when parent opened Activity Feed — now runs every 60s.
    private func checkSafetyEvents() {
        Task {
            guard let cloudKit = appState.cloudKit,
                  let familyID = appState.parentState?.familyID else { return }
            let profiles = appState.childProfiles
            let devices = appState.childDevices

            // Fetch only safety-relevant events from the last hour.
            let cutoff = Date().addingTimeInterval(-3600)
            guard let events = try? await cloudKit.fetchEventLogs(
                familyID: familyID,
                since: cutoff,
                types: SafetyEventNotificationService.notifiableTypes
            ) else { return }

            // Fetch named places for notification filtering
            let namedPlaces = (try? await appState.cloudKit?.fetchNamedPlaces(
                familyID: appState.parentState?.familyID ?? FamilyID(rawValue: "")
            )) ?? []

            for profile in profiles {
                let deviceIDs = Set(devices.filter { $0.childProfileID == profile.id }.map(\.id))
                let childEvents = events.filter { deviceIDs.contains($0.deviceID) }
                SafetyEventNotificationService.checkAndNotify(events: childEvents, childName: profile.name, namedPlaces: namedPlaces)
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        // Suppress during onboarding — PermissionFixerView handles notifications.
        let defaults = UserDefaults.appGroup
        if defaults?.bool(forKey: "showPermissionFixerOnNextLaunch") == true { return }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                #if DEBUG
                print("[DeviceMonitor] Notification permission granted: \(granted)")
                #endif
            } catch {
                #if DEBUG
                print("[DeviceMonitor] Notification auth error: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func childName(for device: ChildDevice) -> String {
        appState.childProfiles.first { $0.id == device.childProfileID }?.name ?? "Unknown"
    }

    private func sendTamperNotification(device: ChildDevice, heartbeat: DeviceHeartbeat) {
        let content = UNMutableNotificationContent()
        let name = childName(for: device)

        content.title = "Possible Tampering"
        content.body = "\(name)'s \(device.displayName) — Screen Time permissions were revoked."
        content.sound = .defaultCritical
        content.interruptionLevel = .critical
        content.threadIdentifier = "device-monitor"

        let request = UNNotificationRequest(
            identifier: "tamper-\(device.id.rawValue)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            #if DEBUG
            if let error {
                print("[DeviceMonitor] Failed to post tamper notification: \(error.localizedDescription)")
            }
            #endif
        }
    }

    /// Send a local notification, but only if at least `throttleHours` have
    /// elapsed since the last notification with the same `id`.
    private func sendThrottledNotification(id: String, title: String, body: String, throttleHours: Int) {
        let now = Date()
        if let last = lastNotificationTimes[id],
           now.timeIntervalSince(last) < Double(throttleHours) * 3600 {
            return
        }
        lastNotificationTimes[id] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "device-monitor"

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            #if DEBUG
            if let error {
                print("[DeviceMonitor] Failed to post \(id) notification: \(error.localizedDescription)")
            }
            #endif
        }
    }

    /// Format a duration in seconds as a human-readable string for push
    /// notifications: "45m", "2h 15m", "3d 4h". Previously the offline
    /// notification reported raw minutes ("3009 minutes") which is
    /// unreadable for anything past an hour or so. Caps at the biggest
    /// meaningful unit + one level of detail — no one needs
    /// "3d 4h 12m 35s."
    static func humanReadableDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400
        let hoursRemainder = (total % 86400) / 3600
        let hours = total / 3600
        let minutesRemainder = (total % 3600) / 60
        let minutes = total / 60
        if days > 0 {
            return hoursRemainder > 0 ? "\(days)d \(hoursRemainder)h" : "\(days)d"
        }
        if hours > 0 {
            return minutesRemainder > 0 ? "\(hours)h \(minutesRemainder)m" : "\(hours)h"
        }
        return "\(max(1, minutes))m"
    }
}
