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

        // Fetch breadcrumbs from CloudKit — last 48h for trip debugging
        if let cloudKit = appState.cloudKit {
            let since = Date().addingTimeInterval(-48 * 3600)
            if let crumbs = try? await cloudKit.fetchLocationBreadcrumbs(deviceID: deviceID, since: since) {
                let sorted = crumbs.sorted { $0.timestamp < $1.timestamp }
                let recent = sorted.suffix(40)
                var prevLoc: CLLocation?
                let timeFmt = DateFormatter()
                timeFmt.dateFormat = "h:mm:ss a"
                for (i, c) in recent.enumerated() {
                    let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    let dist = prevLoc.map { loc.distance(from: $0) } ?? 0
                    let interval = prevLoc != nil && i > 0
                        ? c.timestamp.timeIntervalSince(recent[recent.index(recent.startIndex, offsetBy: i - 1)].timestamp)
                        : 0
                    // Compute speed from distance/time between consecutive breadcrumbs
                    let computedSpeedStr: String
                    if interval > 0 && dist > 10 {
                        let mph = (dist / interval) * 2.237
                        computedSpeedStr = "calc=\(Int(mph))mph"
                    } else {
                        computedSpeedStr = "calc=0"
                    }
                    let speedStr = c.speed.map { $0 >= 0 ? "\(String(format: "%.0f", $0 * 2.237))mph" : "invalid" } ?? "nil"
                    flags["breadcrumb_\(String(format: "%02d", i))"] =
                        "\(timeFmt.string(from: c.timestamp)) | \(String(format: "%.4f,%.4f", c.latitude, c.longitude)) | speed=\(speedStr) | \(computedSpeedStr) | dist=\(Int(dist))m | gap=\(Int(interval))s | acc=\(Int(c.horizontalAccuracy))m"
                    prevLoc = loc
                }
                flags["breadcrumbCount48h"] = "\(sorted.count)"

                // Detect and summarize recent trips (movement segments)
                var tripNum = 0
                var tripStart: Date?
                var tripDist: Double = 0
                var prevTripLoc: CLLocation?
                let tripThreshold: Double = 150 // meters between breadcrumbs = movement
                for c in sorted {
                    let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    if let prev = prevTripLoc {
                        let d = loc.distance(from: prev)
                        if d >= tripThreshold {
                            if tripStart == nil { tripStart = prev.timestamp }
                            tripDist += d
                        } else if tripStart != nil {
                            // Trip ended — log summary
                            let dur = c.timestamp.timeIntervalSince(tripStart!)
                            let avgMPH = dur > 0 ? (tripDist / dur) * 2.237 : 0
                            let dayFmt = DateFormatter()
                            dayFmt.dateFormat = "MMM d h:mm a"
                            flags["trip_\(String(format: "%02d", tripNum))"] =
                                "\(dayFmt.string(from: tripStart!)) → \(dayFmt.string(from: c.timestamp)) | \(String(format: "%.1f", tripDist / 1609))mi | avg \(Int(avgMPH))mph | \(Int(dur / 60))min"
                            tripNum += 1
                            tripStart = nil
                            tripDist = 0
                        }
                    }
                    prevTripLoc = loc
                }
                // Close any open trip
                if let start = tripStart, let last = sorted.last {
                    let dur = last.timestamp.timeIntervalSince(start)
                    let avgMPH = dur > 0 ? (tripDist / dur) * 2.237 : 0
                    let dayFmt = DateFormatter()
                    dayFmt.dateFormat = "MMM d h:mm a"
                    flags["trip_\(String(format: "%02d", tripNum))"] =
                        "\(dayFmt.string(from: start)) → \(dayFmt.string(from: last.timestamp)) | \(String(format: "%.1f", tripDist / 1609))mi | avg \(Int(avgMPH))mph | \(Int(dur / 60))min (ongoing?)"
                }
            }
        }

        // Recent diagnostic log entries (last 200)
        let allLogs = storage.readDiagnosticEntries(category: nil)
        let recentLogs = Array(allLogs.suffix(200))

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
