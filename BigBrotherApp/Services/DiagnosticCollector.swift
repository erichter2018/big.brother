import Foundation
import CoreLocation
import CoreMotion
import BigBrotherCore

/// Collects a comprehensive diagnostic report from the child device.
/// Called when the parent sends a `requestDiagnostics` command.
/// Gathers device state, enforcement status, location/motion config,
/// key flags, and recent diagnostic log entries.
enum DiagnosticCollector {

    @MainActor
    static func collect(
        appState: AppState
    ) async -> DiagnosticReport {
        let storage = AppGroupStorage()
        let keychain = KeychainManager()
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)

        // Enrollment
        let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        )
        let deviceID = enrollment?.deviceID ?? DeviceID(rawValue: "unknown")
        let familyID = enrollment?.familyID ?? FamilyID(rawValue: "unknown")

        // Location & Motion
        let locationService = appState.locationService
        let coreMotionAvailable = CMMotionActivityManager.isActivityAvailable()

        // Enforcement
        let shieldDiag = appState.enforcement?.shieldDiagnostic()
        let authStatus = appState.enforcement?.authorizationStatus

        // Policy snapshot
        let snapshot = PolicySnapshotStore(storage: storage).loadCurrentSnapshot()

        // VPN
        let vpnStatus: String
        if let vpn = appState.vpnManager {
            vpnStatus = vpn.isConnected ? "connected" : "disconnected"
        } else {
            vpnStatus = "not configured"
        }

        // Collect key flags from UserDefaults
        var flags: [String: String] = [:]
        let flagKeys = [
            "scheduleDrivenMode", "forceCloseWebBlocked", "forceCloseLastNagAt",
            "lastShieldChangeReason", "shieldedAppCount", "lastHeartbeatSentAt",
            "mainAppLastLaunchedBuild", "monitorLastActiveAt", "tunnelStatus",
            "tunnelLastActiveAt", "mainAppLastActiveAt", "locationTrackingMode",
            "extensionHeartbeatRequestToken", "extensionHeartbeatAcknowledgedToken",
            "extensionHeartbeatRequestedAt", "extensionHeartbeatAcknowledgedAt",
            "drivingSettings"
        ]
        for key in flagKeys {
            if let val = defaults?.object(forKey: key) {
                flags[key] = "\(val)"
            }
        }

        // Home geofence
        if let lat = defaults?.object(forKey: "homeLatitude") as? Double,
           let lon = defaults?.object(forKey: "homeLongitude") as? Double {
            flags["homeGeofence"] = "\(lat),\(lon)"
        } else {
            flags["homeGeofence"] = "not set"
        }

        // Named places count
        if let data = defaults?.data(forKey: "namedPlaces"),
           let places = try? JSONDecoder().decode([NamedPlace].self, from: data) {
            flags["namedPlacesCount"] = "\(places.count)"
        }

        // Location details
        if let loc = locationService?.lastLocation {
            flags["lastLocationSpeed"] = loc.speed >= 0 ? "\(String(format: "%.1f", loc.speed * 2.237)) mph" : "invalid"
            flags["lastLocationAge"] = "\(Int(Date().timeIntervalSince(loc.timestamp)))s ago"
            flags["lastLocationAccuracy"] = "\(Int(loc.horizontalAccuracy))m"
        } else {
            flags["lastLocation"] = "nil"
        }
        flags["activeTrackingStarted"] = locationService?.activeTrackingStartedAt != nil ? "yes" : "no"
        flags["breadcrumbInterval"] = "\(Int(locationService?.breadcrumbInterval ?? -1))s"
        flags["motionMonitoringActive"] = "\(locationService?.motionMonitoringActive ?? false)"

        // Fetch last 20 breadcrumbs from CloudKit for trip debugging
        if let cloudKit = appState.cloudKit {
            let since = Date().addingTimeInterval(-24 * 3600) // last 24h
            if let crumbs = try? await cloudKit.fetchLocationBreadcrumbs(deviceID: deviceID, since: since) {
                let recent = crumbs.sorted { $0.timestamp < $1.timestamp }.suffix(20)
                var prevLoc: CLLocation?
                let timeFmt = DateFormatter()
                timeFmt.dateFormat = "h:mm:ss a"
                for (i, c) in recent.enumerated() {
                    let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    let dist = prevLoc.map { loc.distance(from: $0) } ?? 0
                    let interval = prevLoc != nil && i > 0
                        ? c.timestamp.timeIntervalSince(recent[recent.index(recent.startIndex, offsetBy: i - 1)].timestamp)
                        : 0
                    let speedStr = c.speed.map { $0 >= 0 ? "\(String(format: "%.0f", $0 * 2.237))mph" : "invalid" } ?? "nil"
                    flags["breadcrumb_\(String(format: "%02d", i))"] =
                        "\(timeFmt.string(from: c.timestamp)) | \(String(format: "%.4f,%.4f", c.latitude, c.longitude)) | speed=\(speedStr) | dist=\(Int(dist))m | gap=\(Int(interval))s | acc=\(Int(c.horizontalAccuracy))m"
                    prevLoc = loc
                }
                flags["breadcrumbCount24h"] = "\(crumbs.count)"
            }
        }

        // Recent diagnostic log entries (last 50)
        let allLogs = storage.readDiagnosticEntries(category: nil)
        let recentLogs = Array(allLogs.suffix(50))

        return DiagnosticReport(
            deviceID: deviceID,
            familyID: familyID,
            appBuildNumber: AppConstants.appBuildNumber,
            deviceRole: appState.deviceRole.rawValue,
            locationMode: locationService?.mode.rawValue ?? "nil",
            coreMotionAvailable: coreMotionAvailable,
            coreMotionMonitoring: locationService?.motionMonitoringActive ?? false,
            isMoving: locationService?.isMoving ?? false,
            isDriving: appState.drivingMonitor?.isDriving ?? false,
            vpnTunnelStatus: vpnStatus,
            familyControlsAuth: authStatus?.rawValue ?? "unknown",
            currentMode: snapshot?.effectivePolicy.resolvedMode.rawValue ?? "unknown",
            shieldsActive: shieldDiag?.shieldsActive ?? false,
            shieldedAppCount: shieldDiag?.appCount ?? 0,
            shieldCategoryActive: shieldDiag?.categoryActive ?? false,
            lastShieldChangeReason: defaults?.string(forKey: "lastShieldChangeReason"),
            flags: flags,
            recentLogs: recentLogs
        )
    }
}
