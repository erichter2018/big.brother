import Foundation
import CloudKit
import CoreMotion
import UserNotifications
import BigBrotherCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ManagedSettings)
import ManagedSettings
#endif

/// Concrete heartbeat service for child devices.
///
/// Periodically sends DeviceHeartbeat records to CloudKit using an upsert pattern
/// (one record per device, updated in place). Uses HeartbeatStatus for backoff
/// on failure and deduplication of recent sends.
final class HeartbeatServiceImpl: HeartbeatServiceProtocol {

    private let cloudKit: any CloudKitServiceProtocol
    private let keychain: any KeychainProtocol
    private let storage: any SharedStorageProtocol
    private let enforcement: (any EnforcementServiceProtocol)?

    private var timer: Timer?
    private var extensionCheckTimer: Timer?
    private let interval: TimeInterval

    /// Called after a successful heartbeat send — piggyback command processing
    /// since the device is clearly online.
    var onHeartbeatSent: (() -> Void)?

    /// Event logger for creating new-app-detected events.
    var eventLogger: (any EventLoggerProtocol)?

    /// Called when the main app positively acknowledges an extension liveness
    /// request or otherwise proves it is responsive again.
    var onLivenessConfirmed: (() -> Void)?

    /// Optional location service — reads cached location for heartbeat inclusion.
    var locationService: LocationService?

    /// VPN manager — ping the tunnel every 30s to prove we're alive.
    var vpnManager: VPNManagerService?

    /// Monotonically increasing sequence number for this app launch.
    /// Persisted across heartbeats within a session; resets on app relaunch.
    private var seqCounter: Int64 = 0

    /// When the last heartbeat was successfully sent (in-memory, for movement-based frequency).
    private var lastSendAt: Date?

    init(
        cloudKit: any CloudKitServiceProtocol,
        keychain: any KeychainProtocol = KeychainManager(),
        storage: any SharedStorageProtocol = AppGroupStorage(),
        enforcement: (any EnforcementServiceProtocol)?,
        interval: TimeInterval = AppConstants.heartbeatIntervalSeconds
    ) {
        self.cloudKit = cloudKit
        self.keychain = keychain
        self.storage = storage
        self.enforcement = enforcement
        self.interval = interval

        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }

    // MARK: - HeartbeatServiceProtocol

    /// Heartbeat interval when the device is moving (more frequent for better tracking).
    private static let movingHeartbeatInterval: TimeInterval = 60

