import NetworkExtension
import Network
import CloudKit
import UserNotifications
import UIKit
import DeviceActivity
// notify import removed — was using private com.apple.springboard.lockstate API
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
    private var enforcementLogTimer: DispatchSourceTimer?
    /// Track last uploaded enforcement log entry ID to avoid duplicates.
    private var lastEnforcementLogUploadAt: Date = .distantPast

    /// Timestamp of last IPC ping from the main app.
    /// Seeded from App Group so the tunnel immediately knows if the app has been dead for hours.
    /// Falls back to Date() only if no App Group timestamp exists (first-ever tunnel start).
    private lazy var lastPingFromApp: Date? = {
        let ts = UserDefaults.appGroup?
            .double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
        return ts > 0 ? Date(timeIntervalSince1970: ts) : Date()
    }()

    /// Whether the main app is considered alive. Seeded from App Group timestamp.
    private lazy var mainAppAlive: Bool = {
        let ts = UserDefaults.appGroup?
            .double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
        // If app was active within the last 10 minutes, assume alive
        return ts > 0 && (Date().timeIntervalSince1970 - ts) < AppConstants.appDeathThresholdSeconds
    }()

    /// Prevent duplicate heartbeats — only send from tunnel when main app is dead.
    private var tunnelOwnsHeartbeat = false

    /// DNS proxy for domain activity logging.
    private var dnsProxy: DNSProxy?

    /// Consecutive command poll failures for diagnostic reporting.
    private var commandPollFailureCount = 0

    // MARK: - DNS Failure Recovery Ladder
    //
    // When the tunnel's DNS-dependent CloudKit calls start failing but APNs
    // push is still being received, it's the "DNS bound to dead interface"
    // pattern — the underlying NWUDPSession is in a ready state but can't
    // actually deliver packets on the current network. NWPathMonitor SHOULD
    // catch this but sometimes misses it. This ladder is a self-healing
    // fallback: on sustained CK failures we escalate through progressively
    // more invasive recovery steps, all without requiring the user to touch
    // Settings.
    //
    // Thresholds are in number of consecutive CK failures (poll + heartbeat
    // combined). The liveness timer runs every 10s so ~6 failures ≈ 1 minute.
    private var consecutiveHealthFailures: Int = 0
    private var healthStreakStartedAt: Date?
    private var lastHealthRecoveryAction: Date?
    private var healthRecoveryLevel: Int = 0  // 0 = no recovery fired yet in this streak

    /// Timer for periodic DNS activity sync.
    private var dnsActivitySyncTimer: DispatchSourceTimer?

    /// Overlap guards for liveness timer tasks
    private var isPollingCommands = false
    private var isSyncingUnlockRequests = false

    // MARK: - Screen Lock Monitoring

    // lockNotifyToken removed — was using private API. Lock state now polled from App Group.
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

        // Telemetry: count every tunnel start. A high count = iOS is
        // churning the NE process (memory pressure or an install loop).
        TunnelTelemetry.update { $0.tunnelStarts += 1 }

        // Write tunnel build number to App Group so the main app can detect
        // stale processes (devicectl install updates the tunnel but may not
        // restart the main app).
        UserDefaults.appGroup?
            .set(AppConstants.appBuildNumber, forKey: AppGroupKeys.tunnelBuildNumber)

        // Configure tunnel with DNS-based safe search enforcement.
        // The tunnel interface claims DNS so all DNS queries go through our configured servers.
        // When safe search is enabled, uses CleanBrowsing Family DNS which enforces
        // safe search on Google, Bing, YouTube, and blocks adult content at DNS level.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        // Check if safe search / content filtering is enabled
        let defaults = UserDefaults.appGroup
        let safeSearchEnabled = defaults?.bool(forKey: AppGroupKeys.safeSearchEnabled) ?? false

        // Seed activeBlockReasons from current state at startup
        seedBlockReasonsOnStart()

        // Determine upstream DNS server.
        // Even during blackhole, use a REAL upstream so Apple domains (CloudKit, APNS)
        // still resolve. The proxy itself refuses non-exempt domains in blackhole mode.
        let upstreamDNS: String
        if shouldBlackhole {
            upstreamDNS = "1.1.1.1" // Real DNS — proxy handles blackhole with Apple exemptions
            NSLog("[Tunnel] DNS blackhole active — internet blocked (Apple domains exempt), reasons: \(activeBlockReasons.map(\.rawValue).joined(separator: ", "))")
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
        dnsProxy?.isBlackholeMode = shouldBlackhole

        // b526: Resurrection cache (tunnelLastKnownBlocklist) deleted.
        // The tunnel is a passive consumer of enforcementBlockedDomains.
        // If the list is empty, that's intentional (unlocked or fresh start).
        // The app/Monitor will populate it within seconds of a mode change.

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
            self?.startEnforcementLogSyncTimer()
            self?.startScreenLockMonitoring()
            self?.startNetworkPathMonitoring()
            self?.installCommandPokeObserver()

            #if DEBUG
            // Install Darwin observers used by test_shield_cycle.sh --background
            // to inject mode-change commands without waking the main app.
            // Debug builds only — observer code is compiled out of release.
            if let self {
                TunnelTestCommandReceiver.install(provider: self)
            }
            #endif

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
        stopNetworkPathMonitoring()

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
            // Release ALL safety-net blackholes — app is alive and handles enforcement.
            releaseBlockReasonsOnAppAlive(trigger: "ping")
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

    // MARK: - Enforcement Log Sync

    /// Upload enforcement-related diagnostic entries to CloudKit every 5 minutes.
    /// Parent app can fetch these to see a rolling enforcement timeline across all devices.
    private func startEnforcementLogSyncTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 300) // First at 1 min, then every 5 min
        timer.setEventHandler { [weak self] in
            Task { await self?.syncEnforcementLogs() }
        }
        timer.resume()
        enforcementLogTimer = timer
    }

    private func syncEnforcementLogs() async {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        let db = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier).publicCloudDatabase

        // Read enforcement-relevant entries newer than our last upload.
        let allEntries = storage.readDiagnosticEntries(category: nil)
        let enforcementCategories: Set<DiagnosticCategory> = [.enforcement, .command, .restoration, .auth, .temporaryUnlock]
        let newEntries = allEntries.filter { entry in
            guard enforcementCategories.contains(entry.category),
                  entry.timestamp > lastEnforcementLogUploadAt else { return false }
            // Skip location breadcrumbs — too noisy for enforcement analysis
            if entry.message.hasPrefix("[Location]") { return false }
            return true
        }

        guard !newEntries.isEmpty else { return }

        // Batch upload (max 50 per batch)
        let batch = Array(newEntries.prefix(50))

        // UIDevice.current.name returns generic "iPhone"/"iPad" since iOS 16.
        // Use enrolled display name from App Group cache instead.
        let deviceName: String
        if let data = storage.readRawData(forKey: StorageKeys.cachedEnrollmentIDs),
           let cached = try? JSONDecoder().decode(CachedEnrollmentIDs.self, from: data),
           let name = cached.deviceDisplayName, !name.isEmpty {
            deviceName = name
        } else {
            deviceName = await MainActor.run { UIDevice.current.name }
        }

        let records: [CKRecord] = batch.map { entry in
            let recordID = CKRecord.ID(recordName: "BBEnforcementLog_\(entry.id.uuidString)")
            let record = CKRecord(recordType: "BBEnforcementLog", recordID: recordID)
            record["deviceID"] = enrollment.deviceID.rawValue
            record["familyID"] = enrollment.familyID.rawValue
            record["category"] = entry.category.rawValue
            record["message"] = entry.message
            record["enfDetails"] = entry.details
            record["timestamp"] = entry.timestamp as NSDate
            record["build"] = AppConstants.appBuildNumber as NSNumber
            record["deviceName"] = deviceName
            return record
        }

        do {
            _ = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys)
            lastEnforcementLogUploadAt = batch.last?.timestamp ?? lastEnforcementLogUploadAt
            NSLog("[Tunnel] Enforcement log: uploaded \(batch.count) entries")
        } catch {
            NSLog("[Tunnel] Enforcement log batch failed: \(error.localizedDescription)")
        }

        // Auto-prune records older than 48 hours
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let predicate = NSPredicate(
            format: "%K == %@ AND %K < %@",
            "familyID", enrollment.familyID.rawValue,
            "timestamp", cutoff as NSDate
        )
        let query = CKQuery(recordType: "BBEnforcementLog", predicate: predicate)
        do {
            let (results, _) = try await db.records(matching: query, resultsLimit: 200)
            let idsToDelete = results.compactMap { id, result -> CKRecord.ID? in
                if case .success = result { return id }
                return nil
            }
            if !idsToDelete.isEmpty {
                _ = try await db.modifyRecords(saving: [], deleting: idsToDelete)
                NSLog("[Tunnel] Enforcement log: pruned \(idsToDelete.count) records older than 48h")
            }
        } catch {
            // Non-fatal — old records just accumulate until next prune
        }
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
        let today = screenTimeTodayString()

        let dayChanged = lastDNSDateCheck != nil && lastDNSDateCheck != today
        if dayChanged {
            // Day changed — flush yesterday's data, reset counters
            dnsProxy?.flushToAppGroup()
            dnsProxy?.resetDaily()
            NSLog("[Tunnel] Daily reset for new day")
        }

        // Reset screen time if stored date doesn't match today — handles both
        // day rollover AND fresh tunnel start after deploy (lastDNSDateCheck was nil).
        let defaults = UserDefaults.appGroup
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
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        // Poll commands every 1 second for responsive command delivery.
        // Push notifications for non-mode commands are throttled by iOS, and
        // even mode commands can take 30-90s for the alert push to arrive.
        // The tunnel poll is the reliable backbone — every halving of the
        // cadence cuts kid-perceived latency proportionally.
        //   b619: 5s → 2s cut apply p50 from 5.5s to 2.5s.
        //   b620: 2s → 1s expected to cut apply p50 to ~1.5-2s.
        // Heavier operations (schedule sync, blocklist persist, app liveness)
        // still run every 30 seconds (now every 30th tick at 1s cadence).
        // Fire immediately on startup, then every 1 second. The first poll
        // is critical — a parent command may be waiting in CK from before the
        // tunnel restarted. Without the immediate fire, the first poll is
        // delayed and if it QoS-stalls, the tunnel is blind for the startup window.
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.livenessTickCount += 1

            // Poll for commands every 5 seconds. Skip if previous poll is
            // still running (CK operations have 15s request timeout via the
            // QoS-enabled helpers, so a single poll should never exceed ~20s).
            if !self.isPollingCommands {
                self.isPollingCommands = true
                Task {
                    await self.pollAndProcessCommands()
                    self.isPollingCommands = false
                }
            }
            // Sync unlock requests from App Group to CloudKit (ShieldAction can't make network calls)
            if !self.isSyncingUnlockRequests {
                self.isSyncingUnlockRequests = true
                Task {
                    await self.syncPendingUnlockRequests()
                    self.isSyncingUnlockRequests = false
                }
            }
            // Check if Monitor needs a confirmation heartbeat (fast path for responsiveness)
            self.checkMonitorHeartbeatRequest()

            // b457: transport-recovery moved from the 30 s slow path to the
            // 5 s fast path. A network flap that wedges setTunnelNetworkSettings
            // or the upstream NWUDPSession used to leave the kid without
            // internet for up to 30 seconds before the next retry. Running
            // these every 5 seconds drops worst-case blackout to ~5 seconds.
            //
            // Both are cheap no-ops when nothing is wrong:
            //   - networkSettingsNeedRetry retries only if the previous
            //     setTunnelNetworkSettings actually failed or timed out
            //   - DNSProxy.healthCheck() reconnects only if the upstream
            //     session is cancelled/failed or the pending queue is stalled
            if self.networkSettingsNeedRetry {
                NSLog("[Tunnel] (fast-path) retrying failed network settings application")
                self.reapplyNetworkSettings()
            }
            if self.dnsProxy?.healthCheck() == false {
                // healthCheck returns false if it had to reconnect (wedged upstream)
                self.recordNetworkHealthResult(success: false, reason: "dns_wedge")
            }
            // b457: screen-lock polling on the fast path. The emergency
            // blackhole counter uses `isDeviceLocked` to decide whether to
            // count toward the 5-tick activation threshold. With lock state
            // only refreshed every 30s, a child who unlocked a device with a
            // dead app got up to 30s of unrestricted internet before the
            // counter even started advancing.
            self.pollScreenLockState()
            self.checkFlushRequest()

            // Auto-re-enable DNS filtering if the disable window has passed
            // (or the child clock rewound). Centralizing the side effect here
            // — on a dedicated timer — instead of in the DNSProxy read path
            // eliminates a race where concurrent processes could observe an
            // inconsistent intermediate state and clobber a fresh disable.
            Self.maintainDNSFilteringAutoReenable()

            // Slow path: heavier operations every 30 seconds (every 30th tick at 1s cadence; b620)
            if self.livenessTickCount % 30 == 0 {
                let livenessDefaults = UserDefaults.appGroup
                livenessDefaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.tunnelLastActiveAt)
                livenessDefaults?.set(self.shouldBlackhole, forKey: AppGroupKeys.tunnelInternetBlocked)
                livenessDefaults?.set(self.blockReasonDescription ?? "", forKey: AppGroupKeys.tunnelInternetBlockedReason)
                self.checkAppLiveness()
                self.checkScheduleEnforcement()
                self.checkPendingShieldConfirmation()
                self.checkNetworkPathAndReconnect()
                self.checkDNSDayRollover()
                self.relayEnforcementRefreshIfNeeded()
                self.verifyEnforcementState()
                // pollScreenLockState moved to fast path above — see b457 note.
                Task { await self.syncScheduleProfileIfNeeded() }
                Task { await self.syncResolvedPendingReviews() }
                self.checkDNSAppVerification()
            }
        }
        timer.resume()
        livenessTimer = timer
    }

    /// Observer for the "tunnel.pokeCommands" Darwin notification. Posted by
    /// the main app whenever it receives a CKSubscription push. The tunnel
    /// responds by scheduling an immediate command poll on the next runloop
    /// cycle — bypassing the 1-second cadence. When iOS delivers silent
    /// pushes quickly (often sub-second), this collapses apply latency to
    /// roughly REST + disk-IO time (~1.5s floor).
    private func installCommandPokeObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let provider = Unmanaged<PacketTunnelProvider>.fromOpaque(observer).takeUnretainedValue()
                provider.triggerImmediatePoll(reason: "pushPoke")
            },
            AppConstants.darwinNotifTunnelPokeCommands as CFString,
            nil,
            .deliverImmediately
        )
        NSLog("[Tunnel] installed command-poke Darwin observer")
    }

    /// Fire a one-shot command poll now, outside the fast-path timer. Safe to
    /// call from any thread. If a poll is already in flight (isPollingCommands
    /// true) this is a no-op — the in-flight poll will see any newly-written
    /// command anyway.
    private func triggerImmediatePoll(reason: String) {
        guard !isPollingCommands else {
            NSLog("[Tunnel] pokePoll (\(reason)) skipped — poll already in flight")
            return
        }
        isPollingCommands = true
        NSLog("[Tunnel] pokePoll (\(reason)) firing immediate command poll")
        Task {
            await self.pollAndProcessCommands()
            self.isPollingCommands = false
        }
    }

    private func checkAppLiveness() {
        let defaults = UserDefaults.appGroup

        // Signal 1: IPC pings from the main app
        let pingStale: Bool
        if let lastPing = lastPingFromApp {
            pingStale = Date().timeIntervalSince(lastPing) > AppConstants.appDeathThresholdSeconds
        } else {
            // No pings ever received — check if app has sent any heartbeat recently
            pingStale = true
        }

        // Signal 2: App Group timestamp (backup for IPC)
        let lastActiveAt = defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
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
            let defaults = UserDefaults.appGroup
            defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.appDiedNeedLocationAt)

            // If screen is currently unlocked AND lock state is fresh, start tracking.
            let appDeathDefaults = UserDefaults.appGroup
            let rawLocked = appDeathDefaults?.bool(forKey: AppGroupKeys.isDeviceLocked) ?? true
            let lockedAt = appDeathDefaults?.double(forKey: "isDeviceLockedAt") ?? 0
            let lockFresh = lockedAt > 0 && (Date().timeIntervalSince1970 - lockedAt) < 120
            if lockFresh && !rawLocked {
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
            // b457: hand heartbeat duties back. Previously only the IPC ping
            // path cleared this flag, so a recovery detected via App Group
            // timestamp would leave `tunnelOwnsHeartbeat = true` — meaning
            // the tunnel kept sending duplicate heartbeats alongside the
            // main app's own send, doubling CloudKit writes and risking
            // ETag conflicts.
            tunnelOwnsHeartbeat = false

            // Release ALL safety-net blackholes via the unified helper.
            // Every "app came back alive" site must funnel through here
            // so the release set and side-effects can't drift apart.
            releaseBlockReasonsOnAppAlive(trigger: "appGroupTimestamp")
        }

        // Check if child paused restrictions (testing/emergency mode).
        // Clear ALL blackholes immediately — child needs internet.
        let pauseDefaults = UserDefaults.appGroup
        if pauseDefaults?.object(forKey: AppGroupKeys.restrictionsPausedByChild) != nil {
            if !activeBlockReasons.isEmpty {
                NSLog("[Tunnel] Restrictions paused by child — clearing all DNS blocks")
                let allReasons = Set(DNSBlockReason.allCases)
                batchUpdateBlockReasons(remove: allReasons)
            }
        }

        // Check if internet block has expired
        let blockDefaults = UserDefaults.appGroup
        if let unblockAt = blockDefaults?.double(forKey: AppGroupKeys.internetBlockedUntil),
           unblockAt > 0, Date().timeIntervalSince1970 >= unblockAt {
            blockDefaults?.removeObject(forKey: AppGroupKeys.internetBlockedUntil)
            setBlockReason(.parentCommand, active: false)
            NSLog("[Tunnel] Internet block expired — traffic restored")
            tunnelOwnsHeartbeat = false
        }

        // b462 invariant: `.parentCommand` in `activeBlockReasons` should
        // always be backed by a live `internetBlockedUntil` flag in
        // UserDefaults. If the flag was cleared (by main-app launch,
        // manual unblock, or any other path) but the in-memory reason
        // is still set, clear it. Otherwise the tunnel stays blackholed
        // indefinitely after the flag goes away — the exact
        // Olivia/Daphne/Juliet deadlock. Runs every 5s on the fast path.
        if activeBlockReasons.contains(.parentCommand) {
            let unblockAt = blockDefaults?.double(forKey: AppGroupKeys.internetBlockedUntil) ?? 0
            if unblockAt <= 0 {
                NSLog("[Tunnel] .parentCommand invariant: internetBlockedUntil cleared — releasing reason")
                setBlockReason(.parentCommand, active: false)
            }
        }

        // b462: ongoing safety net for stuck build-mismatch blackholes.
        // If `internetBlockedUntil` is still in the future AND was set by
        // Monitor's build-mismatch path, AND the main app has now launched
        // on the current build, clear the block immediately. Otherwise a
        // transient 24h block can linger after the mismatch has already
        // been resolved, which is one of the paths that caused Olivia to
        // lose Safari internet for hours until the app was uninstalled.
        if let unblockAt = blockDefaults?.double(forKey: AppGroupKeys.internetBlockedUntil),
           unblockAt > Date().timeIntervalSince1970,
           blockDefaults?.bool(forKey: AppGroupKeys.buildMismatchDNSBlock) == true {
            let mainBuild = blockDefaults?.integer(forKey: AppGroupKeys.mainAppLastLaunchedBuild) ?? 0
            if mainBuild >= AppConstants.appBuildNumber {
                NSLog("[Tunnel] Clearing stale build-mismatch blackhole — main app on b\(mainBuild)")
                blockDefaults?.removeObject(forKey: AppGroupKeys.internetBlockedUntil)
                blockDefaults?.removeObject(forKey: AppGroupKeys.buildMismatchDNSBlock)
                if activeBlockReasons.contains(.parentCommand) {
                    setBlockReason(.parentCommand, active: false)
                }
            }
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

        // NB: networkSettingsNeedRetry is now retried on the fast path (every
        // 5 s) inside startLivenessTimer. Previously it lived here on the
        // slow path and recovery took up to 30 s after a network flap.

        // Emergency enforcement: if both app and Monitor are dead, screen is unlocked,
        // and device should be restricted/locked — activate DNS blackhole as fallback.
        checkEmergencyEnforcement()

        // Cold-start fix: if the tunnel started with the app already dead,
        // the appDead && mainAppAlive transition never fires (mainAppAlive starts false).
        // Catch this case and take over heartbeat duties.
        if appDead && !tunnelOwnsHeartbeat {
            NSLog("[Tunnel] Cold-start: app already dead on tunnel start — taking over heartbeat")
            tunnelOwnsHeartbeat = true
            Task { await sendHeartbeatFromTunnel(reason: "coldStartAppDead") }
        }
    }

    /// Block internet when FamilyControls Individual authorization is explicitly revoked.
    /// Without FC auth, ManagedSettingsStore writes fail silently — DNS blackhole
    /// is the only enforcement available.
    ///
    /// Only checks FC auth status — NOT the generic allPermissionsGranted flag,
    /// which can be false due to child auth failure (MDM blocks .child auth)
    /// even when Individual auth works fine and shields are fully functional.
    private func checkPermissionsEnforcement() {
        let defaults = UserDefaults.appGroup
        let fcAuth = defaults?.string(forKey: AppGroupKeys.familyControlsAuthStatus)

        // Only blackhole when FC auth is EXPLICITLY denied (child revoked in Settings).
        // nil = never set (first boot) — don't blackhole.
        // "notDetermined" = pre-auth or transient state during app install — don't blackhole.
        // "approved"/"authorized" = working — don't blackhole.
        // "denied" = explicitly revoked by user — blackhole.
        let authOK = fcAuth != "denied"
        let resolution = ModeStackResolver.resolve(storage: storage)
        let shouldBeRestricted = resolution.mode != .unlocked

        // Skip ALL DNS enforcement while restrictions are paused by child.
        let pausedByChild = defaults?.object(forKey: AppGroupKeys.restrictionsPausedByChild) != nil
        if !authOK && shouldBeRestricted && !mainAppAlive && !pausedByChild {
            // Only DNS-blackhole when the app is DEAD. If the app is alive, it handles
            // FC auth degradation via its own UI. Blackholing while the app is alive
            // creates a deadlock: DNS blocked → no CloudKit → can't receive commands.
            if !activeBlockReasons.contains(.permissionsRevoked) {
                NSLog("[Tunnel] FC auth revoked (\(fcAuth ?? "nil")) + app dead + mode \(resolution.mode.rawValue) — blocking internet")
                setBlockReason(.permissionsRevoked, active: true)

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
        } else if activeBlockReasons.contains(.permissionsRevoked) && authOK {
            NSLog("[Tunnel] FC auth restored — unblocking internet")
            setBlockReason(.permissionsRevoked, active: false)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["fc-auth-revoked"])
        }
    }

    private func postOpenAppNag(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Open Big Brother"
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: "bb-open-app", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
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
        record["timestamp"] = Date()
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
        // GUARD: Skip if a temporary unlock is currently active.
        // ModeStackResolver file reads can fail silently in the tunnel context
        // (App Group file locks, iOS data protection). If we proceed without this
        // guard, a failed file read causes ModeStackResolver to resolve to the next
        // stack level (restricted/locked), which triggers a false "stale state"
        // detection and re-applies shields during an active unlock.
        // This matches the guard in verifyEnforcementState().
        let tempUnlock = storage.readTemporaryUnlockState()
            ?? storage.readPolicySnapshot()?.temporaryUnlockState
        if let temp = tempUnlock, temp.expiresAt > Date() {
            return  // Temp unlock active — don't interfere
        }

        // Also check timed unlock (penalty + free phases)
        if let timed = storage.readTimedUnlockInfo(), timed.lockAt > Date() {
            return  // Timed unlock active — don't interfere
        }

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
                controlAuthority: resolution.controlAuthority,
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

        NSLog("[Tunnel] Stale unlock state detected — corrected to \(resolution.mode.rawValue) (ext:\(extStale) snap:\(snapshotStale)). Scheduling Monitor refresh.")
        scheduleEnforcementRefreshActivity(source: "staleUnlock")

        // The tunnel can't write to ManagedSettingsStore, so shields remain cleared.
        // If the device should be restricted and neither the app nor Monitor is running,
        // activate the emergency DNS blackhole as a backstop — it's the only enforcement
        // the tunnel can apply. This prevents the kid from having unrestricted internet
        // while shields are down.
        let staleDefaults = UserDefaults.appGroup
        // Emergency DNS blackhole when shields are confirmed down.
        // For lockedDown: always blackhole when app is dead.
        // For restricted/locked: ONLY blackhole when shields are CONFIRMED down
        // (shieldsActiveAtLastHeartbeat == false). This avoids killing internet
        // at school when the app is merely suspended (shields still work).
        let appActiveAt = staleDefaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
        let appDead = appActiveAt > 0 && Date().timeIntervalSince1970 - appActiveAt > 300 // 5 min
        if resolution.mode != .unlocked && !mainAppAlive && appDead && !activeBlockReasons.contains(.emergencyAppDead) {
            let shieldsConfirmedDown = staleDefaults?.object(forKey: AppGroupKeys.shieldsActiveAtLastHeartbeat) as? Bool == false
            if resolution.mode == .lockedDown || shieldsConfirmedDown {
                NSLog("[Tunnel] \(resolution.mode.rawValue) + app dead + shields \(shieldsConfirmedDown ? "CONFIRMED DOWN" : "lockedDown override") — activating DNS blackhole")
                setBlockReason(.emergencyAppDead, active: true)
            }
        }

        // Nudge the kid to open the app (throttle to once per 5 minutes)
        let now = Date()
        if now.timeIntervalSince(lastStaleUnlockNotificationAt) > 300 {
            lastStaleUnlockNotificationAt = now
            postOpenAppNag("Open Big Brother to update your device settings.")
        }
    }

    private var buildMismatchFirstDetectedAt: Date?

    private func checkBuildMismatchEnforcement() {
        let defaults = UserDefaults.appGroup
        let mainAppBuild = defaults?.integer(forKey: AppGroupKeys.mainAppLastLaunchedBuild) ?? 0
        let tunnelBuild = AppConstants.appBuildNumber

        // Don't DNS-block for build mismatch when device is unlocked — the kid
        // has full access anyway, and blocking DNS during deploys is annoying.
        let resolution = ModeStackResolver.resolve(storage: storage)
        if resolution.mode == .unlocked {
            if activeBlockReasons.contains(.buildMismatch) {
                NSLog("[Tunnel] Build mismatch cleared — device is unlocked, no point blocking DNS")
                buildMismatchFirstDetectedAt = nil
                setBlockReason(.buildMismatch, active: false)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["bb-open-app"])
            }
            return
        }

        if mainAppBuild > 0 && mainAppBuild < tunnelBuild {
            if buildMismatchFirstDetectedAt == nil {
                // First detection — start grace period. The deploy script launches
                // the app right after install, so give it 2 minutes to start and
                // write the new build number before blocking internet.
                buildMismatchFirstDetectedAt = Date()
                NSLog("[Tunnel] Build mismatch: app=b\(mainAppBuild) tunnel=b\(tunnelBuild) — 2-min grace before blocking")

                postOpenAppNag("Open Big Brother to restore internet access.")
            }

            // After 2-minute grace, block internet — but only if app is actually dead.
            // If app is alive (writing timestamps), it can enforce via ManagedSettings
            // even on an old build — DNS blocking is overkill.
            let appRecentlyActive: Bool = {
                let lastActive = defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
                return lastActive > 0 && (Date().timeIntervalSince1970 - lastActive) < 300 // 5 min
            }()

            if !activeBlockReasons.contains(.buildMismatch),
               let detected = buildMismatchFirstDetectedAt,
               Date().timeIntervalSince(detected) > 120,
               !appRecentlyActive {
                NSLog("[Tunnel] Build mismatch grace expired + app dead: app=b\(mainAppBuild) tunnel=b\(tunnelBuild) — blocking internet")
                setBlockReason(.buildMismatch, active: true)
            } else if activeBlockReasons.contains(.buildMismatch) && appRecentlyActive {
                NSLog("[Tunnel] Build mismatch: app is alive (can enforce shields) — releasing DNS block")
                setBlockReason(.buildMismatch, active: false)
            }
        } else if buildMismatchFirstDetectedAt != nil {
            NSLog("[Tunnel] Build mismatch resolved: app=b\(mainAppBuild) tunnel=b\(tunnelBuild) — restoring internet")
            buildMismatchFirstDetectedAt = nil
            setBlockReason(.buildMismatch, active: false)
            Task { await sendHeartbeatFromTunnel(reason: "buildMismatchCleared") }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["bb-open-app"])
        }
    }

    /// Consecutive checks where emergency enforcement conditions are met.
    /// Requires multiple checks to avoid false positives from normal iOS process lifecycle.
    private var emergencyCheckCount: Int = 0
    /// Temporary DNS blackhole while ManagedSettings shields are being applied by Monitor.
    /// Set when tunnel processes a lock/restrict command. Cleared when Monitor confirms shields.
    struct PendingShieldConfirmation {
        let targetMode: LockMode
        let requestedAt: Date
    }
    private var pendingShieldConfirmation: PendingShieldConfirmation?

    // MARK: - DNS Block Reasons (consolidated)

    /// Why DNS is being blackholed. Multiple reasons can be active simultaneously.
    enum DNSBlockReason: String, CaseIterable, Comparable {
        case permissionsRevoked      // FC auth explicitly denied
        case buildMismatch           // App needs to launch on new build
        case emergencyAppDead        // App + Monitor dead, device should be restricted
        case scheduledLockedDown     // Schedule says lockedDown, app not running
        case lockedDownMode          // Device is in lockedDown mode (parent command)
        case parentCommand           // Legacy internetBlockedUntil flag
        case pendingShieldConfirmation // Temporary block while Monitor applies shields

        /// Priority order for human-readable description (lower = higher priority).
        static func < (lhs: DNSBlockReason, rhs: DNSBlockReason) -> Bool {
            let order: [DNSBlockReason] = [
                .permissionsRevoked, .buildMismatch, .emergencyAppDead,
                .scheduledLockedDown, .lockedDownMode, .parentCommand,
                .pendingShieldConfirmation
            ]
            return (order.firstIndex(of: lhs) ?? 99) < (order.firstIndex(of: rhs) ?? 99)
        }

        var humanDescription: String {
            switch self {
            case .permissionsRevoked: return "FamilyControls permissions revoked"
            case .buildMismatch: return "App update pending — open Big Brother"
            case .emergencyAppDead: return "Emergency — app not running, shields down"
            case .scheduledLockedDown: return "Schedule enforcement — app not running"
            case .lockedDownMode: return "Locked Down mode active"
            case .parentCommand: return "Internet blocked by parent"
            case .pendingShieldConfirmation: return "Applying parental controls..."
            }
        }

        /// True if this reason should be released the moment the main app is
        /// known alive. The main app can enforce via ManagedSettings, so DNS
        /// blackhole is a last resort for when the app is dead. Keeping any
        /// of these active while the app is alive creates a deadlock
        /// (Olivia/Daphne incidents): DNS blocked → no CloudKit → no commands
        /// → no way to recover short of uninstalling.
        ///
        /// `.lockedDownMode` is deliberately NOT released — it's an active
        /// parent directive to block internet, valid while the app is alive.
        /// `.pendingShieldConfirmation` is a short-lived state with its own
        /// Monitor-response timeout.
        ///
        /// Using a switch instead of a Set literal means adding a new case
        /// is a compile error until the author decides its release policy.
        var releaseOnAppAlive: Bool {
            switch self {
            case .permissionsRevoked, .buildMismatch, .emergencyAppDead,
                 .scheduledLockedDown, .parentCommand:
                return true
            case .lockedDownMode, .pendingShieldConfirmation:
                return false
            }
        }

        /// Single source of truth for the "app came back alive, drop all
        /// safety-net blackholes" set. Every call site that detects the
        /// main app is alive (IPC ping, App Group timestamp, explicit
        /// command processing) must release this exact set. Keeping two
        /// separate literals was the cause of the b462 stuck-blackhole
        /// bug: the IPC ping path had `.parentCommand` missing while the
        /// checkAppLiveness path had it — the disagreement meant devices
        /// that came back via IPC stayed blackholed, while those that
        /// came back via App Group timestamp recovered.
        static let appAliveReleaseSet: Set<DNSBlockReason> =
            Set(DNSBlockReason.allCases.filter(\.releaseOnAppAlive))
    }

    /// Single source of truth for all DNS blackhole state.
    private var activeBlockReasons: Set<DNSBlockReason> = []

    /// Whether DNS should be blackholed (computed from activeBlockReasons).
    private var shouldBlackhole: Bool { !activeBlockReasons.isEmpty }

    /// Human-readable description of the highest-priority active block reason.
    private var blockReasonDescription: String? {
        activeBlockReasons.min()?.humanDescription
    }

    /// Tracks the last state sent to setTunnelNetworkSettings to avoid redundant calls.
    private var lastAppliedBlackholeState: Bool = false

    /// Add or remove a block reason. Only calls reapplyNetworkSettings() on actual change.
    private func setBlockReason(_ reason: DNSBlockReason, active: Bool) {
        let before = shouldBlackhole
        if active {
            activeBlockReasons.insert(reason)
        } else {
            activeBlockReasons.remove(reason)
        }
        let after = shouldBlackhole
        if before != after {
            reapplyNetworkSettings()
        }
        // Always flush so heartbeat picks up reason changes even without blackhole transition
        flushBlockStateToDefaults()
    }

    /// Batch-update multiple block reasons. Single reapply at the end.
    private func batchUpdateBlockReasons(add: Set<DNSBlockReason> = [], remove: Set<DNSBlockReason> = []) {
        let before = shouldBlackhole
        activeBlockReasons.formUnion(add)
        activeBlockReasons.subtract(remove)
        let after = shouldBlackhole
        if before != after {
            reapplyNetworkSettings()
        }
        flushBlockStateToDefaults()
    }

    /// Unified "main app came back alive — drop all safety-net blackholes"
    /// path. Called from every site that detects the main app is alive:
    /// IPC ping, App Group timestamp recovery, explicit command processing.
    /// Clears every reason in `DNSBlockReason.appAliveReleaseSet` in one
    /// consistent bundle:
    ///   1. Log each released reason with the trigger source for traceability.
    ///   2. Reset per-reason in-memory counters (buildMismatchFirstDetectedAt,
    ///      emergencyCheckCount) so next tick doesn't re-seed from stale state.
    ///   3. Clear the UserDefaults flags (internetBlockedUntil,
    ///      buildMismatchDNSBlock) that `seedBlockReasonsOnStart` reads — if
    ///      we don't, the next tunnel restart would re-activate the very
    ///      reason we just cleared.
    ///   4. Batch-remove the reasons (single reapplyNetworkSettings call).
    ///   5. Emit a heartbeat so the parent dashboard sees the recovery fast.
    ///
    /// Previously this logic was duplicated at the IPC ping handler and at
    /// `checkAppLiveness`'s "app came back" branch, and the two copies had
    /// drifted: the ping path was missing `.parentCommand` from its release
    /// set while the other was not. That exact disagreement is how
    /// Olivia/Daphne/Juliet got stuck in the b462 blackhole deadlock.
    /// Single source of truth is the only way to prevent that bug class.
    @discardableResult
    private func releaseBlockReasonsOnAppAlive(trigger: String) -> Set<DNSBlockReason> {
        let releaseSet = DNSBlockReason.appAliveReleaseSet
        let releasing = activeBlockReasons.intersection(releaseSet)
        guard !releasing.isEmpty else { return [] }

        for reason in releasing {
            NSLog("[Tunnel] Releasing \(reason.rawValue) blackhole — app alive (\(trigger))")
        }

        if releasing.contains(.buildMismatch) {
            buildMismatchFirstDetectedAt = nil
        }
        if releasing.contains(.emergencyAppDead) {
            emergencyCheckCount = 0
        }
        if releasing.contains(.parentCommand) {
            let defaults = UserDefaults.appGroup
            defaults?.removeObject(forKey: AppGroupKeys.internetBlockedUntil)
            defaults?.removeObject(forKey: AppGroupKeys.buildMismatchDNSBlock)
        }

        batchUpdateBlockReasons(remove: releaseSet)
        Task { await sendHeartbeatFromTunnel(reason: "blackholeReleased.\(trigger)") }
        return releasing
    }

    /// Apply a parent-commanded mode transition to the DNS blackhole state.
    /// Restricted/locked modes use ManagedSettings shields only — DNS stays
    /// up because blackholing would cut ALL internet, which is wrong for
    /// "only some apps blocked" modes. Only lockedDown and unlocked affect
    /// the DNS path.
    ///
    /// Called from both command-processing paths in this file when a
    /// parent setMode / returnToSchedule / temporaryUnlock lands. Keeping
    /// the logic in one place means a future mode (e.g., a new restricted
    /// variant) doesn't have to be remembered at every call site.
    private func applyModeToBlockReasons(_ mode: LockMode) {
        switch mode {
        case .unlocked:
            // Kid should have internet immediately — drop every safety-net
            // reason and reset per-reason counters so they don't reactivate
            // on the next tick from stale state.
            pendingShieldConfirmation = nil
            emergencyCheckCount = 0
            batchUpdateBlockReasons(remove: Set(DNSBlockReason.allCases))
            NSLog("[Tunnel] DNS released — unlocked mode, shields will clear via Monitor")
        case .lockedDown:
            // Permanent DNS blackhole while lockedDown holds.
            setBlockReason(.lockedDownMode, active: true)
        case .restricted, .locked:
            // Release lockedDown if we're transitioning down from it.
            setBlockReason(.lockedDownMode, active: false)
            NSLog("[Tunnel] Mode \(mode.rawValue) — Monitor will apply shields via stopMonitoring trigger")
        }
    }

    /// Seed activeBlockReasons from persisted state at tunnel startup.
    /// This ensures the proxy starts in the correct mode without waiting for the first liveness tick.
    ///
    /// b462: every seeded reason now has a sanity check against the
    /// current main-app build. Prior behavior trusted
    /// `ExtensionSharedState.currentMode`, `snapshot.resolvedMode`, and the
    /// legacy `internetBlockedUntil` flag unconditionally — which meant a
    /// stale `.lockedDown` snapshot or a build-mismatch `internetBlockedUntil`
    /// left over from a previous session would activate a 24-hour DNS
    /// blackhole on tunnel startup with no way for the kid or parent to
    /// clear it short of uninstalling the app. (That's literally what
    /// Olivia hit.) We now cross-check against `mainAppLastLaunchedBuild`
    /// and `mainAppLastActiveAt` before trusting any seeded blackhole.
    private func seedBlockReasonsOnStart() {
        let resolution = ModeStackResolver.resolve(storage: storage)
        if resolution.mode == .unlocked {
            NSLog("[Tunnel] Seed: mode is unlocked — no block reasons seeded")
            return
        }

        let defaults = UserDefaults.appGroup
        let now = Date().timeIntervalSince1970

        // Freshness inputs. mainAppLastLaunchedBuild == current extension
        // build means the main app has launched on this build at least
        // once, i.e. any stale lockedDown / internetBlockedUntil state has
        // been through the main app's clearance paths and whatever
        // remains is authoritative. mainAppLastActiveAt < 10 min ago
        // means the main app is actively running.
        let mainAppBuild = defaults?.integer(forKey: AppGroupKeys.mainAppLastLaunchedBuild) ?? 0
        let currentBuild = AppConstants.appBuildNumber
        let buildMismatchResolved = mainAppBuild >= currentBuild
        let mainAppLastActive = defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
        let mainAppRecentlyActive = mainAppLastActive > 0 && (now - mainAppLastActive) < 600

        // Check lockedDown mode from persisted state.
        // Don't seed .lockedDownMode from a stale snapshot if the main
        // app has been active recently — if the user was actually in
        // lockedDown, the app would keep the mode fresh. A very old
        // snapshot claiming lockedDown is more likely stale state than
        // an active parent directive.
        if let extState = storage.readExtensionSharedState(), extState.currentMode == .lockedDown {
            let extAge = now - extState.writtenAt.timeIntervalSince1970
            if mainAppRecentlyActive && extAge > 7200 {
                NSLog("[Tunnel] Seed: stale lockedDown extState (\(Int(extAge))s old) — NOT seeding blackhole, main app is active")
            } else {
                activeBlockReasons.insert(.lockedDownMode)
            }
        } else if let snap = storage.readPolicySnapshot(),
                  snap.effectivePolicy.resolvedMode == .lockedDown {
            let snapAge = now - snap.createdAt.timeIntervalSince1970
            if mainAppRecentlyActive && snapAge > 7200 {
                NSLog("[Tunnel] Seed: stale lockedDown snapshot (\(Int(snapAge))s old) — NOT seeding blackhole, main app is active")
            } else {
                activeBlockReasons.insert(.lockedDownMode)
            }
        }

        // Check legacy internetBlockedUntil.
        // If this flag was set by a previous build-mismatch blackhole
        // (Monitor.checkAppLaunchNeeded sets it with a 24h expiry), and
        // the main app has since launched on the current build, clear
        // the flag immediately — the mismatch is resolved. Without this
        // safety net, a transient build-mismatch blackhole could linger
        // for the full 24h even after the app is happily running again.
        if let unblockAt = defaults?.double(forKey: AppGroupKeys.internetBlockedUntil),
           unblockAt > 0, now < unblockAt {
            let buildMismatchFlag = defaults?.bool(forKey: AppGroupKeys.buildMismatchDNSBlock) == true
            if buildMismatchFlag && buildMismatchResolved {
                NSLog("[Tunnel] Seed: clearing stale build-mismatch internetBlockedUntil — main app launched on b\(currentBuild)")
                defaults?.removeObject(forKey: AppGroupKeys.internetBlockedUntil)
                defaults?.removeObject(forKey: AppGroupKeys.buildMismatchDNSBlock)
            } else {
                activeBlockReasons.insert(.parentCommand)
            }
        }

        // FC auth check
        let fcAuth = defaults?.string(forKey: AppGroupKeys.familyControlsAuthStatus)
        if fcAuth == "denied" {
            let resolution = ModeStackResolver.resolve(storage: storage)
            if resolution.mode != .unlocked {
                activeBlockReasons.insert(.permissionsRevoked)
            }
        }

        lastAppliedBlackholeState = shouldBlackhole
        if !activeBlockReasons.isEmpty {
            NSLog("[Tunnel] Seeded block reasons: \(activeBlockReasons.map(\.rawValue).joined(separator: ", "))")
        }
    }

    /// Check if the tunnel should activate emergency DNS blackhole enforcement.
    /// Only triggers when: screen is unlocked, both app and Monitor are dead for
    /// multiple consecutive checks, and the device should be in a restricted state.
    private func checkEmergencyEnforcement() {
        let defaults = UserDefaults.appGroup

        // Grace period after tunnel startup — the app may still be launching
        // after a deploy (devicectl install + launch). Don't fire emergency
        // alerts during this window.
        let timeSinceStart = Date().timeIntervalSince(tunnelStartedAt)
        if timeSinceStart < 300 { // 5 minute grace period
            emergencyCheckCount = 0
            if activeBlockReasons.contains(.emergencyAppDead) { deactivateEmergencyBlackhole() }
            return
        }

        // Shields-back-up early exit: the emergency blackhole is a backstop for
        // CONFIRMED-DOWN shields. If any routine — Monitor retry, foreground
        // enforcement, tunnel apply, heartbeat rectify — has since written a
        // fresh `shieldsActiveAtLastHeartbeat = true`, the backstop is no longer
        // needed, regardless of app/Monitor liveness. Without this, the blackhole
        // stuck around until the kid opened Big Brother (even though shields
        // were already enforcing correctly), which is exactly what Isla hit.
        if activeBlockReasons.contains(.emergencyAppDead) {
            let shieldsUp = defaults?.object(forKey: AppGroupKeys.shieldsActiveAtLastHeartbeat) as? Bool == true
            let shieldsFlagAt = defaults?.double(forKey: AppGroupKeys.shieldsActiveAtLastHeartbeatAt) ?? 0
            // Require a fresh signal (<10 min old) so we don't lift the blackhole
            // on a stale pre-transition "true" — `shieldsConfirmedDown` path that
            // activated us only fires when the flag is false, so any non-false
            // value newer than the activation is a real restoration.
            let shieldsFlagAge = shieldsFlagAt > 0 ? Date().timeIntervalSince1970 - shieldsFlagAt : .infinity
            if shieldsUp && shieldsFlagAge < 600 {
                NSLog("[Tunnel] Shields confirmed UP (flag age \(Int(shieldsFlagAge))s) — lifting emergency blackhole, backstop no longer needed")
                deactivateEmergencyBlackhole()
                return
            }
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
            if activeBlockReasons.contains(.emergencyAppDead) { deactivateEmergencyBlackhole() }
            return
        }

        // Check if main app wrote its timestamp recently.
        // The app writes mainAppLastActiveAt every 30s when in foreground,
        // but iOS suspends it when backgrounded — gaps of 5+ minutes are normal.
        let appLastActive = defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
        let appAge = appLastActive > 0 ? Date().timeIntervalSince1970 - appLastActive : 999
        let appRecentlyActive = appAge < 600 // 10 minutes (tightened from 30)

        // If the main app is alive (IPC pings working), no emergency
        if mainAppAlive || appRecentlyActive {
            emergencyCheckCount = 0
            if activeBlockReasons.contains(.emergencyAppDead) { deactivateEmergencyBlackhole() }
            return
        }

        // App is dead. Check if Monitor can handle enforcement.
        // The Monitor fires on DeviceActivity callbacks — gaps of 60+ minutes
        // are normal during periods with no schedule transitions.
        // But if there's an ACTIVE expiry that was missed, we can't wait.
        let monitorLastActive = defaults?.double(forKey: AppGroupKeys.monitorLastActiveAt) ?? 0
        let monitorAge = monitorLastActive > 0 ? Date().timeIntervalSince1970 - monitorLastActive : 999
        let monitorDead = monitorAge > 3600 // 1 hour (tightened from 2 hours)

        guard monitorDead else {
            emergencyCheckCount = 0
            if activeBlockReasons.contains(.emergencyAppDead) { deactivateEmergencyBlackhole() }
            return
        }

        // Require 5 consecutive checks (liveness timer fires every ~30s = 2.5 minutes)
        emergencyCheckCount += 1
        guard emergencyCheckCount >= 5 else { return }

        // Activate emergency blackhole — only fire once, not every 30s.
        guard !activeBlockReasons.contains(.emergencyAppDead) else { return }
        NSLog("[Tunnel] EMERGENCY: App dead (age \(Int(appAge))s), Monitor dead (\(Int(monitorAge))s), screen unlocked, mode should be \(resolution.mode.rawValue) — activating DNS blackhole")
        setBlockReason(.emergencyAppDead, active: true)

        // Notify parent via CloudKit event (once)
        Task { await sendEmergencyAlert(resolution: resolution, monitorAge: Int(monitorAge)) }
    }

    private func deactivateEmergencyBlackhole() {
        guard activeBlockReasons.contains(.emergencyAppDead) else { return }
        emergencyCheckCount = 0
        setBlockReason(.emergencyAppDead, active: false)
        Task { await sendHeartbeatFromTunnel(reason: "emergencyBlackholeCleared") }
        NSLog("[Tunnel] Emergency blackhole deactivated — normal enforcement resumed")
    }

    /// Immediately write current block state to UserDefaults so the next heartbeat
    /// (from app or tunnel) reports the correct state. Without this, the 30-second
    /// tick delay causes stale "internet blocked" errors in the parent dashboard.
    private func flushBlockStateToDefaults() {
        let defaults = UserDefaults.appGroup
        defaults?.set(shouldBlackhole, forKey: AppGroupKeys.tunnelInternetBlocked)
        defaults?.set(blockReasonDescription ?? "", forKey: AppGroupKeys.tunnelInternetBlockedReason)
    }

    /// Check if the tunnel should enforce the schedule via DNS when ManagedSettings
    /// can't be applied (app not running). Runs every 30 seconds.
    ///
    /// Unlike the emergency blackhole (requires Monitor dead 1hr + 5 checks), this
    /// Relay enforcement refresh signals to the Monitor extension.
    /// The tunnel runs persistently and checks every 30s. If the main app set the
    /// needsEnforcementRefresh flag but the Monitor hasn't confirmed, the tunnel
    /// stops/restarts reconciliation quarters to trigger the Monitor again.
    private func relayEnforcementRefreshIfNeeded() {
        let defaults = UserDefaults.appGroup
        guard let signalTime = defaults?.double(forKey: AppGroupKeys.needsEnforcementRefresh),
              signalTime > 0 else { return }

        // Don't clear the flag here — let the main app or Monitor clear it
        // when they actually re-apply enforcement. The tunnel can't apply
        // ManagedSettings, so clearing the flag before a consumer reads it
        // means enforcement never happens.
        let age = Date().timeIntervalSince1970 - signalTime

        // Check if Monitor or main app already confirmed
        let confirmedAt = defaults?.double(forKey: AppGroupKeys.monitorEnforcementConfirmedAt) ?? 0
        if confirmedAt >= signalTime {
            defaults?.removeObject(forKey: AppGroupKeys.needsEnforcementRefresh)
            return
        }

        // Expire stale flags (2 hours) to prevent indefinite accumulation.
        guard age < 7200 else {
            defaults?.removeObject(forKey: AppGroupKeys.needsEnforcementRefresh)
            return
        }

        // Only attempt relay every 60s to avoid spamming dead-code schedules.
        guard age < 60 else { return }

        NSLog("[Tunnel] Relaying enforcement refresh (signal age: \(Int(age))s, no confirmation)")
    }

    /// Persistent enforcement verifier — runs every 30s on the liveness timer.
    /// Compares expected mode (from snapshot) with actual shield state (from heartbeat).
    /// If they don't match, keeps triggering the Monitor until enforcement is correct.
    /// This is the LAST LINE OF DEFENSE — the tunnel is always running.
    private func verifyEnforcementState() {
        let storage = AppGroupStorage()
        let defaults = UserDefaults.appGroup

        // Skip verification during active temp unlock — the tunnel's ModeStackResolver
        // can fail to read the temp unlock file, causing it to resolve as restricted
        // and trigger the Monitor to re-apply shields during an active unlock.
        // This was the root cause of the shield flip-flop.
        let tempUnlock = storage.readTemporaryUnlockState()
            ?? storage.readPolicySnapshot()?.temporaryUnlockState
        if let temp = tempUnlock, temp.expiresAt > Date() {
            return // Temp unlock active — don't interfere
        }

        // Read expected mode from ModeStackResolver (same logic all processes use)
        let resolution = ModeStackResolver.resolve(storage: storage)
        let expectedShieldsUp = resolution.mode != .unlocked

        // Read actual shield state from what the main app last reported.
        // The main app writes this on each enforcement apply and heartbeat.
        let actualShieldsUp = defaults?.bool(forKey: AppGroupKeys.shieldsActiveAtLastHeartbeat) ?? false

        // Also check the extension shared state for a more recent signal
        if let extState = storage.readExtensionSharedState() {
            let extExpectsShields = extState.currentMode != .unlocked
            // If the extension state disagrees with ModeStackResolver, something is stale
            if extExpectsShields != expectedShieldsUp {
                NSLog("[Tunnel] verifyEnforcement: mode mismatch — resolver=\(resolution.mode.rawValue) extState=\(extState.currentMode.rawValue)")
            }
        }

        // Check for mismatch
        if expectedShieldsUp != actualShieldsUp {
            // Throttle: don't trigger more than once per 30 seconds
            let lastTrigger = defaults?.double(forKey: AppGroupKeys.tunnelEnforcementTriggerAt) ?? 0
            let age = Date().timeIntervalSince1970 - lastTrigger
            guard age >= 30 else { return }

            NSLog("[Tunnel] verifyEnforcement: MISMATCH — expected shields \(expectedShieldsUp ? "UP" : "DOWN") but got \(actualShieldsUp ? "UP" : "DOWN") (mode=\(resolution.mode.rawValue))")
            defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.tunnelEnforcementTriggerAt)
            scheduleEnforcementRefreshActivity(source: "verifyEnforcement")
        }
    }

    /// activates immediately when the schedule says restricted/locked and the app is dead.
    /// Uses proxy-level blocking (Apple domains exempt) rather than system-level 127.0.0.1.
    private func checkScheduleEnforcement() {
        // Grace period after tunnel startup — the app is likely still launching
        // after a deploy (install restarts tunnel, then launch starts the app).
        let timeSinceStart = Date().timeIntervalSince(tunnelStartedAt)
        if timeSinceStart < 60 { return }

        let resolution = ModeStackResolver.resolve(storage: storage)

        // DNS blackhole should ONLY activate for lockedDown mode.
        // For restricted/locked, ManagedSettings shields are the enforcement mechanism.
        // Blocking DNS for restricted/locked was causing kids to lose internet at school
        // whenever the app was dead for >15 minutes — way too aggressive.
        // lockedDown is an explicit parent-initiated total lockdown where DNS blocking is intentional.
        let shouldBlock = resolution.mode == .lockedDown

        let wasActive = activeBlockReasons.contains(.scheduledLockedDown)
        if shouldBlock != wasActive {
            if shouldBlock {
                NSLog("[Tunnel] Schedule enforcement DNS active — mode \(resolution.mode.rawValue), app not alive")
                setBlockReason(.scheduledLockedDown, active: true)
                Task { await sendHeartbeatFromTunnel(reason: "scheduleEnforcementActivated") }
                // Notify the kid — tapping opens BB which restores full enforcement + DNS.
                postOpenAppNag("Open Big Brother to restore internet access.")
            } else {
                NSLog("[Tunnel] Schedule enforcement DNS cleared — \(resolution.mode == .unlocked ? "mode unlocked" : "app alive")")
                setBlockReason(.scheduledLockedDown, active: false)
                Task { await sendHeartbeatFromTunnel(reason: "scheduleEnforcementCleared") }
            }
        }

        // If app has been dead for 30+ minutes, post a one-time local notification
        // prompting the child to open the app (restores location tracking + enforcement).
        let nagDefaults = UserDefaults.appGroup
        let lastAppAt = nagDefaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
        let appDeadFor = lastAppAt > 0 ? Date().timeIntervalSince1970 - lastAppAt : 0
        if !mainAppAlive && appDeadFor > 1800 {
            let lastNagKey = "tunnelLocationNagAt"
            let lastNag = nagDefaults?.double(forKey: lastNagKey) ?? 0
            if Date().timeIntervalSince1970 - lastNag > 3600 { // Max once per hour
                nagDefaults?.set(Date().timeIntervalSince1970, forKey: lastNagKey)
                postOpenAppNag("Tap to restore location tracking and full protection.")
                NSLog("[Tunnel] Posted location nag notification — app dead for \(Int(appDeadFor))s")
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
            setBlockReason(.pendingShieldConfirmation, active: false)
            NSLog("[Tunnel] Shield confirmation received — releasing temporary DNS blackhole (\(Int(age))s)")
            return
        }

        // Hard timeout after 5 minutes — release the block, Monitor may be dead
        if age > 300 {
            NSLog("[Tunnel] Shield confirmation HARD TIMEOUT after \(Int(age))s — releasing DNS block")
            pendingShieldConfirmation = nil
            setBlockReason(.pendingShieldConfirmation, active: false)
            return
        }

        // Soft warning at 2 minutes
        if age > 120 {
            NSLog("[Tunnel] Shield confirmation waiting \(Int(age))s — Monitor may be slow")
        }
    }

    /// Check if the Monitor extension requested an immediate heartbeat after applying enforcement.
    /// The Monitor can't make network calls — it writes a flag, we pick it up and send the heartbeat.
    /// This ensures the parent sees the confirmed mode within seconds of the Monitor applying shields.
    private func checkMonitorHeartbeatRequest() {
        let defaults = UserDefaults.appGroup
        guard let requestTime = defaults?.double(forKey: AppGroupKeys.monitorNeedsHeartbeat),
              requestTime > 0 else { return }

        // Only honor recent requests (within 2 minutes)
        let age = Date().timeIntervalSince1970 - requestTime
        guard age < 120 else {
            defaults?.removeObject(forKey: AppGroupKeys.monitorNeedsHeartbeat)
            return
        }

        defaults?.removeObject(forKey: AppGroupKeys.monitorNeedsHeartbeat)
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

    /// Schedule a one-shot near-future DeviceActivity that wakes the Monitor
    /// extension so it can re-apply enforcement from its privileged context.
    ///
    /// The tunnel is a separate process from the main app so it has its own
    /// copy of this helper (can't import the main app's symbols). The logic
    /// must stay in sync with EnforcementServiceImpl.scheduleEnforcementRefreshActivity
    /// — same activity name prefix, same ~90s delay, same 16-min interval.
    ///
    /// **Why not stopMonitoring-as-trigger:** stopMonitoring does NOT fire
    /// intervalDidEnd in the Monitor on iOS 17+, and re-registering a schedule
    /// whose intervalStart is in the past does NOT fire intervalDidStart. Both
    /// are empirically confirmed. A future-dated schedule is the only reliable
    /// wake mechanism short of a natural boundary.
    private func scheduleEnforcementRefreshActivity(source: String, delaySeconds: TimeInterval = 60) {
        let center = DeviceActivityCenter()

        // Sweep stale enforcementRefresh activities to stay under iOS's cap.
        for activity in center.activities
        where activity.rawValue.hasPrefix("bigbrother.enforcementRefresh.") {
            center.stopMonitoring([activity])
        }

        let now = Date()
        let fireAt = now.addingTimeInterval(delaySeconds)
        let endAt = fireAt.addingTimeInterval(16 * 60)
        let cal = Calendar.current
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: cal.component(.hour, from: fireAt),
                                          minute: cal.component(.minute, from: fireAt)),
            intervalEnd: DateComponents(hour: cal.component(.hour, from: endAt),
                                        minute: cal.component(.minute, from: endAt)),
            repeats: true,
            warningTime: nil
        )
        let activityName = DeviceActivityName(
            rawValue: "bigbrother.enforcementRefresh.\(Int(now.timeIntervalSince1970))"
        )

        UserDefaults.appGroup?
            .set(Date().timeIntervalSince1970, forKey: AppGroupKeys.needsEnforcementRefresh)

        do {
            try center.startMonitoring(activityName, during: schedule)
            NSLog("[Tunnel] EnforcementRefresh \(source): registered \(activityName.rawValue), fires ~\(Int(delaySeconds))s")
        } catch {
            NSLog("[Tunnel] EnforcementRefresh \(source): FAILED — \(error.localizedDescription)")
        }
    }

    /// Write a flag and schedule a Monitor wake so enforcement gets re-applied.
    /// The flag is consumed by any future Monitor callback (including the one
    /// our scheduled activity triggers). Belt-and-suspenders.
    private func signalMonitorToReconcile() {
        scheduleEnforcementRefreshActivity(source: "signalReconcile")
        triggerBackgroundURLSessionWake()
    }

    private func triggerBackgroundURLSessionWake() {
        let id = "bb.enforcement.wake.\(Int(Date().timeIntervalSince1970))"
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.sharedContainerIdentifier = AppConstants.appGroupIdentifier
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        let session = URLSession(configuration: config)
        guard let url = URL(string: "https://www.apple.com/robots.txt") else { return }
        let task = session.downloadTask(with: url)
        task.resume()
        NSLog("[Tunnel] Background URLSession wake triggered: \(id)")
    }

    /// Handle removeTimeLimit from tunnel: remove limit, remove from allowed, update DNS.
    private func handleRemoveTimeLimitFromTunnel(fingerprint: String) {
        var limits = storage.readAppTimeLimits()
        let removed = limits.first(where: { $0.fingerprint == fingerprint })
        limits.removeAll { $0.fingerprint == fingerprint }
        try? storage.writeAppTimeLimits(limits)

        // Persist name before removing
        if let removed {
            let defaults = UserDefaults.appGroup
            var nameMap = (defaults?.dictionary(forKey: AppGroupKeys.harvestedAppNames) as? [String: String]) ?? [:]
            nameMap[removed.fingerprint] = removed.appName
            defaults?.set(nameMap, forKey: AppGroupKeys.harvestedAppNames)
        }

        // Remove from exhausted
        var exhausted = storage.readTimeLimitExhaustedApps()
        exhausted.removeAll { $0.fingerprint == fingerprint }
        try? storage.writeTimeLimitExhaustedApps(exhausted)

        // Write a flag so the Monitor removes the token from allowed list on next reconciliation.
        // The tunnel can't import ManagedSettings (ApplicationToken) to manipulate the set directly.
        if let removed, removed.wasAlreadyAllowed != true {
            let defaults = UserDefaults.appGroup
            var pending = defaults?.stringArray(forKey: AppGroupKeys.pendingTokenRemovals) ?? []
            pending.append(removed.tokenData.base64EncodedString())
            defaults?.set(pending, forKey: AppGroupKeys.pendingTokenRemovals)
        }

        updateTimeLimitBlockedDomains()
        signalMonitorToReconcile()
        NSLog("[Tunnel] Removed time limit for \(removed?.appName ?? fingerprint)")
    }

    /// Recalculate time-limit DNS blocked domains from exhausted apps.
    private func updateTimeLimitBlockedDomains() {
        let resolution = ModeStackResolver.resolve(storage: storage)
        if resolution.mode == .unlocked {
            try? storage.writeTimeLimitBlockedDomains([])
            return
        }
        let today = screenTimeTodayString()
        let exhausted = storage.readTimeLimitExhaustedApps().filter { $0.dateString == today }
        var blockedDomains = Set<String>()
        for app in exhausted {
            let domains = DomainCategorizer.domainsForApp(app.appName)
            blockedDomains.formUnion(domains)
        }
        try? storage.writeTimeLimitBlockedDomains(blockedDomains)
    }

    private func currentExhaustedAppState() -> (fingerprints: [String]?, bundleIDs: [String]?, names: [String]?) {
        let today = screenTimeTodayString()
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
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               !bundleID.isEmpty {
                bundleIDs.insert(bundleID)
            }

            let canonicalName = (limitsByFingerprint[entry.fingerprint]?.appName ?? entry.appName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isUsefulAppName(canonicalName) {
                names.insert(canonicalName)
            }
        }

        return (
            fingerprints: fingerprints.isEmpty ? nil : Array(fingerprints).sorted(),
            bundleIDs: bundleIDs.isEmpty ? nil : Array(bundleIDs).sorted(),
            names: names.isEmpty ? nil : Array(names).sorted()
        )
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
        let defaults = UserDefaults.appGroup
        guard let needsSync = defaults?.object(forKey: AppGroupKeys.pendingReviewNeedsSync) as? Double,
              needsSync > 0 else { return }

        guard let data = storage.readRawData(forKey: AppGroupKeys.pendingReviewLocalJSON),
              var reviews = try? JSONDecoder().decode([PendingAppReview].self, from: data),
              !reviews.isEmpty else { return }

        // Only upload entries that haven't been resolved by the parent.
        // Resolved entries stay in the local file for child UI but are
        // NEVER re-uploaded — this breaks the zombie re-upload loop.
        let toUpload = reviews.filter { $0.syncStatus != .resolved }
        guard !toUpload.isEmpty else {
            defaults?.removeObject(forKey: AppGroupKeys.pendingReviewNeedsSync)
            return
        }

        // REST-first upload. The framework path below hits `cloudd` and
        // hangs silently when the daemon is wedged — the exact scenario
        // the tunnel is supposed to keep working through. Try REST first;
        // if it succeeds, skip the framework path entirely.
        var restSyncedIDs = Set<UUID>()
        let restReqs = toUpload.map { review -> CloudKitRESTClient.ModifyRequest in
            var fields: [String: [String: Any]] = [:]
            if let fv = CloudKitRESTClient.fieldValue(review.familyID.rawValue) { fields["familyID"] = fv }
            if let fv = CloudKitRESTClient.fieldValue(review.childProfileID.rawValue) { fields["profileID"] = fv }
            if let fv = CloudKitRESTClient.fieldValue(review.deviceID.rawValue) { fields["deviceID"] = fv }
            if let fv = CloudKitRESTClient.fieldValue(review.appFingerprint) { fields["appFingerprint"] = fv }
            if let fv = CloudKitRESTClient.fieldValue(review.appName) { fields["appName"] = fv }
            if let bid = review.bundleID, let fv = CloudKitRESTClient.fieldValue(bid) { fields["appBundleID"] = fv }
            if let tok = review.tokenDataBase64, let fv = CloudKitRESTClient.fieldValue(tok) { fields["tokenDataBase64"] = fv }
            if let fv = CloudKitRESTClient.fieldValue(review.nameResolved) { fields["nameResolved"] = fv }
            if let fv = CloudKitRESTClient.fieldValue(review.createdAt) { fields["createdAt"] = fv }
            if let fv = CloudKitRESTClient.fieldValue(review.updatedAt) { fields["updatedAt"] = fv }
            return CloudKitRESTClient.ModifyRequest(
                operationType: .forceReplace,
                recordType: "BBPendingAppReview",
                recordName: "BBPendingAppReview_\(review.id.uuidString)",
                fields: fields
            )
        }
        do {
            _ = try await CloudKitRESTClient.modifyRecords(restReqs)
            restSyncedIDs = Set(toUpload.map(\.id))
            NSLog("[Tunnel] syncResolvedPendingReviews REST: \(restSyncedIDs.count)/\(toUpload.count) uploaded")
        } catch {
            NSLog("[Tunnel] syncResolvedPendingReviews REST failed (\(error.localizedDescription)) — framework fallback")
        }

        // Apply the REST-synced IDs directly if we got them all; otherwise
        // fall through to framework for the rest.
        if restSyncedIDs.count == toUpload.count {
            // Update local state to reflect success — mirrors the framework
            // path's post-op bookkeeping.
            for i in reviews.indices {
                if restSyncedIDs.contains(reviews[i].id) {
                    reviews[i].syncStatus = .synced
                }
            }
            if let newData = try? JSONEncoder().encode(reviews) {
                try? storage.writeRawData(newData, forKey: AppGroupKeys.pendingReviewLocalJSON)
            }
            defaults?.removeObject(forKey: AppGroupKeys.pendingReviewNeedsSync)
            return
        }

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        var records: [CKRecord] = []
        for review in toUpload where !restSyncedIDs.contains(review.id) {
            let recordID = CKRecord.ID(recordName: "BBPendingAppReview_\(review.id.uuidString)")
            let record = CKRecord(recordType: "BBPendingAppReview", recordID: recordID)
            record["familyID"] = review.familyID.rawValue
            record["profileID"] = review.childProfileID.rawValue
            record["deviceID"] = review.deviceID.rawValue
            record["appFingerprint"] = review.appFingerprint
            record["appName"] = review.appName
            record["appBundleID"] = review.bundleID
            record["tokenDataBase64"] = review.tokenDataBase64
            record["nameResolved"] = (review.nameResolved ? 1 : 0) as NSNumber
            record["createdAt"] = review.createdAt as NSDate
            record["updatedAt"] = review.updatedAt as NSDate
            records.append(record)
        }

        let op = CKModifyRecordsOperation(recordsToSave: records)
        op.savePolicy = .changedKeys
        op.isAtomic = false
        op.qualityOfService = .userInitiated

        var syncedIDs = Set<UUID>()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                var resumed = false
                op.perRecordSaveBlock = { recordID, result in
                    if case .success = result {
                        let uuidStr = recordID.recordName.replacingOccurrences(of: "BBPendingAppReview_", with: "")
                        if let uuid = UUID(uuidString: uuidStr) { syncedIDs.insert(uuid) }
                    }
                }
                op.modifyRecordsResultBlock = { result in
                    guard !resumed else { return }
                    resumed = true
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                db.add(op)
            }
        } catch {
            NSLog("[Tunnel] Failed to sync pending reviews: \(error.localizedDescription)")
        }

        if !syncedIDs.isEmpty {
            for i in reviews.indices where syncedIDs.contains(reviews[i].id) {
                if reviews[i].syncStatus == .pending {
                    reviews[i].syncStatus = .synced
                }
            }
            if let encoded = try? JSONEncoder().encode(reviews) {
                try? storage.writeRawData(encoded, forKey: AppGroupKeys.pendingReviewLocalJSON)
            }
            defaults?.removeObject(forKey: AppGroupKeys.pendingReviewNeedsSync)
            NSLog("[Tunnel] Synced \(syncedIDs.count)/\(toUpload.count) pending reviews (skipped \(reviews.count - toUpload.count) resolved)")
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
            record["updatedAt"] = Date()
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
        let defaults = UserDefaults.appGroup
        if durationSeconds > 0 {
            let resolution = ModeStackResolver.resolve(storage: storage)
            if resolution.mode == .unlocked {
                NSLog("[Tunnel] Internet block request ignored — mode is unlocked")
                return
            }
            let unblockAt = Date().addingTimeInterval(Double(durationSeconds))
            defaults?.set(unblockAt.timeIntervalSince1970, forKey: AppGroupKeys.internetBlockedUntil)
            NSLog("[Tunnel] Internet blocked for \(durationSeconds)s (until \(unblockAt))")
            setBlockReason(.parentCommand, active: true)
        } else {
            defaults?.removeObject(forKey: AppGroupKeys.internetBlockedUntil)
            NSLog("[Tunnel] Internet unblocked")
            setBlockReason(.parentCommand, active: false)
        }
    }



    /// Counter of in-flight reapplyNetworkSettings operations. Prevents
    /// `reasserting = false` from firing prematurely when overlapping calls
    /// are in progress (e.g., path change + recovery ladder L3 simultaneously).
    /// Mutated only inside `reapplyLock`.
    private var pendingReapplyCount: Int = 0
    private let reapplyLock = NSLock()

    /// b457: coalesce concurrent reapply entries so two callers never race on
    /// the nil teardown + apply sequence. First caller runs; subsequent
    /// callers flip `reapplyPending = true` and return. When the in-flight
    /// call finishes it re-runs once with `force: true` to pick up any
    /// newer desired state that was batched during the window.
    private var reapplyInFlight: Bool = false
    private var reapplyPending: Bool = false

    /// b432: Track whether the blackhole nil-teardown has already been
    /// committed for the current blackhole transition. On the first attempt
    /// to enter blackhole, the nil teardown runs to kill existing TCP
    /// connections. If the subsequent applySettings fails/times out, the
    /// retry should NOT redo the nil teardown (interface is already torn
    /// down; redundant teardown just adds 5 seconds per retry and can't do
    /// anything useful). Reset to false whenever we successfully exit blackhole.
    private var blackholeInterfaceTornDown: Bool = false

    /// b434 (audit fix): Generation counter for reapplyNetworkSettings calls.
    /// Each call captures the current generation; the completion only commits
    /// state (lastAppliedBlackholeState, blackholeInterfaceTornDown) if its
    /// captured generation still matches the current (latest) generation. This
    /// prevents an older in-flight "block" completion from overwriting a newer
    /// "unblock" request's committed state. Mutated only inside applyGenerationLock.
    private var applyGeneration: Int64 = 0
    private let applyGenerationLock = NSLock()

    private func nextApplyGeneration() -> Int64 {
        applyGenerationLock.lock()
        applyGeneration &+= 1
        let g = applyGeneration
        applyGenerationLock.unlock()
        return g
    }

    /// Atomically check if `generation` is still the latest AND, if so, commit
    /// the new blackhole state. Holds the generation lock across both the
    /// check and the commit to prevent TOCTOU: otherwise another thread could
    /// bump the generation between our check and our write, letting a stale
    /// completion overwrite the canonical state.
    ///
    /// - Returns: true if the commit happened (was latest), false if skipped.
    @discardableResult
    private func commitBlackholeStateIfLatest(generation: Int64, wantBlackhole: Bool) -> Bool {
        applyGenerationLock.lock()
        defer { applyGenerationLock.unlock() }
        guard applyGeneration == generation else { return false }
        lastAppliedBlackholeState = wantBlackhole
        if !wantBlackhole {
            // Reset teardown tracker so next blackhole entry does a fresh teardown.
            blackholeInterfaceTornDown = false
        }
        return true
    }

    /// b436 (audit fix): Atomically mark the blackhole interface as torn down
    /// IF our call is still the latest generation. Used by the nil-teardown
    /// callback to avoid an older stale completion dirtying the flag after a
    /// newer unblock has already reset it.
    private func setBlackholeTornDownIfLatest(generation: Int64) {
        applyGenerationLock.lock()
        defer { applyGenerationLock.unlock() }
        guard applyGeneration == generation else { return }
        blackholeInterfaceTornDown = true
    }

    /// Reapply tunnel network settings (DNS) based on current block/safe-search state.
    /// When transitioning INTO blackhole mode, tears down the network interface first
    /// (setTunnelNetworkSettings(nil)) to kill all existing TCP connections. Apps must
    /// reconnect, and new DNS lookups hit the blackhole. This prevents cached DNS /
    /// persistent connections from bypassing the block.
    ///
    /// - Parameter force: If true, always reapply even if the blackhole state hasn't
    ///   changed. Used by network-path recovery (unsatisfied→satisfied) where the
    ///   underlying NWUDPSession is wedged and needs a full re-plumbing, and by L3
    ///   of the CK recovery ladder where everything else has failed.
    private func reapplyNetworkSettings(force: Bool = false) {
        // b457: concurrent reapply coalescing. If another reapply is in
        // flight, flip the pending flag and return — the in-flight one
        // will re-run once it completes. Without this, two overlapping
        // calls could both compute `needsTeardown = true` and both fire
        // setTunnelNetworkSettings(nil), leaving the tunnel in a wedged
        // state where an older teardown lands after a newer apply.
        reapplyLock.lock()
        if reapplyInFlight {
            reapplyPending = true
            reapplyLock.unlock()
            NSLog("[Tunnel] reapplyNetworkSettings: coalesced (another call in flight)")
            return
        }
        reapplyInFlight = true
        reapplyLock.unlock()

        let wantBlackhole = shouldBlackhole

        // Always sync proxy blackhole mode (cheap Bool assignment)
        dnsProxy?.isBlackholeMode = wantBlackhole
        if wantBlackhole {
            NSLog("[Tunnel] DNS proxy blackhole active — reasons: \(activeBlockReasons.map(\.rawValue).joined(separator: ", "))")
        }

        // Always flush state to UserDefaults for heartbeat
        flushBlockStateToDefaults()

        // Skip setTunnelNetworkSettings() if blackhole state hasn't changed (rate-limit).
        // BUT: forced reapplies always go through, e.g. recovery from a stale
        // NWUDPSession. Also bypass the equality guard whenever a previous
        // apply failed/timed out (networkSettingsNeedRetry = true) — otherwise
        // the retry would short-circuit because the desired state already
        // matches lastAppliedBlackholeState. (b432: this was a real wedge bug.)
        if !force && !networkSettingsNeedRetry {
            guard wantBlackhole != lastAppliedBlackholeState else {
                // b457: early return — still need to clear the in-flight
                // flag and handle any coalesced pending call.
                reapplyLock.lock()
                reapplyInFlight = false
                let shouldRerun = reapplyPending
                reapplyPending = false
                reapplyLock.unlock()
                if shouldRerun {
                    NSLog("[Tunnel] reapplyNetworkSettings: coalesced rerun (no-op early return)")
                    reapplyNetworkSettings(force: true)
                }
                return
            }
        }

        // Detect transition INTO blackhole — tear down interface to kill
        // existing connections.
        // b432: We do NOT commit lastAppliedBlackholeState here. The previous
        // ordering committed before the apply, so a failed/timed-out apply
        // would leave the next non-forced call short-circuiting on the equality
        // guard while the actual tunnel was still wedged. Now we commit only
        // inside the success branch of the completion handler.
        //
        // b432 (audit fix): On retries of a failed "enter blackhole" apply,
        // skip the nil teardown if we've already committed one (tracked via
        // blackholeInterfaceTornDown). The nil teardown is idempotent but
        // expensive (5s timeout per call). Only run it once per transition.
        let enteringBlackhole = wantBlackhole && !lastAppliedBlackholeState
        let needsTeardown = enteringBlackhole && !blackholeInterfaceTornDown

        // b431: tell iOS we're recovering, not failing. Without this, iOS 17+
        // will move us to .disconnected after 5 minutes in reasserting state if
        // we end up flapping. Cleared in the completion handler — but only
        // when no other reapply is in flight (counter protects against
        // overlapping reapply calls flipping reasserting=false too early).
        reapplyLock.lock()
        pendingReapplyCount += 1
        reapplyLock.unlock()
        self.reasserting = true

        // b434 (audit fix): Capture a generation ID. Completions only commit
        // state if this is still the latest generation. Prevents an older
        // in-flight "block" completion from overwriting a newer "unblock"
        // request's state.
        let myGeneration = nextApplyGeneration()

        let applySettings = { [weak self] in
            guard let self else { return }
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
            settings.ipv4Settings = ipv4
            settings.mtu = 1500

            let dns = NEDNSSettings(servers: ["198.18.0.1"])
            dns.matchDomains = [""]
            settings.dnsSettings = dns

            // b431: NSCondition-wrapped timeout. setTunnelNetworkSettings is
            // documented to occasionally hang indefinitely (Apple radar; see
            // wireguard-apple WireGuardAdapter.setNetworkSettings for the
            // canonical workaround). Without a timeout, the tunnel can be
            // wedged for the lifetime of the process.
            self.setNetworkSettingsWithTimeout(settings, timeoutSeconds: 5.0) { [weak self] error, timedOut in
                guard let self else { return }
                if let error {
                    NSLog("[Tunnel] Failed to reapply settings: \(error.localizedDescription) — will retry on next liveness tick")
                    self.networkSettingsNeedRetry = true
                    // b432: Do NOT commit lastAppliedBlackholeState — leave it
                    // at the previous value so the next non-forced call won't
                    // short-circuit on the equality guard.
                } else if timedOut {
                    NSLog("[Tunnel] setTunnelNetworkSettings timed out after 5s — proceeding anyway, DNS read loop will restart")
                    self.networkSettingsNeedRetry = true
                    // Same as error case — don't commit on timeout.
                } else {
                    // b434 (audit fix): Atomic check-and-commit via
                    // commitBlackholeStateIfLatest. Holds the generation lock
                    // across both the check and the write to prevent TOCTOU
                    // where another thread bumps the generation between our
                    // check and our commit.
                    let committed = self.commitBlackholeStateIfLatest(
                        generation: myGeneration,
                        wantBlackhole: wantBlackhole
                    )
                    if committed {
                        NSLog("[Tunnel] Network settings reapplied\(enteringBlackhole ? " (connections reset)" : "")\(force ? " (forced)" : "") [gen=\(myGeneration)]")
                        self.networkSettingsNeedRetry = false
                    } else {
                        NSLog("[Tunnel] Network settings reapplied but generation stale (my=\(myGeneration)) — skipping commit")
                    }
                }
                // Restart DNS read loop regardless — the old packetFlow becomes
                // invalid after setTunnelNetworkSettings completes (success or
                // timeout). On a timeout we may not have a valid flow yet, but
                // the next successful settings application will restart it.
                self.dnsProxy?.startReadLoop()
                // b457: also rebind the upstream DNS NWUDPSession. The prior
                // session was bound to the pre-reapply interface; even after a
                // successful setTunnelNetworkSettings the old session stays
                // wedged on the dead path (Apple NWUDPSession roaming bug —
                // cf. wireguard-apple wgDisableSomeRoamingForBrokenMobileSemantics).
                // Without this, every "fix wifi→cell handover" path still
                // leaves DNS broken because the proxy continues trying to
                // forward on the original interface. Ties in-process DNS
                // plumbing to the same instant as the tunnel re-plumb.
                self.dnsProxy?.reconnectUpstream()
                // Clear reasserting only when this is the LAST in-flight call.
                // Overlapping reapply calls increment the counter; we don't
                // want an early call's completion to flip reasserting=false
                // while a later call's settings change is still pending.
                //
                // b457: also clear the top-level in-flight flag and re-fire
                // if a coalesced call was deferred during this run.
                self.reapplyLock.lock()
                self.pendingReapplyCount = max(0, self.pendingReapplyCount - 1)
                let stillPending = self.pendingReapplyCount > 0
                self.reapplyInFlight = false
                let shouldRerun = self.reapplyPending
                self.reapplyPending = false
                self.reapplyLock.unlock()
                if !stillPending {
                    self.reasserting = false
                }
                if shouldRerun {
                    NSLog("[Tunnel] reapplyNetworkSettings: coalesced rerun picked up")
                    self.reapplyNetworkSettings(force: true)
                }
            }
        }

        if needsTeardown {
            // Two-step: nil settings tears down the interface → drops all TCP connections.
            // Then re-apply with blackhole DNS. Apps that try to reconnect hit the blackhole.
            NSLog("[Tunnel] Entering blackhole — tearing down interface to kill existing connections")
            setNetworkSettingsWithTimeout(nil, timeoutSeconds: 5.0) { [weak self] error, timedOut in
                guard let self else { return }
                // b436 (audit fix): If the nil teardown FAILED or TIMED OUT,
                // the interface was NOT fully torn down — existing TCP
                // connections may still be alive. Calling applySettings() now
                // would succeed and commit `lastAppliedBlackholeState = true`,
                // making the next reapply short-circuit on the equality guard.
                // Result: kid has blackhole DNS but leaky connections, forever.
                //
                // Instead, abort the reapply: mark needsRetry, decrement the
                // in-flight counter, clear reasserting if last in-flight, and
                // DO NOT proceed to applySettings. The next liveness tick will
                // retry the whole sequence (equality guard is bypassed when
                // networkSettingsNeedRetry is true).
                if error != nil || timedOut {
                    NSLog("[Tunnel] Nil-teardown failed (error=\(error?.localizedDescription ?? "none"), timedOut=\(timedOut)) — ABORTING reapply, will retry")
                    try? self.storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .command,
                        message: "Blackhole nil-teardown FAILED — aborting reapply",
                        details: "gen=\(myGeneration), error=\(error?.localizedDescription ?? "none"), timedOut=\(timedOut). Existing connections may still be alive; next liveness tick will retry."
                    ))
                    self.networkSettingsNeedRetry = true
                    // Decrement the in-flight counter since we're not proceeding.
                    // b457: also clear reapplyInFlight and handle any pending coalesce.
                    self.reapplyLock.lock()
                    self.pendingReapplyCount = max(0, self.pendingReapplyCount - 1)
                    let stillPending = self.pendingReapplyCount > 0
                    self.reapplyInFlight = false
                    let shouldRerun = self.reapplyPending
                    self.reapplyPending = false
                    self.reapplyLock.unlock()
                    if !stillPending {
                        self.reasserting = false
                    }
                    if shouldRerun {
                        NSLog("[Tunnel] reapplyNetworkSettings: coalesced rerun (after teardown fail)")
                        self.reapplyNetworkSettings(force: true)
                    }
                    return
                }
                // Teardown succeeded — mark it atomically IF our generation
                // is still the latest, then proceed to apply blackhole DNS.
                self.setBlackholeTornDownIfLatest(generation: myGeneration)
                applySettings()
            }
        } else if enteringBlackhole {
            // Retry of a failed blackhole entry — teardown already committed
            // on the previous attempt, just re-run applySettings to push the
            // blackhole DNS through.
            NSLog("[Tunnel] Entering blackhole retry — teardown already committed, skipping to applySettings")
            applySettings()
        } else {
            applySettings()
        }
    }

    /// b431: Wrap `setTunnelNetworkSettings` in an NSCondition timeout. The
    /// API is documented to occasionally hang the completion handler. WireGuard
    /// uses this exact pattern in production (WireGuardAdapter.setNetworkSettings).
    ///
    /// - Parameters:
    ///   - settings: The settings to apply, or nil to tear down.
    ///   - timeoutSeconds: How long to wait before considering the call timed out.
    ///   - completion: Called with (error?, timedOut). If timedOut is true, the
    ///     completion runs from the timeout watchdog and the actual completion
    ///     handler may still fire later (we ignore it).
    private func setNetworkSettingsWithTimeout(
        _ settings: NEPacketTunnelNetworkSettings?,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Error?, Bool) -> Void
    ) {
        let condition = NSCondition()
        var didFire = false

        // Schedule the timeout watchdog on a background queue.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
            condition.lock()
            if !didFire {
                didFire = true
                condition.unlock()
                completion(nil, true)
            } else {
                condition.unlock()
            }
        }

        // Make the actual call.
        setTunnelNetworkSettings(settings) { [weak self] error in
            condition.lock()
            if !didFire {
                didFire = true
                condition.unlock()
                completion(error, false)
            } else {
                condition.unlock()
                // b466 (three-way audit fix): late completion handling.
                // Previously this branch just logged. That left
                // `networkSettingsNeedRetry = true` (set by the timeout
                // path) stuck high even when Apple eventually completed
                // the call successfully. The 5-second fast-path retry
                // then kept firing `reapplyNetworkSettings()` forever —
                // and each reapply called `dnsProxy?.startReadLoop()`,
                // which (pre-generation-fix) leaked a new read loop
                // every 5 seconds. Compound effect: dozens of concurrent
                // readers on `packetFlow`, DNS delivery wedges, all CK
                // ops return `CKErrorDomain 3`, recovery ladder fails
                // because L4 cancelTunnelWithError restart re-hits the
                // same seed bugs. THIS is the core repro path.
                //
                // On late success: Apple actually DID apply the settings,
                // we just didn't wait long enough. Clear the retry flag
                // so the fast path stops reapplying.
                if let error {
                    NSLog("[Tunnel] setTunnelNetworkSettings late completion (post-timeout): \(error.localizedDescription)")
                } else {
                    NSLog("[Tunnel] setTunnelNetworkSettings late completion (post-timeout): success — clearing retry flag")
                    self?.networkSettingsNeedRetry = false
                }
            }
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

        let defaults = UserDefaults.appGroup
        var processedByTunnel = Set(defaults?.stringArray(forKey: AppGroupKeys.tunnelProcessedCommandIDs) ?? [])
        var deferredHeartbeat = false

        do {
            // Use URLSession + CloudKit REST API instead of CK framework.
            // CK framework operations hang after ~3 min of main app being
            // backgrounded (cloudd daemon throttles the operation queue).
            // URLSession bypasses cloudd entirely — the tunnel is a high-priority
            // NE process with persistent network access.
            let results = try await Self.queryCommandsViaREST(
                familyID: enrollment.familyID.rawValue
            )
            for record in results {
                let actionJSON = record["actionJSON"] ?? ""
                let commandID = record["recordName"] ?? ""
                let targetType = record["targetType"] ?? ""
                let targetID = record["targetID"] ?? ""

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
                let issuedAtMs = Double(record["issuedAt"] ?? "0") ?? 0
                let issuedAt = Date(timeIntervalSince1970: issuedAtMs / 1000)
                if Date().timeIntervalSince(issuedAt) > AppConstants.defaultCommandExpirySeconds {
                    processedByTunnel.insert(commandID)
                    continue
                }

                let tunnelAction = Self.parseTunnelActionType(from: actionJSON)
                if tunnelAction == "requestHeartbeat" {
                    deferredHeartbeat = true
                    processedByTunnel.insert(commandID)
                    Self.markCommandAppliedAsync(db: db, recordName: commandID)
                    NSLog("[Tunnel] Processed requestHeartbeat command: \(commandID)")
                } else if tunnelAction == "requestDiagnostics" {
                    await collectAndUploadDiagnostics(enrollment: enrollment)
                    processedByTunnel.insert(commandID)
                    Self.markCommandAppliedAsync(db: db, recordName: commandID)
                    NSLog("[Tunnel] Processed requestDiagnostics command: \(commandID)")
                } else if tunnelAction == "blockInternet" {
                    reapplyNetworkSettings()
                    processedByTunnel.insert(commandID)
                    Self.markCommandAppliedAsync(db: db, recordName: commandID)
                    NSLog("[Tunnel] Processed blockInternet (mode-driven): \(commandID)")
                } else if let tunnelAction,
                          Self.isTunnelProcessableAction(tunnelAction) {
                    let ckRecord = CKRecord(
                        recordType: "BBRemoteCommand",
                        recordID: CKRecord.ID(recordName: commandID)
                    )
                    ckRecord["actionJSON"] = actionJSON
                    ckRecord["issuedAt"] = issuedAt as NSDate
                    ckRecord["status"] = "pending"
                    ckRecord["targetType"] = targetType
                    ckRecord["targetID"] = targetID
                    await handleModeCommandFromTunnel(
                        actionType: tunnelAction,
                        actionJSON: actionJSON,
                        record: ckRecord,
                        enrollment: enrollment,
                        db: db
                    )
                    processedByTunnel.insert(commandID)
                    NSLog("[Tunnel] Processed mode command \(tunnelAction): \(commandID) (appAlive=\(mainAppAlive))")
                } else {
                    processedByTunnel.insert(commandID)
                }
            }

            commandPollFailureCount = 0
            recordNetworkHealthResult(success: true, reason: "poll")
        } catch {
            NSLog("[Tunnel] Command poll failed: \(error.localizedDescription)")
            commandPollFailureCount += 1
            if commandPollFailureCount >= 6 {
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .command,
                    message: "Command polling failed \(commandPollFailureCount)x: \(error.localizedDescription)"
                ))
                commandPollFailureCount = 0
            }
            recordNetworkHealthResult(success: false, reason: "poll: \(error.localizedDescription)")
        }

        if processedByTunnel.count > 200 {
            processedByTunnel = Set(processedByTunnel.suffix(200))
        }
        defaults?.set(Array(processedByTunnel), forKey: AppGroupKeys.tunnelProcessedCommandIDs)

        if deferredHeartbeat {
            await sendHeartbeatFromTunnel(reason: "command")
        }
    }


    // MARK: - CloudKit Operations with QoS

    // MARK: - CloudKit REST API (bypasses cloudd throttling)

    private static let ckAPIToken = "1a091d3460a9c1b488dd4259ae2f5c7bd9200ef9dd311a42c1b447da992766b7"
    /// Environment must match the shared `CloudKitRESTClient` — otherwise
    /// the tunnel's command poll talks to a different container than the
    /// parent-app REST writes, and commands pushed to production become
    /// invisible to the tunnel running against development (or vice
    /// versa). Previously hardcoded to `development`, which broke Release
    /// builds because the shared client correctly flipped to production.
    #if DEBUG
    private static let ckRESTBase = "https://api.apple-cloudkit.com/database/1/\(AppConstants.cloudKitContainerIdentifier)/development/public"
    #else
    private static let ckRESTBase = "https://api.apple-cloudkit.com/database/1/\(AppConstants.cloudKitContainerIdentifier)/production/public"
    #endif

    private static let restSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static func queryCommandsViaREST(familyID: String) async throws -> [[String: String]] {
        let cutoffMs = Int((Date().timeIntervalSince1970 - 86400) * 1000)
        let body: [String: Any] = [
            "query": [
                "recordType": "BBRemoteCommand",
                "filterBy": [
                    ["fieldName": "familyID", "comparator": "EQUALS",
                     "fieldValue": ["value": familyID]],
                    ["fieldName": "status", "comparator": "EQUALS",
                     "fieldValue": ["value": "pending"]],
                    ["fieldName": "issuedAt", "comparator": "GREATER_THAN",
                     "fieldValue": ["value": cutoffMs, "type": "TIMESTAMP"]]
                ],
                "sortBy": [["fieldName": "issuedAt", "ascending": false]]
            ],
            "resultsLimit": 100
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "\(ckRESTBase)/records/query?ckAPIToken=\(ckAPIToken)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, _) = try await restSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["records"] as? [[String: Any]] else {
            return []
        }

        return records.compactMap { rec -> [String: String]? in
            guard let fields = rec["fields"] as? [String: Any],
                  let recordName = (rec["recordName"] as? String)
                    ?? (rec["recordID"] as? [String: Any])?["recordName"] as? String
            else { return nil }
            var dict: [String: String] = ["recordName": recordName]
            for (key, val) in fields {
                if let field = val as? [String: Any], let v = field["value"] {
                    dict[key] = "\(v)"
                }
            }
            return dict
        }
    }

    /// Record that shields have been verified applied for a specific commandID.
    /// Mirrors CommandProcessorImpl.recordShieldsAppliedForCmd — writes both
    /// the ID and the timestamp to AppGroup so the next heartbeat carries them
    /// to the parent. Guards against stomping a newer command's already-
    /// recorded verification: if the current lastCommandID differs from ours,
    /// another command landed between our apply and our verify, and its own
    /// verify path owns the write.
    private static func recordShieldsAppliedForCmd(_ cmdID: String) {
        let defaults = UserDefaults.appGroup
        let currentLatest = defaults?.string(forKey: AppGroupKeys.lastCommandID)
        if let currentLatest, currentLatest != cmdID {
            return
        }
        defaults?.set(cmdID, forKey: AppGroupKeys.lastShieldAppliedForCmdID)
        defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.lastShieldAppliedForCmdAt)
    }

    private static func markCommandAppliedAsync(db: CKDatabase, recordName: String) {
        Task.detached {
            do {
                let record = try await db.record(for: CKRecord.ID(recordName: recordName))
                record["status"] = "applied"
                _ = try? await db.save(record)
            } catch {
                NSLog("[Tunnel] markApplied failed for \(recordName): \(error.localizedDescription)")
            }
        }
    }

    private static func performCKQuery(db: CKDatabase, query: CKQuery, resultsLimit: Int = 100) async throws -> [CKRecord] {
        // CKDatabase.records(matching:resultsLimit:) (iOS 15+) replaces the
        // older `CKQueryOperation` + completion-block pattern. The tuple it
        // returns is `(matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
        // queryCursor: CKQueryOperation.Cursor?)`. We unwrap successes and
        // drop per-record failures (matches prior behavior — the old code
        // silently ignored failed matches inside `recordMatchedBlock`).
        let (matchResults, _) = try await db.records(
            matching: query,
            resultsLimit: resultsLimit
        )
        return matchResults.compactMap { try? $0.1.get() }
    }

    private static func performCKFetch(db: CKDatabase, recordID: CKRecord.ID) async throws -> CKRecord {
        // `CKDatabase.record(for:)` (iOS 15+) is the async replacement for
        // `CKFetchRecordsOperation` with completion blocks. Errors propagate
        // through the async throws — no manual continuation bridging, no
        // lock for resume-once-only semantics.
        try await db.record(for: recordID)
    }

    /// REST-based heartbeat save. Iterates every key on the assembled
    /// CKRecord, marshals it into CK REST's `{value, type}` shape via
    /// `CloudKitRESTClient.fieldValue(_:)`, and submits as a
    /// `forceReplace` modification. Returns `true` if the server
    /// acknowledged the save. Returns `false` (without throwing) on any
    /// network/parse failure so the caller can fall back to the
    /// framework path.
    ///
    /// Using `forceReplace` rather than `update` matches the framework's
    /// default-save behavior for heartbeats, where the writer owns the
    /// full record and we don't want phantom server-side fields from a
    /// previous build's schema.
    private static func saveHeartbeatViaREST(record: CKRecord) async -> Bool {
        var fields: [String: [String: Any]] = [:]
        for key in record.allKeys() {
            let value = record[key]
            // Unwrap NSNumber into its underlying primitive so the
            // marshaler can pick the correct CK type (INT64 vs DOUBLE).
            // Booleans that came in as `1 as NSNumber` become Int here —
            // close enough; CK's INT64 accepts 0/1 as a bool proxy.
            let unwrapped: Any
            if let n = value as? NSNumber {
                // NSNumber covers Int, Double, Bool. Use CFNumberType to
                // pick the right Swift type.
                let type = CFNumberGetType(n as CFNumber)
                switch type {
                case .doubleType, .float32Type, .float64Type, .cgFloatType, .floatType:
                    unwrapped = n.doubleValue
                default:
                    unwrapped = n.int64Value
                }
            } else if let d = value as? Date {
                unwrapped = d
            } else if let s = value as? String {
                unwrapped = s
            } else if let arr = value as? [String] {
                unwrapped = arr
            } else if let arr = value as? NSArray {
                unwrapped = arr as? [String] ?? []
            } else if let v = value {
                unwrapped = v
            } else {
                // Explicit nil — tell REST to clear the field.
                fields[key] = ["value": NSNull()]
                continue
            }
            if let fv = CloudKitRESTClient.fieldValue(unwrapped) {
                fields[key] = fv
            }
        }

        let req = CloudKitRESTClient.ModifyRequest(
            operationType: .forceReplace,
            recordType: record.recordType,
            recordName: record.recordID.recordName,
            fields: fields
        )
        do {
            _ = try await CloudKitRESTClient.modifyRecords([req])
            return true
        } catch {
            NSLog("[Tunnel] Heartbeat REST save failed: \(error.localizedDescription) — falling back to framework")
            return false
        }
    }

    private static func performCKSave(db: CKDatabase, record: CKRecord) async -> Bool {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false

            let op = CKModifyRecordsOperation(recordsToSave: [record])
            op.qualityOfService = .userInitiated
            op.savePolicy = .changedKeys
            op.configuration.timeoutIntervalForRequest = 10
            op.configuration.timeoutIntervalForResource = 15

            op.modifyRecordsResultBlock = { result in
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                lock.unlock()
                switch result {
                case .success: continuation.resume(returning: true)
                case .failure: continuation.resume(returning: false)
                }
            }
            db.add(op)
        }
    }

    /// Periodic auto-reenable check. Called from the 5s liveness timer.
    /// Reads the persisted state and, if it has effectively expired (duration
    /// elapsed or clock rewound), writes a fresh `.defaultEnabled` back to
    /// App Group. Centralized here so the DNSProxy read path stays pure —
    /// no side-effect writes from packet processing.
    ///
    /// ## Race mitigation
    ///
    /// The obvious implementation — `read → compute → write_if_flip` — has a
    /// window where a concurrent fresh disable command can be clobbered:
    ///   1. We read a stale expired state.
    ///   2. Command handler writes a fresh disable.
    ///   3. We write `.defaultEnabled`, silently cancelling the disable.
    /// We close this by re-reading just before writing and bailing if the
    /// state has changed. The remaining race window is the few microseconds
    /// between the second read and the write, which is small enough that a
    /// command arriving in that window would be applied a tick later. For a
    /// remote command with tens/hundreds of ms of network latency inherent,
    /// this is not a meaningful loss.
    static func maintainDNSFilteringAutoReenable() {
        let defaults = UserDefaults.appGroup
        let snapshot = DNSFilteringState.read(from: defaults)
        guard !snapshot.enabled else { return }
        let effective = snapshot.effective(now: Date())
        guard effective.enabled else { return }   // not yet expired

        // Re-read and bail if the state was updated under us — avoids
        // clobbering a just-installed fresh disable command.
        let verify = DNSFilteringState.read(from: defaults)
        guard verify == snapshot else {
            NSLog("[Tunnel] DNS filtering auto-reenable deferred — state changed under us")
            return
        }
        DNSFilteringState.write(.defaultEnabled, to: defaults)
        NSLog("[Tunnel] DNS filtering auto-re-enabled")
    }

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

        // 1. Write TemporaryUnlockState if this is a temporary unlock.
        // Anchor expiry to issuedAt (when parent pressed the button), matching the
        // main app's behavior. This prevents the child from getting extra time when
        // command delivery is delayed.
        if actionType == "temporaryUnlock", let duration = tempUnlockDuration, duration > 0 {
            let issuedAt = record["issuedAt"] as? Date ?? Date()
            let expiresAt = issuedAt.addingTimeInterval(Double(duration))
            // If the unlock already expired before we could process it, skip
            guard expiresAt > Date() else {
                NSLog("[Tunnel] Temp unlock already expired (issued \(issuedAt), duration \(duration)s)")
                record["status"] = "applied"
                _ = try? await db.save(record)
                return
            }
            let currentMode = ModeStackResolver.resolve(storage: storage).mode
            let unlockState = TemporaryUnlockState(
                unlockID: UUID(),
                origin: .remoteCommand,
                previousMode: currentMode == .unlocked ? .restricted : currentMode,
                startedAt: issuedAt,
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
        // Authority must match the action type so ModeStackResolver's
        // priority chain works correctly. Previously this collapsed
        // everything except returnToSchedule into `.parentManual`, which
        // meant a parent's `.lockUntil` command (tap "Restrict for 1 hour")
        // got committed as parentManual when the tunnel processed it ahead
        // of the main app — resolver then fell into Step 4 "Parent command"
        // instead of Step 3 "lockUntil active", overriding the lockUntil
        // stack semantics entirely. Simon hit this repeatedly tonight.
        let authority: ControlAuthority
        switch actionType {
        case "returnToSchedule":
            authority = .schedule
        case "lockUntil":
            authority = .lockUntil
        case "temporaryUnlock":
            authority = .temporaryUnlock
        case "timedUnlock":
            authority = .timedUnlock
        default:
            // setMode, setRestrictions, lockDown, etc. — legitimate parent
            // manual overrides that should win over schedule.
            authority = .parentManual
        }
        // **CRITICAL**: Read the always-allowed tokens FRESH from storage, not from
        // the existing snapshot's copy. The prior snapshot may have been written
        // before applyMode populated this field (pre-b449), in which case its
        // allowedAppTokensData is nil. If we carry nil forward, the Monitor's
        // snapshot fallback kicks in with nil data, falls through to zero tokens,
        // and writes .all() for restricted mode — collapsing it to locked.
        let freshAllowedTokensData = storage.readRawData(forKey: StorageKeys.allowedAppTokens)
            ?? existingPolicy?.allowedAppTokensData
        let correctedPolicy = EffectivePolicy(
            resolvedMode: mode,
            controlAuthority: authority,
            isTemporaryUnlock: isTemp,
            temporaryUnlockExpiresAt: isTemp ? storage.readTemporaryUnlockState()?.expiresAt : nil,
            shieldedCategoriesData: existingPolicy?.shieldedCategoriesData,
            allowedAppTokensData: freshAllowedTokensData,
            warnings: existingPolicy?.warnings ?? [],
            policyVersion: (existingPolicy?.policyVersion ?? 0) + 1
        )
        NSLog("[Tunnel] processCommand(\(actionType) → \(mode.rawValue)): allowedAppTokensData \(freshAllowedTokensData == nil ? "nil" : "\(freshAllowedTokensData!.count)B")")
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

        // 4. DNS enforcement — centralized in applyModeToBlockReasons.
        applyModeToBlockReasons(mode)

        // 5. Mark returnToSchedule flag
        if actionType == "returnToSchedule" {
            UserDefaults.appGroup?
                .set(true, forKey: AppGroupKeys.scheduleDrivenMode)
        } else if actionType == "setMode" {
            UserDefaults.appGroup?
                .set(false, forKey: AppGroupKeys.scheduleDrivenMode)
        }

        // 6. Mark command as applied in CloudKit — fire-and-forget so the
        // confirmation heartbeat can fire immediately (b619). The status update
        // is best-effort; local dedup (markCommandProcessed below) is the
        // authoritative signal that prevents re-processing.
        record["status"] = "applied"
        let statusRecord = record
        Task { _ = await Self.performCKSave(db: db, record: statusRecord) }

        // 7. Mark in shared storage so main app's dedup catches it via readProcessedCommandIDs().
        // The recordName is "BBRemoteCommand_<UUID>" — strip the prefix before
        // parsing as a UUID. The previous version passed the full prefixed name
        // to UUID(uuidString:), which always returned nil and silently skipped
        // the file mark, leaving only the unreliable cross-process UserDefaults
        // path as dedup. Result: every mode command the tunnel processed got
        // re-applied by the main app on its next poll, inflating policyVersion
        // by thousands and creating rolling temp-unlock loops.
        let bareName: String = {
            let prefix = "BBRemoteCommand_"
            if record.recordID.recordName.hasPrefix(prefix) {
                return String(record.recordID.recordName.dropFirst(prefix.count))
            }
            return record.recordID.recordName
        }()
        if let commandUUID = UUID(uuidString: bareName) {
            do {
                try storage.markCommandProcessed(commandUUID)
            } catch {
                NSLog("[Tunnel] markCommandProcessed FAILED for \(commandUUID): \(error.localizedDescription)")
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .command,
                    message: "Tunnel markCommandProcessed failed for \(commandUUID.uuidString.prefix(8)): \(error.localizedDescription)"
                ))
            }
        } else {
            NSLog("[Tunnel] Could not parse UUID from recordName \(record.recordID.recordName) — primary dedup will miss this command")
        }

        // Also mark in tunnel-specific UserDefaults for tunnel's own dedup.
        let defaults = UserDefaults.appGroup
        var appProcessed = defaults?.stringArray(forKey: AppGroupKeys.tunnelAppliedCommandIDs) ?? []
        appProcessed.append(record.recordID.recordName)
        if appProcessed.count > 200 { appProcessed = Array(appProcessed.suffix(200)) }
        defaults?.set(appProcessed, forKey: AppGroupKeys.tunnelAppliedCommandIDs)
        var tunnelProcessed = defaults?.stringArray(forKey: AppGroupKeys.tunnelProcessedCommandIDs) ?? []
        tunnelProcessed.append(record.recordID.recordName)
        if tunnelProcessed.count > 200 { tunnelProcessed = Array(tunnelProcessed.suffix(200)) }
        defaults?.set(tunnelProcessed, forKey: AppGroupKeys.tunnelProcessedCommandIDs)

        // Write lastCommandProcessedAt + lastCommandID so the heartbeat (whether
        // uploaded by the main app or by the tunnel itself) reports that THIS
        // specific command landed. Without this, the parent/test-harness sees
        // hbLastCmdID stuck at an older value whenever the tunnel — not the
        // main app — applied the command. Parity with CommandProcessorImpl:527.
        defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.lastCommandProcessedAt)
        defaults?.set(bareName, forKey: AppGroupKeys.lastCommandID)

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

        // Signal Monitor to re-apply ManagedSettings from the snapshot we
        // wrote. 5s delay (vs the 60s default) so the Monitor wakes for the
        // next-minute boundary, keeping shield-apply latency in the 5-30s
        // range. The Monitor itself stamps `lastShieldAppliedForCmdID` on
        // success (see `stampEnforcementConfirmed` in the Monitor extension),
        // so there's no tunnel-side polling/watcher — that was removed when
        // the Monitor became the authoritative writer.
        scheduleEnforcementRefreshActivity(source: "tunnelCmd.\(actionType)", delaySeconds: 5)
        triggerBackgroundURLSessionWake()

        // Fire an immediate heartbeat so the parent sees the command-ack
        // within seconds. The subsequent Monitor-confirm heartbeat (triggered
        // from `monitorNeedsHeartbeat` on the tunnel's 1s fast-path) carries
        // the shield-confirm.
        Task { await sendHeartbeatFromTunnel(reason: "modeCommandApplied", force: true) }
    }

    #if DEBUG
    /// Entry point for TunnelTestCommandReceiver. Applies a test command
    /// using the same plumbing as the "main app dead" CK-poll path, but
    /// without any CK-side marshalling. Returns after the heartbeat upload
    /// completes so the harness can poll for the updated record.
    ///
    /// This is the BACKGROUND test path — the main app is assumed suspended
    /// or dead. The only writer that can actually flip ManagedSettings
    /// shields is the Monitor extension, which this method wakes via the
    /// same `scheduleEnforcementRefreshActivity` trick the production code
    /// uses. Test latencies observed here are representative of real
    /// production latency when a parent flips a mode and the child's main
    /// app has been suspended.
    func handleTunnelTestNotification(_ notif: TunnelTestCommandReceiver.TestNotification) async {
        NSLog("[Tunnel] handleTunnelTestNotification: \(notif.rawValue)")
        if notif == .requestHeartbeat {
            await sendHeartbeatFromTunnel(reason: "bgTestRequestHeartbeat", force: true)
            return
        }

        // VPN recovery hooks — exercise the tunnel's network recovery paths
        // on wifi-only devices that can't do real interface transitions.
        if notif == .recoverReapply {
            NSLog("[Tunnel] Recovery test: forcing full network settings reapply")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "Recovery test: reapply (simulated interface transition)"
            ))
            reapplyNetworkSettings(force: true)
            // Wait for the reapply to settle, then send a heartbeat so
            // the harness can verify CK connectivity recovered.
            try? await Task.sleep(for: .seconds(3))
            await sendHeartbeatFromTunnel(reason: "bgTest.recoverReapply", force: true)
            return
        }
        if notif == .recoverStaleTransport {
            NSLog("[Tunnel] Recovery test: injecting stale transport state")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "Recovery test: staleTransport (simulated DNS wedge)"
            ))
            networkSettingsNeedRetry = true
            dnsProxy?.markUpstreamUnhealthy()
            // Don't send an immediate heartbeat — the point is to let the
            // 5-second fast-path liveness tick detect the stale state and
            // self-heal. The harness polls until CK ops succeed (heartbeat
            // timestamp advances). Timeout = 30s (6 ticks × 5s).
            return
        }

        guard let mode = notif.mode else { return }
        let isTempUnlock = notif.actionType == "temporaryUnlock"
        let tempDuration = notif.tempUnlockDurationSeconds

        // Replicate the mode-apply body from handleModeCommandFromTunnel,
        // minus CK record bookkeeping.
        if isTempUnlock, let duration = tempDuration, duration > 0 {
            let issuedAt = Date()
            let expiresAt = issuedAt.addingTimeInterval(Double(duration))
            let currentMode = ModeStackResolver.resolve(storage: storage).mode
            let unlockState = TemporaryUnlockState(
                unlockID: UUID(),
                origin: .remoteCommand,
                previousMode: currentMode == .unlocked ? .restricted : currentMode,
                startedAt: issuedAt,
                expiresAt: expiresAt
            )
            try? storage.writeTemporaryUnlockState(unlockState)
        } else {
            try? storage.clearTemporaryUnlockState()
        }

        // Commit the corrected snapshot (same logic as handleModeCommandFromTunnel).
        let existingSnapshot = storage.readPolicySnapshot()
        let existingPolicy = existingSnapshot?.effectivePolicy
        let freshAllowedTokensData = storage.readRawData(forKey: StorageKeys.allowedAppTokens)
            ?? existingPolicy?.allowedAppTokensData
        let correctedPolicy = EffectivePolicy(
            resolvedMode: mode,
            controlAuthority: .parentManual,
            isTemporaryUnlock: isTempUnlock,
            temporaryUnlockExpiresAt: isTempUnlock ? storage.readTemporaryUnlockState()?.expiresAt : nil,
            shieldedCategoriesData: existingPolicy?.shieldedCategoriesData,
            allowedAppTokensData: freshAllowedTokensData,
            warnings: existingPolicy?.warnings ?? [],
            policyVersion: (existingPolicy?.policyVersion ?? 0) + 1
        )
        let correctedSnapshot = PolicySnapshot(
            source: .commandApplied,
            trigger: "Tunnel test: \(notif.actionType) → \(mode.rawValue)",
            effectivePolicy: correctedPolicy
        )
        _ = try? storage.commitCorrectedSnapshot(correctedSnapshot)

        // Mark apply timing for harness metrics. This is written ONLY here
        // on the tunnel side — the Monitor's own apply doesn't touch it.
        let applyDefaults = UserDefaults.appGroup
        let applyStartedAt = Date().timeIntervalSince1970
        applyDefaults?.set(applyStartedAt, forKey: AppGroupKeys.enforcementApplyStartedAt)

        // b468 (three-way audit fix): eagerly write the EXPECTED shield state
        // for this command right now, with a fresh timestamp. Why: the
        // tunnel's Monitor-confirmation poll loop below has a 20s timeout,
        // and in practice DeviceActivity callback scheduling consistently
        // takes ~21s to fire — so the poll times out before Monitor
        // overwrites `shieldsActiveAtLastHeartbeat`. Before this fix, the
        // tunnel's heartbeat read the PREVIOUS iteration's value (which is
        // still <30s old and therefore treated as "fresh" by the wall-clock
        // age check in `sendHeartbeatFromTunnel`), causing every unlock in
        // the bg harness to show `shieldsUp=true` against the new
        // `mode=unlocked`. By writing the expected value here, the next
        // heartbeat reflects the command's intent; Monitor's own write
        // later is either idempotent (same value = confirm) or a correction
        // (main app's 60s verifier will catch drift). See codex audit round
        // 2 on /tmp/bb_unlock_bug.md for the full trace.
        let expectedShieldsUp = (mode != .unlocked)
        applyDefaults?.set(expectedShieldsUp, forKey: AppGroupKeys.shieldsActiveAtLastHeartbeat)
        applyDefaults?.set(applyStartedAt, forKey: AppGroupKeys.shieldsActiveAtLastHeartbeatAt)

        // Update ExtensionSharedState so Monitor reads consistent state.
        let extState = storage.readExtensionSharedState()
        let newExtState = ExtensionSharedState(
            currentMode: mode,
            isTemporaryUnlock: isTempUnlock,
            temporaryUnlockExpiresAt: isTempUnlock ? storage.readTemporaryUnlockState()?.expiresAt : nil,
            authorizationAvailable: extState?.authorizationAvailable ?? true,
            enforcementDegraded: extState?.enforcementDegraded ?? false,
            shieldConfig: extState?.shieldConfig ?? ShieldConfig(),
            writtenAt: Date(),
            policyVersion: (extState?.policyVersion ?? 0) + 1
        )
        try? storage.writeExtensionSharedState(newExtState)

        // DNS enforcement — same as the CK-driven path.
        applyModeToBlockReasons(mode)

        // Record command processing time so the 10s grace in the main app's
        // verifyAndFixEnforcement skips this (if the main app happens to be
        // alive). Avoids a race against the Monitor-driven apply.
        applyDefaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.lastCommandProcessedAt)

        // Wake the Monitor extension so it can apply ManagedSettings shields.
        // Use a short 5s delay for tests — DeviceActivity is reliable with
        // sub-minute delays when the schedule's start is in the future.
        scheduleEnforcementRefreshActivity(source: "bgTest.\(notif.actionType)", delaySeconds: 5)

        // Poll until the Monitor confirms the apply (or time out).
        let triggerTime = Date().timeIntervalSince1970
        for attempt in 1...20 {
            try? await Task.sleep(for: .seconds(1))
            let confirmedAt = applyDefaults?.double(forKey: AppGroupKeys.monitorEnforcementConfirmedAt) ?? 0
            if confirmedAt >= triggerTime {
                NSLog("[Tunnel] bgTest Monitor confirmed after \(attempt)s")
                applyDefaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.enforcementApplyFinishedAt)
                break
            }
        }

        // Send a fresh heartbeat so the harness sees the new policyVersion
        // and shield state as quickly as possible. The tunnel's heartbeat
        // upload reads ModeStackResolver + shield audit flags that the
        // Monitor just wrote, so the harness's lookup-by-ID poll picks
        // this up immediately. `force: true` bypasses the "main app sent
        // one recently" dedup — tests always want to see the tunnel's
        // view after the Monitor wake.
        await sendHeartbeatFromTunnel(reason: "bgTest.\(notif.actionType)", force: true)
    }
    #endif

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
        let defaults = UserDefaults.appGroup
        let allLogs = storage.readDiagnosticEntries(category: nil)
        let recentLogs = Array(allLogs.suffix(50))

        var flags: [String: String] = [
            "source": "vpnTunnel",
            "mainAppAlive": "\(mainAppAlive)",
            "tunnelOwnsHeartbeat": "\(tunnelOwnsHeartbeat)",
            "dns.activeBlockReasons": activeBlockReasons.isEmpty ? "none" : activeBlockReasons.map(\.rawValue).sorted().joined(separator: ", "),
            "dns.shouldBlackhole": "\(shouldBlackhole)",
            "dns.proxyBlackholeMode": "\(dnsProxy?.isBlackholeMode ?? false)",
            "dns.lastAppliedBlackholeState": "\(lastAppliedBlackholeState)",
            "dns.upstreamState": "\(dnsProxy?.upstreamConnectionState.map { "\($0)" } ?? "nil")",
            "dns.pendingQueryCount": "\(dnsProxy?.pendingCount ?? 0)",
            "lastHeartbeatSentAt": "\(defaults?.double(forKey: AppGroupKeys.lastHeartbeatSentAt) ?? 0)",
            "mainAppLastActiveAt": "\(defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0)",
            "tunnelLastActiveAt": "\(defaults?.double(forKey: AppGroupKeys.tunnelLastActiveAt) ?? 0)",
            "mainAppLastLaunchedBuild": "\(defaults?.integer(forKey: AppGroupKeys.mainAppLastLaunchedBuild) ?? 0)",
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
        if modeResolution.mode == .unlocked && activeBlockReasons.contains(.emergencyAppDead) {
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
        let fcAuth = defaults?.string(forKey: AppGroupKeys.familyControlsAuthStatus)
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
        flags["deviceActivity.monitorLastActiveAt"] = "\(defaults?.double(forKey: AppGroupKeys.monitorLastActiveAt) ?? 0)"
        flags["deviceActivity.monitorLastReconcileAt"] = "\(defaults?.double(forKey: AppGroupKeys.monitorLastReconcileAt) ?? 0)"

        // Restrictions from App Group
        if let r = storage.readDeviceRestrictions() {
            flags["restrictions.denyAppRemoval"] = "\(r.denyAppRemoval)"
            flags["restrictions.denyExplicitContent"] = "\(r.denyExplicitContent)"
            flags["restrictions.denyWebWhenRestricted"] = "\(r.denyWebWhenRestricted)"
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
            locationMode: defaults?.string(forKey: AppGroupKeys.locationTrackingMode) ?? "unknown",
            coreMotionAvailable: true,
            coreMotionMonitoring: false,
            isMoving: false,
            isDriving: false,
            vpnTunnelStatus: "running (self)",
            familyControlsAuth: UserDefaults.appGroup?.string(forKey: AppGroupKeys.familyControlsAuthStatus) ?? "unknown (tunnel)",
            currentMode: storage.readPolicySnapshot()?.effectivePolicy.resolvedMode.rawValue ?? "unknown",
            shieldsActive: defaults?.object(forKey: AppGroupKeys.shieldsActiveAtLastHeartbeat) as? Bool ?? false,
            shieldedAppCount: 0,
            shieldCategoryActive: defaults?.object(forKey: AppGroupKeys.shieldsActiveAtLastHeartbeat) as? Bool ?? false,
            lastShieldChangeReason: defaults?.string(forKey: AppGroupKeys.lastShieldChangeReason),
            flags: flags,
            recentLogs: recentLogs
        )

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase
        let ckRecord = CKRecord(recordType: "BBDiagnosticReport",
                                recordID: CKRecord.ID(recordName: "BBDiagnosticReport_\(report.id.uuidString)"))
        ckRecord["deviceID"] = enrollment.deviceID.rawValue
        ckRecord["familyID"] = enrollment.familyID.rawValue
        ckRecord["timestamp"] = Date()
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
    ///
    /// - Parameters:
    ///   - reason: audit trail label.
    ///   - force: bypass the "main app sent one recently, skip" dedup
    ///            check. Test injection paths always want to see the
    ///            tunnel's own view of state even if the main app is alive.
    private func sendHeartbeatFromTunnel(reason: String, force: Bool = false) async {
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
        let defaults = UserDefaults.appGroup
        let lastHBAt = defaults?.double(forKey: AppGroupKeys.lastHeartbeatSentAt) ?? 0
        if !force && mainAppAlive && lastHBAt > 0 && Date().timeIntervalSince1970 - lastHBAt < 120 {
            NSLog("[Tunnel] Main app sent heartbeat recently — skipping")
            return
        }

        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        let db = container.publicCloudDatabase

        let recordID = CKRecord.ID(recordName: "BBHeartbeat_\(enrollment.deviceID.rawValue)")
        let record: CKRecord
        let exhaustedAppState = currentExhaustedAppState()

        // Fetch existing record to preserve change tag (QoS: userInitiated)
        do {
            record = try await Self.performCKFetch(db: db, recordID: recordID)
        } catch {
            record = CKRecord(recordType: "BBHeartbeat", recordID: recordID)
        }

        // Core identity
        record["deviceID"] = enrollment.deviceID.rawValue
        record["familyID"] = enrollment.familyID.rawValue
        record["timestamp"] = Date()
        record["hbAppBuildNumber"] = AppConstants.appBuildNumber as NSNumber
        let mainAppBuild = UserDefaults.appGroup?.integer(forKey: AppGroupKeys.mainAppLastLaunchedBuild) ?? 0
        if mainAppBuild > 0 {
            record["hbMainAppBuild"] = mainAppBuild as NSNumber
        }
        record["hbSource"] = "vpnTunnel"
        record["hbTunnel"] = 1 as NSNumber

        // Extension build numbers — read from App Group (written by each extension when it runs)
        let extDefaults = UserDefaults.appGroup
        let monBuild = extDefaults?.integer(forKey: AppGroupKeys.monitorBuildNumber) ?? 0
        let shieldBuild = extDefaults?.integer(forKey: AppGroupKeys.shieldBuildNumber) ?? 0
        let actionBuild = extDefaults?.integer(forKey: AppGroupKeys.shieldActionBuildNumber) ?? 0
        if monBuild > 0 { record["hbMonitorBuild"] = monBuild as NSNumber }
        if shieldBuild > 0 { record["hbShieldBuild"] = shieldBuild as NSNumber }
        if actionBuild > 0 { record["hbShieldActionBuild"] = actionBuild as NSNumber }

        // FC auth type from App Group (written by main app)
        if let authType = defaults?.string(forKey: AppGroupKeys.authorizationType) {
            record["hbFCAuthType"] = authType
        }
        // Child auth fail reason (why .child wasn't granted)
        if let failReason = defaults?.string(forKey: AppGroupKeys.childAuthFailReason) {
            record["hbFCChildFailReason"] = failReason
        }
        // Per-permission status snapshot (written by main app ChildHomeViewModel)
        if let permJSON = defaults?.string(forKey: AppGroupKeys.permissionSnapshot) {
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

        // Device lock state (read from App Group, written by main app's DeviceLockMonitor)
        let isLocked = UserDefaults.appGroup?
            .bool(forKey: AppGroupKeys.isDeviceLocked) ?? true
        record["hbLocked"] = (isLocked ? 1 : 0) as NSNumber

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
        // The tunnel can't import ManagedSettings, but the main app / Monitor writes
        // this whenever it applies shields.
        //
        // TRANSITION RACE: when the schedule transitions unlocked → restricted,
        // ModeStackResolver.resolve() immediately returns the new mode, but the
        // Monitor extension hasn't yet fired intervalDidEnd → applied shields →
        // written shieldsActiveAtLastHeartbeat. If the tunnel's heartbeat fires
        // during that few-second window, it would report "mode: restricted,
        // shields: down" and trigger a false "shields broken" alert on the parent
        // dashboard.
        //
        // Resolution: if our reported mode is non-unlocked but the shield flag is
        // stale (last written > 30s ago), leave the field unset so the CK record
        // preserves its previous value. Only overwrite when we have fresh
        // evidence that matches the current mode.
        let lastShieldsActive = defaults?.object(forKey: AppGroupKeys.shieldsActiveAtLastHeartbeat) as? Bool
        let shieldFlagWrittenAt = defaults?.double(forKey: AppGroupKeys.shieldsActiveAtLastHeartbeatAt) ?? 0
        let shieldFlagAge = shieldFlagWrittenAt > 0
            ? Date().timeIntervalSince1970 - shieldFlagWrittenAt
            : .infinity
        let shieldFlagIsFresh = shieldFlagAge < 30

        let reportedModeIsUnlocked = modeResolution.mode == .unlocked

        let shouldReportShields: Bool = {
            guard let shieldsActive = lastShieldsActive else { return false }
            // Always OK to report when it matches the mode expectation.
            if reportedModeIsUnlocked && !shieldsActive { return true }
            if !reportedModeIsUnlocked && shieldsActive { return true }
            // Mismatch — only report if the flag was written in the last 30s
            // (i.e., Monitor really did just write it and it's authoritative).
            return shieldFlagIsFresh
        }()

        if shouldReportShields, let shieldsActive = lastShieldsActive {
            record["hbShieldsActive"] = (shieldsActive ? 1 : 0) as NSNumber
            if shieldsActive {
                record["hbShieldCategoryActive"] = 1 as NSNumber
            }
        } else if lastShieldsActive != nil && !reportedModeIsUnlocked {
            // Suppressing a stale "shields down in restricted" report during a
            // transition. Log it so we can confirm the fix is working.
            NSLog("[Tunnel] Suppressed stale shield=down report during mode transition (mode=\(modeResolution.mode.rawValue), flagAge=\(Int(shieldFlagAge))s)")
        }
        // If lastShieldsActive is nil (main app never sent heartbeat), leave fields
        // as-is from the record (may have previous main-app values).

        // DNS blocking state — the tunnel CAN report this directly
        record["hbInetBlocked"] = (shouldBlackhole ? 1 : 0) as NSNumber
        record["hbInternetBlockedReason"] = blockReasonDescription
        let dnsCount = storage.readEnforcementBlockedDomains().count
            + storage.readTimeLimitBlockedDomains().count
        if dnsCount > 0 {
            record["hbDnsBlockedDomainCount"] = dnsCount as NSNumber
        } else {
            record["hbDnsBlockedDomainCount"] = nil
        }
        // Tunnel heartbeats reuse the same CK record as main-app heartbeats.
        // Clear stale per-app usage when the tunnel is the writer, then report
        // the authoritative exhausted-app set from local storage.
        record["hbAppUsageMinutes"] = nil
        record["hbExhaustedFPs"] = exhaustedAppState.fingerprints.flatMap { $0.isEmpty ? nil : $0 as NSArray }
        record["hbExhaustedBIDs"] = exhaustedAppState.bundleIDs.flatMap { $0.isEmpty ? nil : $0 as NSArray }
        record["hbExhaustedNames"] = exhaustedAppState.names.flatMap { $0.isEmpty ? nil : $0 as NSArray }

        // b431: Forward ghost shield detection from ShieldConfiguration extension.
        // Same 24h auto-expiry logic as the main-app heartbeat path.
        // b436 (audit fix): Bound age >= 0 to handle clock skew / future timestamps.
        let ghostSeenAt = defaults?.double(forKey: AppGroupKeys.ghostShieldsDetectedAt) ?? 0
        if ghostSeenAt > 0 {
            let ghostAge = Date().timeIntervalSince1970 - ghostSeenAt
            if ghostAge >= 0 && ghostAge < 86400 {
                record["hbGhostShields"] = 1 as NSNumber
            }
        }
        // Forward fcAuthDegraded too (for symmetry with main-app heartbeat).
        if defaults?.bool(forKey: AppGroupKeys.fcAuthDegraded) == true {
            record["hbFCDegraded"] = 1 as NSNumber
        }

        // Forward lastCommandProcessedAt + lastCommandID so the heartbeat
        // always reflects the most recent command applied — whether the main
        // app or the tunnel did the apply. Matches the fields CommandProcessor
        // and the tunnel's handleModeCommandFromTunnel write to UserDefaults.
        let lastCmdAt = defaults?.double(forKey: AppGroupKeys.lastCommandProcessedAt) ?? 0
        if lastCmdAt > 0 {
            record["hbLastCmdAt"] = Date(timeIntervalSince1970: lastCmdAt) as NSDate
        }
        if let lastCmdID = defaults?.string(forKey: AppGroupKeys.lastCommandID), !lastCmdID.isEmpty {
            record["hbLastCmdID"] = lastCmdID
        }

        // Shield-apply confirmation — the gap between lastCmdAt and
        // hbShldCmdAt is what the kid perceives as shields lagging behind
        // the command.
        let shieldCmdAt = defaults?.double(forKey: AppGroupKeys.lastShieldAppliedForCmdAt) ?? 0
        if shieldCmdAt > 0 {
            record["hbShldCmdAt"] = Date(timeIntervalSince1970: shieldCmdAt) as NSDate
        }
        if let shieldCmdID = defaults?.string(forKey: AppGroupKeys.lastShieldAppliedForCmdID), !shieldCmdID.isEmpty {
            record["hbShldCmdID"] = shieldCmdID
        }

        // Null out fields the tunnel can't provide — prevents stale main-app values
        record["hbDriving"] = nil
        record["hbSpeed"] = nil

        // Rewrite hbDiagnosticSnapshot with the tunnel's current view of the
        // world. Without this, the record keeps whatever structured diagnostic
        // the main app last uploaded, which is invisibly STALE while the
        // tunnel is the only writer — test harness and parent dashboard both
        // read `hbDiagnosticSnapshot.mode` and end up seeing the last
        // main-app-observed mode instead of what just happened.
        //
        // The tunnel can't import ManagedSettings so it can't produce the
        // full DiagnosticSnapshot; we write the minimum subset the harness
        // and dashboard check against (mode, shieldsUp, apply timing) and
        // leave the rest empty/zero. It's a downgrade from the main-app
        // version but strictly fresher than a stale full snapshot.
        let applyStartedTS = defaults?.double(forKey: AppGroupKeys.enforcementApplyStartedAt) ?? 0
        let applyFinishedTS = defaults?.double(forKey: AppGroupKeys.enforcementApplyFinishedAt) ?? 0

        // b468 (three-way audit fix): compute ONE canonical effective shield
        // state and use it for both `hbShieldsActive` (top-level CK field)
        // and `hbDiagnosticSnapshot.shieldsUp` (JSON blob). Previously the
        // two paths diverged: the top-level field applied the
        // 30s-age freshness suppression via `shouldReportShields`, while the
        // diagnostic JSON path unconditionally used `lastShieldsActive ??
        // fallback`. That meant the harness, which reads the JSON blob,
        // saw the raw stale value even when the CK field correctly
        // suppressed it. Unifying them here guarantees both paths report
        // the same thing. See /tmp/bb_unlock_bug.md audit.
        let effectiveShieldsUp: Bool
        if let flagValue = lastShieldsActive,
           shieldFlagWrittenAt >= applyStartedTS,
           shieldFlagIsFresh {
            // Flag was written after (or at) the current apply started AND
            // is within the wall-clock freshness window — trust it as the
            // authoritative confirmed state.
            effectiveShieldsUp = flagValue
        } else {
            // Flag predates the current command, or has no fresh write —
            // fall back to the mode-derived expectation.
            effectiveShieldsUp = modeResolution.mode != .unlocked
        }
        // Keys match `TunnelTelemetry` stored-property names so the parent
        // can decode the top-level JSON as a `DiagnosticSnapshot` without a
        // custom CodingKeys mapping.
        let telemetry = TunnelTelemetry.load()
        var telemetryDict: [String: Any] = [
            "dateString": telemetry.dateString,
            "dnsProbeTimeouts": telemetry.dnsProbeTimeouts,
            "dnsReconnects": telemetry.dnsReconnects,
            "dnsUpstreamWriteErrors": telemetry.dnsUpstreamWriteErrors,
            "pathChanges": telemetry.pathChanges,
            "networkRecoveryL1": telemetry.networkRecoveryL1,
            "networkRecoveryL2": telemetry.networkRecoveryL2,
            "networkRecoveryL3": telemetry.networkRecoveryL3,
            "networkRecoveryL4": telemetry.networkRecoveryL4,
            "tunnelStarts": telemetry.tunnelStarts,
        ]
        if let ts = telemetry.lastReconnectAt { telemetryDict["lastReconnectAt"] = ts }
        if let ts = telemetry.lastProbeTimeoutAt { telemetryDict["lastProbeTimeoutAt"] = ts }
        let tunnelDiagJSON: [String: Any] = [
            "mode": modeResolution.mode.rawValue,
            "authority": modeResolution.controlAuthority.rawValue,
            "reason": modeResolution.reason,
            "isTemporary": modeResolution.isTemporary,
            "shieldsUp": effectiveShieldsUp,
            "shieldsExpected": modeResolution.mode != .unlocked,
            "shieldedAppCount": defaults?.integer(forKey: AppGroupKeys.shieldedAppCount) ?? 0,
            "categoryShieldActive": effectiveShieldsUp && modeResolution.mode != .unlocked,
            "webBlocked": false,
            "shieldReason": defaults?.string(forKey: AppGroupKeys.lastShieldChangeReason) ?? "",
            "shieldAudit": defaults?.string(forKey: AppGroupKeys.lastShieldAudit) ?? "",
            "builds": [
                "app": AppConstants.appBuildNumber,
                "tunnel": AppConstants.appBuildNumber,
                "monitor": monBuild,
                "shield": shieldBuild,
                "shieldAction": actionBuild,
            ],
            "scheduleDriven": AppConstants.isScheduleDriven(),
            "transitions": [],
            "recentLogs": [],
            "applyStartedAt": applyStartedTS,
            "applyFinishedAt": applyFinishedTS,
            "tokenVerdicts": [],
            "shieldRenders": (defaults?.array(forKey: "shieldRenderLog") as? [[String: Any]]) ?? [],
            "monitorConfirmedAt": defaults?.double(forKey: AppGroupKeys.monitorEnforcementConfirmedAt) ?? 0,
            "telemetry": telemetryDict,
        ]
        if let diagData = try? JSONSerialization.data(withJSONObject: tunnelDiagJSON, options: []),
           let diagStr = String(data: diagData, encoding: .utf8) {
            record["hbDiagnosticSnapshot"] = diagStr
        }

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
            // REST-first save. The framework's `db.save(_)` routes through
            // cloudd, which hangs silently after ~3 min of backgrounding
            // (tunnel-specific variant of the parent-side hangs that cost
            // the user an afternoon on 2026-04-15). URLSession REST has a
            // real timeout and no daemon dependency, so the child can keep
            // uploading heartbeats even when cloudd on her device is
            // wedged from install churn. Framework save is a last-resort
            // fallback only.
            let restSaved = await Self.saveHeartbeatViaREST(record: record)
            if !restSaved {
                let saved = await Self.performCKSave(db: db, record: record)
                if !saved { throw NSError(domain: "CKSave", code: -1) }
            }
            heartbeatPermissionFailures = 0
            // Don't feed heartbeat results into the recovery ladder.
            // Heartbeat CK saves hang after ~3 min of background (cloudd
            // throttling) but that doesn't mean the tunnel is broken —
            // command polling uses URLSession REST and works fine.
        } catch {
            // "WRITE operation not permitted" = record owned by a different iCloud account.
            // Delete the stale record and create a fresh one we own.
            let desc = error.localizedDescription.lowercased()
            if desc.contains("permission") || desc.contains("not permitted") {
                heartbeatPermissionFailures += 1
                NSLog("[Tunnel] Heartbeat permission denied (attempt \(heartbeatPermissionFailures)) — deleting stale record and recreating")
                // b457: check the delete result. If the delete itself fails
                // with a permission error, the record is owned by an iCloud
                // account we can no longer touch — recreating will also fail
                // and the loop will retry forever (previous bug was silent
                // `_ = try? await db.deleteRecord(...)` discarding the error
                // and always falling through to the save, which ALSO fails,
                // and then we back off only the save attempt). Detect this
                // case and bail early so we don't wedge CloudKit with a
                // poisoned record we can't modify. Re-enrollment is the only
                // real fix; mark a flag so the main app can nudge the kid.
                var deleteFailedPermission = false
                do {
                    _ = try await db.deleteRecord(withID: recordID)
                } catch let deleteError {
                    let deleteDesc = deleteError.localizedDescription.lowercased()
                    if deleteDesc.contains("permission") || deleteDesc.contains("not permitted") {
                        deleteFailedPermission = true
                    }
                    NSLog("[Tunnel] Heartbeat record delete failed: \(deleteError.localizedDescription)")
                }
                if deleteFailedPermission {
                    UserDefaults.appGroup?
                        .set(true, forKey: AppGroupKeys.tunnelHeartbeatRecordPoisoned)
                    try? storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .command,
                        message: "Heartbeat record poisoned — delete permission-denied",
                        details: "Record owned by a different iCloud account; re-enrollment required."
                    ))
                    // Long backoff so we don't spin on an unfixable condition.
                    heartbeatPermissionBackoffUntil = Date().addingTimeInterval(300)
                    return
                }
                let fresh = CKRecord(recordType: "BBHeartbeat", recordID: recordID)
                for key in record.allKeys() { fresh[key] = record[key] }
                do {
                    try await db.save(fresh)
                    heartbeatPermissionFailures = 0 // Recreate succeeded
                    // Clear the poison flag — delete+recreate healed.
                    UserDefaults.appGroup?
                        .removeObject(forKey: AppGroupKeys.tunnelHeartbeatRecordPoisoned)
                    // Heartbeat recreate success — don't feed recovery ladder
                } catch {
                    // Exponential backoff: 1min, 2min, 4min, max 5min.
                    // Heartbeats are critical — never go silent for more than 5 minutes.
                    let backoff = min(60.0 * pow(2.0, Double(heartbeatPermissionFailures - 1)), 300)
                    heartbeatPermissionBackoffUntil = Date().addingTimeInterval(backoff)
                    NSLog("[Tunnel] Heartbeat recreate failed — backing off \(Int(backoff))s")
                    // Don't feed permission failures into the DNS recovery ladder —
                    // permission errors are an account-level issue, not a network one.
                    return
                }
            } else {
                NSLog("[Tunnel] Heartbeat failed: \(error.localizedDescription)")
                // b468: DO NOT feed heartbeat failures into the network recovery ladder.
                // Framework-based CloudKit saves (db.save) are throttled by cloudd after
                // ~3 minutes of the main app being backgrounded, even when the tunnel
                // itself has perfect internet access. Command polling (which uses
                // URLSession REST) is the source of truth for tunnel health.
                return
            }
        }

        defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.lastHeartbeatSentAt)
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
        let dateStr = date ?? screenTimeTodayString()

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
        stRecord["timestamp"] = Date()
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


    // MARK: - Status

    private func writeTunnelStatus(_ status: String) {
        UserDefaults.appGroup?
            .set(status, forKey: AppGroupKeys.tunnelStatus)
        UserDefaults.appGroup?
            .set(Date().timeIntervalSince1970, forKey: AppGroupKeys.tunnelLastActiveAt)
    }

    // MARK: - Network Path Monitoring

    /// NWPathMonitor provides instant callbacks on path transitions (WiFi↔cell,
    /// WiFi→different WiFi, loss of connectivity, etc). The old implementation
    /// polled defaultPath.hashValue every 30s from the liveness timer — but
    /// NWPath.hashValue is not a reliable change-detection signal and the 30s
    /// polling interval left the kid with 0-30 seconds of broken DNS on every
    /// network transition (because the NWUDPSession used for upstream DNS is
    /// bound to the original interface and becomes invalid when that interface
    /// goes away). NWPathMonitor fires immediately and provides a stable
    /// interface-based identity we can compare.
    private var pathMonitor: NWPathMonitor?
    private var lastPathInterfaceSignature: String = ""
    private var pathMonitorQueue: DispatchQueue?
    private var pathDebounceWork: DispatchWorkItem?

    private func startNetworkPathMonitoring() {
        // b466 (three-way audit): reset the seed flag so the very next
        // callback is treated as a snapshot, not a real transition. The
        // previous code left `lastPathInterfaceSignature` empty with a
        // comment claiming that would seed-suppress the first update —
        // but `handlePathUpdate` only skips when the new signature
        // EQUALS the last one, and an empty string never equals a real
        // signature. So the very first callback always looked like a
        // transition and fired a full `reapplyNetworkSettings(force: true)`
        // on every tunnel boot, which in turn called
        // `dnsProxy.startReadLoop()` a second time and permanently left
        // two concurrent read loops sharing packetFlow. This is one of
        // the root causes of the post-reboot "tunnel wedges after a few
        // minutes" failure on Olivia's iPad.
        pathMonitorInitialCallbackPending = true
        let queue = DispatchQueue(label: "fr.bigbrother.tunnel.pathMonitor")
        pathMonitorQueue = queue
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// True until the first `NWPathMonitor.pathUpdateHandler` callback
    /// has been absorbed as a seed. Prevents the boot-time first-callback
    /// from looking like a real network transition.
    private var pathMonitorInitialCallbackPending: Bool = true

    private func stopNetworkPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        // Cancel any pending debounced path-change work so it cannot fire
        // after stopTunnel and trigger a rogue `dnsProxy.healthCheck()` →
        // `reconnectUpstream()` that resurrects the upstream connection
        // during teardown. `DNSProxy.stop()` also gates `setupUpstreamConnection`
        // behind a `stopped` flag, but cancelling here avoids even the
        // queued work's useless wakeup.
        pathDebounceWork?.cancel()
        pathDebounceWork = nil
    }

    /// Build a stable identity for an NWPath based on its interfaces and status.
    /// Two NWPath instances that represent the same underlying network produce
    /// the same signature; a network transition produces a different one.
    private static func pathSignature(for path: Network.NWPath) -> String {
        let status = "\(path.status)"
        let interfaces = path.availableInterfaces
            .map { "\($0.type):\($0.name)" }
            .sorted()
            .joined(separator: ",")
        let isExpensive = path.isExpensive ? "exp" : "noexp"
        let supportsV4 = path.supportsIPv4 ? "v4" : ""
        let supportsV6 = path.supportsIPv6 ? "v6" : ""
        return "\(status)|\(interfaces)|\(isExpensive)|\(supportsV4)\(supportsV6)"
    }

    /// Track whether the path was previously satisfied. Used to detect
    /// unsatisfied→satisfied recoveries that warrant a full network settings
    /// reapply rather than a cheap session bounce.
    private var lastPathStatusSatisfied: Bool = true

    private func handlePathUpdate(_ path: Network.NWPath) {
        let signature = Self.pathSignature(for: path)

        // b466 (three-way audit fix): absorb the FIRST callback as a seed
        // without firing any reapply. NWPathMonitor delivers the current
        // snapshot on subscribe, and we don't want the boot-time snapshot
        // to look like a transition from "" → "real-signature".
        if pathMonitorInitialCallbackPending {
            pathMonitorInitialCallbackPending = false
            lastPathInterfaceSignature = signature
            lastPathStatusSatisfied = path.status == .satisfied
            NSLog("[Tunnel] Network path seed: '\(signature)' (status: \(path.status)) — no reapply")
            // Persist for other code that reads the last-known signature.
            let seedDefaults = UserDefaults.appGroup
            seedDefaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.tunnelNetworkPathChangedAt)
            seedDefaults?.set(signature, forKey: AppGroupKeys.tunnelLastPathSignature)
            return
        }

        // Skip if the signature hasn't actually changed.
        if signature == lastPathInterfaceSignature { return }
        let previous = lastPathInterfaceSignature
        lastPathInterfaceSignature = signature

        let nowSatisfied = path.status == .satisfied
        lastPathStatusSatisfied = nowSatisfied

        // Telemetry: count real interface transitions (wifi↔cell swaps,
        // satisfied↔unsatisfied flips). Excludes the first-callback seed.
        TunnelTelemetry.update { $0.pathChanges += 1 }

        NSLog("[Tunnel] Network path changed — was '\(previous)', now '\(signature)' (status: \(path.status))")

        // b513: Debounce rapid network transitions. Toggling wifi off produces
        // multiple intermediate states (wifi+cell → cell → wifi+cell → ...) within
        // milliseconds. Without debouncing, each one fires a full
        // setTunnelNetworkSettings call. While reapplyNetworkSettings coalesces
        // concurrent calls, the rapid destroy/recreate of the DNS upstream session
        // breaks cloudd's DNS path and wedges CloudKit as "temporarilyUnavailable"
        // for minutes. Wait 2 seconds after the LAST path change before reapplying.
        pathDebounceWork?.cancel()

        if nowSatisfied {
            // Immediately reconnect upstream DNS — cheap, no downtime.
            // This alone fixes most wifi↔cellular transitions.
            self.dnsProxy?.reconnectUpstream()
            NSLog("[Tunnel] Network changed — reconnected upstream DNS (instant)")

            // Schedule a health check after the network settles.
            // Only do the expensive full re-plumb if DNS is actually broken.
            let capturedSignature = signature
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let healthy = self.dnsProxy?.healthCheck() ?? false
                if !healthy {
                    NSLog("[Tunnel] DNS health failed after network change — full re-plumb")
                    try? self.storage.appendDiagnosticEntry(DiagnosticEntry(
                        category: .command,
                        message: "Network path transition — re-plumbing tunnel",
                        details: "DNS unhealthy after interface change to \(capturedSignature)"
                    ))
                    self.reapplyNetworkSettings(force: true)
                } else {
                    NSLog("[Tunnel] DNS healthy after network change — skipping re-plumb")
                }
            }
            pathDebounceWork = work
            (pathMonitorQueue ?? DispatchQueue.global()).asyncAfter(
                deadline: .now() + 3.0, execute: work
            )
        }

        // Signal main app that the device likely moved (cell tower / WiFi change).
        let defaults = UserDefaults.appGroup
        defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupKeys.tunnelNetworkPathChangedAt)
        defaults?.set(signature, forKey: AppGroupKeys.tunnelLastPathSignature)
    }

    /// Legacy periodic safety-net check, still called from the liveness timer.
    /// NWPathMonitor (started in startNetworkPathMonitoring) is the primary
    /// trigger. This is just a watchdog to re-seed the monitor if it ever
    /// dies. The DNS proxy's own healthCheck handles stuck sessions.
    private func checkNetworkPathAndReconnect() {
        if pathMonitor == nil {
            NSLog("[Tunnel] Path monitor missing — re-seeding")
            startNetworkPathMonitoring()
        }
    }

    /// Register a network operation result (e.g. command poll or DNS health check).
    /// Triggers the recovery ladder when consecutive failures cross escalating thresholds.
    private func recordNetworkHealthResult(success: Bool, reason: String) {
        if success {
            if consecutiveHealthFailures > 0 {
                let streak = consecutiveHealthFailures
                NSLog("[Tunnel] Network health recovered after \(streak) consecutive failures")
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .command,
                    message: "Network health recovered after \(streak) consecutive failures (recovery level reached: \(healthRecoveryLevel))"
                ))
            }
            consecutiveHealthFailures = 0
            healthStreakStartedAt = nil
            healthRecoveryLevel = 0
            return
        }

        consecutiveHealthFailures += 1
        if healthStreakStartedAt == nil {
            healthStreakStartedAt = Date()
        }
        escalateNetworkRecoveryIfNeeded(reason: reason)
    }

    /// Escalating recovery ladder. Each level is more invasive but all are
    /// invisible to the user — no Settings toggling required. The levels
    /// fire once per streak (tracked via healthRecoveryLevel), in order:
    ///
    ///   L1 (6 failures, ~1 min):  DNS proxy reconnectUpstream()
    ///   L2 (18 failures, ~3 min): recreate DNS proxy entirely
    ///   L3 (36 failures, ~6 min): reapplyNetworkSettings(force: true) — full re-plumb
    ///   L4 (60 failures, ~10 min): cancelTunnelWithError() → OS restarts us
    ///
    /// Thresholds are based on the 5-second liveness timer ticks.
    /// 60 consecutive failures = 5 minutes of total connectivity loss via REST polling.
    private func escalateNetworkRecoveryIfNeeded(reason: String) {
        // Throttle: never fire two recovery actions within 60 seconds
        if let last = lastHealthRecoveryAction,
           Date().timeIntervalSince(last) < 60 {
            return
        }

        let count = consecutiveHealthFailures

        // FAST L3: if APNs still works (recent ping from app) but network
        // operations fail, that's likely a wedged interface/NWUDPSession.
        let now = Date()
        let recentlyHeardFromApp: Bool = {
            guard let lastPing = lastPingFromApp else { return false }
            return now.timeIntervalSince(lastPing) < 120
        }()
        if healthRecoveryLevel < 3 && count >= 12 && recentlyHeardFromApp {
            healthRecoveryLevel = 3
            lastHealthRecoveryAction = now
            NSLog("[Tunnel] Network recovery FAST L3: reapplyNetworkSettings (count=\(count), reason=\(reason))")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "Network recovery FAST L3: reapplyNetworkSettings (DNS bound to dead interface)",
                details: "Failures=\(count), reason=\(reason). APNs working (recent ping), REST/DNS failing — classic stale NWUDPSession."
            ))
            reapplyNetworkSettings(force: true)
            TunnelTelemetry.update { $0.networkRecoveryL3 += 1 }
            return
        }

        if healthRecoveryLevel < 1 && count >= 6 {
            healthRecoveryLevel = 1
            lastHealthRecoveryAction = Date()
            NSLog("[Tunnel] Network recovery L1: reconnectUpstream (\(count) failures, reason=\(reason))")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "Network recovery L1: reconnectUpstream",
                details: "Failures=\(count), reason=\(reason)"
            ))
            dnsProxy?.reconnectUpstream()
            TunnelTelemetry.update { $0.networkRecoveryL1 += 1 }
            return
        }

        if healthRecoveryLevel < 2 && count >= 18 {
            healthRecoveryLevel = 2
            lastHealthRecoveryAction = Date()
            NSLog("[Tunnel] Network recovery L2: recreate DNS proxy (\(count) failures, reason=\(reason))")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "Network recovery L2: recreate DNS proxy",
                details: "Failures=\(count), reason=\(reason)"
            ))
            recreateDNSProxy()
            TunnelTelemetry.update { $0.networkRecoveryL2 += 1 }
            return
        }

        if healthRecoveryLevel < 3 && count >= 36 {
            healthRecoveryLevel = 3
            lastHealthRecoveryAction = Date()
            NSLog("[Tunnel] Network recovery L3: reapplyNetworkSettings (\(count) failures, reason=\(reason))")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "Network recovery L3: reapplyNetworkSettings",
                details: "Failures=\(count), reason=\(reason)"
            ))
            reasserting = true
            reapplyNetworkSettings(force: true)
            TunnelTelemetry.update { $0.networkRecoveryL3 += 1 }
            return
        }

        if healthRecoveryLevel < 4 && count >= 60 {
            healthRecoveryLevel = 4
            lastHealthRecoveryAction = Date()
            NSLog("[Tunnel] Network recovery L4: RESTARTING TUNNEL (\(count) failures, reason=\(reason))")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .command,
                message: "L4 Recovery: Restarting tunnel after \(count) consecutive health failures",
                details: "Last failure reason: \(reason)"
            ))
            TunnelTelemetry.update { $0.networkRecoveryL4 += 1 }
            // Clear reasserting first so iOS treats the cancel as a real failure and relaunches us.
            reasserting = false
            cancelTunnelWithError(NSError(domain: "fr.bigbrother.recovery", code: 4, userInfo: [NSLocalizedDescriptionKey: "L4 Network Recovery: \(reason)"]))
        }
    }

    /// Recreate the DNS proxy from scratch on the current provider. Does NOT
    /// reapply network settings — just rebuilds the DNSProxy instance so the
    /// NWUDPSession is freshly allocated against the current interface. Used
    /// by the recovery ladder as a middle-ground between reconnectUpstream
    /// (cheap, targeted) and full network-settings reapply (expensive).
    private func recreateDNSProxy() {
        let safeSearchEnabled = UserDefaults.appGroup?
            .bool(forKey: AppGroupKeys.safeSearchEnabled) ?? false
        let upstreamDNS: String
        if shouldBlackhole {
            upstreamDNS = "1.1.1.1"
        } else if safeSearchEnabled {
            upstreamDNS = "185.228.168.168"
        } else {
            upstreamDNS = "1.1.1.1"
        }

        dnsProxy?.stop()
        dnsProxy = nil
        dnsProxy = DNSProxy(provider: self, upstreamDNSServer: upstreamDNS, storage: storage)
        dnsProxy?.onAppDomainSeen = { [weak self] appName, domain, at in
            self?.handleAppDomainSeen(appName: appName, domain: domain, at: at)
        }
        dnsProxy?.isBlackholeMode = shouldBlackhole
        dnsProxy?.start()
        NSLog("[Tunnel] DNS proxy recreated with upstream \(upstreamDNS)")
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
        let defaults = UserDefaults.appGroup
        let rawLocked = defaults?.bool(forKey: AppGroupKeys.isDeviceLocked) ?? true
        let lockedAt = defaults?.double(forKey: "isDeviceLockedAt") ?? 0
        let stale = lockedAt == 0 || (Date().timeIntervalSince1970 - lockedAt) > 120
        let locked = stale ? true : rawLocked
        dnsProxy?.isDeviceLocked = locked
        if !locked { lastUnlockAt = Date() }
        NSLog("[Tunnel] Screen lock monitoring started (initial: \(locked ? "locked" : "unlocked"), stale: \(stale))")
    }

    private func stopScreenLockMonitoring() {
        // No cleanup needed — we poll from App Group instead of using Darwin notifications.
    }

    /// Poll screen lock state from App Group (written by main app's DeviceLockMonitor).
    /// Treats stale or missing lock state as locked (conservative — avoids phantom screen time).
    private func pollScreenLockState() {
        let defaults = UserDefaults.appGroup
        let rawLocked = defaults?.bool(forKey: AppGroupKeys.isDeviceLocked) ?? true
        let lockedAt = defaults?.double(forKey: "isDeviceLockedAt") ?? 0
        let stale = lockedAt == 0 || (Date().timeIntervalSince1970 - lockedAt) > 120
        let locked = stale ? true : rawLocked
        let wasLocked = dnsProxy?.isDeviceLocked ?? true
        if locked != wasLocked {
            handleScreenLockTransition(locked: locked)
        }
    }

    private func handleScreenLockTransition(locked: Bool) {
        // Update DNS proxy so it skips activity counting while screen is locked.
        dnsProxy?.isDeviceLocked = locked

        // Always track screen time from the tunnel — it's the only process that
        // reliably receives every lock/unlock transition. The main app's
        // DeviceLockMonitor misses transitions when iOS suspends the app.

        let defaults = UserDefaults.appGroup
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
        // Split session at midnight if it spans two days.
        let sessionStart = Date().addingTimeInterval(TimeInterval(-seconds))
        let startDate = screenTimeTodayString(for: sessionStart)
        if startDate != date && seconds > 0 {
            let cal = Calendar.current
            let midnight = cal.startOfDay(for: Date())
            let beforeMidnight = max(1, Int(midnight.timeIntervalSince(sessionStart)))
            let afterMidnight = seconds - beforeMidnight
            if beforeMidnight > 0 {
                addScreenTimeToDate(seconds: beforeMidnight, date: startDate, defaults: defaults)
            }
            if afterMidnight > 0 {
                addScreenTimeToDate(seconds: afterMidnight, date: date, defaults: defaults)
            }
            return
        }
        addScreenTimeToDate(seconds: seconds, date: date, defaults: defaults)
    }

    private func addScreenTimeToDate(seconds: Int, date: String, defaults: UserDefaults?) {
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
            // The end of slot N is the start of slot N+1. Computing `minute =
            // ((slotIndex % 4) + 1) * 15` produced an invalid DateComponent of
            // `minute: 60` for the last quarter (e.g. 14:45→15:00), which
            // `Calendar.date(bySettingHour:minute:second:of:)` silently rejects
            // — the `?? endTime` fallback then lumps every last-quarter chunk
            // into the remainder-of-day, corrupting `slotsJSON` on the child
            // detail timeline. Roll minute=60 → hour+1, minute=0.
            let minuteInHour = ((slotIndex % 4) + 1) * 15
            let (endHour, endMinute) = minuteInHour >= 60
                ? ((slotIndex / 4) + 1, 0)
                : (slotIndex / 4, minuteInHour)
            let slotEnd = cal.date(bySettingHour: endHour, minute: endMinute, second: 0, of: cursor) ?? endTime
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
        let flushDefaults = UserDefaults.appGroup
        let rawLocked = flushDefaults?.bool(forKey: AppGroupKeys.isDeviceLocked) ?? true
        let lockedAt = flushDefaults?.double(forKey: "isDeviceLockedAt") ?? 0
        let stale = lockedAt == 0 || (Date().timeIntervalSince1970 - lockedAt) > 120
        let screenLocked = stale ? true : rawLocked
        guard !screenLocked else {
            // Screen is locked — lock handler already counted this session.
            lastUnlockAt = nil
            return
        }
        let sessionSeconds = Int(Date().timeIntervalSince(unlockTime))
        guard sessionSeconds > 0 else { return }
        let defaults = UserDefaults.appGroup
        addScreenTimeFromTunnel(seconds: sessionSeconds, date: screenTimeTodayString(), defaults: defaults)
        lastUnlockAt = Date()
    }

    private func checkFlushRequest() {
        let defaults = UserDefaults.appGroup
        guard let requestedAt = defaults?.double(forKey: "tunnelFlushRequestedAt"),
              requestedAt > 0,
              Date().timeIntervalSince1970 - requestedAt < 10 else { return }
        defaults?.removeObject(forKey: "tunnelFlushRequestedAt")
        flushScreenTimeSession()
    }

    private func screenTimeTodayString(for date: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func isUsefulAppName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized != "app"
            && normalized != "application"
            && normalized != "unknown"
            && normalized != "restricted app"
    }
}
