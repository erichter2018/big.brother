import NetworkExtension
import CloudKit
import UserNotifications
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
    private var lastPingFromApp: Date?

    /// Whether the main app is considered alive.
    private var mainAppAlive = true

    /// Prevent duplicate heartbeats — only send from tunnel when main app is dead.
    private var tunnelOwnsHeartbeat = false

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[Tunnel] startTunnel called")

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

        if safeSearchEnabled {
            // CleanBrowsing Family Filter DNS: enforces safe search on major search engines
            // and blocks adult content domains at the DNS level.
            let dns = NEDNSSettings(servers: ["185.228.168.168", "185.228.169.168"])
            dns.matchDomains = [""]  // Match ALL domains (empty string = default DNS)
            settings.dnsSettings = dns
            NSLog("[Tunnel] DNS safe search enabled (CleanBrowsing Family)")
        }

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                NSLog("[Tunnel] Failed to set network settings: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            NSLog("[Tunnel] Tunnel started successfully (no-route mode)")

            self?.writeTunnelStatus("running")
            self?.startHeartbeatTimer()
            self?.startLivenessTimer()

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[Tunnel] stopTunnel called (reason: \(reason.rawValue))")

        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        livenessTimer?.cancel()
        livenessTimer = nil

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
            // Main app is alive
            lastPingFromApp = Date()
            if !mainAppAlive {
                NSLog("[Tunnel] Main app came back alive")
                mainAppAlive = true
                tunnelOwnsHeartbeat = false
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
            Task { await self.sendHeartbeatFromTunnel(reason: "timer") }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - App Liveness Detection

    /// Check every 60 seconds if the main app is still alive + poll for pending commands.
    private var lastScheduleSyncAt: Date?

    private func startLivenessTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.checkAppLiveness()
            Task {
                await self?.pollAndProcessCommands()
                await self?.syncScheduleProfileIfNeeded()
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
            // App just died
            NSLog("[Tunnel] Main app appears dead — taking over heartbeat duties")
            mainAppAlive = false
            tunnelOwnsHeartbeat = true

            // Send immediate heartbeat
            Task { await sendHeartbeatFromTunnel(reason: "appDeath") }

            // Notify the child to reopen the app
            sendReopenNotification()
        } else if !appDead && !mainAppAlive {
            // App came back (via App Group timestamp, before IPC resumes)
            NSLog("[Tunnel] Main app appears alive again (App Group timestamp updated)")
            mainAppAlive = true
            tunnelOwnsHeartbeat = false
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

                var freeWindows: [ActiveWindow] = []
                var essentialWindows: [ActiveWindow] = []

                if let freeJSON = record["freeWindowsJSON"] as? String,
                   let freeData = freeJSON.data(using: .utf8) {
                    freeWindows = (try? JSONDecoder().decode([ActiveWindow].self, from: freeData)) ?? []
                }
                if let essJSON = record["essentialWindowsJSON"] as? String,
                   let essData = essJSON.data(using: .utf8) {
                    essentialWindows = (try? JSONDecoder().decode([ActiveWindow].self, from: essData)) ?? []
                }

                let lockedModeRaw = record["lockedMode"] as? String ?? "dailyMode"
                let lockedMode = LockMode(rawValue: lockedModeRaw) ?? .dailyMode

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
                    freeWindows: freeWindows,
                    essentialWindows: essentialWindows,
                    lockedMode: lockedMode,
                    exceptionDates: exceptionDates,
                    updatedAt: updatedAt
                )

                // Compare with local — check all fields, not just windows
                let local = storage.readActiveScheduleProfile()
                if local != profile {
                    try? storage.writeActiveScheduleProfile(profile)
                    NSLog("[Tunnel] Schedule profile synced: \(name) (\(essentialWindows.count) essential, \(freeWindows.count) free windows)")
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

        do {
            let (results, _) = try await db.records(matching: query, resultsLimit: 10)
            for (_, result) in results {
                guard let record = try? result.get() else { continue }
                let actionJSON = record["actionJSON"] as? String ?? ""
                let commandID = record.recordID.recordName
                let targetType = record["targetType"] as? String ?? ""
                let targetID = record["targetID"] as? String ?? ""

                // Check if this command targets our device
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

                // Handle simple commands from the tunnel
                if actionJSON.contains("requestHeartbeat") {
                    await sendHeartbeatFromTunnel(reason: "command")
                    record["status"] = "applied"
                    try? await db.save(record)
                    NSLog("[Tunnel] Processed requestHeartbeat command: \(commandID)")
                } else if actionJSON.contains("requestDiagnostics") {
                    await collectAndUploadDiagnostics(enrollment: enrollment)
                    record["status"] = "applied"
                    try? await db.save(record)
                    NSLog("[Tunnel] Processed requestDiagnostics command: \(commandID)")
                }
                // Other commands are left for the main app
            }
        } catch {
            // Silently fail — command polling is best-effort
        }
    }

    /// Collect a lightweight diagnostic report from the tunnel (less complete than main app).
    private func collectAndUploadDiagnostics(enrollment: ChildEnrollmentState) async {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let allLogs = storage.readDiagnosticEntries(category: nil)
        let recentLogs = Array(allLogs.suffix(50))

        let report = DiagnosticReport(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            appBuildNumber: AppConstants.appBuildNumber,
            deviceRole: "child (via tunnel)",
            locationMode: defaults?.string(forKey: "locationTrackingMode") ?? "unknown",
            coreMotionAvailable: true,
            coreMotionMonitoring: false, // Can't check from tunnel
            isMoving: false,
            isDriving: false,
            vpnTunnelStatus: "running (self)",
            familyControlsAuth: "unknown (tunnel)",
            currentMode: storage.readPolicySnapshot()?.effectivePolicy.resolvedMode.rawValue ?? "unknown",
            shieldsActive: false, // Can't check ManagedSettingsStore from tunnel
            shieldedAppCount: 0,
            shieldCategoryActive: false,
            lastShieldChangeReason: defaults?.string(forKey: "lastShieldChangeReason"),
            flags: [
                "source": "vpnTunnel",
                "mainAppAlive": "\(mainAppAlive)",
                "tunnelOwnsHeartbeat": "\(tunnelOwnsHeartbeat)",
                "lastHeartbeatSentAt": "\(defaults?.double(forKey: "lastHeartbeatSentAt") ?? 0)",
                "mainAppLastActiveAt": "\(defaults?.double(forKey: "mainAppLastActiveAt") ?? 0)",
                "tunnelLastActiveAt": "\(defaults?.double(forKey: "tunnelLastActiveAt") ?? 0)",
                "mainAppLastLaunchedBuild": "\(defaults?.integer(forKey: "mainAppLastLaunchedBuild") ?? 0)",
            ],
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
        try? await db.save(ckRecord)
        NSLog("[Tunnel] Diagnostic report uploaded (\(recentLogs.count) log entries)")
    }

    // MARK: - CloudKit Heartbeat

    /// Send a lightweight heartbeat to CloudKit from the tunnel extension.
    /// Uses the same BBHeartbeat record type and deviceID as the main app.
    private func sendHeartbeatFromTunnel(reason: String) async {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else {
            NSLog("[Tunnel] No enrollment state — cannot send heartbeat")
            return
        }

        // Check if main app recently sent a heartbeat (coordination to avoid duplicates)
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let lastHBAt = defaults?.double(forKey: "lastHeartbeatSentAt") ?? 0
        if lastHBAt > 0 && Date().timeIntervalSince1970 - lastHBAt < 120 {
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

        // Write minimal heartbeat fields
        record["deviceID"] = enrollment.deviceID.rawValue
        record["familyID"] = enrollment.familyID.rawValue
        record["timestamp"] = Date() as NSDate
        record["hbAppBuildNumber"] = AppConstants.appBuildNumber as NSNumber
        record["hbSource"] = "vpnExtension" // Signal that this came from the tunnel
        record["hbTunnel"] = 1 as NSNumber

        // Report actual enforcement state from App Group.
        // The tunnel cannot read ManagedSettingsStore, so use the best available
        // actual-state source: ExtensionSharedState (written by Monitor after
        // each enforcement action), then fall back to PolicySnapshot.
        let policyVersion = storage.readPolicySnapshot()?.effectivePolicy.policyVersion ?? 0
        if let extState = storage.readExtensionSharedState() {
            record["currentMode"] = extState.currentMode.rawValue
        } else if let snap = storage.readPolicySnapshot() {
            record["currentMode"] = snap.effectivePolicy.resolvedMode.rawValue
        }
        record["policyVersion"] = policyVersion as NSNumber

        // Battery level
        #if canImport(UIKit)
        // UIDevice not available in NE extension — skip battery
        #endif

        do {
            try await db.save(record)
            defaults?.set(Date().timeIntervalSince1970, forKey: "lastHeartbeatSentAt")
            NSLog("[Tunnel] Heartbeat sent (reason: \(reason))")
        } catch {
            NSLog("[Tunnel] Heartbeat failed: \(error.localizedDescription)")
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

    // MARK: - Status

    private func writeTunnelStatus(_ status: String) {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(status, forKey: "tunnelStatus")
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: "tunnelLastActiveAt")
    }
}
