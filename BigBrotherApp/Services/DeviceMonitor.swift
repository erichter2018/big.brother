import Foundation
import UserNotifications
import BigBrotherCore

/// Monitors child device heartbeats on the parent device and fires local
/// notifications when a device goes offline (stops sending heartbeats) or
/// when a previously-offline device comes back online.
///
/// **Runs only on the parent device.**
///
/// Uses an **escalating probe** strategy to avoid false alarms from sleeping
/// iOS devices:
///   1. Heartbeat gap exceeded → send ping #1, no alert.
///   2. Still no response next cycle → ping #2.
///   3. Still nothing → ping #3 (final attempt).
///   4. Still nothing → fire offline notification.
///
/// Smart patience: if last heartbeat showed low battery, skip probing and
/// just note "likely dead." FamilyControls revocation alerts immediately.
@MainActor
final class DeviceMonitor {

    // MARK: - Configuration

    /// How often to check device status (seconds).
    private static let checkIntervalSeconds: TimeInterval = 60

    /// How often to auto-refresh dashboard data (seconds).
    private static let dashboardRefreshIntervalSeconds: TimeInterval = 120

    /// Fallback max heartbeat gap when no profile exists (2 hours).
    private static let fallbackMaxGap: TimeInterval = 7200

    /// Number of pings to send before declaring a device truly offline.
    private static let maxPingAttempts = 3

    // MARK: - State

    private let appState: AppState

    /// Timer that fires the heartbeat-freshness check.
    private var checkTimer: Timer?

    /// Timer that periodically refreshes dashboard data from CloudKit.
    private var refreshTimer: Timer?

    /// Tracks devices that currently have an active offline notification.
    /// Prevents re-nagging — one notification per offline transition.
    private var notifiedOfflineDevices: Set<String> = []

    /// Tracks how many pings have been sent to each device while it appears
    /// offline. Once this reaches `maxPingAttempts`, the device is declared
    /// truly offline. Reset when a heartbeat arrives.
    private var pingCounts: [String: Int] = [:]

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        requestNotificationPermission()

