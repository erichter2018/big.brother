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
    private var checkTimer: Timer?

    /// Timer that periodically refreshes dashboard data from CloudKit.
    private var refreshTimer: Timer?

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
        let chkTimer = Timer(timeInterval: Self.checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDeviceStatus()
            }
        }
        RunLoop.main.add(chkTimer, forMode: .common)
        checkTimer = chkTimer

        // Periodic dashboard refresh so heartbeat data stays current.
        let refTimer = Timer(timeInterval: Self.dashboardRefreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
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
        RunLoop.main.add(refTimer, forMode: .common)
        refreshTimer = refTimer

        // Run an initial check right now.
        checkDeviceStatus()

        #if DEBUG
        print("[DeviceMonitor] Started monitoring \(appState.childDevices.count) devices")
        #endif
    }

    func stopMonitoring() {
        checkTimer?.invalidate()
        checkTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
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

            // --- VPN Detection ---
            let vpnAckKey = "vpnAcknowledged.\(device.id.rawValue)"
            if let hb = heartbeat, hb.vpnDetected == true {
                if !UserDefaults.standard.bool(forKey: vpnAckKey) {
                    let name = childName(for: device)
                    sendThrottledNotification(
                        id: "vpn-\(key)",
                        title: "VPN Detected",
                        body: "\(name)'s \(device.displayName) has an active VPN connection. This may block Big Brother.",
                        throttleHours: 6
                    )
                }
            } else {
                UserDefaults.standard.removeObject(forKey: vpnAckKey)
            }

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

            // --- Location Authorization Detection (iPhone only) ---
            if let hb = heartbeat, device.modelIdentifier.hasPrefix("iPhone") {
                let childProfileID = device.childProfileID
                let locMode = UserDefaults.standard.string(forKey: "locationMode.\(childProfileID.rawValue)")
                let isLocationExpected = locMode != nil && locMode != "off"
                let isOnline = Date().timeIntervalSince(hb.timestamp) < AppConstants.onlineThresholdSeconds
                if isLocationExpected && isOnline {
                    let locAuth = hb.locationAuthorization
                    if locAuth == "denied" || locAuth == "restricted" {
                        let name = childName(for: device)
                        sendThrottledNotification(
                            id: "loc-disabled-\(key)",
                            title: "Location Disabled",
                            body: "\(name)'s \(device.displayName) has location permission \(locAuth ?? "unknown"). Change to Always in Settings.",
                            throttleHours: 24
                        )
                    } else if locAuth == "whenInUse" {
                        let name = childName(for: device)
                        sendThrottledNotification(
                            id: "loc-downgraded-\(key)",
                            title: "Location Not Set to Always",
                            body: "\(name)'s \(device.displayName) has location set to While Using App. Background tracking won't work.",
                            throttleHours: 24
                        )
                    }
                }
            }

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
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            #if DEBUG
            if let error {
                print("[DeviceMonitor] Notification auth error: \(error.localizedDescription)")
            } else {
                print("[DeviceMonitor] Notification permission granted: \(granted)")
            }
            #endif
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
}