    func startHeartbeat() {
        stopHeartbeat()
        let hbTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                try? await self.sendNow(force: self.acknowledgeExtensionHeartbeatRequest())
            }
        }
        RunLoop.main.add(hbTimer, forMode: .common)
        timer = hbTimer
        // Check every 30s for extension-requested heartbeats, movement-based sends,
        // and ping the VPN tunnel to prove liveness.
        let extTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Write liveness timestamp for the VPN tunnel to read.
            let liveDefaults = UserDefaults.appGroup
            liveDefaults?.set(Date().timeIntervalSince1970, forKey: "mainAppLastActiveAt")
            // Refresh lock state timestamp so tunnel knows the value is fresh.
            liveDefaults?.set(Date().timeIntervalSince1970, forKey: "isDeviceLockedAt")

            // Ping the VPN tunnel (IPC liveness signal).
            self.vpnManager?.sendPing()

            if let vpn = self.vpnManager {
                Task { await vpn.restartIfNeeded() }
            }

            // Extension heartbeat request.
            if self.acknowledgeExtensionHeartbeatRequest() {
                Task { try? await self.sendNow(force: true) }
                return
            }
            // While moving, send heartbeats more frequently (every ~60s).
            if self.locationService?.isMoving == true {
                let sinceLastSend = Date().timeIntervalSince(self.lastSendAt ?? .distantPast)
                if sinceLastSend >= Self.movingHeartbeatInterval {
                    Task { try? await self.sendNow(force: false) }
                }
            }
        }
        RunLoop.main.add(extTimer, forMode: .common)
        extensionCheckTimer = extTimer
        // Fire immediately on start.
        Task { try? await sendNow(force: false) }
    }

    func stopHeartbeat() {
        timer?.invalidate()
        timer = nil
        extensionCheckTimer?.invalidate()
        extensionCheckTimer = nil
    }

    /// Check if the Monitor extension requested a heartbeat via App Group flag.
    /// Positively acknowledge the current request token to prove liveness.
    /// Returns true only for recent requests (< 5 min) to trigger a forced heartbeat send.
    private func acknowledgeExtensionHeartbeatRequest() -> Bool {
        let defaults = UserDefaults.appGroup
        let requestToken = defaults?.string(forKey: "extensionHeartbeatRequestToken")
        guard let requestToken, !requestToken.isEmpty else { return false }

        let ackToken = defaults?.string(forKey: "extensionHeartbeatAcknowledgedToken")
        let requestedAt = defaults?.double(forKey: "extensionHeartbeatRequestedAt") ?? 0
        let justAcknowledged = ackToken != requestToken
        if justAcknowledged {
            defaults?.set(requestToken, forKey: "extensionHeartbeatAcknowledgedToken")
            defaults?.set(Date().timeIntervalSince1970, forKey: "extensionHeartbeatAcknowledgedAt")
            onLivenessConfirmed?()
        }

        guard requestedAt > 0 else { return false }
        let age = Date().timeIntervalSince1970 - requestedAt

        // Only trigger a forced heartbeat send for recent requests.
        guard age < 300 else {
            #if DEBUG
            if justAcknowledged {
                print("[BigBrother] Extension heartbeat request acknowledged (stale: \(Int(age))s old)")
            }
            #endif
            return false
        }
        #if DEBUG
        print("[BigBrother] Extension requested heartbeat \(Int(age))s ago — sending")
        #endif
        return justAcknowledged
    }

    func sendNow(force: Bool = false) async throws {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        // Check backoff and dedup via HeartbeatStatus (skip if forced).
        let status = storage.readHeartbeatStatus() ?? .initial

        if !force {
            guard status.shouldRetry(
                baseInterval: AppConstants.heartbeatRetryBaseSeconds
            ) else { return }

            guard !status.wasRecentlySent(
                within: AppConstants.heartbeatRecentWindow
            ) else { return }
        }

        // Record attempt.
        let attemptStatus = status.recordingAttempt()
        try? storage.writeHeartbeatStatus(attemptStatus)

        let snapshot = storage.readPolicySnapshot()
        // Determine current mode from multiple sources, in priority order:
        // 1. ExtensionSharedState (Monitor writes this on schedule transitions)
        // 2. PolicySnapshot (ground truth after command processing)
        // Determine currentMode from ACTUAL device state.
        // The heartbeat must report what the device IS doing, not what it SHOULD be doing.
        // The ground truth is ManagedSettingsStore — if shields are on, the device is locked.
        // If shields are off, the device is unlocked, period.
        let currentMode: LockMode
        #if canImport(ManagedSettings)
        if let enforcement = enforcement {
            let diagnostic = enforcement.shieldDiagnostic()
            if !diagnostic.shieldsActive {
                // Shields are off — device is actually unlocked
                currentMode = .unlocked
            } else {
                // Shields are on — determine which locked mode.
                // Prefer ExtensionSharedState (Monitor's last enforcement action),
                // then PolicySnapshot, as label for which type of lock is active.
                let extState = storage.readExtensionSharedState()
                if let ext = extState, ext.currentMode != .unlocked {
                    currentMode = ext.currentMode
                } else if let snap = snapshot, snap.effectivePolicy.resolvedMode != .unlocked {
                    currentMode = snap.effectivePolicy.resolvedMode
                } else {
                    // Shields are on but no state says which mode — safe default
                    currentMode = .restricted
                }
            }
        } else {
            // No enforcement service (shouldn't happen on child) — fall back to state files
            let extState = storage.readExtensionSharedState()
            if let ext = extState, ext.writtenAt > (snapshot?.createdAt ?? .distantPast) {
                currentMode = ext.currentMode
            } else if let snap = snapshot {
                currentMode = snap.effectivePolicy.resolvedMode
            } else {
                currentMode = .unlocked
            }
        }
        #else
        // Non-child builds (parent) — use state files
        let extState = storage.readExtensionSharedState()
        if let ext = extState, ext.writtenAt > (snapshot?.createdAt ?? .distantPast) {
            currentMode = ext.currentMode
        } else if let snap = snapshot {
            currentMode = snap.effectivePolicy.resolvedMode
        } else {
            currentMode = .unlocked
        }
        #endif
        let policyVersion = snapshot?.effectivePolicy.policyVersion ?? 0
        let tempUnlockState: TemporaryUnlockState? = {
            // Only report if the device is actually unlocked.
            // The TemporaryUnlockState file may linger after a lock command.
            guard currentMode == .unlocked,
                  let state = storage.readTemporaryUnlockState(),
                  state.expiresAt > Date() else { return nil }
            return state
        }()
        let tempUnlockExpiry = tempUnlockState?.expiresAt

        let blockingConfig = storage.readAppBlockingConfig()
        let cachedAppNames = Self.discoveredAppNames(from: storage)
        let allowedNames = Self.resolvedAllowedAppNames(from: storage)
        let allowedTokenCount = Self.rawAllowedAppTokenCount(from: storage)
        let tempAllowedNames = Self.resolvedTemporaryAllowedAppNames(from: storage)

        let selfUnlocksUsed: Int? = {
            guard let state = storage.readSelfUnlockState() else { return nil }
            let today = SelfUnlockState.todayDateString()
            if state.date != today {
                // Persist the reset so other readers see the updated state.
                let reset = state.resettingIfNeeded(currentDate: today)
                try? storage.writeSelfUnlockState(reset)
                return 0
            }
            return state.usedCount
        }()

        seqCounter += 1
        let ckStatus = await Self.cloudKitAccountStatus()

        // Refresh location on each heartbeat so data stays reasonably fresh
        // even if device hasn't moved enough for a significant-change event.
        locationService?.refreshLocation()
        let loc = locationService?.lastLocation
        let locAddress = locationService?.lastAddress

        // Shield diagnostic: read actual ManagedSettingsStore state
        let shieldsActive: Bool?
        let shieldedAppCount: Int?
        let shieldCategoryActive: Bool?
        let webBlockingActive: Bool?
        let denyAppRemovalActive: Bool?
        #if canImport(ManagedSettings)
        if let enforcement = enforcement {
            let diagnostic = enforcement.shieldDiagnostic()
            shieldsActive = diagnostic.shieldsActive
            shieldedAppCount = diagnostic.appCount
            shieldCategoryActive = diagnostic.categoryActive
            webBlockingActive = diagnostic.webBlockingActive
            denyAppRemovalActive = diagnostic.denyAppRemoval
        } else {
            shieldsActive = nil
            shieldedAppCount = nil
            shieldCategoryActive = nil
            webBlockingActive = nil
            denyAppRemovalActive = nil
        }
        #else
        shieldsActive = nil
        shieldedAppCount = nil
        shieldCategoryActive = nil
        webBlockingActive = nil
        denyAppRemovalActive = nil
        #endif

        // Persist shield state so the tunnel can check it without ManagedSettings access.
        // Used to decide: if shields are up, don't DNS-block even if app is dead.
        // Companion timestamp marks freshness so the tunnel can suppress stale
        // "shields down" reports during mode transitions.
        if let shieldsActive {
            let shieldDefaults = UserDefaults.appGroup
            shieldDefaults?.set(shieldsActive, forKey: "shieldsActiveAtLastHeartbeat")
            shieldDefaults?.set(Date().timeIntervalSince1970, forKey: "shieldsActiveAtLastHeartbeatAt")
        }

        // Schedule diagnostic — report what the child's LOCAL schedule says right now.
        // If this disagrees with the parent's schedule, the child has stale data.
        let scheduleResolvedMode: String?
        if let profile = storage.readActiveScheduleProfile() {
            let now = Date()
            let mode = profile.resolvedMode(at: now)
            let inFree = profile.isInUnlockedWindow(at: now)
            let inEssential = profile.isInLockedWindow(at: now)
            // Include diagnostic detail: mode + why
            let detail: String
            if inFree {
                detail = "\(mode.rawValue) (in unlocked window)"
            } else if inEssential {
                detail = "\(mode.rawValue) (in locked window)"
            } else {
                let ewCount = profile.lockedWindows.count
                let ewDays = profile.lockedWindows.first?.daysOfWeek.map(\.displayName).sorted().joined(separator: ",") ?? "none"
                let ewStart = profile.lockedWindows.first.map { "\($0.startTime.hour):\(String(format: "%02d", $0.startTime.minute))" } ?? "?"
                let ewEnd = profile.lockedWindows.first.map { "\($0.endTime.hour):\(String(format: "%02d", $0.endTime.minute))" } ?? "?"
                detail = "\(mode.rawValue) (lw:\(ewCount) days:\(ewDays) \(ewStart)-\(ewEnd))"
            }
            scheduleResolvedMode = detail
        } else {
            scheduleResolvedMode = nil
        }

        // Last shield change reason
        let lastShieldChangeReason = UserDefaults.appGroup?
            .string(forKey: "lastShieldChangeReason")
        let exhaustedAppState = Self.currentExhaustedAppState(from: storage)

        let heartbeat = DeviceHeartbeat(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            currentMode: currentMode,
            policyVersion: policyVersion,
            familyControlsAuthorized: enforcement?.authorizationStatus == .authorized,
            familyControlsAuthType: UserDefaults.appGroup?.string(forKey: "fr.bigbrother.authorizationType"),
            childAuthFailReason: UserDefaults.appGroup?.string(forKey: "fr.bigbrother.childAuthFailReason"),
            permissionDetails: UserDefaults.appGroup?.string(forKey: "permissionSnapshot"),
            batteryLevel: Self.batteryLevel,
            isCharging: Self.isCharging,
            appBlockingConfigured: blockingConfig?.isConfigured,
            blockedCategoryCount: blockingConfig?.blockedCategoryCount,
            blockedAppCount: cachedAppNames.isEmpty ? blockingConfig?.allowedAppCount : cachedAppNames.count,
            blockedAppNames: cachedAppNames.isEmpty
                ? (blockingConfig?.blockedAppNames.isEmpty == false ? blockingConfig?.blockedAppNames : nil)
                : cachedAppNames,
            blockedCategoryNames: blockingConfig?.blockedCategoryNames.isEmpty == false ? blockingConfig?.blockedCategoryNames : nil,
            installID: enrollment.installID,
            heartbeatSeq: seqCounter,
            cloudKitStatus: ckStatus,
            allowedAppNames: allowedNames.isEmpty ? nil : allowedNames,
            allowedAppCount: allowedTokenCount > 0 ? allowedTokenCount : nil,
            temporaryAllowedAppNames: tempAllowedNames.isEmpty ? nil : tempAllowedNames,
            temporaryUnlockExpiresAt: tempUnlockExpiry,
            isChildAuthorization: UserDefaults.standard.string(forKey: "fr.bigbrother.authorizationType") == "child",
            availableDiskSpace: Self.availableDiskSpace,
            totalDiskSpace: Self.totalDiskSpace,
            selfUnlocksUsedToday: selfUnlocksUsed,
            temporaryUnlockOrigin: tempUnlockState?.origin,
            osVersion: Self.currentOSVersion,
            modelIdentifier: Self.currentModelIdentifier,
            appBuildNumber: AppConstants.appBuildNumber,
            mainAppLastLaunchedBuild: AppConstants.appBuildNumber,
            enforcementError: Self.lastEnforcementError(from: storage),
            activeScheduleWindowName: Self.activeScheduleWindowName(from: storage),
            lastCommandProcessedAt: Self.lastCommandProcessedAt(from: storage),
            monitorLastActiveAt: Self.monitorLastActiveAt(),
            vpnDetected: VPNDetector.isVPNActive(),
            internetBlocked: UserDefaults.appGroup?
                .bool(forKey: "tunnelInternetBlocked") == true ? true : nil,
            internetBlockedReason: {
                let r = UserDefaults.appGroup?
                    .string(forKey: "tunnelInternetBlockedReason")
                return (r?.isEmpty == false) ? r : nil
            }(),
            dnsBlockedDomainCount: {
                let count = storage.readEnforcementBlockedDomains().count
                    + storage.readTimeLimitBlockedDomains().count
                return count > 0 ? count : nil
            }(),
            appUsageMinutes: {
                guard let snapshot = storage.readAppUsageSnapshot() else { return nil }
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                guard snapshot.dateString == f.string(from: Date()) else { return nil }
                return snapshot.usageByFingerprint.isEmpty ? nil : snapshot.usageByFingerprint
            }(),
            exhaustedAppFingerprints: exhaustedAppState.fingerprints,
            exhaustedAppBundleIDs: exhaustedAppState.bundleIDs,
            exhaustedAppNames: exhaustedAppState.names,
            timeZoneIdentifier: TimeZone.current.identifier,
            timeZoneOffsetSeconds: TimeZone.current.secondsFromGMT(),
            screenTimeMinutes: Self.currentScreenTimeMinutes(from: storage),
            screenUnlockCount: UserDefaults.appGroup?.integer(forKey: "screenUnlockCount"),
            hasSigningKeys: Self.hasSigningKeys(keychain: keychain),
            jailbreakDetected: JailbreakDetector.isJailbroken(),
            jailbreakReason: JailbreakDetector.detectedReason(),
            isDriving: locationService?.drivingMonitor?.isDriving == true ? true : nil,
            currentSpeed: locationService?.lastLocation?.speed,
            heartbeatSource: "mainApp",
            buildType: Self.currentBuildType,
            tunnelConnected: vpnManager?.isConnected,
            motionAuthorized: CMMotionActivityManager.authorizationStatus() == .authorized,
            notificationsAuthorized: Self.notificationsAuthorized(),
            isDeviceLocked: DeviceLockMonitor.shared.isDeviceLocked,
            shieldsActive: shieldsActive,
            scheduleResolvedMode: scheduleResolvedMode,
            lastShieldChangeReason: lastShieldChangeReason,
            shieldedAppCount: shieldedAppCount,
            shieldCategoryActive: shieldCategoryActive,
            latitude: loc?.coordinate.latitude,
            longitude: loc?.coordinate.longitude,
            locationTimestamp: loc?.timestamp,
            locationAddress: locAddress,
            locationAccuracy: loc?.horizontalAccuracy,
            locationAuthorization: locationService?.authorizationStatusString,
            monitorBuildNumber: {
                let b = UserDefaults.appGroup?.integer(forKey: "monitorBuildNumber") ?? 0
                return b > 0 ? b : nil
            }(),
            shieldBuildNumber: {
                let b = UserDefaults.appGroup?.integer(forKey: "shieldBuildNumber") ?? 0
                return b > 0 ? b : nil
            }(),
            shieldActionBuildNumber: {
                let b = UserDefaults.appGroup?.integer(forKey: "shieldActionBuildNumber") ?? 0
                return b > 0 ? b : nil
            }(),
            fcAuthDegraded: UserDefaults.appGroup?.bool(forKey: "fcAuthDegraded") == true ? true : nil,
            ghostShieldsDetected: {
                // Ghost shield = OS shielded an app our policy said should be allowed.
                // Detected by ShieldConfiguration extension; written to App Group with
                // a recent timestamp. Auto-expire after 24h so a one-time fluke doesn't
                // pollute every heartbeat thereafter — but persistent issues keep firing
                // and stay surfaced.
                //
                // b436 (audit fix): Bound age >= 0 to handle clock skew or
                // corrupt future timestamps. Without this, a future timestamp
                // would produce negative age which is < 86400 and would keep
                // the flag true indefinitely.
                let defaults = UserDefaults.appGroup
                let lastSeen = defaults?.double(forKey: "ghostShieldsDetectedAt") ?? 0
                guard lastSeen > 0 else { return nil }
                let age = Date().timeIntervalSince1970 - lastSeen
                return (age >= 0 && age < 86400) ? true : nil
            }(),
            diagnosticSnapshot: Self.buildDiagnosticSnapshot(
                storage: storage,
                enforcement: enforcement,
                shieldsActive: shieldsActive,
                currentMode: currentMode,
                webBlockingActive: webBlockingActive,
                denyAppRemovalActive: denyAppRemovalActive
            )
        )

        do {
            try await cloudKit.sendHeartbeat(heartbeat)

            let successStatus = attemptStatus.recordingSuccess()
            try? storage.writeHeartbeatStatus(successStatus)

            // Record successful heartbeat timestamp so the Monitor can distinguish
            // between a truly force-closed app and one merely suspended by iOS.
            lastSendAt = Date()
            UserDefaults.appGroup?
                .set(Date().timeIntervalSince1970, forKey: "lastHeartbeatSentAt")

            // Update device record with current OS version + model if changed.
            await updateDeviceRecordIfNeeded(enrollment: enrollment)

            // Safety net: reconcile enforcement on every successful heartbeat.
            reconcileEnforcement()

            // Check for new app activity detected by the VPN tunnel.
            flushNewAppDetections()

            // Process commands — device is online if heartbeat succeeded.
            onHeartbeatSent?()
        } catch {
            let failureStatus = attemptStatus.recordingFailure(reason: error.localizedDescription)
            try? storage.writeHeartbeatStatus(failureStatus)

            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .heartbeat,
                message: "Heartbeat send failed",
                details: "Consecutive failures: \(failureStatus.consecutiveFailures), reason: \(error.localizedDescription)"
            ))
            throw error
        }
    }

    // MARK: - Enforcement Reconciliation

    /// Re-apply enforcement as a safety net after each heartbeat.
    /// Uses ModeStackResolver to compute the correct mode from the stack files,
    /// then applies it if shields don't match. This is idempotent — if the Monitor
    /// already applied the correct state, this is a no-op.
    ///
    /// See `AppState.verifyAndFixEnforcement` for the full discussion of the
    /// THREE overlapping reconcile paths and why they haven't been unified.
    /// TL;DR: this is the post-heartbeat pass, `verifyAndFixEnforcement` is the
    /// 60s safety-net timer, and `forceDaemonRescue` is the foreground-wake
    /// daemon rescue. All three must stay consistent in the policy-construction
    /// logic; ideally they share a helper eventually.
    private func reconcileEnforcement() {
        guard let enforcement else { return }
        let resolution = ModeStackResolver.resolve(storage: storage)
        guard let snapshot = storage.readPolicySnapshot() else { return }

        // Check if shields match the resolved mode
        let diagnostic = enforcement.shieldDiagnostic()
        let shouldBeShielded = resolution.mode != .unlocked
        let isShielded = diagnostic.shieldsActive

        // Also check if the snapshot's mode diverged from ModeStackResolver.
        // This happens when a temp unlock expired while the app was dead —
        // ModeStackResolver cleaned the temp state but nobody updated the snapshot.
        let snapshotMode = snapshot.effectivePolicy.resolvedMode
        let snapshotStale = snapshotMode != resolution.mode

        if shouldBeShielded != isShielded || snapshotStale {
            // Build a corrected policy with the right mode from ModeStackResolver.
            //
            // b459: ModeStackResolver.Resolution.isTemporary is true for
            // BOTH "mode=unlocked via temp unlock" AND "mode=restricted
            // via lockUntil/timedUnlock penalty". EffectivePolicy.isTemporaryUnlock
            // must only be true in the first case — it's specifically
            // "the mode is unlocked because a temp unlock is overriding
            // the base mode". Copying `resolution.isTemporary` blindly
            // meant that lockUntil-mode snapshots had `isTemporaryUnlock=true`
            // while `resolvedMode=.restricted`, and downstream readers
            // cleared shields on a locked device.
            let effectivelyTempUnlock = resolution.isTemporary && resolution.mode == .unlocked
            let policyToApply: EffectivePolicy
            if snapshotStale {
                let existing = snapshot.effectivePolicy
                let corrected = EffectivePolicy(
                    resolvedMode: resolution.mode,
                    controlAuthority: resolution.controlAuthority,
                    isTemporaryUnlock: effectivelyTempUnlock,
                    temporaryUnlockExpiresAt: effectivelyTempUnlock ? resolution.expiresAt : nil,
                    shieldedCategoriesData: existing.shieldedCategoriesData,
                    allowedAppTokensData: existing.allowedAppTokensData,
                    warnings: existing.warnings,
                    policyVersion: existing.policyVersion + 1
                )
                // Update the snapshot so future reads are correct
                let correctedSnapshot = PolicySnapshot(
                    source: .restoration,
                    trigger: "Heartbeat reconciliation: snapshot stale (\(snapshotMode.rawValue) → \(resolution.mode.rawValue))",
                    effectivePolicy: corrected
                )
                _ = try? storage.commitCorrectedSnapshot(correctedSnapshot)
                policyToApply = corrected
            } else {
                policyToApply = snapshot.effectivePolicy
            }

            try? enforcement.apply(policyToApply)

            #if DEBUG
            print("[BigBrother] Heartbeat reconciliation: shields were \(isShielded ? "up" : "DOWN"), should be \(shouldBeShielded ? "up" : "down") (mode: \(resolution.mode.rawValue), reason: \(resolution.reason), snapshotStale: \(snapshotStale))")
            #endif

            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "Heartbeat reconciled shields",
                details: "Mode: \(resolution.mode.rawValue), reason: \(resolution.reason)\(snapshotStale ? " [snapshot corrected from \(snapshotMode.rawValue)]" : "")"
            ))
        }
    }

    // MARK: - New App Detection

    /// Flush pending new-app detections written by the VPN tunnel's DNS proxy.
    ///
    /// b461: compare-and-swap the pending list instead of read → process →
    /// remove. The tunnel (DNSProxy.recordDomain on bgQueue) appends to the
    /// same UserDefaults key; the old read/remove pattern had a lost-write
    /// race where the tunnel's append could land after our read but before
    /// our remove, silently dropping the new app from the pending list.
    /// We now read-then-overwrite with only the items we actually processed
    /// removed from the list — entries appended after our read are
    /// preserved for the next flush.
    ///
    /// Additional cross-app-process dedup at the event-log level: only log
    /// a newAppDetected event if we haven't logged one for this app within
    /// the last 6 hours. The notification layer also dedups semantically,
    /// but logging sparingly keeps the activity feed cleaner too.
    private func flushNewAppDetections() {
        let defaults = UserDefaults.appGroup
        guard let pending = defaults?.stringArray(forKey: "newAppDetections"),
              !pending.isEmpty else { return }

        // Snapshot what we're about to process; anything the tunnel
        // appends after this read stays in the list for the next flush.
        let processing = pending
        let uniqueNames = Set(processing).sorted()

        // Load the per-app flush-dedup map: appName → last-logged-epoch.
        var logged = (defaults?.dictionary(forKey: "newAppLastLoggedAt") as? [String: Double]) ?? [:]
        let now = Date().timeIntervalSince1970
        let logWindow: TimeInterval = 6 * 3600
        // Expire stale entries.
        logged = logged.filter { now - $0.value < logWindow }

        var freshlyLogged: [String] = []
        for appName in uniqueNames {
            if let last = logged[appName], now - last < logWindow {
                #if DEBUG
                print("[BigBrother] Skipping duplicate newAppDetected for \(appName) (last logged \(Int(now - last))s ago)")
                #endif
                continue
            }
            logged[appName] = now
            eventLogger?.log(.newAppDetected, details: "New app activity: \(appName)")
            freshlyLogged.append(appName)
        }

        // Cap map at 500 entries to bound growth.
        if logged.count > 500 {
            logged = Dictionary(uniqueKeysWithValues: logged.sorted { $0.value > $1.value }.prefix(500).map { ($0.key, $0.value) })
        }
        defaults?.set(logged, forKey: "newAppLastLoggedAt")

        // Compare-and-swap: re-read the pending list (it may have grown
        // while we were processing) and write back only the entries we
        // didn't process. Subtractive overwrite preserves late appends.
        let afterFlush = (defaults?.stringArray(forKey: "newAppDetections") ?? [])
            .filter { !processing.contains($0) }
        if afterFlush.isEmpty {
            defaults?.removeObject(forKey: "newAppDetections")
        } else {
            defaults?.set(afterFlush, forKey: "newAppDetections")
        }

        #if DEBUG
        print("[BigBrother] Flushed \(freshlyLogged.count) new app detections (logged: \(freshlyLogged.joined(separator: ", "))), \(uniqueNames.count - freshlyLogged.count) suppressed as duplicates")
        #endif
    }

    // MARK: - Device Info

    private static var batteryLevel: Double? {
        #if canImport(UIKit)
        let level = UIDevice.current.batteryLevel
        // UIDevice.batteryLevel rounds to 5% increments.
        // Return nil if monitoring isn't available (-1.0).
        guard level >= 0 else { return nil }
        return Double(level)
        #else
        return nil
        #endif
    }

    private static var isCharging: Bool? {
        #if canImport(UIKit)
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        return nil
        #endif
    }

    private static var availableDiskSpace: Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return bytes
    }

    private static var totalDiskSpace: Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let bytes = values.volumeTotalCapacity else {
            return nil
        }
        return Int64(bytes)
    }

    private static var currentOSVersion: String { DeviceInfo.osVersion }
    private static var currentModelIdentifier: String { DeviceInfo.modelIdentifier }

    private static func cloudKitAccountStatus() async -> String {
        do {
            let status = try await CKContainer.default().accountStatus()
            switch status {
            case .available: return "available"
            case .noAccount: return "noAccount"
            case .restricted: return "restricted"
            case .couldNotDetermine: return "couldNotDetermine"
            case .temporarilyUnavailable: return "temporarilyUnavailable"
            @unknown default: return "unknown"
            }
        } catch {
            return "error"
        }
    }

    /// Resolve names for permanently allowed apps using the name cache.
    /// Raw count of permanently allowed app tokens (no name resolution needed).
    private static func rawAllowedAppTokenCount(from storage: any SharedStorageProtocol) -> Int {
        #if canImport(ManagedSettings)
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
            return tokens.count
        }
        #endif
        return 0
    }

    /// Resolve names for allowed apps. Uses cached names when available,
    /// falls back to "App N" placeholders so the count is always accurate.
    private static func resolvedAllowedAppNames(from storage: any SharedStorageProtocol) -> [String] {
        let cache = storage.readAllCachedAppNames()
        var names: [String] = []

        #if canImport(ManagedSettings)
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
            var index = 1
            for token in tokens {
                var resolved: String?
                if let tokenData = try? JSONEncoder().encode(token) {
                    let key = tokenData.base64EncodedString()
                    if let name = cache[key], isUsefulAppName(name) {
                        resolved = name
                    }
                }
                names.append(resolved ?? "App \(index)")
                index += 1
            }
        }
        #endif

        return names.sorted()
    }

    /// Resolve names for temporarily allowed apps (non-expired).
    private static func resolvedTemporaryAllowedAppNames(from storage: any SharedStorageProtocol) -> [String] {
        let entries = storage.readTemporaryAllowedApps()
        let cache = storage.readAllCachedAppNames()
        return entries.filter(\.isValid).compactMap { entry -> String? in
            let key = entry.tokenData.base64EncodedString()
            if let cachedName = cache[key], isUsefulAppName(cachedName) {
                return cachedName
            }
            return isUsefulAppName(entry.appName) ? entry.appName : nil
        }.sorted()
    }

    private static func discoveredAppNames(from storage: any SharedStorageProtocol) -> [String] {
        let names = storage.readAllCachedAppNames().values
            .filter(isUsefulAppName(_:))
        let unique = Set(names)
        return unique.sorted()
    }

    /// Update the BBChildDevice record in CloudKit with current OS version and model
    /// if they've changed since enrollment (or last update).
    /// Only touches osVersion and modelIdentifier — does NOT use saveDevice() to avoid
    /// overwriting parent-set fields (scheduleProfileID, penaltySeconds, etc.).
    private func updateDeviceRecordIfNeeded(enrollment: ChildEnrollmentState) async {
        let osVersion = Self.currentOSVersion
        let model = Self.currentModelIdentifier
        let key = "lastReportedDeviceInfo"
        let defaults = UserDefaults.appGroup ?? .standard
        let lastReported = defaults.string(forKey: key)
        let current = "\(osVersion)|\(model)"
        guard lastReported != current else { return }

        do {
            try await cloudKit.updateDeviceFields(
                deviceID: enrollment.deviceID,
                fields: [
                    CKFieldName.osVersion: osVersion as CKRecordValue,
                    CKFieldName.modelIdentifier: model as CKRecordValue
                ]
            )
            defaults.set(current, forKey: key)
            #if DEBUG
            print("[BigBrother] Updated device record: iOS \(osVersion), model \(model)")
            #endif
        } catch {
            #if DEBUG
            print("[BigBrother] Failed to update device record: \(error.localizedDescription)")
            #endif
        }
    }

    /// Build a structured DiagnosticSnapshot and JSON-encode it for the heartbeat.
    /// Machine-parseable on the parent side for rich UI rendering.
    private static func buildDiagnosticSnapshot(
        storage: any SharedStorageProtocol,
        enforcement: (any EnforcementServiceProtocol)? = nil,
        shieldsActive: Bool?,
        currentMode: LockMode,
        webBlockingActive: Bool? = nil,
        denyAppRemovalActive: Bool? = nil
    ) -> String {
        let defaults = UserDefaults.appGroup
        let now = Date()

        // Mode stack
        let resolution = ModeStackResolver.resolve(storage: storage)

        // Shield state
        let shields = shieldsActive ?? false
        let expected = resolution.mode != .unlocked

        // Component builds
        let builds = DiagnosticSnapshot.ComponentBuilds(
            app: AppConstants.appBuildNumber,
            tunnel: defaults?.integer(forKey: "tunnelBuildNumber") ?? 0,
            monitor: defaults?.integer(forKey: "monitorBuildNumber") ?? 0,
            shield: defaults?.integer(forKey: "shieldBuildNumber") ?? 0,
            shieldAction: defaults?.integer(forKey: "shieldActionBuildNumber") ?? 0
        )

        // Monitor / tunnel age
        let monitorAt = defaults?.double(forKey: "monitorLastActiveAt") ?? 0
        let monitorAge = monitorAt > 0 ? Int(now.timeIntervalSince1970 - monitorAt) : nil
        let tunnelAt = defaults?.double(forKey: "tunnelLastActiveAt") ?? 0
        let tunnelAge = tunnelAt > 0 ? Int(now.timeIntervalSince1970 - tunnelAt) : nil

        // Schedule info
        let profile = storage.readActiveScheduleProfile()
        let scheduleDriven = AppConstants.isScheduleDriven(defaults: defaults)
        let scheduleWindow: String? = {
            guard let p = profile else { return nil }
            let cal = Calendar.current
            if p.isInUnlockedWindow(at: now, calendar: cal) {
                return "unlocked window"
            } else if p.isInLockedWindow(at: now, calendar: cal) {
                return "locked window"
            }
            return "default (\(p.lockedMode.rawValue))"
        }()

        // Temp unlock
        let temp = storage.readTemporaryUnlockState()
        let tempRemaining: Int? = {
            guard let t = temp, t.expiresAt > now else { return nil }
            return Int(t.expiresAt.timeIntervalSince(now))
        }()

        // Restrictions
        let restrictions = storage.readDeviceRestrictions()

        // Transitions — last 10 from snapshot history, enriched with shield state
        let history = storage.readSnapshotHistory()
        let recentTransitions = history.suffix(10).map { t in
            DiagnosticSnapshot.TransitionEntry(
                at: t.timestamp,
                from: t.fromMode.rawValue,
                to: t.toMode.rawValue,
                source: t.source.rawValue,
                authority: t.source.rawValue,
                shieldsUp: nil,  // historical — not tracked per-transition yet
                changes: t.changes
            )
        }

        // Recent enforcement + command logs — last 30, merged by time.
        // Filter out noisy entries (location, reconciliation registration) to keep
        // substantive enforcement actions and command processing visible.
        let enfLogs = storage.readDiagnosticEntries(category: .enforcement)
        let cmdLogs = storage.readDiagnosticEntries(category: .command)
        let noisePatterns = ["[Location]", "Reconciliation registration starting", "Reconciliation registered OK"]
        let filtered = (enfLogs + cmdLogs).filter { entry in
            !noisePatterns.contains(where: { entry.message.contains($0) })
        }
        let merged = filtered.sorted { $0.timestamp < $1.timestamp }
        let recentLogs = merged.suffix(30).map { entry in
            DiagnosticSnapshot.LogEntry(
                at: entry.timestamp,
                msg: "[\(entry.category.rawValue.prefix(3))] \(String(entry.message.prefix(110)))"
            )
        }

        // Push delivery diagnostics — critical for debugging slow command delivery.
        let nowEpoch = Date().timeIntervalSince1970
        let lastPushAge: Int? = {
            let ts = defaults?.double(forKey: "lastPushReceivedAt") ?? 0
            return ts > 0 ? Int(nowEpoch - ts) : nil
        }()
        let apnsTokenAge: Int? = {
            let ts = defaults?.double(forKey: "apnsTokenRegisteredAt") ?? 0
            return ts > 0 ? Int(nowEpoch - ts) : nil
        }()

        let snapshot = DiagnosticSnapshot(
            mode: resolution.mode.rawValue,
            authority: resolution.controlAuthority.rawValue,
            reason: resolution.reason,
            isTemporary: resolution.isTemporary,
            expiresAt: resolution.expiresAt,
            shieldsUp: shields,
            shieldsExpected: expected,
            shieldedAppCount: defaults?.integer(forKey: "shieldedAppCount") ?? 0,
            categoryShieldActive: shields && expected,
            webBlocked: webBlockingActive ?? false,
            shieldReason: defaults?.string(forKey: "lastShieldChangeReason"),
            shieldAudit: defaults?.string(forKey: "lastShieldAudit"),
            builds: builds,
            monitorAge: monitorAge,
            tunnelAge: tunnelAge,
            tunnelConnected: defaults?.bool(forKey: "tunnelConnected"),
            lastPushAge: lastPushAge,
            apnsTokenAge: apnsTokenAge,
            scheduleName: profile?.name,
            scheduleDriven: scheduleDriven,
            scheduleWindow: scheduleWindow,
            tempUnlockRemaining: tempRemaining,
            tempUnlockOrigin: temp?.origin.rawValue,
            denyWebWhenRestricted: restrictions?.denyWebWhenRestricted,
            denyAppRemoval: denyAppRemovalActive ?? restrictions?.denyAppRemoval,
            internetBlocked: defaults?.bool(forKey: "tunnelInternetBlocked") == true ? true : nil,
            internetBlockReason: {
                let r = defaults?.string(forKey: "tunnelInternetBlockedReason")
                return (r?.isEmpty == false) ? r : nil
            }(),
            dnsBlockedDomains: {
                let count = (storage.readEnforcementBlockedDomains().count)
                    + (storage.readTimeLimitBlockedDomains().count)
                return count > 0 ? count : nil
            }(),
            transitions: recentTransitions,
            recentLogs: recentLogs,
            applyStartedAt: {
                let ts = defaults?.double(forKey: "enforcementApplyStartedAt") ?? 0
                return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
            }(),
            applyFinishedAt: {
                let ts = defaults?.double(forKey: "enforcementApplyFinishedAt") ?? 0
                return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
            }(),
            tokenVerdicts: enforcement?.computeTokenVerdicts(for: resolution.mode) ?? [],
            telemetry: TunnelTelemetry.load()
        )

        // JSON-encode — compact, no pretty print (saves ~30% space)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(snapshot),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        // Fallback to legacy string if encoding fails
        return "mode: \(resolution.mode.rawValue) (\(resolution.reason))"
    }

    private static func lastEnforcementError(from storage: any SharedStorageProtocol) -> String? {
        let entries = storage.readDiagnosticEntries(category: .enforcement)
        guard let last = entries.last else { return nil }
        let isFailed = last.message.contains("failed") || last.message.contains("Failed")
        return isFailed ? last.message : nil
    }

    private static func activeScheduleWindowName(from storage: any SharedStorageProtocol) -> String? {
        guard let profile = storage.readActiveScheduleProfile() else { return nil }
        let now = Date()
        let cal = Calendar.current
        if profile.isInUnlockedWindow(at: now, calendar: cal) {
            // Find matching window and format its time range.
            let weekday = cal.component(.weekday, from: now)
            guard let today = DayOfWeek(rawValue: weekday) else { return "Unlocked" }
            let hour = cal.component(.hour, from: now)
            let minute = cal.component(.minute, from: now)
            let nowTime = DayTime(hour: hour, minute: minute)
            for window in profile.unlockedWindows where window.daysOfWeek.contains(today) {
                if nowTime >= window.startTime && nowTime < window.endTime {
                    return "\(profile.name) unlocked window"
                }
            }
            return "Unlocked"
        }
        return nil
    }

    private static func lastCommandProcessedAt(from storage: any SharedStorageProtocol) -> Date? {
        let defaults = UserDefaults.appGroup ?? .standard
        let timestamp = defaults.double(forKey: "fr.bigbrother.lastCommandProcessedAt")
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    private static func monitorLastActiveAt() -> Date? {
        let defaults = UserDefaults.appGroup ?? .standard
        let timestamp = defaults.double(forKey: "monitorLastActiveAt")
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    /// Check notification permission synchronously via cached value.
    /// Updated each heartbeat cycle.
    private static let _notifAuthLock = NSLock()
    private static var _notifAuthBacking: Bool?
    private static func notificationsAuthorized() -> Bool? {
        // Async check runs in background, caches result for next heartbeat
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            _notifAuthLock.withLock {
                _notifAuthBacking = settings.authorizationStatus == .authorized
            }
        }
        _notifAuthLock.lock()
        defer { _notifAuthLock.unlock() }
        return _notifAuthBacking
    }

    private static func hasSigningKeys(keychain: any KeychainProtocol) -> Bool {
        guard let data = try? keychain.getData(forKey: StorageKeys.commandSigningPublicKey) else { return false }
        if let keys = try? JSONDecoder().decode([String].self, from: data) { return !keys.isEmpty }
        return data.count >= 32
    }

    private static func currentScreenTimeMinutes(from storage: any SharedStorageProtocol) -> Int? {
        // Signal tunnel to flush any in-progress session before we read.
        let defaults = UserDefaults.appGroup ?? .standard
        defaults.set(Date().timeIntervalSince1970, forKey: "tunnelFlushRequestedAt")

        let today = SelfUnlockState.todayDateString()
        guard defaults.string(forKey: "screenTimeDate") == today else { return nil }
        return defaults.integer(forKey: "screenTimeMinutes")
    }

    private static func currentExhaustedAppState(
        from storage: any SharedStorageProtocol
    ) -> (fingerprints: [String]?, bundleIDs: [String]?, names: [String]?) {
        let today = SelfUnlockState.todayDateString()
        let exhausted = storage.readTimeLimitExhaustedApps().filter { $0.dateString == today }
        guard !exhausted.isEmpty else { return (nil, nil, nil) }

        let limitsByFingerprint = Dictionary(
            uniqueKeysWithValues: storage.readAppTimeLimits().map { ($0.fingerprint, $0) }
        )

        var fingerprints = Set<String>()
        var bundleIDs = Set<String>()
        var names = Set<String>()

        for entry in exhausted {
            fingerprints.insert(entry.fingerprint)
            if let bundleID = limitsByFingerprint[entry.fingerprint]?.bundleID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleID.isEmpty {
                bundleIDs.insert(bundleID.lowercased())
            }
            let name = (limitsByFingerprint[entry.fingerprint]?.appName ?? entry.appName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsefulAppName(name) {
                names.insert(name)
            }
        }

        return (
            fingerprints: fingerprints.isEmpty ? nil : Array(fingerprints).sorted(),
            bundleIDs: bundleIDs.isEmpty ? nil : Array(bundleIDs).sorted(),
            names: names.isEmpty ? nil : Array(names).sorted()
        )
    }

    /// Detect build type: debug, testflight, or appstore.
    static var currentBuildType: String {
        #if DEBUG
        return "debug"
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return "testflight"
        }
        return "appstore"
        #endif
    }

    private static func isUsefulAppName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.hasPrefix("blocked app ") &&
            !normalized.contains("token(") &&
            !normalized.contains("data:") &&
            !normalized.contains("bytes)")
    }
}