        // Periodic heartbeat-freshness check.
        checkTimer = Timer.scheduledTimer(
            withTimeInterval: Self.checkIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkDeviceStatus()
            }
        }

        // Periodic dashboard refresh so heartbeat data stays current.
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.dashboardRefreshIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
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
        notifiedOfflineDevices.removeAll()
        pingCounts.removeAll()

        #if DEBUG
        print("[DeviceMonitor] Stopped monitoring")
        #endif
    }

    // MARK: - Core Logic

    private func checkDeviceStatus() {
        let now = Date()

        for device in appState.childDevices {
            let key = device.id.rawValue
            let heartbeat = appState.latestHeartbeats.first { $0.deviceID == device.id }
            let profile = resolveProfile(for: device)

            // ALWAYS alert immediately for FamilyControls revocation.
            if let hb = heartbeat, !hb.familyControlsAuthorized {
                if !notifiedOfflineDevices.contains(key) {
                    notifiedOfflineDevices.insert(key)
                    pingCounts.removeValue(forKey: key)
                    sendOfflineNotification(device: device, heartbeat: heartbeat)
                }
                continue
            }

            // Determine if we're in an active monitoring window.
            let inActiveWindow: Bool
            if let profile {
                inActiveWindow = profile.isInActiveWindow(at: now)
            } else {
                inActiveWindow = true
            }

            // Determine if the device is overdue based on check mode.
            let isOverdue: Bool
            let checkMode = profile?.effectiveCheckMode(at: now) ?? .gap(Self.fallbackMaxGap)

            switch checkMode {
            case .gap(let maxGap):
                let threshold = now.addingTimeInterval(-maxGap)
                isOverdue = heartbeat == nil || heartbeat!.timestamp < threshold

            case .oncePerDay:
                if let windowStart = profile?.windowStart(at: now) {
                    isOverdue = heartbeat == nil || heartbeat!.timestamp < windowStart
                } else {
                    let threshold = now.addingTimeInterval(-Self.fallbackMaxGap)
                    isOverdue = heartbeat == nil || heartbeat!.timestamp < threshold
                }
            }

            if isOverdue && inActiveWindow {
                handleOverdueDevice(
                    device: device,
                    heartbeat: heartbeat,
                    checkMode: checkMode,
                    key: key
                )
            } else if !isOverdue {
                // Device checked in — clear all probe/offline state.
                if pingCounts[key] != nil {
                    pingCounts.removeValue(forKey: key)
                    #if DEBUG
                    print("[DeviceMonitor] \(device.displayName) responded to ping — clearing probe state")
                    #endif
                }
                if notifiedOfflineDevices.contains(key) {
                    notifiedOfflineDevices.remove(key)
                    sendOnlineNotification(device: device)
                    #if DEBUG
                    print("[DeviceMonitor] \(device.displayName) is back online")
                    #endif
                }
            } else if !inActiveWindow && (notifiedOfflineDevices.contains(key) || pingCounts[key] != nil) {
                // Left active window — clear everything.
                pingCounts.removeValue(forKey: key)
                notifiedOfflineDevices.remove(key)
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: ["offline-\(key)"]
                )
                #if DEBUG
                print("[DeviceMonitor] \(device.displayName) left active window — clearing alert")
                #endif
            }
        }
    }

    /// Handle a device that has exceeded its heartbeat threshold.
    /// Uses escalating probes and smart patience based on last known state.
    private func handleOverdueDevice(
        device: ChildDevice,
        heartbeat: DeviceHeartbeat?,
        checkMode: HeartbeatCheckMode,
        key: String
    ) {
        // Already notified — nothing more to do.
        guard !notifiedOfflineDevices.contains(key) else { return }

        // Smart patience: if battery was very low, skip probing entirely.
        // The device almost certainly died — alert immediately but non-urgently.
        if let hb = heartbeat, let battery = hb.batteryLevel, battery < 0.1, hb.isCharging != true {
            notifiedOfflineDevices.insert(key)
            pingCounts.removeValue(forKey: key)
            sendOfflineNotification(device: device, heartbeat: heartbeat)
            #if DEBUG
            print("[DeviceMonitor] \(device.displayName) had \(Int(battery * 100))% battery — likely dead, alerting without probing")
            #endif
            return
        }

        let currentPings = pingCounts[key] ?? 0

        if currentPings >= Self.maxPingAttempts {
            // Exhausted all probe attempts — truly offline.
            notifiedOfflineDevices.insert(key)
            pingCounts.removeValue(forKey: key)
            sendOfflineNotification(device: device, heartbeat: heartbeat)

            #if DEBUG
            let modeDesc: String = {
                switch checkMode {
                case .gap(let g): return "gap > \(Int(g / 60))min"
                case .oncePerDay: return "no heartbeat today"
                }
            }()
            print("[DeviceMonitor] \(device.displayName) is offline after \(Self.maxPingAttempts) pings (\(modeDesc))")
            #endif
        } else {
            // Send another ping and increment counter.
            pingCounts[key] = currentPings + 1
            sendPing(device: device)

            #if DEBUG
            print("[DeviceMonitor] \(device.displayName) overdue — ping \(currentPings + 1)/\(Self.maxPingAttempts)")
            #endif
        }
    }

    /// Resolve the HeartbeatProfile for a device:
    /// 1. Use the device's assigned profile if present.
    /// 2. Fall back to the family default profile.
    /// 3. Return nil if neither exists (caller uses hardcoded fallback).
    private func resolveProfile(for device: ChildDevice) -> HeartbeatProfile? {
        if let profileID = device.heartbeatProfileID,
           let profile = appState.heartbeatProfiles.first(where: { $0.id == profileID }) {
            return profile
        }
        return appState.heartbeatProfiles.first(where: { $0.isDefault })
    }

    // MARK: - Active Probing

    /// Send a requestHeartbeat command to wake a sleeping device via CloudKit
    /// push notification.
    private func sendPing(device: ChildDevice) {
        Task {
            do {
                try await appState.sendCommand(
                    target: .device(device.id),
                    action: .requestHeartbeat
                )
            } catch {
                #if DEBUG
                print("[DeviceMonitor] Failed to ping \(device.displayName): \(error.localizedDescription)")
                #endif
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

    private func sendOfflineNotification(device: ChildDevice, heartbeat: DeviceHeartbeat?) {
        let content = UNMutableNotificationContent()
        let name = childName(for: device)

        let reason = offlineReason(heartbeat: heartbeat)
        content.title = reason.title
        content.body = "\(name)'s \(device.displayName) — \(reason.body)"

        content.sound = reason.isSuspicious ? .defaultCritical : .default
        content.interruptionLevel = reason.isSuspicious ? .critical : .timeSensitive
        content.threadIdentifier = "device-monitor"

        let request = UNNotificationRequest(
            identifier: "offline-\(device.id.rawValue)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            #if DEBUG
            if let error {
                print("[DeviceMonitor] Failed to post offline notification: \(error.localizedDescription)")
            }
            #endif
        }
    }

    private func sendOnlineNotification(device: ChildDevice) {
        // Remove the offline notification from Notification Center.
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["offline-\(device.id.rawValue)"]
        )

        let content = UNMutableNotificationContent()
        let name = childName(for: device)

        content.title = "Device Back Online"
        content.body = "\(name)'s \(device.displayName) is checking in again."
        content.sound = .default
        content.threadIdentifier = "device-monitor"

        let request = UNNotificationRequest(
            identifier: "online-\(device.id.rawValue)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            #if DEBUG
            if let error {
                print("[DeviceMonitor] Failed to post online notification: \(error.localizedDescription)")
            }
            #endif
        }
    }

    // MARK: - Offline Reason Analysis

    private struct OfflineReason {
        let title: String
        let body: String
        let isSuspicious: Bool
    }

    /// Analyze the last known heartbeat to determine the most likely reason
    /// the device went offline.
    private func offlineReason(heartbeat: DeviceHeartbeat?) -> OfflineReason {
        guard let hb = heartbeat else {
            return OfflineReason(
                title: "Device Never Connected",
                body: "Has never checked in. The app may not be installed or running.",
                isSuspicious: true
            )
        }

        let ago = formattedTimeSince(hb.timestamp)

        // Low battery — likely died
        if let battery = hb.batteryLevel, battery < 0.1, hb.isCharging != true {
            return OfflineReason(
                title: "Device Likely Out of Battery",
                body: "Last seen \(ago) ago with \(Int(battery * 100))% battery. Probably powered off.",
                isSuspicious: false
            )
        }

        // FamilyControls was revoked in last heartbeat — settings tampering
        if hb.familyControlsAuthorized == false {
            return OfflineReason(
                title: "Possible Tampering",
                body: "Last seen \(ago) ago. Screen Time permissions were revoked before going offline.",
                isSuspicious: true
            )
        }

        // Good battery, authorized, just vanished — suspicious (app deleted?)
        if let battery = hb.batteryLevel, battery > 0.2 {
            return OfflineReason(
                title: "Device Went Silent",
                body: "Last seen \(ago) ago with \(Int(battery * 100))% battery. Did not respond to \(Self.maxPingAttempts) wake attempts.",
                isSuspicious: true
            )
        }

        // Default — can't determine cause
        return OfflineReason(
            title: "Device Offline",
            body: "Last seen \(ago) ago. Did not respond to \(Self.maxPingAttempts) wake attempts.",
            isSuspicious: false
        )
    }

    // MARK: - Helpers

    private func formattedTimeSince(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "\(hours)h \(remainingMinutes)m"
    }
}
