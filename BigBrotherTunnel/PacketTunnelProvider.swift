import NetworkExtension
import CloudKit
import UserNotifications
import UIKit
import DeviceActivity
import notify
import BigBrotherCore

/// VPN Packet Tunnel extension.
///
/// Runs as a system-managed process that persists even when the main app
/// is force-closed. iOS keeps the tunnel alive via Connect On Demand rules
/// and restarts it after reboots and network changes.
///
/// Responsibilities:
/// - Send heartbeats to CloudKit when the main app is dead
/// - Detect main app death via IPC pings + App Group timestamps
/// - Provide persistent background execution for parental monitoring
///
/// Phase 1: No-route tunnel (no traffic flows through the tunnel).
/// The tunnel process stays alive purely for heartbeat + detection duties.
/// Phase 2 (future): DNS-based web content filtering.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private let storage = AppGroupStorage()
    private let keychain = KeychainManager()
    private var heartbeatTimer: DispatchSourceTimer?
    private var livenessTimer: DispatchSourceTimer?

    /// Timestamp of last IPC ping from the main app.
    /// Seeded from App Group so the tunnel immediately knows if the app has been dead for hours.
    /// Falls back to Date() only if no App Group timestamp exists (first-ever tunnel start).
    private lazy var lastPingFromApp: Date? = {
        let ts = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .double(forKey: "mainAppLastActiveAt") ?? 0
        return ts > 0 ? Date(timeIntervalSince1970: ts) : Date()
    }()

    /// Whether the main app is considered alive. Seeded from App Group timestamp.
    private lazy var mainAppAlive: Bool = {
        let ts = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .double(forKey: "mainAppLastActiveAt") ?? 0
        // If app was active within the last 10 minutes, assume alive
        return ts > 0 && (Date().timeIntervalSince1970 - ts) < AppConstants.appDeathThresholdSeconds
    }()

    /// Prevent duplicate heartbeats — only send from tunnel when main app is dead.
    private var tunnelOwnsHeartbeat = false

    /// DNS proxy for domain activity logging.
    private var dnsProxy: DNSProxy?

    /// Timer for periodic DNS activity sync.
    private var dnsActivitySyncTimer: DispatchSourceTimer?

    // MARK: - Screen Lock Monitoring

    private var lockNotifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private var lastUnlockAt: Date?

    /// When the tunnel process started. Used to skip emergency enforcement
    /// during the startup grace period (app may still be launching after deploy).
    private var tunnelStartedAt: Date = Date()

    /// Set when `setTunnelNetworkSettings` fails — retried on the next liveness tick.
    private var networkSettingsNeedRetry = false

    /// Backoff counter for persistent CloudKit heartbeat permission failures.
    /// Prevents spamming delete-recreate on every heartbeat interval.
    private var heartbeatPermissionFailures = 0
    private var heartbeatPermissionBackoffUntil: Date?

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[Tunnel] startTunnel called (b\(AppConstants.appBuildNumber))")
        tunnelStartedAt = Date()

        // Write tunnel build number to App Group so the main app can detect
        // stale processes (devicectl install updates the tunnel but may not
        // restart the main app).
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(AppConstants.appBuildNumber, forKey: "tunnelBuildNumber")

        // Configure tunnel with DNS-based safe search enforcement.
        // The tunnel interface claims DNS so all DNS queries go through our configured servers.
        // When safe search is enabled, uses CleanBrowsing Family DNS which enforces
        // safe search on Google, Bing, YouTube, and blocks adult content at DNS level.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        // Check if safe search / content filtering is enabled
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let safeSearchEnabled = defaults?.bool(forKey: "safeSearchEnabled") ?? false

        // Determine upstream DNS server.
        // Even during blackhole, use a REAL upstream so Apple domains (CloudKit, APNS)
        // still resolve. The proxy itself refuses non-exempt domains in blackhole mode.
        let upstreamDNS: String
        if isInternetBlocked {
            upstreamDNS = "1.1.1.1" // Real DNS — proxy handles blackhole with Apple exemptions
            NSLog("[Tunnel] DNS blackhole active — internet blocked (Apple domains exempt)")
        } else if safeSearchEnabled {
            upstreamDNS = "185.228.168.168" // CleanBrowsing Family
            NSLog("[Tunnel] DNS safe search enabled (CleanBrowsing Family)")
        } else {
            upstreamDNS = "1.1.1.1" // Cloudflare (fast, reliable)
        }

        // Route ALL DNS through our tunnel IP so DNSProxy can intercept and log queries
        let dns = NEDNSSettings(servers: ["198.18.0.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        // Create DNS proxy with the selected upstream
        dnsProxy = DNSProxy(provider: self, upstreamDNSServer: upstreamDNS, storage: storage)
        dnsProxy?.onAppDomainSeen = { [weak self] appName, domain, at in
            self?.handleAppDomainSeen(appName: appName, domain: domain, at: at)
        }
        // Schedule enforcement has a 60-second grace period after startup to let the
        // app launch after a deploy. The 30-second tick will activate it after the grace.
        dnsProxy?.isBlackholeMode = isInternetBlocked

        // Seed enforcement blocked domains from last-known fallback if the
        // main list is empty (main app may not have written one yet after reboot).
        let mainBlocklist = storage.readEnforcementBlockedDomains()
        if mainBlocklist.isEmpty,
           let lastKnownData = storage.readRawData(forKey: "tunnel_last_known_blocklist"),
           let lastKnownDomains = try? JSONDecoder().decode(Set<String>.self, from: lastKnownData),
           !lastKnownDomains.isEmpty {
            try? storage.writeEnforcementBlockedDomains(lastKnownDomains)
            NSLog("[Tunnel] Seeded enforcement blocklist from last-known fallback (\(lastKnownDomains.count) domains)")
        }

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                NSLog("[Tunnel] Failed to set network settings: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            NSLog("[Tunnel] Tunnel started successfully (no-route mode)")

            self?.writeTunnelStatus("running")
            self?.dnsProxy?.start()
            self?.startDNSActivitySyncTimer()
            self?.startHeartbeatTimer()
            self?.startLivenessTimer()
            self?.startScreenLockMonitoring()
            self?.startNetworkPathMonitoring()

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[Tunnel] stopTunnel called (reason: \(reason.rawValue))")

        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        livenessTimer?.cancel()
        livenessTimer = nil
        dnsActivitySyncTimer?.cancel()
        dnsActivitySyncTimer = nil
        dnsProxy?.flushToAppGroup()
        dnsProxy?.stop()
        flushScreenTimeSession()
        stopScreenLockMonitoring()

        // Persist current blocklist so next tunnel start has a fallback
        // if the main app hasn't written one yet.
        persistCurrentBlocklist()

        writeTunnelStatus("stopped:\(reason.rawValue)")
        completionHandler()
    }

    // MARK: - IPC (Main App Communication)

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }

        switch message {
        case "ping":
            // Main app is alive — hand off heartbeat duties (but tunnel keeps screen time tracking)
            lastPingFromApp = Date()
            // Flush screen time so the main app reads current values for its heartbeat.
            flushScreenTimeSession()
            if !mainAppAlive {
                NSLog("[Tunnel] Main app came back alive")
                mainAppAlive = true
                tunnelOwnsHeartbeat = false
            }
            // Immediately check build mismatch — app just launched, may have resolved it.
            checkBuildMismatchEnforcement()
            if emergencyBlackholeActive { deactivateEmergencyBlackhole() }
            if scheduleBlackholeActive {
                scheduleBlackholeActive = false
                dnsProxy?.isBlackholeMode = isInternetBlocked
                flushBlockStateToDefaults()
                NSLog("[Tunnel] Schedule enforcement DNS cleared — app alive, sending heartbeat")
                Task { await sendHeartbeatFromTunnel(reason: "scheduleBlackholeCleared") }
            }
            completionHandler?("pong".data(using: .utf8))

        case "forceHeartbeat":
            // Main app requests the tunnel send a heartbeat
            Task {
                await sendHeartbeatFromTunnel(reason: "requested")
                completionHandler?("sent".data(using: .utf8))
            }

        case "status":
            // Return tunnel health info
            let status: [String: Any] = [
                "alive": true,
                "mainAppAlive": mainAppAlive,
                "tunnelOwnsHeartbeat": tunnelOwnsHeartbeat,
                "lastPing": lastPingFromApp?.timeIntervalSince1970 ?? 0
            ]
            if let data = try? JSONSerialization.data(withJSONObject: status) {
                completionHandler?(data)
            } else {
                completionHandler?(nil)
            }

        case "blockInternet":
            applyInternetBlock(durationSeconds: 3600) // default 1 hour via IPC
            completionHandler?("blocked".data(using: .utf8))

        case "unblockInternet":
            applyInternetBlock(durationSeconds: 0)
            completionHandler?("unblocked".data(using: .utf8))

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Heartbeat Timer

    /// Send heartbeats from the tunnel extension when the main app is dead.
    /// Only activates when IPC pings stop arriving.
    private func startHeartbeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + AppConstants.vpnHeartbeatIntervalSeconds,
                       repeating: AppConstants.vpnHeartbeatIntervalSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.tunnelOwnsHeartbeat else { return }
            // Re-check before sending — app may have recovered since we took over.
            // A recent IPC ping (within 2 minutes) means the app is back.
            if let lastPing = self.lastPingFromApp, Date().timeIntervalSince(lastPing) < 120 {
                self.tunnelOwnsHeartbeat = false
                self.mainAppAlive = true
                NSLog("[Tunnel] App recovered (recent IPC ping) — handing back heartbeat duties")
                return
            }
            Task { await self.sendHeartbeatFromTunnel(reason: "timer") }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - DNS Activity Sync

    /// Flush DNS activity to App Group + CloudKit every 15 minutes.
    private func startDNSActivitySyncTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 900, repeating: 900) // 15 min
        timer.setEventHandler { [weak self] in
            self?.dnsProxy?.flushToAppGroup()
            self?.dnsProxy?.cleanupStalePendingQueries()

            // Sync to CloudKit so parent can see near-real-time activity
            guard let self,
                  let enrollment = try? self.keychain.get(
                      ChildEnrollmentState.self,
                      forKey: StorageKeys.enrollmentState
                  ) else { return }

            let snapshot = self.dnsProxy?.takeSnapshot(
                deviceID: enrollment.deviceID,
                familyID: enrollment.familyID
            )
            guard let snapshot, !snapshot.domains.isEmpty else { return }

            Task {
                await self.syncDNSActivityToCloudKit(snapshot, enrollment: enrollment)
            }
        }
        timer.resume()
        dnsActivitySyncTimer = timer
    }

    private func syncDNSActivityToCloudKit(_ snapshot: DomainActivitySnapshot, enrollment: ChildEnrollmentState) async {
        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        // Upsert: one record per device per day
        let recordID = CKRecord.ID(recordName: "BBDNSActivity_\(enrollment.deviceID.rawValue)_\(snapshot.date)")
        let record: CKRecord
        var existingDomains: [String: DomainHit] = [:]

        do {
            record = try await db.record(for: recordID)
            // Parse existing domains to merge with (never lose data)
            if let json = record["domainsJSON"] as? String,
               let data = json.data(using: .utf8),
               let saved = try? JSONDecoder().decode([DomainHit].self, from: data) {
                for hit in saved {
                    existingDomains[hit.domain] = hit
                }
            }
        } catch {
            record = CKRecord(recordType: "BBDNSActivity", recordID: recordID)
        }

        // Merge: for each domain, keep the higher count (handles tunnel restarts)
        var merged = existingDomains
        for hit in snapshot.domains {
            if let existing = merged[hit.domain] {
                if hit.count > existing.count {
                    merged[hit.domain] = hit
                }
            } else {
                merged[hit.domain] = hit
            }
        }
        let mergedDomains = Array(merged.values)
        let mergedTotal = max(
            snapshot.totalQueries,
            (record["totalQueries"] as? Int) ?? 0
        )

        record["deviceID"] = enrollment.deviceID.rawValue
        record["familyID"] = enrollment.familyID.rawValue
        record["date"] = snapshot.date
        record["timestamp"] = snapshot.timestamp as NSDate
        record["totalQueries"] = mergedTotal as NSNumber
        if let data = try? JSONEncoder().encode(mergedDomains),
           let json = String(data: data, encoding: .utf8) {
            record["domainsJSON"] = json
        }

        do {
            try await db.save(record)
            NSLog("[Tunnel] DNS activity synced: \(mergedDomains.count) domains (merged), \(mergedTotal) queries")
        } catch {
            NSLog("[Tunnel] DNS activity sync failed: \(error.localizedDescription)")
        }
    }

    private var lastDNSDateCheck: String?

    private func checkDNSDayRollover() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let dayChanged = lastDNSDateCheck != nil && lastDNSDateCheck != today
        if dayChanged {
            // Day changed — flush yesterday's data, reset counters
            dnsProxy?.flushToAppGroup()
            dnsProxy?.resetDaily()
            NSLog("[Tunnel] Daily reset for new day")
        }

        // Reset screen time if stored date doesn't match today — handles both
        // day rollover AND fresh tunnel start after deploy (lastDNSDateCheck was nil).
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if defaults?.string(forKey: screenTimeDateKey) != today {
            NSLog("[Tunnel] Screen time reset for new day (was: \(defaults?.integer(forKey: screenTimeMinutesKey) ?? 0)m, \(defaults?.integer(forKey: screenTimeUnlockCountKey) ?? 0) unlocks)")
            defaults?.set(today, forKey: screenTimeDateKey)
            defaults?.set(0, forKey: screenTimeSecondsKey)
            defaults?.set(0, forKey: screenTimeMinutesKey)
            defaults?.set(0, forKey: screenTimeUnlockCountKey)
            defaults?.removeObject(forKey: screenTimeSlotKey)
        }

        lastDNSDateCheck = today
    }

    // MARK: - App Liveness Detection

    /// Check every 30 seconds if the main app is still alive + poll for pending commands.
    private var lastScheduleSyncAt: Date?

    private var livenessTickCount: Int = 0

    private func startLivenessTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // Poll commands every 10 seconds for responsive command delivery.
        // Heavier operations (schedule sync, blocklist persist, app liveness) run
        // every 3rd tick (30 seconds) to save battery.
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.livenessTickCount += 1

            // Fast path: poll for commands every 10 seconds
            Task { await self.pollAndProcessCommands() }
            // Sync unlock requests from App Group to CloudKit (ShieldAction can't make network calls)
            Task { await self.syncPendingUnlockRequests() }
            // Check if Monitor needs a confirmation heartbeat (fast path for responsiveness)
            self.checkMonitorHeartbeatRequest()

            // Slow path: heavier operations every 30 seconds (every 3rd tick)
            if self.livenessTickCount % 3 == 0 {
                let livenessDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
                livenessDefaults?.set(Date().timeIntervalSince1970, forKey: "tunnelLastActiveAt")
                livenessDefaults?.set(self.isInternetBlocked || self.scheduleBlackholeActive, forKey: "tunnelInternetBlocked")
                let reason = self.internetBlockedReason ?? (self.scheduleBlackholeActive ? "Schedule enforcement — app not running" : "")
                livenessDefaults?.set(reason, forKey: "tunnelInternetBlockedReason")
                self.checkAppLiveness()
                self.checkScheduleEnforcement()
                self.checkPendingShieldConfirmation()
                self.checkNetworkPathAndReconnect()
                self.checkDNSDayRollover()
                self.persistCurrentBlocklist()
                Task { await self.syncScheduleProfileIfNeeded() }
                Task { await self.syncResolvedPendingReviews() }
                self.checkDNSAppVerification()
            }
        }
        timer.resume()
        livenessTimer = timer
    }

    private func checkAppLiveness() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)

        // Signal 1: IPC pings from the main app
        let pingStale: Bool
        if let lastPing = lastPingFromApp {
            pingStale = Date().timeIntervalSince(lastPing) > AppConstants.appDeathThresholdSeconds
        } else {
            // No pings ever received — check if app has sent any heartbeat recently
            pingStale = true
        }

        // Signal 2: App Group timestamp (backup for IPC)
        let lastActiveAt = defaults?.double(forKey: "mainAppLastActiveAt") ?? 0
        let appGroupStale: Bool
        if lastActiveAt > 0 {
            appGroupStale = Date().timeIntervalSince1970 - lastActiveAt > AppConstants.appDeathThresholdSeconds
        } else {
            appGroupStale = true
        }

        // Both signals must agree (avoid false positives during brief suspensions)
        let appDead = pingStale && appGroupStale

        if appDead && mainAppAlive {
            // App just died — take over screen time tracking + heartbeats
            NSLog("[Tunnel] Main app appears dead — taking over heartbeat duties")
            mainAppAlive = false
            tunnelOwnsHeartbeat = true

            // Write flag so app knows to grab location immediately on relaunch
            let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
            defaults?.set(Date().timeIntervalSince1970, forKey: "appDiedNeedLocationAt")

            // If screen is currently unlocked, start tracking from now
            var currentLockState: UInt64 = 0
            if lockNotifyToken != NOTIFY_TOKEN_INVALID {
                notify_get_state(lockNotifyToken, &currentLockState)
            }
            if currentLockState == 0 {
                lastUnlockAt = Date()
            }

            // Send immediate heartbeat
            Task { await sendHeartbeatFromTunnel(reason: "appDeath") }

            // Don't nag the kid — the device is already locked down via
            // ManagedSettingsStore. The Monitor handles free-window-specific nags.
        } else if !appDead && !mainAppAlive {
            // App came back (via App Group timestamp, before IPC resumes)
            NSLog("[Tunnel] Main app appears alive again (App Group timestamp updated)")
            mainAppAlive = true

            // Immediately release any safety-net blackholes — the app is alive and
            // can enforce shields directly. Without this, blackholes linger until
            // the next periodic check (~30s).
            var released = false
            if scheduleBlackholeActive {
                NSLog("[Tunnel] Releasing schedule blackhole — app is alive")
                scheduleBlackholeActive = false
                released = true
            }
            if buildMismatchBlackholeActive {
                NSLog("[Tunnel] Releasing build mismatch blackhole — app launched on new build")
                buildMismatchBlackholeActive = false
                buildMismatchFirstDetectedAt = nil
                released = true
            }
            if emergencyBlackholeActive {
                NSLog("[Tunnel] Releasing emergency blackhole — app is alive")
                deactivateEmergencyBlackhole()
                released = true
            }
            if released {
                dnsProxy?.isBlackholeMode = isInternetBlocked
                flushBlockStateToDefaults()
                Task { await sendHeartbeatFromTunnel(reason: "blackholeReleasedAppAlive") }
            }
        }

        // Check if internet block has expired
        let blockDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if let unblockAt = blockDefaults?.double(forKey: "internetBlockedUntil"),
           unblockAt > 0, Date().timeIntervalSince1970 >= unblockAt {
            blockDefaults?.removeObject(forKey: "internetBlockedUntil")
            reapplyNetworkSettings()
            NSLog("[Tunnel] Internet block expired — traffic restored")
            tunnelOwnsHeartbeat = false
        }

        // Expired temp unlock: if the Monitor missed the expiry callback,
        // update the extension shared state so the app re-locks on next launch.
        // The tunnel can't apply ManagedSettings, but it can fix the shared state
        // and nudge the kid to open the app (which triggers AppLaunchRestorer).
        checkExpiredTempUnlock()

        // FC auth revoked: if the kid turned off FamilyControls, block internet immediately.
        // This is our only enforcement when ManagedSettingsStore can't be written.
        checkPermissionsEnforcement()

        // Build mismatch: app was updated but hasn't launched yet on the new build.
        // Block internet until the kid opens the app (triggers restoration on new code).
        checkBuildMismatchEnforcement()

        // Retry failed network settings application (DNS blackhole or proxy config).
        if networkSettingsNeedRetry {
            NSLog("[Tunnel] Retrying failed network settings application")
            reapplyNetworkSettings()
        }

        // Emergency enforcement: if both app and Monitor are dead, screen is unlocked,
        // and device should be restricted/locked — activate DNS blackhole as fallback.
        checkEmergencyEnforcement()
    }

    private var permissionsBlackholeActive: Bool = false

    /// Block internet when FamilyControls Individual authorization is explicitly revoked.
    /// Without FC auth, ManagedSettingsStore writes fail silently — DNS blackhole
    /// is the only enforcement available.
    ///
    /// Only checks FC auth status — NOT the generic allPermissionsGranted flag,
    /// which can be false due to child auth failure (MDM blocks .child auth)
    /// even when Individual auth works fine and shields are fully functional.
    private func checkPermissionsEnforcement() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let fcAuth = defaults?.string(forKey: "familyControlsAuthStatus")

        // Only blackhole when FC auth is EXPLICITLY denied (child revoked in Settings).
        // nil = never set (first boot) — don't blackhole.
        // "notDetermined" = pre-auth or transient state during app install — don't blackhole.
        // "approved"/"authorized" = working — don't blackhole.
        // "denied" = explicitly revoked by user — blackhole.
        let authOK = fcAuth != "denied"
        let resolution = ModeStackResolver.resolve(storage: storage)
        let shouldBeRestricted = resolution.mode != .unlocked

        if !authOK && shouldBeRestricted {
            if !permissionsBlackholeActive {
                permissionsBlackholeActive = true
                NSLog("[Tunnel] FC auth revoked (\(fcAuth ?? "nil")) + device should be \(resolution.mode.rawValue) — blocking internet")
                reapplyNetworkSettings()

                // Notify kid
                let content = UNMutableNotificationContent()
                content.title = "Big Brother"
                content.body = "Parental controls were disabled. Internet blocked until restored."
                content.sound = .default
                let request = UNNotificationRequest(identifier: "fc-auth-revoked", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)

                // Alert parent via CloudKit
                Task { await sendPermissionRevokedAlert() }
            }
        } else if permissionsBlackholeActive && authOK {
            permissionsBlackholeActive = false
            NSLog("[Tunnel] FC auth restored — unblocking internet")
            reapplyNetworkSettings()
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["fc-auth-revoked"])
        }
    }

    private func sendPermissionRevokedAlert() async {
        guard let enrollment = try? keychain.get(ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState) else { return }
        let entry = EventLogEntry(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            eventType: .authorizationLost,
            details: "ALERT: FamilyControls authorization was REVOKED — all shields disabled, internet blocked by tunnel"
        )
        let storage = AppGroupStorage()
        try? storage.appendEventLog(entry)

        // Also try to sync immediately so parent sees it fast
        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase
        let record = CKRecord(recordType: "BBEventLog", recordID: CKRecord.ID(recordName: "BBEventLog_\(entry.id.uuidString)"))
        record["deviceID"] = enrollment.deviceID.rawValue
        record["familyID"] = enrollment.familyID.rawValue
        record["eventType"] = "authorizationLost"
        record["details"] = entry.details
        record["timestamp"] = Date() as NSDate
        _ = try? await db.save(record)
    }

    /// Detect stale enforcement state — the PolicySnapshot or ExtensionSharedState
    /// says unlocked but ModeStackResolver says the device should be locked.
    /// The tunnel can't apply ManagedSettings, but it can:
    /// 1. Clean up expired state files (ModeStackResolver does this)
    /// 2. Update PolicySnapshot and ExtensionSharedState to the correct mode
    /// 3. Send a notification nudging the kid to open the app (which re-locks via AppLaunchRestorer)
    private var lastStaleUnlockNotificationAt: Date = .distantPast

    private func checkExpiredTempUnlock() {
        let resolution = ModeStackResolver.resolve(storage: storage)

        // Check if any state file disagrees with ModeStackResolver (the source of truth).
        // This catches: temp unlock expired (unlocked→restricted), schedule transitions
        // (restricted→locked), and any other mode drift.
        let extState = storage.readExtensionSharedState()
        let snapshot = storage.readPolicySnapshot()
        let extStale = extState != nil && extState!.currentMode != resolution.mode
        let snapshotStale = snapshot != nil && (
            snapshot!.effectivePolicy.resolvedMode != resolution.mode ||
            (snapshot!.effectivePolicy.isTemporaryUnlock && !resolution.isTemporary)
        )

        guard extStale || snapshotStale else { return }

        // Fix stale ExtensionSharedState
        if extStale, let extState {
            let corrected = ExtensionSharedState(
                currentMode: resolution.mode,
                isTemporaryUnlock: false,
                temporaryUnlockExpiresAt: nil,
                authorizationAvailable: extState.authorizationAvailable,
                enforcementDegraded: extState.enforcementDegraded,
                shieldConfig: extState.shieldConfig,
                writtenAt: Date(),
                policyVersion: extState.policyVersion + 1
            )
            try? storage.writeExtensionSharedState(corrected)
        }

        // Fix stale PolicySnapshot
        if snapshotStale, let snapshot {
            let existingPolicy = snapshot.effectivePolicy
            let correctedPolicy = EffectivePolicy(
                resolvedMode: resolution.mode,
                isTemporaryUnlock: false,
                temporaryUnlockExpiresAt: nil,
                shieldedCategoriesData: existingPolicy.shieldedCategoriesData,
                allowedAppTokensData: existingPolicy.allowedAppTokensData,
                warnings: existingPolicy.warnings,
                policyVersion: existingPolicy.policyVersion + 1
            )
            let correctedSnapshot = PolicySnapshot(
                source: .restoration,
                trigger: "Tunnel: stale unlock state corrected to \(resolution.mode.rawValue)",
                effectivePolicy: correctedPolicy
            )
            _ = try? storage.commitCorrectedSnapshot(correctedSnapshot)
        }

        NSLog("[Tunnel] Stale unlock state detected — corrected to \(resolution.mode.rawValue) (ext:\(extStale) snap:\(snapshotStale)). App must launch to re-apply ManagedSettings.")

        // The tunnel can't write to ManagedSettingsStore, so shields remain cleared.
        // If the device should be restricted and neither the app nor Monitor is running,
        // activate the emergency DNS blackhole as a backstop — it's the only enforcement
        // the tunnel can apply. This prevents the kid from having unrestricted internet
        // while shields are down.
        let staleDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if resolution.mode != .unlocked && !mainAppAlive && !emergencyBlackholeActive {
            let appActiveAt = staleDefaults?.double(forKey: "mainAppLastActiveAt") ?? 0
            let appDead = appActiveAt > 0 && Date().timeIntervalSince1970 - appActiveAt > 300 // 5 min
            if appDead {
                NSLog("[Tunnel] Shields confirmed down + app dead — activating DNS blackhole as enforcement backstop")
                emergencyBlackholeActive = true
            }
        }

        reapplyNetworkSettings()

        // Nudge the kid to open the app (throttle to once per 5 minutes)
        let now = Date()
        if now.timeIntervalSince(lastStaleUnlockNotificationAt) > 300 {
            lastStaleUnlockNotificationAt = now
            let content = UNMutableNotificationContent()
            content.title = "Big Brother"
            content.body = "Open Big Brother to update your device settings."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "expired-temp-unlock",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private var buildMismatchBlackholeActive: Bool = false
    private var buildMismatchFirstDetectedAt: Date?

    private func checkBuildMismatchEnforcement() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let mainAppBuild = defaults?.integer(forKey: "mainAppLastLaunchedBuild") ?? 0
        let tunnelBuild = AppConstants.appBuildNumber

        if mainAppBuild > 0 && mainAppBuild < tunnelBuild {
            if buildMismatchFirstDetectedAt == nil {
                // First detection — start grace period. The deploy script launches
                // the app right after install, so give it 2 minutes to start and
                // write the new build number before blocking internet.
                buildMismatchFirstDetectedAt = Date()
                NSLog("[Tunnel] Build mismatch: app=b\(mainAppBuild) tunnel=b\(tunnelBuild) — 2-min grace before blocking")

                let content = UNMutableNotificationContent()
                content.title = "Big Brother Update"
                content.body = "Open Big Brother to restore internet access."
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "build-mismatch",
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request)
            }

            // After 2-minute grace, block internet
            if !buildMismatchBlackholeActive,
               let detected = buildMismatchFirstDetectedAt,
               Date().timeIntervalSince(detected) > 120 {
                NSLog("[Tunnel] Build mismatch grace expired: app=b\(mainAppBuild) tunnel=b\(tunnelBuild) — blocking internet")
                buildMismatchBlackholeActive = true
                reapplyNetworkSettings()
            }
        } else if buildMismatchFirstDetectedAt != nil {
            NSLog("[Tunnel] Build mismatch resolved: app=b\(mainAppBuild) tunnel=b\(tunnelBuild) — restoring internet")
            buildMismatchFirstDetectedAt = nil
            buildMismatchBlackholeActive = false
            reapplyNetworkSettings()
            flushBlockStateToDefaults()
            Task { await sendHeartbeatFromTunnel(reason: "buildMismatchCleared") }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["build-mismatch"])
        }
    }

    /// Consecutive checks where emergency enforcement conditions are met.
    /// Requires multiple checks to avoid false positives from normal iOS process lifecycle.
    private var emergencyCheckCount: Int = 0
    private var emergencyBlackholeActive: Bool = false

    /// Proxy-level DNS blocking when schedule says restricted/locked but the main app
    /// isn't running to apply ManagedSettings. Unlike emergencyBlackholeActive (which
    /// requires Monitor dead for 1 hour), this activates immediately when the app is dead
    /// and the schedule says the device shouldn't be unlocked. Uses DNSProxy's blackhole
    /// mode (Apple domains exempt) instead of system-level 127.0.0.1.
    private var scheduleBlackholeActive: Bool = false

    /// Temporary DNS blackhole while ManagedSettings shields are being applied by Monitor.
    /// Set when tunnel processes a lock/restrict command. Cleared when Monitor confirms shields.
    struct PendingShieldConfirmation {
        let targetMode: LockMode
        let requestedAt: Date
    }
    private var pendingShieldConfirmation: PendingShieldConfirmation?

    /// Check if the tunnel should activate emergency DNS blackhole enforcement.
    /// Only triggers when: screen is unlocked, both app and Monitor are dead for
    /// multiple consecutive checks, and the device should be in a restricted state.
    private func checkEmergencyEnforcement() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)

        // Grace period after tunnel startup — the app may still be launching
        // after a deploy (devicectl install + launch). Don't fire emergency
        // alerts during this window.
        let timeSinceStart = Date().timeIntervalSince(tunnelStartedAt)
        if timeSinceStart < 300 { // 5 minute grace period
            emergencyCheckCount = 0
            if emergencyBlackholeActive { deactivateEmergencyBlackhole() }
            return
        }

        // Only act when screen is unlocked (kid is actively using the phone)
        guard !(dnsProxy?.isDeviceLocked ?? true) else {
            emergencyCheckCount = 0
            // Don't deactivate blackhole when screen locks — keep it active
            // so DNS is blocked the moment the kid unlocks the screen.
            return
        }

        // Resolve what mode the device should be in
        let resolution = ModeStackResolver.resolve(storage: storage)

        // If device should be unlocked, no emergency needed
        guard resolution.mode != .unlocked else {
            emergencyCheckCount = 0
            if emergencyBlackholeActive { deactivateEmergencyBlackhole() }
            return
        }

        // Check if main app wrote its timestamp recently.
        // The app writes mainAppLastActiveAt every 30s when in foreground,
        // but iOS suspends it when backgrounded — gaps of 5+ minutes are normal.
        let appLastActive = defaults?.double(forKey: "mainAppLastActiveAt") ?? 0
        let appAge = appLastActive > 0 ? Date().timeIntervalSince1970 - appLastActive : 999
        let appRecentlyActive = appAge < 600 // 10 minutes (tightened from 30)

        // If the main app is alive (IPC pings working), no emergency
        if mainAppAlive || appRecentlyActive {
            emergencyCheckCount = 0
            if emergencyBlackholeActive { deactivateEmergencyBlackhole() }
            return
        }

        // App is dead. Check if Monitor can handle enforcement.
        // The Monitor fires on DeviceActivity callbacks — gaps of 60+ minutes
        // are normal during periods with no schedule transitions.
        // But if there's an ACTIVE expiry that was missed, we can't wait.
        let monitorLastActive = defaults?.double(forKey: "monitorLastActiveAt") ?? 0
        let monitorAge = monitorLastActive > 0 ? Date().timeIntervalSince1970 - monitorLastActive : 999
        let monitorDead = monitorAge > 3600 // 1 hour (tightened from 2 hours)

        guard monitorDead else {
            emergencyCheckCount = 0
            if emergencyBlackholeActive { deactivateEmergencyBlackhole() }
            return
        }

        // Require 5 consecutive checks (liveness timer fires every ~30s = 2.5 minutes)
        emergencyCheckCount += 1
        guard emergencyCheckCount >= 5 else { return }

        // Activate emergency blackhole — only fire once, not every 30s.
        guard !emergencyBlackholeActive else { return }
        NSLog("[Tunnel] EMERGENCY: App dead (age \(Int(appAge))s), Monitor dead (\(Int(monitorAge))s), screen unlocked, mode should be \(resolution.mode.rawValue) — activating DNS blackhole")
        emergencyBlackholeActive = true
        reapplyNetworkSettings()

        // Notify parent via CloudKit event (once)
        Task { await sendEmergencyAlert(resolution: resolution, monitorAge: Int(monitorAge)) }
    }

    private func deactivateEmergencyBlackhole() {
        guard emergencyBlackholeActive else { return }
        emergencyBlackholeActive = false
        emergencyCheckCount = 0
        reapplyNetworkSettings()
        flushBlockStateToDefaults()
        Task { await sendHeartbeatFromTunnel(reason: "emergencyBlackholeCleared") }
        NSLog("[Tunnel] Emergency blackhole deactivated — normal enforcement resumed")
    }

    /// Immediately write current block state to UserDefaults so the next heartbeat
    /// (from app or tunnel) reports the correct state. Without this, the 30-second
    /// tick delay causes stale "internet blocked" errors in the parent dashboard.
    private func flushBlockStateToDefaults() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.set(isInternetBlocked || scheduleBlackholeActive, forKey: "tunnelInternetBlocked")
        let reason = internetBlockedReason ?? (scheduleBlackholeActive ? "Schedule enforcement — app not running" : "")
        defaults?.set(reason, forKey: "tunnelInternetBlockedReason")
    }

    /// Check if the tunnel should enforce the schedule via DNS when ManagedSettings
    /// can't be applied (app not running). Runs every 30 seconds.
    ///
    /// Unlike the emergency blackhole (requires Monitor dead 1hr + 5 checks), this
    /// activates immediately when the schedule says restricted/locked and the app is dead.
    /// Uses proxy-level blocking (Apple domains exempt) rather than system-level 127.0.0.1.
    private func checkScheduleEnforcement() {
        // Grace period after tunnel startup — the app is likely still launching
        // after a deploy (install restarts tunnel, then launch starts the app).
        let timeSinceStart = Date().timeIntervalSince(tunnelStartedAt)
        if timeSinceStart < 60 { return }

        let resolution = ModeStackResolver.resolve(storage: storage)

        // DNS-block when we have evidence shields may be down.
        // Positive evidence: auth revoked or main app reported shields=false.
        // Prolonged app death: app dead >15 min means shields can't self-heal, so
        // DNS-block as safety net even if last heartbeat said shields were up.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let authRevoked = defaults?.string(forKey: "familyControlsAuthStatus") == "denied"
        let lastShieldsActive = defaults?.object(forKey: "shieldsActiveAtLastHeartbeat") as? Bool
        let shieldsConfirmedDown = lastShieldsActive == false
        let lastAppActiveAt = defaults?.double(forKey: "mainAppLastActiveAt") ?? 0
        let appDeadDuration = lastAppActiveAt > 0 ? Date().timeIntervalSince1970 - lastAppActiveAt : .infinity
        let prolongedAppDeath = appDeadDuration > 900 // 15 minutes
        let positiveEvidence = authRevoked || shieldsConfirmedDown || prolongedAppDeath
        // If shields are confirmed down, DNS-block regardless of app liveness.
        // The app may be "alive" but unable to enforce (e.g., .child auth silently failing).
        let shouldBlock = resolution.mode != .unlocked
            && (shieldsConfirmedDown || (!mainAppAlive && positiveEvidence))

        if shouldBlock != scheduleBlackholeActive {
            scheduleBlackholeActive = shouldBlock
            dnsProxy?.isBlackholeMode = shouldBlock || isInternetBlocked
            flushBlockStateToDefaults()
            if shouldBlock {
                NSLog("[Tunnel] Schedule enforcement DNS active — mode \(resolution.mode.rawValue), app not alive")
                Task { await sendHeartbeatFromTunnel(reason: "scheduleEnforcementActivated") }
                // Notify the kid — tapping opens BB which restores full enforcement + DNS.
                let notif = UNMutableNotificationContent()
                notif.title = "Internet Paused"
                notif.body = "Open Big Brother to restore internet access."
                notif.sound = .default
                let req = UNNotificationRequest(
                    identifier: "schedule-enforcement",
                    content: notif,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(req)
            } else {
                NSLog("[Tunnel] Schedule enforcement DNS cleared — \(resolution.mode == .unlocked ? "mode unlocked" : "app alive")")
                Task { await sendHeartbeatFromTunnel(reason: "scheduleEnforcementCleared") }
            }
        }

        // Always sync DNS proxy with actual internet block state.
        let actualBlocked = isInternetBlocked || scheduleBlackholeActive
        if (dnsProxy?.isBlackholeMode ?? false) != actualBlocked {
            dnsProxy?.isBlackholeMode = actualBlocked
            flushBlockStateToDefaults()
            if actualBlocked {
                reapplyNetworkSettings()
                NSLog("[Tunnel] DNS blackhole synced — lockedDown mode detected")
            } else {
                reapplyNetworkSettings()
                NSLog("[Tunnel] DNS blackhole released — mode no longer blocked")
            }
        }

        // If app has been dead for 30+ minutes, post a one-time local notification
        // prompting the child to open the app (restores location tracking + enforcement).
        if !mainAppAlive && appDeadDuration > 1800 {
            let lastNagKey = "tunnelLocationNagAt"
            let lastNag = defaults?.double(forKey: lastNagKey) ?? 0
            if Date().timeIntervalSince1970 - lastNag > 3600 { // Max once per hour
                defaults?.set(Date().timeIntervalSince1970, forKey: lastNagKey)
                let content = UNMutableNotificationContent()
                content.title = "Open Big Brother"
                content.body = "Tap to restore location tracking and full protection."
                content.sound = .default
                let req = UNNotificationRequest(identifier: "tunnel-location-nag", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
                NSLog("[Tunnel] Posted location nag notification — app dead for \(Int(appDeadDuration))s")
            }
        }
    }

    /// Check if the Monitor has confirmed shield application after a mode command.
    /// When we temporarily block DNS during a lock/restrict transition, we release
    /// the blackhole once the Monitor writes ExtensionSharedState confirming the mode.
    private func checkPendingShieldConfirmation() {
        guard let pending = pendingShieldConfirmation else { return }

        let age = Date().timeIntervalSince(pending.requestedAt)

        // Check if Monitor confirmed shields for the target mode
        if let extState = storage.readExtensionSharedState(),
           extState.currentMode == pending.targetMode,
           extState.writtenAt > pending.requestedAt {
            // Monitor confirmed! Release temporary DNS blackhole.
            pendingShieldConfirmation = nil
            dnsProxy?.isBlackholeMode = isInternetBlocked // Revert to normal (lockedDown stays blocked)
            reapplyNetworkSettings()
            flushBlockStateToDefaults()
            NSLog("[Tunnel] Shield confirmation received — releasing temporary DNS blackhole (\(Int(age))s)")
            return
        }

        // Timeout after 2 minutes — keep DNS blocked and log
        if age > 120 {
            NSLog("[Tunnel] Shield confirmation TIMEOUT after \(Int(age))s — keeping DNS blocked for safety")
            // Don't clear pendingShieldConfirmation — keep checking
        }
    }

    /// Check if the Monitor extension requested an immediate heartbeat after applying enforcement.
    /// The Monitor can't make network calls — it writes a flag, we pick it up and send the heartbeat.
    /// This ensures the parent sees the confirmed mode within seconds of the Monitor applying shields.
    private func checkMonitorHeartbeatRequest() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard let requestTime = defaults?.double(forKey: "monitorNeedsHeartbeat"),
              requestTime > 0 else { return }

        // Only honor recent requests (within 2 minutes)
        let age = Date().timeIntervalSince1970 - requestTime
        guard age < 120 else {
            defaults?.removeObject(forKey: "monitorNeedsHeartbeat")
            return
        }

        defaults?.removeObject(forKey: "monitorNeedsHeartbeat")
        NSLog("[Tunnel] Monitor requested heartbeat (\(Int(age))s ago) — sending")
        Task { await sendHeartbeatFromTunnel(reason: "monitorConfirmation") }
    }

    /// Handle grantExtraTime from tunnel: remove exhausted entry, update limit, clear DNS block.
    /// Signals the Monitor to reconcile immediately so ManagedSettings shield clears.
    private func handleGrantExtraTimeFromTunnel(fingerprint: String, extraMinutes: Int) {
        // Remove from exhausted list
        var exhausted = storage.readTimeLimitExhaustedApps()
        let appName = exhausted.first(where: { $0.fingerprint == fingerprint })?.appName ?? "App"
        exhausted.removeAll { $0.fingerprint == fingerprint }
        try? storage.writeTimeLimitExhaustedApps(exhausted)

        // Increase daily limit
        var limits = storage.readAppTimeLimits()
        if let idx = limits.firstIndex(where: { $0.fingerprint == fingerprint }) {
            limits[idx].dailyLimitMinutes += extraMinutes
            limits[idx].updatedAt = Date()
            try? storage.writeAppTimeLimits(limits)
            NSLog("[Tunnel] Granted +\(extraMinutes)m for \(limits[idx].appName) (now \(limits[idx].dailyLimitMinutes)m)")
        }

        // Update DNS blocked domains (remove this app's domains).
        // Don't do full reapplyNetworkSettings (interface teardown) — that would
        // kill connections for OTHER apps that should stay blocked.
        updateTimeLimitBlockedDomains()

        // Signal Monitor to re-apply ManagedSettings ASAP.
        // The Monitor will remove ONLY the granted app from shield.applications
        // and keep the other exhausted apps shielded.
        signalMonitorToReconcile()

        // Notify the kid to open BB so enforcement refreshes (ManagedSettings require
        // app or Monitor process to write — tunnel can't). The notification acts as
        // both a "your request was granted" confirmation and an enforcement trigger.
        let content = UNMutableNotificationContent()
        content.title = "Extra Time Granted"
        content.body = "Tap to start using \(appName)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "extra-time-\(fingerprint)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Handle blockAppForToday from tunnel: mark as exhausted, update DNS block.
    private func handleBlockAppForTodayFromTunnel(fingerprint: String) {
        let limits = storage.readAppTimeLimits()
        guard let limit = limits.first(where: { $0.fingerprint == fingerprint }) else { return }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())

        let entry = TimeLimitExhaustedApp(
            timeLimitID: limit.id,
            appName: limit.appName,
            tokenData: limit.tokenData,
            fingerprint: fingerprint,
            exhaustedAt: Date(),
            dateString: today
        )

        var exhausted = storage.readTimeLimitExhaustedApps()
        if !exhausted.contains(where: { $0.fingerprint == fingerprint && $0.dateString == today }) {
            exhausted.append(entry)
            try? storage.writeTimeLimitExhaustedApps(exhausted)
        }

        updateTimeLimitBlockedDomains()
        reapplyNetworkSettings()
        signalMonitorToReconcile()
        NSLog("[Tunnel] Blocked \(limit.appName) for today")
    }

    /// Write a flag to UserDefaults that tells the Monitor extension to reconcile
    /// on its next callback (any intervalDidStart). The Monitor checks this flag
    /// at the top of every callback and re-applies ManagedSettings if set.
    private func signalMonitorToReconcile() {
        // Write the flag (consumed by Monitor on any callback)
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "needsEnforcementRefresh")

        // Stop the currently-active reconciliation quarter to fire intervalDidEnd in the Monitor.
        let center = DeviceActivityCenter()
        let hour = Calendar.current.component(.hour, from: Date())
        let quarter = hour / 6
        let name = DeviceActivityName(rawValue: "bigbrother.reconciliation.q\(quarter)")
        center.stopMonitoring([name])
        NSLog("[Tunnel] Triggered Monitor via stopMonitoring (q\(quarter))")
    }

    /// Handle removeTimeLimit from tunnel: remove limit, remove from allowed, update DNS.
    private func handleRemoveTimeLimitFromTunnel(fingerprint: String) {
        var limits = storage.readAppTimeLimits()
        let removed = limits.first(where: { $0.fingerprint == fingerprint })
        limits.removeAll { $0.fingerprint == fingerprint }
        try? storage.writeAppTimeLimits(limits)

        // Persist name before removing
        if let removed {
            let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
            var nameMap = (defaults?.dictionary(forKey: "harvestedAppNames") as? [String: String]) ?? [:]
            nameMap[removed.fingerprint] = removed.appName
            defaults?.set(nameMap, forKey: "harvestedAppNames")
        }

        // Remove from exhausted
        var exhausted = storage.readTimeLimitExhaustedApps()
        exhausted.removeAll { $0.fingerprint == fingerprint }
        try? storage.writeTimeLimitExhaustedApps(exhausted)

        // Write a flag so the Monitor removes the token from allowed list on next reconciliation.
        // The tunnel can't import ManagedSettings (ApplicationToken) to manipulate the set directly.
        if let removed, removed.wasAlreadyAllowed != true {
            let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
            var pending = defaults?.stringArray(forKey: "pendingTokenRemovals") ?? []
            pending.append(removed.tokenData.base64EncodedString())
            defaults?.set(pending, forKey: "pendingTokenRemovals")
        }

        updateTimeLimitBlockedDomains()
        signalMonitorToReconcile()
        NSLog("[Tunnel] Removed time limit for \(removed?.appName ?? fingerprint)")
    }

    /// Recalculate time-limit DNS blocked domains from exhausted apps.
    private func updateTimeLimitBlockedDomains() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        let exhausted = storage.readTimeLimitExhaustedApps().filter { $0.dateString == today }
        var blockedDomains = Set<String>()
        for app in exhausted {
            let domains = DomainCategorizer.domainsForApp(app.appName)
            blockedDomains.formUnion(domains)
        }
        try? storage.writeTimeLimitBlockedDomains(blockedDomains)
    }

    /// Sync pending unlock request events from App Group to CloudKit.
    /// The ShieldAction extension writes events to App Group but can't make network calls.
    /// The tunnel picks them up and uploads them so the parent gets notified promptly.
    private var syncedUnlockRequestIDs: Set<String> = []

    private func syncPendingUnlockRequests() async {
        let pending = storage.readPendingEventLogs()
        let unlockRequests = pending.filter { $0.eventType == .unlockRequested && $0.uploadState == .pending }
        guard !unlockRequests.isEmpty else { return }

        let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase

        for entry in unlockRequests {
            let idString = entry.id.uuidString
            guard !syncedUnlockRequestIDs.contains(idString) else { continue }

            let recordID = CKRecord.ID(recordName: "BBEventLog_\(idString)")
            let record = CKRecord(recordType: "BBEventLog", recordID: recordID)
            record["eventID"] = idString
            record["deviceID"] = entry.deviceID.rawValue
            record["familyID"] = entry.familyID.rawValue
            record["eventType"] = entry.eventType.rawValue
            record["details"] = entry.details
            record["timestamp"] = entry.timestamp as NSDate

            do {
                try await db.save(record)
                syncedUnlockRequestIDs.insert(idString)
                try? storage.updateEventUploadState(ids: [entry.id], state: .uploaded)
                NSLog("[Tunnel] Synced unlock request to CloudKit: \(entry.details?.prefix(60) ?? "?")")
            } catch {
                NSLog("[Tunnel] Failed to sync unlock request: \(error.localizedDescription)")
            }
        }
    }

    /// Sync pending app reviews to CloudKit (both resolved and unresolved).
    /// Child picks apps → reviews saved locally → tunnel pushes to CloudKit immediately.
    /// ShieldConfiguration later resolves names → tunnel updates the CloudKit records.
    private func syncResolvedPendingReviews() async {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard let needsSync = defaults?.object(forKey: "pendingReviewNeedsSync") as? Double,
              needsSync > 0 else { return }

        guard let data = storage.readRawData(forKey: "pending_review_local.json"),
              let reviews = try? JSONDecoder().decode([PendingAppReview].self, from: data),
              !reviews.isEmpty else { return }

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        // Build records for all reviews
        var records: [CKRecord] = []
        for review in reviews {
            let recordID = CKRecord.ID(recordName: "BBPendingAppReview_\(review.id.uuidString)")
            let record = CKRecord(recordType: "BBPendingAppReview", recordID: recordID)
            record["familyID"] = review.familyID.rawValue
            record["profileID"] = review.childProfileID.rawValue
            record["deviceID"] = review.deviceID.rawValue
            record["appFingerprint"] = review.appFingerprint
            record["appName"] = review.appName
            record["appBundleID"] = review.bundleID
            record["nameResolved"] = (review.nameResolved ? 1 : 0) as NSNumber
            record["createdAt"] = review.createdAt as NSDate
            record["updatedAt"] = review.updatedAt as NSDate
            records.append(record)
        }

        // Use CKModifyRecordsOperation with .changedKeys so updates work
        // (db.save() would fail with serverRecordChanged on second sync).
        let op = CKModifyRecordsOperation(recordsToSave: records)
        op.savePolicy = .changedKeys
        op.isAtomic = false
        op.qualityOfService = .userInitiated

        var synced = 0
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                op.perRecordSaveBlock = { _, result in
                    if case .success = result { synced += 1 }
                }
                db.add(op)
            }
        } catch {
            NSLog("[Tunnel] Failed to sync pending reviews: \(error.localizedDescription)")
        }

        if synced > 0 {
            // Keep unresolved reviews locally so ShieldConfiguration can still update names.
            // Only clear resolved reviews — they don't need further local updates.
            let remaining = reviews.filter { !$0.nameResolved }
            if let encoded = try? JSONEncoder().encode(remaining) {
                try? storage.writeRawData(encoded, forKey: "pending_review_local.json")
            }
            defaults?.removeObject(forKey: "pendingReviewNeedsSync")
            NSLog("[Tunnel] Synced \(synced) pending reviews to CloudKit (\(reviews.filter(\.nameResolved).count) named, \(remaining.count) unresolved kept locally)")
        }
    }

    // MARK: - DNS App Name Verification

    /// In-memory buffer of recent app domain sightings for correlation with unverified apps.
    private var recentAppDomainSightings: [(appName: String, domain: String, at: Date)] = []
    private let sightingsLock = NSLock()

    /// Called by DNSProxy when a cataloged app domain is seen.
    /// Buffers sightings for correlation with unverified app watches.
    private func handleAppDomainSeen(appName: String, domain: String, at: Date) {
        sightingsLock.lock()
        recentAppDomainSightings.append((appName, domain, at))
        // Keep only last 5 minutes of sightings
        let cutoff = Date().addingTimeInterval(-300)
        recentAppDomainSightings.removeAll { $0.at < cutoff }
        sightingsLock.unlock()
    }

    /// Periodic check: correlate DNS sightings with unverified app watches.
    /// Runs every 30 seconds (on liveness timer slow path).
    private func checkDNSAppVerification() {
        let watchKey = "unverified_app_watches.json"
        guard let data = storage.readRawData(forKey: watchKey),
              var watches = try? JSONDecoder().decode([UnverifiedAppWatch].self, from: data),
              !watches.isEmpty else { return }

        let now = Date()
        var changed = false

        sightingsLock.lock()
        let sightings = recentAppDomainSightings
        sightingsLock.unlock()

        for i in watches.indices where !watches[i].resolved {
            let watch = watches[i]
            let age = now.timeIntervalSince(watch.unblockedAt)

            // Phase 1: Immediate window (first 120 seconds after unblock)
            if age < 120 {
                let windowSightings = sightings.filter { $0.at > watch.unblockedAt }
                let appNames = Set(windowSightings.map(\.appName))
                let domains = Set(windowSightings.map(\.domain))
                watches[i].immediateDomains = Array(domains)

                // If we see a cataloged app in the immediate window, verify
                if let detected = appNames.first {
                    let childName = watch.childGivenName.lowercased().trimmingCharacters(in: .whitespaces)
                    let detectedLower = detected.lowercased()
                    let isMatch = childName.contains(detectedLower) || detectedLower.contains(childName)

                    watches[i].verifiedName = detected
                    watches[i].deceptionDetected = !isMatch
                    watches[i].resolved = true
                    watches[i].resolvedAt = now
                    changed = true

                    if !isMatch {
                        NSLog("[Tunnel] DNS DECEPTION: child said '\(watch.childGivenName)' but DNS shows '\(detected)'")
                        // Create event for parent
                        Task { await self.reportDeception(watch: watches[i], detectedName: detected) }
                    } else {
                        NSLog("[Tunnel] DNS verified: '\(watch.childGivenName)' matches '\(detected)'")
                    }
                }
            }

            // Phase 2: Ongoing monitoring (up to 7 days)
            if !watches[i].resolved && age < 604800 {
                // Check if any NEW cataloged app domains appeared since the app was allowed
                let postAllowSightings = sightings.filter { $0.at > watch.unblockedAt }
                let newDomains = Set(postAllowSightings.map(\.domain)).subtracting(Set(watch.newDomainsSinceAllow))
                if !newDomains.isEmpty {
                    watches[i].newDomainsSinceAllow.append(contentsOf: newDomains)
                    changed = true

                    // Check if accumulated domains point to a specific app
                    let appCounts = Dictionary(grouping: postAllowSightings, by: \.appName)
                        .mapValues(\.count)
                        .sorted { $0.value > $1.value }

                    if let top = appCounts.first, top.value >= 3 {
                        let childName = watch.childGivenName.lowercased().trimmingCharacters(in: .whitespaces)
                        let detectedLower = top.key.lowercased()
                        let isMatch = childName.contains(detectedLower) || detectedLower.contains(childName)

                        watches[i].verifiedName = top.key
                        watches[i].deceptionDetected = !isMatch
                        watches[i].resolved = true
                        watches[i].resolvedAt = now
                        changed = true

                        if !isMatch {
                            NSLog("[Tunnel] DNS DECEPTION (ongoing): child said '\(watch.childGivenName)' but DNS shows '\(top.key)' (\(top.value) hits)")
                            Task { await self.reportDeception(watch: watches[i], detectedName: top.key) }
                        }
                    }
                }
            }

            // Phase 3: Timeout after 7 days — mark resolved without verification
            if !watches[i].resolved && age >= 604800 {
                watches[i].resolved = true
                watches[i].resolvedAt = now
                changed = true
            }
        }

        if changed {
            if let encoded = try? JSONEncoder().encode(watches) {
                try? storage.writeRawData(encoded, forKey: watchKey)
            }
        }
    }

    /// Report deception to parent via CloudKit event.
    private func reportDeception(watch: UnverifiedAppWatch, detectedName: String) async {
        guard let enrollment = try? keychain.get(ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState) else { return }
        let entry = EventLogEntry(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            eventType: .appNameDeception,
            details: "App name mismatch: child said '\(watch.childGivenName)' but DNS identifies '\(detectedName)'"
        )
        try? storage.appendEventLog(entry)

        // Also update the app name in CloudKit TimeLimitConfig
        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase
        let pred = NSPredicate(format: "appFingerprint == %@ AND profileID == %@",
                               watch.fingerprint, watch.childProfileID.rawValue)
        let query = CKQuery(recordType: "BBTimeLimitConfig", predicate: pred)
        if let results = try? await db.records(matching: query, resultsLimit: 1),
           let record = try? results.matchResults.first?.1.get() {
            record["appName"] = "\(detectedName) (child said: \(watch.childGivenName))" as NSString
            record["updatedAt"] = Date() as NSDate
            _ = try? await db.save(record)
            NSLog("[Tunnel] Updated CloudKit app name to '\(detectedName)' (was '\(watch.childGivenName)')")
        }
    }

    private func sendEmergencyAlert(resolution: ModeStackResolver.Resolution, monitorAge: Int) async {
        guard let enrollment = try? keychain.get(ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState) else { return }
        let details = "EMERGENCY: Shields down, DNS blackhole activated. Mode should be \(resolution.mode.rawValue) (\(resolution.reason)). App dead, Monitor last active \(monitorAge)s ago."
        let entry = EventLogEntry(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            eventType: .enforcementDegraded,
            details: details
        )
        try? storage.appendEventLog(entry)
        // Also try direct CloudKit upload
        do {
            let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase
            let recordID = CKRecord.ID(recordName: "BBEventLog_\(entry.id.uuidString)")
            let record = CKRecord(recordType: "BBEventLog", recordID: recordID)
            record["eventID"] = entry.id.uuidString
            record["deviceID"] = entry.deviceID.rawValue
            record["familyID"] = entry.familyID.rawValue
            record["eventType"] = entry.eventType.rawValue
            record["details"] = details
            record["timestamp"] = entry.timestamp as NSDate
            try await db.save(record)
            NSLog("[Tunnel] Emergency alert uploaded to CloudKit")
        } catch {
            NSLog("[Tunnel] Failed to upload emergency alert: \(error.localizedDescription)")
        }
    }

    // MARK: - Internet Block

    /// Block or unblock internet by reapplying tunnel DNS settings.
    /// When blocked, DNS routes to 127.0.0.1 (blackhole) — no app can resolve any domain.
    /// CloudKit polling continues because the tunnel makes direct IP connections for its own queries.
    private func applyInternetBlock(durationSeconds: Int) {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if durationSeconds > 0 {
            let unblockAt = Date().addingTimeInterval(Double(durationSeconds))
            defaults?.set(unblockAt.timeIntervalSince1970, forKey: "internetBlockedUntil")
            NSLog("[Tunnel] Internet blocked for \(durationSeconds)s (until \(unblockAt))")
        } else {
            defaults?.removeObject(forKey: "internetBlockedUntil")
            NSLog("[Tunnel] Internet unblocked")
        }
        // Reapply network settings with updated DNS
        reapplyNetworkSettings()
    }

    /// Check if internet should be blocked based on current enforcement mode.
    /// Internet is blocked when: device is in .lockedDown mode, emergency blackhole is active,
    /// or legacy internetBlockedUntil flag is set.
    private var isInternetBlocked: Bool {
        return internetBlockedReason != nil
    }

    /// Returns the reason DNS is blackholed, or nil if not blocked.
    /// This reason is written to UserDefaults so the heartbeat can report it to the parent.
    private var internetBlockedReason: String? {
        // Permissions blackhole (FC auth revoked)
        if permissionsBlackholeActive { return "FamilyControls permissions revoked" }
        // Build mismatch blackhole (app needs to launch on new build)
        if buildMismatchBlackholeActive { return "App update pending — open Big Brother" }
        // Emergency blackhole (tunnel last-resort enforcement)
        if emergencyBlackholeActive { return "Emergency — app not running, shields down" }
        // Schedule enforcement blackhole (app dead, schedule says restricted)
        if scheduleBlackholeActive { return "Schedule enforcement — app not running" }
        // Primary: check current mode from policy snapshot or extension shared state
        if let extState = storage.readExtensionSharedState(), extState.currentMode == .lockedDown {
            return "Locked Down mode active"
        }
        if let snap = storage.readPolicySnapshot(),
           snap.effectivePolicy.resolvedMode == .lockedDown {
            return "Locked Down mode active"
        }
        // Legacy: check explicit internetBlockedUntil flag
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard let unblockTimestamp = defaults?.double(forKey: "internetBlockedUntil"),
              unblockTimestamp > 0 else { return nil }
        if Date().timeIntervalSince1970 >= unblockTimestamp {
            defaults?.removeObject(forKey: "internetBlockedUntil")
            return nil
        }
        return "Internet blocked by parent"
    }

    /// Whether the previous reapply had blackhole active. Used to detect transitions
    /// into blackhole mode so we can force-drop existing TCP connections.
    private var wasBlackholeActive: Bool = false

    /// Reapply tunnel network settings (DNS) based on current block/safe-search state.
    /// When transitioning INTO blackhole mode, tears down the network interface first
    /// (setTunnelNetworkSettings(nil)) to kill all existing TCP connections. Apps must
    /// reconnect, and new DNS lookups hit the blackhole. This prevents cached DNS /
    /// persistent connections from bypassing the block.
    private func reapplyNetworkSettings() {
        let proxyBlackhole = isInternetBlocked || scheduleBlackholeActive

        // Sync proxy blackhole mode
        dnsProxy?.isBlackholeMode = proxyBlackhole
        if proxyBlackhole {
            NSLog("[Tunnel] DNS proxy blackhole active — \(isInternetBlocked ? "internet blocked" : "schedule enforcement")")
        } else {
            dnsProxy?.reconnectUpstream()
        }

        // Detect transition INTO blackhole — tear down interface to kill existing connections.
        let enteringBlackhole = proxyBlackhole && !wasBlackholeActive
        wasBlackholeActive = proxyBlackhole

        let applySettings = { [weak self] in
            guard let self else { return }
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
            settings.ipv4Settings = ipv4
            settings.mtu = 1500

            let dns = NEDNSSettings(servers: ["198.18.0.1"])
            dns.matchDomains = [""]
            settings.dnsSettings = dns

            self.setTunnelNetworkSettings(settings) { [weak self] error in
                if let error {
                    NSLog("[Tunnel] Failed to reapply settings: \(error.localizedDescription) — will retry on next liveness tick")
                    self?.networkSettingsNeedRetry = true
                } else {
                    NSLog("[Tunnel] Network settings reapplied\(enteringBlackhole ? " (connections reset)" : "")")
                    self?.networkSettingsNeedRetry = false
                }
            }
        }

        if enteringBlackhole {
            // Two-step: nil settings tears down the interface → drops all TCP connections.
            // Then re-apply with blackhole DNS. Apps that try to reconnect hit the blackhole.
            NSLog("[Tunnel] Entering blackhole — tearing down interface to kill existing connections")
            setTunnelNetworkSettings(nil) { _ in
                applySettings()
            }
        } else {
            applySettings()
        }
    }

    // MARK: - Schedule Profile Sync

    /// Sync the schedule profile from CloudKit to App Group.
    /// The tunnel can't register DeviceActivity schedules (no framework access),
    /// but it can write the profile JSON so the Monitor and main app read fresh data.
    /// Runs every 10 minutes to keep the profile current.
    private func syncScheduleProfileIfNeeded() async {
        // Throttle to every 10 minutes
        if let last = lastScheduleSyncAt, Date().timeIntervalSince(last) < 600 { return }
        lastScheduleSyncAt = Date()

        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        // Find which schedule profile is assigned to this device
        let devicePredicate = NSPredicate(format: "deviceID == %@", enrollment.deviceID.rawValue)
        let deviceQuery = CKQuery(recordType: "BBChildDevice", predicate: devicePredicate)

        do {
            let (deviceResults, _) = try await db.records(matching: deviceQuery, resultsLimit: 1)
            guard let deviceRecord = try deviceResults.first?.1.get(),
                  let scheduleProfileID = deviceRecord["scheduleProfileID"] as? String else { return }

            // Fetch all schedule profiles for this family
            let profilePredicate = NSPredicate(format: "familyID == %@", enrollment.familyID.rawValue)
            let profileQuery = CKQuery(recordType: "BBScheduleProfile", predicate: profilePredicate)
            let (profileResults, _) = try await db.records(matching: profileQuery, resultsLimit: 20)

            for (_, result) in profileResults {
                guard let record = try? result.get() else { continue }
                let recordID = record.recordID.recordName
                // Match by profile ID (record name format: BBScheduleProfile_<UUID>)
                guard recordID.contains(scheduleProfileID) else { continue }

                // Decode the profile
                guard let name = record["name"] as? String,
                      let familyID = record["familyID"] as? String else { continue }

                var unlockedWindows: [ActiveWindow] = []
                var lockedWindows: [ActiveWindow] = []

                if let freeJSON = record["freeWindowsJSON"] as? String,
                   let freeData = freeJSON.data(using: .utf8) {
                    unlockedWindows = (try? JSONDecoder().decode([ActiveWindow].self, from: freeData)) ?? []
                }
                if let essJSON = record["essentialWindowsJSON"] as? String,
                   let essData = essJSON.data(using: .utf8) {
                    lockedWindows = (try? JSONDecoder().decode([ActiveWindow].self, from: essData)) ?? []
                }

                let lockedModeRaw = record["lockedMode"] as? String ?? "restricted"
                let lockedMode = LockMode.from(lockedModeRaw) ?? .restricted

                var exceptionDates: [Date] = []
                if let exJSON = record["exceptionDatesJSON"] as? String,
                   let exData = exJSON.data(using: .utf8) {
                    exceptionDates = (try? JSONDecoder().decode([Date].self, from: exData)) ?? []
                }

                let updatedAt: Date
                if let ts = record["updatedAt"] as? Date {
                    updatedAt = ts
                } else {
                    updatedAt = record.modificationDate ?? Date()
                }

                let profile = ScheduleProfile(
                    id: UUID(uuidString: scheduleProfileID) ?? UUID(),
                    familyID: FamilyID(rawValue: familyID),
                    name: name,
                    unlockedWindows: unlockedWindows,
                    lockedWindows: lockedWindows,
                    lockedMode: lockedMode,
                    exceptionDates: exceptionDates,
                    updatedAt: updatedAt
                )

                // Compare with local — check all fields, not just windows
                let local = storage.readActiveScheduleProfile()
                if local != profile {
                    try? storage.writeActiveScheduleProfile(profile)
                    NSLog("[Tunnel] Schedule profile synced: \(name) (\(profile.lockedWindows.count) locked, \(profile.unlockedWindows.count) unlocked windows)")
                }
                break
            }
        } catch {
            // Best-effort sync
        }
    }

    // MARK: - Command Polling

    /// Poll CloudKit for pending commands and handle simple ones directly.
    /// Handles: requestHeartbeat, requestDiagnostics.
    /// Other commands are left for the main app to process.
    private func pollAndProcessCommands() async {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        // Query for pending commands targeting this device or child profile
        let predicate = NSPredicate(
            format: "familyID == %@ AND status == %@",
            enrollment.familyID.rawValue, "pending"
        )
        let query = CKQuery(recordType: "BBRemoteCommand", predicate: predicate)

        // Track processed command IDs to prevent re-execution.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        var processedByTunnel = Set(defaults?.stringArray(forKey: "tunnelProcessedCommandIDs") ?? [])

        do {
            let (results, _) = try await db.records(matching: query, resultsLimit: 25)
            for (_, result) in results {
                guard let record = try? result.get() else { continue }
                let actionJSON = record["actionJSON"] as? String ?? ""
                let commandID = record.recordID.recordName
                let targetType = record["targetType"] as? String ?? ""
                let targetID = record["targetID"] as? String ?? ""

                // Skip commands already processed by this tunnel instance
                guard !processedByTunnel.contains(commandID) else { continue }

                // Check if this command targets our device FIRST —
                // never mark another child's commands as applied.
                let deviceIDStr = enrollment.deviceID.rawValue
                let childIDStr = enrollment.childProfileID.rawValue
                let isTargeted: Bool
                switch targetType {
                case "device":  isTargeted = targetID == deviceIDStr
                case "child":   isTargeted = targetID == childIDStr
                case "all":     isTargeted = true
                default:        isTargeted = false
                }
                guard isTargeted else { continue }

                // Skip expired commands — use the same 24-hour window as the main app.
                // Previously 30 minutes, which caused commands valid for the app to be
                // silently dropped when the app was dead for hours.
                if let issuedAt = record["issuedAt"] as? Date,
                   Date().timeIntervalSince(issuedAt) > AppConstants.defaultCommandExpirySeconds {
                    processedByTunnel.insert(commandID)
                    NSLog("[Tunnel] Skipping expired command \(commandID) (issued \(Int(Date().timeIntervalSince(issuedAt)))s ago)")
                    continue
                }

                processedByTunnel.insert(commandID)

                // Handle simple commands from the tunnel.
                // Parse the action type from JSON to match exactly (not substring).
                let tunnelAction = Self.parseTunnelActionType(from: actionJSON)
                if tunnelAction == "requestHeartbeat" {
                    await sendHeartbeatFromTunnel(reason: "command")
                    record["status"] = "applied"
                    _ = try? await db.save(record)
                    NSLog("[Tunnel] Processed requestHeartbeat command: \(commandID)")
                } else if tunnelAction == "requestDiagnostics" {
                    // Always handle from tunnel — the main app may be suspended
                    // even when mainAppAlive is true. Both tunnel and app can
                    // upload reports; the parent sees whichever arrives.
                    await collectAndUploadDiagnostics(enrollment: enrollment)
                    record["status"] = "applied"
                    _ = try? await db.save(record)
                    NSLog("[Tunnel] Processed requestDiagnostics command: \(commandID)")
                } else if tunnelAction == "blockInternet" {
                    // Legacy: internet blocking is now mode-driven.
                    // Just reapply network settings — tunnel reads mode from App Group.
                    reapplyNetworkSettings()
                    record["status"] = "applied"
                    _ = try? await db.save(record)
                    NSLog("[Tunnel] Processed blockInternet (mode-driven): \(commandID)")
                } else if let tunnelAction,
                          Self.isTunnelProcessableAction(tunnelAction) {
                    // Always process mode commands from the tunnel — don't gate on mainAppAlive.
                    // Push notifications may be broken (iCloud account change, MDM removal),
                    // so the app can't be relied on to wake and process commands.
                    // The tunnel polls every 30s and is the reliable fallback.
                    // Dedup via processedCommandIDs prevents double application if both
                    // the tunnel and main app process the same command.
                    await handleModeCommandFromTunnel(
                        actionType: tunnelAction,
                        actionJSON: actionJSON,
                        record: record,
                        enrollment: enrollment,
                        db: db
                    )
                    NSLog("[Tunnel] Processed mode command \(tunnelAction): \(commandID) (appAlive=\(mainAppAlive))")
                }
                // Other commands are left for the main app
            }
        } catch {
            // Silently fail — command polling is best-effort
        }

        // Persist processed IDs (cap at 200 to prevent unbounded growth)
        if processedByTunnel.count > 200 {
            processedByTunnel = Set(processedByTunnel.suffix(200))
        }
        defaults?.set(Array(processedByTunnel), forKey: "tunnelProcessedCommandIDs")
    }

    /// Parse the top-level action type from a command's JSON string.
    /// Returns the exact action key (e.g. "requestHeartbeat") or nil if unparseable.
    private static func parseTunnelActionType(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // CommandAction encodes as { "actionType": { ...params } } or just "actionType"
        // Try the single-key dictionary pattern first, then fall back to "type" field.
        if obj.count == 1, let key = obj.keys.first {
            return key
        }
        return obj["type"] as? String
    }

    /// Whether the given action type is a mode-changing command that the tunnel
    /// should handle when the main app is dead.
    private static func isTunnelProcessableAction(_ action: String) -> Bool {
        switch action {
        case "setMode", "temporaryUnlock", "timedUnlock", "lockUntil", "returnToSchedule",
             "grantExtraTime", "blockAppForToday", "removeTimeLimit":
            return true
        default:
            return false
        }
    }

    /// Handle a mode-changing command from the tunnel when the main app is dead.
    /// Writes state files to App Group and sends a notification to prompt the user
    /// to open the app (which triggers AppLaunchRestorer for ManagedSettings).
    private func handleModeCommandFromTunnel(
        actionType: String,
        actionJSON: String,
        record: CKRecord,
        enrollment: ChildEnrollmentState,
        db: CKDatabase
    ) async {
        let jsonData = actionJSON.data(using: .utf8)
        let jsonObj = jsonData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        // Determine the target mode from the command.
        let targetMode: LockMode?
        var tempUnlockDuration: Int?

        switch actionType {
        case "setMode":
            // JSON: { "setMode": { "mode": "locked" } } or { "setMode": "locked" }
            if let params = jsonObj?["setMode"] {
                if let modeStr = params as? String {
                    targetMode = LockMode.from(modeStr)
                } else if let dict = params as? [String: Any],
                          let modeStr = dict["_0"] as? String ?? dict["mode"] as? String {
                    targetMode = LockMode.from(modeStr)
                } else {
                    targetMode = nil
                }
            } else {
                targetMode = nil
            }

        case "temporaryUnlock":
            // JSON: { "temporaryUnlock": { "durationSeconds": 900 } }
            targetMode = .unlocked
            if let params = jsonObj?["temporaryUnlock"] as? [String: Any] {
                tempUnlockDuration = params["durationSeconds"] as? Int
            }

        case "returnToSchedule":
            // Use schedule to determine mode
            if let profile = storage.readActiveScheduleProfile() {
                targetMode = profile.resolvedMode(at: Date())
            } else {
                targetMode = .restricted
            }

        case "lockUntil":
            targetMode = .locked

        case "timedUnlock":
            // Timed unlock has penalty + free phases — keep current lock mode during penalty.
            // The tunnel can't register DeviceActivity, so just ensure locked state is set
            // and let the main app handle the full timed unlock lifecycle.
            targetMode = storage.readActiveScheduleProfile()?.lockedMode ?? .restricted

        case "grantExtraTime":
            // { "grantExtraTime": { "appFingerprint": "...", "extraMinutes": 30 } }
            if let params = jsonObj?["grantExtraTime"] as? [String: Any],
               let fingerprint = params["appFingerprint"] as? String,
               let extraMinutes = params["extraMinutes"] as? Int {
                handleGrantExtraTimeFromTunnel(fingerprint: fingerprint, extraMinutes: extraMinutes)
            }
            // Mark as applied
            record["status"] = "applied"
            _ = try? await db.save(record)
            return

        case "blockAppForToday":
            // { "blockAppForToday": { "appFingerprint": "..." } }
            if let params = jsonObj?["blockAppForToday"] as? [String: Any],
               let fingerprint = params["appFingerprint"] as? String {
                handleBlockAppForTodayFromTunnel(fingerprint: fingerprint)
            }
            record["status"] = "applied"
            _ = try? await db.save(record)
            return

        case "removeTimeLimit":
            // { "removeTimeLimit": { "appFingerprint": "..." } }
            if let params = jsonObj?["removeTimeLimit"] as? [String: Any],
               let fingerprint = params["appFingerprint"] as? String {
                handleRemoveTimeLimitFromTunnel(fingerprint: fingerprint)
            }
            record["status"] = "applied"
            _ = try? await db.save(record)
            return

        default:
            targetMode = nil
        }

        guard let mode = targetMode else {
            NSLog("[Tunnel] Could not determine target mode from \(actionType) command")
            return
        }

        // 1. Write TemporaryUnlockState if this is a temporary unlock
        if actionType == "temporaryUnlock", let duration = tempUnlockDuration, duration > 0 {
            let now = Date()
            let expiresAt = now.addingTimeInterval(Double(duration))
            let currentMode = ModeStackResolver.resolve(storage: storage).mode
            let unlockState = TemporaryUnlockState(
                unlockID: UUID(),
                origin: .remoteCommand,
                previousMode: currentMode == .unlocked ? .restricted : currentMode,
                startedAt: now,
                expiresAt: expiresAt
            )
            try? storage.writeTemporaryUnlockState(unlockState)
        } else if actionType != "temporaryUnlock" {
            // Non-temporary command — clear any stale temp unlock state
            try? storage.clearTemporaryUnlockState()
        }

        // 2. Write corrected PolicySnapshot
        let existingSnapshot = storage.readPolicySnapshot()
        let existingPolicy = existingSnapshot?.effectivePolicy
        let isTemp = actionType == "temporaryUnlock"
        let correctedPolicy = EffectivePolicy(
            resolvedMode: mode,
            isTemporaryUnlock: isTemp,
            temporaryUnlockExpiresAt: isTemp ? storage.readTemporaryUnlockState()?.expiresAt : nil,
            shieldedCategoriesData: existingPolicy?.shieldedCategoriesData,
            allowedAppTokensData: existingPolicy?.allowedAppTokensData,
            warnings: existingPolicy?.warnings ?? [],
            policyVersion: (existingPolicy?.policyVersion ?? 0) + 1
        )
        let correctedSnapshot = PolicySnapshot(
            source: .commandApplied,
            trigger: "Tunnel: \(actionType) while app dead → \(mode.rawValue)",
            effectivePolicy: correctedPolicy
        )
        _ = try? storage.commitCorrectedSnapshot(correctedSnapshot)

        // 3. Update ExtensionSharedState so the Monitor picks up the change
        let extState = storage.readExtensionSharedState()
        let newExtState = ExtensionSharedState(
            currentMode: mode,
            isTemporaryUnlock: isTemp,
            temporaryUnlockExpiresAt: isTemp ? storage.readTemporaryUnlockState()?.expiresAt : nil,
            authorizationAvailable: extState?.authorizationAvailable ?? true,
            enforcementDegraded: extState?.enforcementDegraded ?? false,
            shieldConfig: extState?.shieldConfig ?? ShieldConfig(),
            writtenAt: Date(),
            policyVersion: (extState?.policyVersion ?? 0) + 1
        )
        try? storage.writeExtensionSharedState(newExtState)

        // 4. DNS enforcement — only for lockedDown (permanent) and unlock (release).
        // Restricted/locked modes use ManagedSettings shields only (applied by Monitor).
        // DNS blackhole would cut ALL internet, which is wrong for restricted mode.
        if mode == .unlocked {
            // Release ALL blackholes — kid should have internet immediately
            if emergencyBlackholeActive { deactivateEmergencyBlackhole() }
            if scheduleBlackholeActive { scheduleBlackholeActive = false }
            pendingShieldConfirmation = nil
            dnsProxy?.isBlackholeMode = false
            reapplyNetworkSettings()
            flushBlockStateToDefaults()
            NSLog("[Tunnel] DNS released — unlocked mode, shields will clear via Monitor")
        } else if mode == .lockedDown {
            // Permanent DNS blackhole — lockedDown means no internet
            reapplyNetworkSettings()
            flushBlockStateToDefaults()
        } else {
            // Restricted/locked: Monitor applies ManagedSettings shields via stopMonitoring trigger.
            // No DNS blackhole — internet stays up, only app access changes.
            reapplyNetworkSettings()
            flushBlockStateToDefaults()
            NSLog("[Tunnel] Mode \(mode.rawValue) — Monitor will apply shields via stopMonitoring trigger")
        }

        // 5. Mark returnToSchedule flag
        if actionType == "returnToSchedule" {
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(true, forKey: "scheduleDrivenMode")
        } else if actionType == "setMode" {
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(false, forKey: "scheduleDrivenMode")
        }

        // 6. Mark command as applied in CloudKit
        record["status"] = "applied"
        _ = try? await db.save(record)

        // 7. Also mark in App Group so main app doesn't re-process
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        var appProcessed = defaults?.stringArray(forKey: "tunnelAppliedCommandIDs") ?? []
        appProcessed.append(record.recordID.recordName)
        if appProcessed.count > 200 { appProcessed = Array(appProcessed.suffix(200)) }
        defaults?.set(appProcessed, forKey: "tunnelAppliedCommandIDs")

        // Notify the kid about the mode change.
        let notifContent = UNMutableNotificationContent()
        notifContent.title = "Mode Changed"
        notifContent.body = mode == .unlocked ? "Device unlocked — all apps accessible."
            : mode == .locked ? "Device locked — essential apps only."
            : mode == .lockedDown ? "Device locked down — no internet."
            : "Device restricted — limited apps available."
        notifContent.sound = .default
        let notifRequest = UNNotificationRequest(
            identifier: "mode-change-\(record.recordID.recordName)",
            content: notifContent,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(notifRequest)

        // Signal Monitor to re-apply ManagedSettings from the snapshot we wrote.
        signalMonitorToReconcile()
    }

    /// Request a local notification to prompt the child to open the app
    /// so ManagedSettings enforcement can be applied by the main process.
    private func requestAppLaunchNotification(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Parental Settings Updated"
        content.body = "Tap to apply new settings."
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "tunnel-command-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Collect a diagnostic report from the tunnel. Includes schedule + restriction
    /// details from App Group so the parent can debug desync issues even when the
    /// main app is suspended.
    private func collectAndUploadDiagnostics(enrollment: ChildEnrollmentState) async {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let allLogs = storage.readDiagnosticEntries(category: nil)
        let recentLogs = Array(allLogs.suffix(50))

        var flags: [String: String] = [
            "source": "vpnTunnel",
            "mainAppAlive": "\(mainAppAlive)",
            "tunnelOwnsHeartbeat": "\(tunnelOwnsHeartbeat)",
            "buildMismatchBlackholeActive": "\(buildMismatchBlackholeActive)",
            "emergencyBlackholeActive": "\(emergencyBlackholeActive)",
            "scheduleBlackholeActive": "\(scheduleBlackholeActive)",
            "isInternetBlocked": "\(isInternetBlocked)",
            "lastHeartbeatSentAt": "\(defaults?.double(forKey: "lastHeartbeatSentAt") ?? 0)",
            "mainAppLastActiveAt": "\(defaults?.double(forKey: "mainAppLastActiveAt") ?? 0)",
            "tunnelLastActiveAt": "\(defaults?.double(forKey: "tunnelLastActiveAt") ?? 0)",
            "mainAppLastLaunchedBuild": "\(defaults?.integer(forKey: "mainAppLastLaunchedBuild") ?? 0)",
        ]

        // === MODE STACK RESOLUTION (source of truth) ===
        let modeResolution = ModeStackResolver.resolve(storage: storage)
        flags["modeStack.expectedMode"] = modeResolution.mode.rawValue
        flags["modeStack.reason"] = modeResolution.reason
        flags["modeStack.isTemporary"] = "\(modeResolution.isTemporary)"

        // === TEMPORARY UNLOCK STATE ===
        if let temp = storage.readTemporaryUnlockState() {
            flags["tempUnlock.origin"] = temp.origin.rawValue
            flags["tempUnlock.previousMode"] = temp.previousMode.rawValue
            flags["tempUnlock.expiresAt"] = "\(temp.expiresAt)"
            flags["tempUnlock.isExpired"] = "\(temp.isExpired(at: Date()))"
            flags["tempUnlock.remainingSeconds"] = "\(Int(temp.expiresAt.timeIntervalSince(Date())))"
        }

        // === POLICY SNAPSHOT ===
        if let snap = storage.readPolicySnapshot() {
            flags["snapshot.generation"] = "\(snap.generation)"
            flags["snapshot.source"] = snap.source.rawValue
            flags["snapshot.resolvedMode"] = snap.effectivePolicy.resolvedMode.rawValue
            flags["snapshot.isTemporaryUnlock"] = "\(snap.effectivePolicy.isTemporaryUnlock)"
            flags["snapshot.policyVersion"] = "\(snap.effectivePolicy.policyVersion)"
            flags["snapshot.createdAt"] = "\(snap.createdAt)"
        }

        // === EXTENSION SHARED STATE ===
        if let ext = storage.readExtensionSharedState() {
            flags["extState.currentMode"] = ext.currentMode.rawValue
            flags["extState.isTemporaryUnlock"] = "\(ext.isTemporaryUnlock)"
            flags["extState.writtenAt"] = "\(ext.writtenAt)"
            flags["extState.policyVersion"] = "\(ext.policyVersion)"
        }

        // === AUTO-DIAGNOSIS ===
        var diagnosis: [String] = []
        if modeResolution.mode == .unlocked && emergencyBlackholeActive {
            diagnosis.append("EMERGENCY BLACKHOLE ACTIVE but device should be unlocked — deactivating")
        }
        if let ext = storage.readExtensionSharedState(),
           ext.currentMode != modeResolution.mode {
            diagnosis.append("ExtensionSharedState (\(ext.currentMode.rawValue)) != ModeStackResolver (\(modeResolution.mode.rawValue))")
        }
        if let snap = storage.readPolicySnapshot(),
           snap.effectivePolicy.resolvedMode != modeResolution.mode {
            diagnosis.append("PolicySnapshot (\(snap.effectivePolicy.resolvedMode.rawValue)) != ModeStackResolver (\(modeResolution.mode.rawValue))")
        }
        // Check FC auth from App Group (written by main app)
        let fcAuth = defaults?.string(forKey: "familyControlsAuthStatus")
        if let fcAuth, fcAuth != "approved" && fcAuth != "authorized" {
            diagnosis.append("⚠️ FC Auth: \(fcAuth) — ManagedSettings writes will fail!")
        }

        if !diagnosis.isEmpty {
            flags["🔍 DIAGNOSIS"] = diagnosis.joined(separator: " | ")
        }

        // === DEVICE ACTIVITY (reconciliation health) ===
        let daCenter = DeviceActivityCenter()
        let allActivities = daCenter.activities
        let reconciliation = allActivities.filter { $0.rawValue.hasPrefix("bigbrother.reconciliation") }
        let usageTracking = allActivities.filter { $0.rawValue.hasPrefix("bigbrother.usagetracking") }
        flags["deviceActivity.total"] = "\(allActivities.count)"
        flags["deviceActivity.reconciliation"] = "\(reconciliation.count) [\(reconciliation.map(\.rawValue).joined(separator: ", "))]"
        flags["deviceActivity.usageTracking"] = "\(usageTracking.count)"
        flags["deviceActivity.monitorLastActiveAt"] = "\(defaults?.double(forKey: "monitorLastActiveAt") ?? 0)"
        flags["deviceActivity.monitorLastReconcileAt"] = "\(defaults?.double(forKey: "monitorLastReconcileAt") ?? 0)"

        // Restrictions from App Group
        if let r = storage.readDeviceRestrictions() {
            flags["restrictions.denyAppRemoval"] = "\(r.denyAppRemoval)"
            flags["restrictions.denyExplicitContent"] = "\(r.denyExplicitContent)"
            flags["restrictions.denyWebWhenLocked"] = "\(r.denyWebWhenLocked)"
            flags["restrictions.lockAccounts"] = "\(r.lockAccounts)"
            flags["restrictions.requireAutoDateTime"] = "\(r.requireAutomaticDateAndTime)"
        } else {
            flags["restrictions"] = "nil (using defaults)"
        }

        // Schedule from App Group
        if let profile = storage.readActiveScheduleProfile() {
            let now = Date()
            flags["schedule.name"] = profile.name
            flags["schedule.id"] = profile.id.uuidString.prefix(8).description
            flags["schedule.resolvedMode"] = profile.resolvedMode(at: now).rawValue
            flags["schedule.inUnlockedWindow"] = "\(profile.isInUnlockedWindow(at: now))"
            flags["schedule.inLockedWindow"] = "\(profile.isInLockedWindow(at: now))"
            flags["schedule.lockedMode"] = profile.lockedMode.rawValue
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

        let report = DiagnosticReport(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            appBuildNumber: AppConstants.appBuildNumber,
            deviceRole: "child (via tunnel)",
            locationMode: defaults?.string(forKey: "locationTrackingMode") ?? "unknown",
            coreMotionAvailable: true,
            coreMotionMonitoring: false,
            isMoving: false,
            isDriving: false,
            vpnTunnelStatus: "running (self)",
            familyControlsAuth: UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.string(forKey: "familyControlsAuthStatus") ?? "unknown (tunnel)",
            currentMode: storage.readPolicySnapshot()?.effectivePolicy.resolvedMode.rawValue ?? "unknown",
            shieldsActive: defaults?.object(forKey: "shieldsActiveAtLastHeartbeat") as? Bool ?? false,
            shieldedAppCount: 0,
            shieldCategoryActive: defaults?.object(forKey: "shieldsActiveAtLastHeartbeat") as? Bool ?? false,
            lastShieldChangeReason: defaults?.string(forKey: "lastShieldChangeReason"),
            flags: flags,
            recentLogs: recentLogs
        )

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase
        let ckRecord = CKRecord(recordType: "BBDiagnosticReport",
                                recordID: CKRecord.ID(recordName: "BBDiagnosticReport_\(report.id.uuidString)"))
        ckRecord["deviceID"] = enrollment.deviceID.rawValue
        ckRecord["familyID"] = enrollment.familyID.rawValue
        ckRecord["timestamp"] = Date() as NSDate
        if let json = try? JSONEncoder().encode(report),
           let str = String(data: json, encoding: .utf8) {
            ckRecord["diagJSON"] = str
        }
        _ = try? await db.save(ckRecord)
        NSLog("[Tunnel] Diagnostic report uploaded (\(recentLogs.count) log entries)")
    }

    // MARK: - CloudKit Heartbeat

    /// Send a lightweight heartbeat to CloudKit from the tunnel extension.
    /// Uses the same BBHeartbeat record type and deviceID as the main app.
    private func sendHeartbeatFromTunnel(reason: String) async {
        // Flush screen time so heartbeat reports current numbers.
        flushScreenTimeSession()

        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else {
            NSLog("[Tunnel] No enrollment state — cannot send heartbeat")
            return
        }

        // Check if main app recently sent a heartbeat (coordination to avoid duplicates).
        // But ONLY skip if the main app is actually alive — if it's dead, we must send regardless.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let lastHBAt = defaults?.double(forKey: "lastHeartbeatSentAt") ?? 0
        if mainAppAlive && lastHBAt > 0 && Date().timeIntervalSince1970 - lastHBAt < 120 {
            NSLog("[Tunnel] Main app sent heartbeat recently — skipping")
            return
        }

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        let recordID = CKRecord.ID(recordName: "BBHeartbeat_\(enrollment.deviceID.rawValue)")
        let record: CKRecord

        // Fetch existing record to preserve change tag
        do {
            record = try await db.record(for: recordID)
        } catch {
            record = CKRecord(recordType: "BBHeartbeat", recordID: recordID)
        }

        // Core identity
        record["deviceID"] = enrollment.deviceID.rawValue
        record["familyID"] = enrollment.familyID.rawValue
        record["timestamp"] = Date() as NSDate
        record["hbAppBuildNumber"] = AppConstants.appBuildNumber as NSNumber
        let mainAppBuild = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.integer(forKey: "mainAppLastLaunchedBuild") ?? 0
        if mainAppBuild > 0 {
            record["hbMainAppBuild"] = mainAppBuild as NSNumber
        }
        record["hbSource"] = "vpnTunnel"
        record["hbTunnel"] = 1 as NSNumber

        // FC auth type from App Group (written by main app)
        if let authType = defaults?.string(forKey: "fr.bigbrother.authorizationType") {
            record["hbFCAuthType"] = authType
        }
        // Child auth fail reason (why .child wasn't granted)
        if let failReason = defaults?.string(forKey: "fr.bigbrother.childAuthFailReason") {
            record["hbFCChildFailReason"] = failReason
        }
        // Per-permission status snapshot (written by main app ChildHomeViewModel)
        if let permJSON = defaults?.string(forKey: "permissionSnapshot") {
            record["hbPermissions"] = permJSON
        }

        // Enforcement state — use ModeStackResolver for ground truth
        let policyVersion = storage.readPolicySnapshot()?.effectivePolicy.policyVersion ?? 0
        let modeResolution = ModeStackResolver.resolve(storage: storage)
        record["currentMode"] = modeResolution.mode.rawValue
        record["policyVersion"] = policyVersion as NSNumber

        // Schedule resolved mode — compute fresh so parent sees current state,
        // not the stale value from when the main app last sent a heartbeat.
        if let profile = storage.readActiveScheduleProfile() {
            let now = Date()
            let mode = profile.resolvedMode(at: now)
            let inFree = profile.isInUnlockedWindow(at: now)
            let inLocked = profile.isInLockedWindow(at: now)
            let detail: String
            if inFree { detail = "\(mode.rawValue) (in unlocked window)" }
            else if inLocked { detail = "\(mode.rawValue) (in locked window)" }
            else { detail = mode.rawValue }
            record["hbScheduleResolvedMode"] = detail
        }

        // Screen time + unlock count (tunnel tracks this when main app is dead)
        record["hbScreenTimeMins"] = defaults?.integer(forKey: screenTimeMinutesKey) as NSNumber?
        record["hbUnlockCount"] = defaults?.integer(forKey: screenTimeUnlockCountKey) as NSNumber?

        // Device lock state (tunnel tracks this via Darwin notification)
        var lockState: UInt64 = 0
        if lockNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_get_state(lockNotifyToken, &lockState)
        }
        record["hbLocked"] = (lockState != 0 ? 1 : 0) as NSNumber

        // Battery — changes while app is dead, parent wants current level
        let (batteryLevel, batteryCharging) = await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
            return (level, charging)
        }
        if batteryLevel >= 0 {
            record["batteryLevel"] = batteryLevel as NSNumber
            record["isCharging"] = (batteryCharging ? 1 : 0) as NSNumber
        }

        // Report last-known shield state from main app (persisted to UserDefaults).
        // The tunnel can't import ManagedSettings, but the main app writes this on each heartbeat.
        // Without this, the parent always sees "Shields Down" when the tunnel sends the heartbeat.
        let lastShieldsActive = defaults?.object(forKey: "shieldsActiveAtLastHeartbeat") as? Bool
        if let shieldsActive = lastShieldsActive {
            record["hbShieldsActive"] = (shieldsActive ? 1 : 0) as NSNumber
            // If main app reported shields were up, also report category as active
            // (the tunnel can't distinguish per-app vs category, but if shields are up, both are).
            if shieldsActive {
                record["hbShieldCategoryActive"] = 1 as NSNumber
            }
        }
        // If lastShieldsActive is nil (main app never sent heartbeat), leave fields
        // as-is from the record (may have previous main-app values).

        // DNS blocking state — the tunnel CAN report this directly
        let dnsCount = storage.readEnforcementBlockedDomains().count
            + storage.readTimeLimitBlockedDomains().count
        if dnsCount > 0 {
            record["hbDnsBlockedDomainCount"] = dnsCount as NSNumber
        }

        // Null out fields the tunnel can't provide — prevents stale main-app values
        record["hbDriving"] = nil
        record["hbSpeed"] = nil

        // Skip if in permission-failure backoff period.
        // Permission backoff — but cap at 5 minutes max and always try at least once every 5 min.
        // Previous bug: exponential backoff up to 30 min caused heartbeats to go silent for too long.
        if let backoffUntil = heartbeatPermissionBackoffUntil, Date() < backoffUntil {
            NSLog("[Tunnel] Heartbeat skipped — permission backoff (\(heartbeatPermissionFailures) failures, retry at \(backoffUntil))")
            return
        }
        // Reset backoff if enough time has passed — don't stay backed off forever
        if heartbeatPermissionFailures > 0, let backoffUntil = heartbeatPermissionBackoffUntil, Date() > backoffUntil {
            heartbeatPermissionFailures = max(0, heartbeatPermissionFailures - 1)
        }

        do {
            try await db.save(record)
            heartbeatPermissionFailures = 0 // Reset on success
        } catch {
            // "WRITE operation not permitted" = record owned by a different iCloud account.
            // Delete the stale record and create a fresh one we own.
            let desc = error.localizedDescription.lowercased()
            if desc.contains("permission") || desc.contains("not permitted") {
                heartbeatPermissionFailures += 1
                NSLog("[Tunnel] Heartbeat permission denied (attempt \(heartbeatPermissionFailures)) — deleting stale record and recreating")
                _ = try? await db.deleteRecord(withID: recordID)
                let fresh = CKRecord(recordType: "BBHeartbeat", recordID: recordID)
                for key in record.allKeys() { fresh[key] = record[key] }
                do {
                    try await db.save(fresh)
                    heartbeatPermissionFailures = 0 // Recreate succeeded
                } catch {
                    // Exponential backoff: 1min, 2min, 4min, max 5min.
                    // Heartbeats are critical — never go silent for more than 5 minutes.
                    let backoff = min(60.0 * pow(2.0, Double(heartbeatPermissionFailures - 1)), 300)
                    heartbeatPermissionBackoffUntil = Date().addingTimeInterval(backoff)
                    NSLog("[Tunnel] Heartbeat recreate failed — backing off \(Int(backoff))s")
                    return
                }
            } else {
                NSLog("[Tunnel] Heartbeat failed: \(error.localizedDescription)")
                return
            }
        }

        defaults?.set(Date().timeIntervalSince1970, forKey: "lastHeartbeatSentAt")
        NSLog("[Tunnel] Heartbeat sent (reason: \(reason))")

        // Save daily screen time snapshot (one record per device per day)
        let slotData = (defaults?.dictionary(forKey: screenTimeSlotKey) as? [String: Int]) ?? [:]
        await saveDailyScreenTimeSnapshot(
            db: db,
            enrollment: enrollment,
            minutes: defaults?.integer(forKey: screenTimeMinutesKey) ?? 0,
            unlocks: defaults?.integer(forKey: screenTimeUnlockCountKey) ?? 0,
            date: defaults?.string(forKey: screenTimeDateKey),
            slotSeconds: slotData
        )
    }

    private func saveDailyScreenTimeSnapshot(db: CKDatabase, enrollment: ChildEnrollmentState, minutes: Int, unlocks: Int, date: String?, slotSeconds: [String: Int]) async {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = date ?? fmt.string(from: Date())

        let recordID = CKRecord.ID(recordName: "BBScreenTime_\(enrollment.deviceID.rawValue)_\(dateStr)")
        let stRecord: CKRecord
        do {
            stRecord = try await db.record(for: recordID)
        } catch {
            stRecord = CKRecord(recordType: "BBScreenTime", recordID: recordID)
        }

        stRecord["deviceID"] = enrollment.deviceID.rawValue
        stRecord["familyID"] = enrollment.familyID.rawValue
        stRecord["date"] = dateStr
        stRecord["timestamp"] = Date() as NSDate
        stRecord["minutes"] = minutes as NSNumber
        stRecord["unlocks"] = unlocks as NSNumber

        // Slot data: seconds per 15-minute slot (key = "0"-"95", value = seconds)
        if !slotSeconds.isEmpty,
           let data = try? JSONEncoder().encode(slotSeconds),
           let json = String(data: data, encoding: .utf8) {
            stRecord["slotsJSON"] = json
        }

        do {
            try await db.save(stRecord)
        } catch {
            NSLog("[Tunnel] Screen time snapshot save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Notifications

    private func sendReopenNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Big Brother"
        content.body = "Open Big Brother to restore full monitoring."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "tunnel-reopen",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - DNS Blocklist Persistence

    /// Save the current enforcement blocklist to a last-known key so a future
    /// tunnel start can fall back to it if the main app hasn't written one yet.
    private func persistCurrentBlocklist() {
        let current = storage.readEnforcementBlockedDomains()
        guard !current.isEmpty else { return }
        if let data = try? JSONEncoder().encode(current) {
            try? storage.writeRawData(data, forKey: "tunnel_last_known_blocklist")
        }
    }

    // MARK: - Status

    private func writeTunnelStatus(_ status: String) {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(status, forKey: "tunnelStatus")
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "tunnelLastActiveAt")
    }

    // MARK: - Network Path Monitoring

    private var lastNetworkPathHash: Int = 0

    private func startNetworkPathMonitoring() {
        // Initial snapshot
        lastNetworkPathHash = defaultPath?.hashValue ?? 0
    }

    /// Check if the network path changed and reconnect DNS upstream if needed.
    /// Called every 30 seconds from the liveness timer.
    private func checkNetworkPathAndReconnect() {
        let currentHash = defaultPath?.hashValue ?? 0
        guard currentHash != lastNetworkPathHash, lastNetworkPathHash != 0 else {
            lastNetworkPathHash = currentHash
            return
        }
        lastNetworkPathHash = currentHash
        NSLog("[Tunnel] Network path changed — reconnecting DNS upstream")
        dnsProxy?.reconnectUpstream()

        // Signal main app that the device likely moved (cell tower / WiFi change).
        // The main app's location service checks this flag to re-activate tracking
        // even if it was backgrounded without an active location session.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.set(Date().timeIntervalSince1970, forKey: "tunnelNetworkPathChangedAt")
    }

    // MARK: - Screen Lock Monitoring
    //
    // Tracks screen unlock/lock transitions via Darwin notification.
    // Writes to the same App Group keys as DeviceLockMonitor in the main app,
    // so screen time accumulates even when the main app is dead.

    private let screenTimeDateKey = "screenTimeDate"
    private let screenTimeMinutesKey = "screenTimeMinutes"
    private let screenTimeSecondsKey = "screenTimeAccumulatedSeconds"
    private let screenTimeUnlockCountKey = "screenUnlockCount"

    private func startScreenLockMonitoring() {
        guard lockNotifyToken == NOTIFY_TOKEN_INVALID else { return }

        notify_register_dispatch(
            "com.apple.springboard.lockstate",
            &lockNotifyToken,
            DispatchQueue.main
        ) { [weak self] token in
            var state: UInt64 = 0
            notify_get_state(token, &state)
            let locked = state != 0
            self?.handleScreenLockTransition(locked: locked)
        }

        // Query initial state.
        if lockNotifyToken != NOTIFY_TOKEN_INVALID {
            var state: UInt64 = 0
            notify_get_state(lockNotifyToken, &state)
            let locked = state != 0
            dnsProxy?.isDeviceLocked = locked
            if !locked {
                lastUnlockAt = Date()
            }
            NSLog("[Tunnel] Screen lock monitoring started (initial: \(locked ? "locked" : "unlocked"))")
        }
    }

    private func stopScreenLockMonitoring() {
        if lockNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(lockNotifyToken)
            lockNotifyToken = NOTIFY_TOKEN_INVALID
        }
    }

    private func handleScreenLockTransition(locked: Bool) {
        // Update DNS proxy so it skips activity counting while screen is locked.
        dnsProxy?.isDeviceLocked = locked

        // Always track screen time from the tunnel — it's the only process that
        // reliably receives every lock/unlock transition. The main app's
        // DeviceLockMonitor misses transitions when iOS suspends the app.

        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let today = screenTimeTodayString()

        if locked {
            // Screen locked — accumulate the unlock→lock session
            if let unlockTime = lastUnlockAt {
                let sessionSeconds = Int(Date().timeIntervalSince(unlockTime))
                if sessionSeconds > 0 {
                    addScreenTimeFromTunnel(seconds: sessionSeconds, date: today, defaults: defaults)
                }
            }
            lastUnlockAt = nil
        } else {
            // Screen unlocked — start tracking
            lastUnlockAt = Date()

            // Reset counters on new day
            if defaults?.string(forKey: screenTimeDateKey) != today {
                defaults?.set(today, forKey: screenTimeDateKey)
                defaults?.set(0, forKey: screenTimeSecondsKey)
                defaults?.set(0, forKey: screenTimeMinutesKey)
                defaults?.set(0, forKey: screenTimeUnlockCountKey)
                defaults?.removeObject(forKey: screenTimeSlotKey)
            }

            // Increment unlock count
            let count = defaults?.integer(forKey: screenTimeUnlockCountKey) ?? 0
            defaults?.set(count + 1, forKey: screenTimeUnlockCountKey)
        }
    }

    private let screenTimeSlotKey = "screenTimeSlots"

    private func addScreenTimeFromTunnel(seconds: Int, date: String, defaults: UserDefaults?) {
        // Reset if day changed
        if defaults?.string(forKey: screenTimeDateKey) != date {
            defaults?.set(date, forKey: screenTimeDateKey)
            defaults?.set(0, forKey: screenTimeSecondsKey)
            defaults?.removeObject(forKey: screenTimeSlotKey)
        }

        let accumulated = (defaults?.integer(forKey: screenTimeSecondsKey) ?? 0) + seconds
        defaults?.set(accumulated, forKey: screenTimeSecondsKey)
        defaults?.set(accumulated / 60, forKey: screenTimeMinutesKey)

        // Distribute this session across 15-minute slots
        // Walk backward from now by `seconds` to find which slots this session covers
        let endTime = Date()
        let startTime = endTime.addingTimeInterval(TimeInterval(-seconds))
        let cal = Calendar.current

        var slots = (defaults?.dictionary(forKey: screenTimeSlotKey) as? [String: Int]) ?? [:]

        // Walk through slots from session start to end
        var cursor = startTime
        while cursor < endTime {
            let comps = cal.dateComponents([.hour, .minute], from: cursor)
            let slotIndex = (comps.hour ?? 0) * 4 + (comps.minute ?? 0) / 15
            let slotKey = String(slotIndex)

            // How many seconds fall in this slot?
            let slotEnd = cal.date(bySettingHour: slotIndex / 4, minute: ((slotIndex % 4) + 1) * 15, second: 0, of: cursor) ?? endTime
            let chunkEnd = min(slotEnd, endTime)
            let chunkSeconds = max(1, Int(chunkEnd.timeIntervalSince(cursor)))

            slots[slotKey, default: 0] += chunkSeconds
            cursor = chunkEnd
        }

        defaults?.set(slots, forKey: screenTimeSlotKey)

        NSLog("[Tunnel] Screen time: +\(seconds)s = \(accumulated / 60)m total today")
    }

    /// Flush any in-progress unlock session (call before heartbeat or tunnel stop).
    /// Safe to call from any context — checks that screen is actually unlocked.
    private func flushScreenTimeSession() {
        guard let unlockTime = lastUnlockAt else { return }
        // Double-check screen state to prevent double-counting if lock handler
        // already cleared lastUnlockAt on a different dispatch.
        var lockState: UInt64 = 0
        if lockNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_get_state(lockNotifyToken, &lockState)
        }
        guard lockState == 0 else {
            // Screen is locked — lock handler already counted this session.
            lastUnlockAt = nil
            return
        }
        let sessionSeconds = Int(Date().timeIntervalSince(unlockTime))
        guard sessionSeconds > 0 else { return }
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        addScreenTimeFromTunnel(seconds: sessionSeconds, date: screenTimeTodayString(), defaults: defaults)
        lastUnlockAt = Date()
    }

    private func screenTimeTodayString() -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
