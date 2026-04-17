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
        appState: AppState,
        includeBreadcrumbs: Bool = false
    ) async -> DiagnosticReport {
        let storage = AppGroupStorage()
        let keychain = KeychainManager()
        let defaults = UserDefaults.appGroup

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
            "apnsTokenRegisteredAt", "apnsTokenError", "lastPushReceivedAt",
            "shieldResolvedName", "shieldResolvedToken", "shieldResolvedAt",
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
        if let lat = defaults?.object(forKey: AppGroupKeys.homeLatitude) as? Double,
           let lon = defaults?.object(forKey: AppGroupKeys.homeLongitude) as? Double {
            flags["homeGeofence"] = "\(lat),\(lon)"
        } else {
            flags["homeGeofence"] = "not set"
        }

        // Named places count
        if let data = defaults?.data(forKey: AppGroupKeys.namedPlaces),
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
        // Skipped by default (takes 15+ min) — only included for full reports.
        if includeBreadcrumbs, let cloudKit = appState.cloudKit {
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

                // Detect and summarize recent trips (movement segments).
                // Uses breadcrumb timestamps (not CLLocation.timestamp which is creation time).
                var tripNum = 0
                var tripStartTime: Date?
                var tripDist: Double = 0
                var prevTripCrumb: (loc: CLLocation, time: Date)?
                let tripThreshold: Double = 150 // meters between breadcrumbs = movement
                let dayFmt = DateFormatter()
                dayFmt.dateFormat = "MMM d h:mm a"
                for c in sorted {
                    let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    if let prev = prevTripCrumb {
                        let d = loc.distance(from: prev.loc)
                        if d >= tripThreshold {
                            if tripStartTime == nil { tripStartTime = prev.time }
                            tripDist += d
                        } else if tripStartTime != nil {
                            // Trip ended
                            let dur = c.timestamp.timeIntervalSince(tripStartTime!)
                            let avgMPH = dur > 0 ? (tripDist / dur) * 2.237 : 0
                            flags["trip_\(String(format: "%02d", tripNum))"] =
                                "\(dayFmt.string(from: tripStartTime!)) → \(dayFmt.string(from: c.timestamp)) | \(String(format: "%.1f", tripDist / 1609))mi | avg \(Int(avgMPH))mph | \(Int(dur / 60))min"
                            tripNum += 1
                            tripStartTime = nil
                            tripDist = 0
                        }
                    }
                    prevTripCrumb = (loc: loc, time: c.timestamp)
                }
                // Close any open trip
                if let start = tripStartTime, let last = sorted.last {
                    let dur = last.timestamp.timeIntervalSince(start)
                    let avgMPH = dur > 0 ? (tripDist / dur) * 2.237 : 0
                    flags["trip_\(String(format: "%02d", tripNum))"] =
                        "\(dayFmt.string(from: start)) → \(dayFmt.string(from: last.timestamp)) | \(String(format: "%.1f", tripDist / 1609))mi | avg \(Int(avgMPH))mph | \(Int(dur / 60))min (ongoing?)"
                }
            }
        }

        // === MODE STACK RESOLUTION (source of truth) ===
        let modeResolution = ModeStackResolver.resolve(storage: storage)
        flags["modeStack.expectedMode"] = modeResolution.mode.rawValue
        flags["modeStack.reason"] = modeResolution.reason
        flags["modeStack.isTemporary"] = "\(modeResolution.isTemporary)"
        if let exp = modeResolution.expiresAt {
            flags["modeStack.expiresAt"] = "\(exp)"
        }

        // === MODE MISMATCH DETECTION ===
        let actualShieldsActive = shieldDiag?.shieldsActive ?? false
        let shouldBeShielded = modeResolution.mode != .unlocked
        if shouldBeShielded != actualShieldsActive {
            flags["⚠️ MISMATCH"] = "Expected shields \(shouldBeShielded ? "UP" : "DOWN") but they are \(actualShieldsActive ? "UP" : "DOWN")"
        }

        // === TEMPORARY UNLOCK STATE ===
        let tempUnlock = storage.readTemporaryUnlockState()
        if let temp = tempUnlock {
            flags["tempUnlock.origin"] = temp.origin.rawValue
            flags["tempUnlock.previousMode"] = temp.previousMode.rawValue
            flags["tempUnlock.expiresAt"] = "\(temp.expiresAt)"
            flags["tempUnlock.isExpired"] = "\(temp.isExpired(at: Date()))"
            flags["tempUnlock.commandID"] = temp.commandID?.uuidString.prefix(8).description ?? "nil"
            let remaining = temp.expiresAt.timeIntervalSince(Date())
            flags["tempUnlock.remainingSeconds"] = "\(Int(remaining))"
        }

        // === TIMED UNLOCK STATE ===
        if let timed = storage.readTimedUnlockInfo() {
            flags["timedUnlock.commandID"] = timed.commandID.uuidString.prefix(8).description
            flags["timedUnlock.unlockAt"] = "\(timed.unlockAt)"
            flags["timedUnlock.lockAt"] = "\(timed.lockAt)"
            let now = Date()
            if now < timed.unlockAt {
                flags["timedUnlock.phase"] = "penalty (locks at \(timed.unlockAt))"
            } else if now < timed.lockAt {
                flags["timedUnlock.phase"] = "free (locks at \(timed.lockAt))"
            } else {
                flags["timedUnlock.phase"] = "EXPIRED (should have locked at \(timed.lockAt))"
            }
        }

        // === POLICY SNAPSHOT METADATA ===
        if let snap = snapshot {
            flags["snapshot.generation"] = "\(snap.generation)"
            flags["snapshot.source"] = snap.source.rawValue
            flags["snapshot.trigger"] = snap.trigger ?? "nil"
            flags["snapshot.createdAt"] = "\(snap.createdAt)"
            flags["snapshot.appliedAt"] = snap.appliedAt.map { "\($0)" } ?? "never"
            flags["snapshot.resolvedMode"] = snap.effectivePolicy.resolvedMode.rawValue
            flags["snapshot.isTemporaryUnlock"] = "\(snap.effectivePolicy.isTemporaryUnlock)"
            flags["snapshot.policyVersion"] = "\(snap.effectivePolicy.policyVersion)"
            flags["snapshot.writerVersion"] = "b\(snap.writerVersion)"
        }

        // === EXTENSION SHARED STATE ===
        let extState = storage.readExtensionSharedState()
        if let ext = extState {
            flags["extState.currentMode"] = ext.currentMode.rawValue
            flags["extState.isTemporaryUnlock"] = "\(ext.isTemporaryUnlock)"
            flags["extState.writtenAt"] = "\(ext.writtenAt)"
            flags["extState.policyVersion"] = "\(ext.policyVersion)"
            flags["extState.authAvailable"] = "\(ext.authorizationAvailable)"
            flags["extState.degraded"] = "\(ext.enforcementDegraded)"
            // Check freshness vs snapshot
            if let snap = snapshot, ext.policyVersion < snap.effectivePolicy.policyVersion {
                flags["⚠️ STALE_EXT_STATE"] = "Extension v\(ext.policyVersion) < snapshot v\(snap.effectivePolicy.policyVersion)"
            }
        }

        // === PROCESSED COMMANDS ===
        let processedIDs = storage.readProcessedCommandIDs()
        flags["processedCommandCount"] = "\(processedIDs.count)"

        // === TUNNEL LIVENESS ===
        flags["mainAppAlive"] = defaults?.bool(forKey: "mainAppAlive") == true ? "true" : "false"
        let tunnelBuild = defaults?.integer(forKey: AppGroupKeys.tunnelBuildNumber) ?? 0
        if tunnelBuild > 0 {
            flags["tunnelBuildNumber"] = "b\(tunnelBuild)"
            if tunnelBuild != AppConstants.appBuildNumber {
                flags["⚠️ BUILD_MISMATCH"] = "App=b\(AppConstants.appBuildNumber) Tunnel=b\(tunnelBuild)"
            }
        }

        // === AUTO-DIAGNOSIS ===
        var diagnosis: [String] = []
        if shouldBeShielded != actualShieldsActive {
            diagnosis.append("SHIELDS MISMATCH: Expected \(shouldBeShielded ? "UP" : "DOWN"), actual \(actualShieldsActive ? "UP" : "DOWN")")
            if let temp = tempUnlock, temp.isExpired(at: Date()) {
                diagnosis.append("  → Temp unlock expired \(Int(-temp.expiresAt.timeIntervalSinceNow))s ago but state not cleared")
            }
            if extState?.currentMode == .unlocked && modeResolution.mode != .unlocked {
                diagnosis.append("  → ExtensionSharedState is stale (says unlocked, should be \(modeResolution.mode.rawValue))")
            }
            if snapshot?.effectivePolicy.resolvedMode == .unlocked && modeResolution.mode != .unlocked {
                diagnosis.append("  → PolicySnapshot is stale (says unlocked, should be \(modeResolution.mode.rawValue))")
            }
        }
        if !diagnosis.isEmpty {
            flags["🔍 DIAGNOSIS"] = diagnosis.joined(separator: " | ")
        }

        // Device restrictions — show what the child device has locally
        let restrictions = storage.readDeviceRestrictions()
        if let r = restrictions {
            flags["restrictions.denyAppRemoval"] = "\(r.denyAppRemoval)"
            flags["restrictions.denyExplicitContent"] = "\(r.denyExplicitContent)"
            flags["restrictions.lockAccounts"] = "\(r.lockAccounts)"
            flags["restrictions.requireAutoDateTime"] = "\(r.requireAutomaticDateAndTime)"
            flags["restrictions.denyWebWhenRestricted"] = "\(r.denyWebWhenRestricted)"
        } else {
            flags["restrictions"] = "nil (using defaults)"
        }

        // Schedule profile — show what the child device has locally vs resolved state
        if let profile = storage.readActiveScheduleProfile() {
            flags["schedule.name"] = profile.name
            flags["schedule.id"] = profile.id.uuidString.prefix(8).description
            flags["schedule.lockedMode"] = profile.lockedMode.rawValue
            flags["schedule.updatedAt"] = "\(profile.updatedAt)"
            let now = Date()
            flags["schedule.resolvedMode"] = profile.resolvedMode(at: now).rawValue
            flags["schedule.inUnlockedWindow"] = "\(profile.isInUnlockedWindow(at: now))"
            flags["schedule.inLockedWindow"] = "\(profile.isInLockedWindow(at: now))"
            flags["schedule.isExceptionDate"] = "\(profile.isExceptionDate(now))"
            // Show all unlocked windows with their days/times
            for (i, w) in profile.unlockedWindows.enumerated() {
                let days = w.daysOfWeek.sorted { $0.rawValue < $1.rawValue }.map { $0.shortName }.joined(separator: ",")
                flags["schedule.unlocked_\(i)"] = "\(days) \(w.startTime.hour):\(String(format: "%02d", w.startTime.minute))-\(w.endTime.hour):\(String(format: "%02d", w.endTime.minute))"
            }
            for (i, w) in profile.lockedWindows.enumerated() {
                let days = w.daysOfWeek.sorted { $0.rawValue < $1.rawValue }.map { $0.shortName }.joined(separator: ",")
                flags["schedule.locked_\(i)"] = "\(days) \(w.startTime.hour):\(String(format: "%02d", w.startTime.minute))-\(w.endTime.hour):\(String(format: "%02d", w.endTime.minute))"
            }
        } else {
            flags["schedule"] = "none assigned"
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
            familyControlsAuth: {
                let status = authStatus?.rawValue ?? "unknown"
                let authType = UserDefaults.appGroup?.string(forKey: AppGroupKeys.authorizationType) ?? "unknown"
                return "\(status) (\(authType))"
            }(),
            currentMode: snapshot?.effectivePolicy.resolvedMode.rawValue ?? "unknown",
            shieldsActive: shieldDiag?.shieldsActive ?? false,
            shieldedAppCount: shieldDiag?.appCount ?? 0,
            shieldCategoryActive: shieldDiag?.categoryActive ?? false,
            lastShieldChangeReason: defaults?.string(forKey: AppGroupKeys.lastShieldChangeReason),
            flags: flags,
            recentLogs: recentLogs
        )
    }
}
