import Foundation
import NetworkExtension
import BigBrotherCore

/// Minimal DNS proxy: intercept queries, forward upstream, return responses.
/// Activity logging is fire-and-forget on a background queue.
final class DNSProxy {

    private weak var provider: NEPacketTunnelProvider?
    private var upstreamSession: NWUDPSession?
    private let upstreamDNS: NWHostEndpoint
    private let tunnelIP: Data = Data([198, 18, 0, 1])
    private let storage: AppGroupStorage

    // Pending queries: txnID → (sourceIP, sourcePort, timestamp, original query)
    private var pending: [UInt16: (ip: Data, port: UInt16, at: Date, query: Data)] = [:]
    private let pendingLock = NSLock()

    // Safe search cache (avoid disk I/O per query)
    private var safeSearchOn: Bool = false
    private var safeSearchExpiry: Date = .distantPast

    // Activity tracking (background, non-blocking)
    private let bgQueue = DispatchQueue(label: "dns.bg", qos: .utility)
    private var domainCounts: [String: DomainHit] = [:]
    private var totalQueries: Int = 0
    private let statsLock = NSLock()
    var isDeviceLocked: Bool = false
    /// When true, all DNS queries are REFUSED except Apple infrastructure domains
    /// (CloudKit, APNS, iCloud). This ensures the device stays reachable for commands
    /// even when internet is blackholed for enforcement.
    var isBlackholeMode: Bool = false
    private var knownApps: Set<String> = []

    /// Called when a known app domain is seen. Parameters: (appName, rootDomain, timestamp)
    var onAppDomainSeen: ((String, String, Date) -> Void)?

    /// Domains always allowed through the blackhole — Apple infrastructure for CloudKit
    /// commands, APNS push delivery, and iCloud sync. Without these, a blackholed device
    /// becomes permanently unreachable and parent can't send commands to fix it.
    private static let blackholeExemptSuffixes = [
        "icloud.com", "apple-cloudkit.com", "icloud-content.com",
        "apple.com", "mzstatic.com", "push.apple.com",
        "cdn-apple.com", "apple-dns.net"
    ]

    private func isBlackholeExempt(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        return Self.blackholeExemptSuffixes.contains { lower.hasSuffix($0) }
    }

    // DNS-based per-app time tracking
    private var appWindows: [String: Date] = [:]     // app name -> current 60s window start
    private var appMinutes: [String: Int] = [:]       // app name -> accumulated active minutes today
    private var appUsageDateString: String = ""        // "yyyy-MM-dd" for daily reset
    private var timeLimitsCache: [AppTimeLimit] = []   // cached time limits
    private var timeLimitsCacheExpiry: Date = .distantPast

    private static let safeSearchRedirects: [String: String] = [
        "www.google.com": "216.239.38.120", "google.com": "216.239.38.120",
        "www.youtube.com": "216.239.38.120", "youtube.com": "216.239.38.120",
        "m.youtube.com": "216.239.38.120",
        "www.bing.com": "204.79.197.220", "bing.com": "204.79.197.220",
        "duckduckgo.com": "52.142.124.215", "www.duckduckgo.com": "52.142.124.215",
    ]

    init(provider: NEPacketTunnelProvider, upstreamDNSServer: String, storage: AppGroupStorage) {
        self.provider = provider
        self.upstreamDNS = NWHostEndpoint(hostname: upstreamDNSServer, port: "53")
        self.storage = storage
    }

    // MARK: - Lifecycle

    func start() {
        restoreFromAppGroup()
        restoreKnownApps()
        // Pre-load enforcement blocked domains so the first DNS query is already enforced.
        enforcementBlockedDomains = storage.readEnforcementBlockedDomains()
        enforcementBlockedExpiry = Date().addingTimeInterval(5)
        timeLimitBlockedDomains = storage.readTimeLimitBlockedDomains()
        timeLimitBlockedExpiry = Date().addingTimeInterval(5)
        upstreamSession = provider?.createUDPSession(to: upstreamDNS, from: nil)
        upstreamSession?.setReadHandler({ [weak self] datagrams, error in
            if let error {
                NSLog("[DNSProxy] Upstream read error: \(error.localizedDescription)")
            }
            guard let datagrams else { return }
            for d in datagrams { self?.onUpstreamResponse(d) }
        }, maxDatagrams: 64)
        readLoop()
        NSLog("[DNSProxy] Started → \(upstreamDNS.hostname)")
    }

    func stop() {
        upstreamSession?.cancel()
        upstreamSession = nil
    }

    /// Periodic health check — call from the tunnel's liveness timer.
    /// Detects stale upstream sessions and reconnects.
    func healthCheck() {
        guard let session = upstreamSession else {
            NSLog("[DNSProxy] Health: no upstream session — reconnecting")
            reconnectUpstream()
            return
        }
        // Session stuck in non-ready state
        if session.state == .cancelled || session.state == .failed {
            NSLog("[DNSProxy] Health: upstream session \(session.state.rawValue) — reconnecting")
            reconnectUpstream()
            return
        }
        // Check for query blackhole: many pending queries = responses not arriving
        pendingLock.lock()
        let count = pending.count
        let oldest = pending.values.min(by: { $0.at < $1.at })?.at
        pendingLock.unlock()
        if count > 20, let oldest, Date().timeIntervalSince(oldest) > 3 {
            NSLog("[DNSProxy] Health: \(count) pending queries (oldest \(Int(Date().timeIntervalSince(oldest)))s) — upstream may be dead, reconnecting")
            reconnectUpstream()
        }
    }

    /// Recreate the upstream UDP session after a network change (WiFi↔cellular).
    /// The old NWUDPSession becomes invalid when the network path changes.
    func reconnectUpstream() {
        upstreamSession?.cancel()
        upstreamSession = provider?.createUDPSession(to: upstreamDNS, from: nil)
        upstreamSession?.setReadHandler({ [weak self] datagrams, error in
            if let error {
                NSLog("[DNSProxy] Upstream read error after reconnect: \(error.localizedDescription)")
            }
            guard let datagrams else { return }
            for d in datagrams { self?.onUpstreamResponse(d) }
        }, maxDatagrams: 64)
        // Drain orphaned queries with REFUSED so clients get an immediate error
        // instead of waiting for a timeout that never comes.
        pendingLock.lock()
        let orphaned = pending
        pending.removeAll()
        pendingLock.unlock()
        if !orphaned.isEmpty {
            for (_, entry) in orphaned {
                let refused = buildRefusedResponse(query: entry.query)
                writeResponse(refused, destIP: entry.ip, destPort: entry.port)
            }
            NSLog("[DNSProxy] Upstream reconnected → \(upstreamDNS.hostname) (\(orphaned.count) orphaned queries refused)")
        } else {
            NSLog("[DNSProxy] Upstream reconnected → \(upstreamDNS.hostname)")
        }
    }

    // MARK: - Packet Loop

    private func readLoop() {
        provider?.packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            for p in packets { self.onPacket(p) }
            self.readLoop()
        }
    }

    // MARK: - Incoming Query

    private func onPacket(_ packet: Data) {
        // Parse IPv4 + UDP + DNS minimum
        guard packet.count >= 40, packet[0] >> 4 == 4, packet[9] == 17 else { return }
        let ihl = Int(packet[0] & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl + 8 else { return }
        let udp = ihl
        guard UInt16(packet[udp+2]) << 8 | UInt16(packet[udp+3]) == 53 else { return }

        let srcIP = packet.subdata(in: 12..<16)
        let srcPort = UInt16(packet[udp]) << 8 | UInt16(packet[udp+1])
        let dns = packet.subdata(in: (udp+8)..<packet.count)
        guard dns.count >= 12 else { return }
        let txn = UInt16(dns[0]) << 8 | UInt16(dns[1])
        let domain = parseDomain(dns)

        // Priority order: enforcement blocks win over everything, then time limits,
        // then blackhole, then safe search. A shielded app's domain should be REFUSED
        // even if safe search would redirect it.

        // 1. Enforcement domain blocking: block web versions of shielded apps.
        if let domain, isEnforcementBlocked(domain) {
            let resp = buildRefusedResponse(query: dns)
            writeResponse(resp, destIP: srcIP, destPort: srcPort)
            bgLog(domain)
            return
        }

        // 2. Time-limit domain blocking: REFUSED for exhausted app domains.
        if let domain, isTimeLimitBlocked(domain) {
            let resp = buildRefusedResponse(query: dns)
            writeResponse(resp, destIP: srcIP, destPort: srcPort)
            bgLog(domain)
            return
        }

        // 3. DNS blackhole mode: REFUSE everything except Apple infrastructure.
        if isBlackholeMode, let domain, !isBlackholeExempt(domain) {
            let resp = buildRefusedResponse(query: dns)
            writeResponse(resp, destIP: srcIP, destPort: srcPort)
            bgLog(domain)
            return
        }

        // 4. Safe search: redirect search engines to safe-search IPs.
        if let domain, let ip = checkSafeSearch(domain) {
            let resp = buildDNSResponse(query: dns, ip: ip)
            writeResponse(resp, destIP: srcIP, destPort: srcPort)
            bgLog(domain)
            return
        }

        // 5. Forward upstream
        pendingLock.lock()
        pending[txn] = (ip: srcIP, port: srcPort, at: Date(), query: dns)
        // Evict queries older than 5 seconds (timed out) and cap at 300
        let now = Date()
        if pending.count > 100 {
            let stale = pending.filter { now.timeIntervalSince($0.value.at) >= 5 }
            for (_, entry) in stale {
                let refused = buildRefusedResponse(query: entry.query)
                writeResponse(refused, destIP: entry.ip, destPort: entry.port)
            }
            pending = pending.filter { now.timeIntervalSince($0.value.at) < 5 }
        }
        if pending.count > 300 {
            let sorted = pending.sorted { $0.value.at < $1.value.at }
            let keepFrom = sorted.count / 2
            let dropped = Array(sorted.prefix(keepFrom))
            for (_, entry) in dropped {
                let refused = buildRefusedResponse(query: entry.query)
                writeResponse(refused, destIP: entry.ip, destPort: entry.port)
            }
            pending = Dictionary(uniqueKeysWithValues: sorted.suffix(from: keepFrom).map { ($0.key, $0.value) })
        }
        pendingLock.unlock()

        // Check session health before forwarding
        if let session = upstreamSession {
            if session.state == .cancelled || session.state == .failed {
                NSLog("[DNSProxy] Upstream session dead (state=\(session.state.rawValue)) — reconnecting")
                reconnectUpstream()
            }
        }

        upstreamSession?.writeDatagram(dns) { error in
            if let error {
                NSLog("[DNSProxy] Upstream write failed: \(error.localizedDescription)")
            }
        }

        // Log async
        if let domain { bgLog(domain) }
    }

    // MARK: - Upstream Response

    private func onUpstreamResponse(_ data: Data) {
        guard data.count >= 12 else { return }
        let txn = UInt16(data[0]) << 8 | UInt16(data[1])

        pendingLock.lock()
        let p = pending.removeValue(forKey: txn)
        pendingLock.unlock()

        guard let p else { return }
        writeResponse(data, destIP: p.ip, destPort: p.port)
    }

    private func writeResponse(_ payload: Data, destIP: Data, destPort: UInt16) {
        let pkt = buildIPPacket(srcIP: tunnelIP, dstIP: destIP, srcPort: 53, dstPort: destPort, payload: payload)
        provider?.packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
    }

    // MARK: - Time Limit Domain Blocking

    private var timeLimitBlockedDomains: Set<String> = []
    private var timeLimitBlockedExpiry: Date = .distantPast

    /// Check if a domain should be blocked because its app's time limit is exhausted.
    private func isTimeLimitBlocked(_ domain: String) -> Bool {
        // Refresh cache every 30 seconds
        let now = Date()
        if now >= timeLimitBlockedExpiry {
            timeLimitBlockedDomains = storage.readTimeLimitBlockedDomains()
            timeLimitBlockedExpiry = now.addingTimeInterval(5)
        }
        guard !timeLimitBlockedDomains.isEmpty else { return false }
        let root = DomainCategorizer.rootDomain(domain)
        return timeLimitBlockedDomains.contains(root)
    }

    // MARK: - Enforcement Domain Blocking

    private var enforcementBlockedDomains: Set<String> = []
    private var enforcementBlockedExpiry: Date = .distantPast

    /// Check if a domain should be blocked because its app is shielded (not allowed).
    /// Blocks web versions of apps so kids can't bypass shield.applications via Safari.
    private func isEnforcementBlocked(_ domain: String) -> Bool {
        let now = Date()
        if now >= enforcementBlockedExpiry {
            enforcementBlockedDomains = storage.readEnforcementBlockedDomains()
            enforcementBlockedExpiry = now.addingTimeInterval(5)
        }
        guard !enforcementBlockedDomains.isEmpty else { return false }
        let root = DomainCategorizer.rootDomain(domain)
        return enforcementBlockedDomains.contains(root)
    }

    // MARK: - Safe Search

    private func checkSafeSearch(_ domain: String) -> String? {
        let now = Date()
        if now >= safeSearchExpiry {
            let r = storage.readDeviceRestrictions()?.denyExplicitContent == true
            let t = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.bool(forKey: "safeSearchEnabled") ?? false
            safeSearchOn = r || t
            safeSearchExpiry = now.addingTimeInterval(5)
        }
        guard safeSearchOn else { return nil }
        return Self.safeSearchRedirects[domain.lowercased()]
    }

    // MARK: - DNS Parsing

    private func parseDomain(_ dns: Data) -> String? {
        guard dns.count > 12, (UInt16(dns[4]) << 8 | UInt16(dns[5])) >= 1 else { return nil }
        var off = 12
        var labels: [String] = []
        while off < dns.count {
            let len = Int(dns[off])
            if len == 0 { break }
            if len > 63 { return nil }
            off += 1
            guard off + len <= dns.count else { return nil }
            if let s = String(data: dns.subdata(in: off..<off+len), encoding: .ascii) { labels.append(s) }
            off += len
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }

    // MARK: - DNS Response Builder

    /// Build a REFUSED DNS response. Works for any query type (A, AAAA, etc.)
    /// by returning the query's own question section with RCODE=5 (REFUSED).
    private func buildRefusedResponse(query: Data) -> Data {
        guard query.count >= 12 else { return query }
        var r = Data(query)
        // Set QR=1 (response), RCODE=5 (REFUSED)
        r[2] = 0x81  // QR=1, Opcode=0, AA=0, TC=0, RD=1
        r[3] = 0x05  // RA=0, Z=0, RCODE=5 (REFUSED)
        // Zero answer, authority, additional counts
        r[6] = 0; r[7] = 0  // ANCOUNT = 0
        r[8] = 0; r[9] = 0  // NSCOUNT = 0
        r[10] = 0; r[11] = 0 // ARCOUNT = 0
        return r
    }

    private func buildDNSResponse(query: Data, ip: String) -> Data {
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard query.count >= 12, octets.count == 4 else { return query }

        var r = Data()
        r.append(contentsOf: [query[0], query[1]])           // txn ID
        r.append(contentsOf: [0x81, 0x80])                    // flags
        r.append(contentsOf: [0,1, 0,1, 0,0, 0,0])           // counts

        // Copy question
        var off = 12
        while off < query.count { let l = query[off]; if l == 0 { off += 1; break }; off += Int(l)+1 }
        off += 4
        if off <= query.count { r.append(query[12..<off]) }

        // Answer
        r.append(contentsOf: [0xC0, 0x0C, 0,1, 0,1, 0,0,1,0x2C, 0,4])
        for o in octets { r.append(o) }
        return r
    }

    // MARK: - IP Packet Builder

    private func buildIPPacket(srcIP: Data, dstIP: Data, srcPort: UInt16, dstPort: UInt16, payload: Data) -> Data {
        let udpLen = UInt16(8 + payload.count)
        let totalLen = UInt16(28 + payload.count)
        var p = Data(count: Int(totalLen))

        p[0] = 0x45; p[1] = 0
        p[2] = UInt8(totalLen >> 8); p[3] = UInt8(totalLen & 0xFF)
        p[4] = 0; p[5] = 0; p[6] = 0x40; p[7] = 0
        p[8] = 64; p[9] = 17; p[10] = 0; p[11] = 0
        p.replaceSubrange(12..<16, with: srcIP)
        p.replaceSubrange(16..<20, with: dstIP)

        var sum: UInt32 = 0
        for i in stride(from: 0, to: 20, by: 2) { sum += UInt32(p[i]) << 8 | UInt32(p[i+1]) }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        let ck = ~UInt16(sum & 0xFFFF)
        p[10] = UInt8(ck >> 8); p[11] = UInt8(ck & 0xFF)

        p[20] = UInt8(srcPort >> 8); p[21] = UInt8(srcPort & 0xFF)
        p[22] = UInt8(dstPort >> 8); p[23] = UInt8(dstPort & 0xFF)
        p[24] = UInt8(udpLen >> 8); p[25] = UInt8(udpLen & 0xFF)
        p[26] = 0; p[27] = 0
        p.replaceSubrange(28..<Int(totalLen), with: payload)
        return p
    }

    // MARK: - Background Activity Logging

    private func bgLog(_ domain: String) {
        bgQueue.async { [weak self] in self?.recordDomain(domain) }
    }

    private func recordDomain(_ fullDomain: String) {
        let root = DomainCategorizer.rootDomain(fullDomain)
        if DomainCategorizer.isNoise(fullDomain) { return }
        guard !isDeviceLocked else { return }

        // New app detection + per-app time tracking
        let appName = DomainCategorizer.appName(for: root)
        if let appName, !knownApps.contains(appName) {
            knownApps.insert(appName)
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.set(Array(knownApps), forKey: "knownAppDomains")
            var p = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.stringArray(forKey: "newAppDetections") ?? []
            p.append(appName)
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.set(p, forKey: "newAppDetections")
            NSLog("[DNSProxy] New app: \(appName)")
        }
        if let appName {
            trackAppMinute(appName)
            onAppDomainSeen?(appName, root, Date())
        }

        let display = DomainCategorizer.displayDomain(fullDomain)
        let (flagged, category) = DomainCategorizer.categorize(root)
        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let slot = DomainHit.slotIndex(hour: comps.hour ?? 0, minute: comps.minute ?? 0)

        statsLock.lock()
        totalQueries += 1
        if var existing = domainCounts[display] {
            existing.count += 1
            existing.lastSeen = now
            var slots = existing.slotCounts ?? [:]
            slots[slot, default: 0] += 1
            existing.slotCounts = slots
            if flagged && !existing.flagged { existing.flagged = true; existing.category = category }
            domainCounts[display] = existing
        } else {
            domainCounts[display] = DomainHit(domain: display, count: 1, firstSeen: now, lastSeen: now,
                                               flagged: flagged, category: category, slotCounts: [slot: 1])
        }
        statsLock.unlock()
    }

    // MARK: - Per-App Time Tracking

    /// Track a 60-second activity window for an app. Called from recordDomain() on bgQueue.
    /// A "minute" requires sustained DNS activity: an open window must last 60s before counting.
    private func trackAppMinute(_ appName: String) {
        let now = Date()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: now)

        // Day rollover: reset all tracking
        if today != appUsageDateString {
            appWindows.removeAll()
            appMinutes.removeAll()
            appUsageDateString = today
        }

        if let windowStart = appWindows[appName] {
            // Open window exists — check if 60s has elapsed
            if now.timeIntervalSince(windowStart) >= 60 {
                // Close window: increment minute count
                appMinutes[appName, default: 0] += 1
                // Open a new window for continued activity
                appWindows[appName] = now
                checkTimeLimitExhaustion(appName)
            }
            // Otherwise window is still open, nothing to do (sustained activity continues)
        } else {
            // No open window — start one
            appWindows[appName] = now
        }
    }

    /// Check if an app has exceeded its time limit (with 10% buffer for DNS noise).
    /// If exhausted, write to the same pathway the Monitor uses (TimeLimitExhaustedApp).
    private func checkTimeLimitExhaustion(_ appName: String) {
        let now = Date()

        // Refresh time limits cache every 30 seconds
        if now >= timeLimitsCacheExpiry {
            timeLimitsCache = storage.readAppTimeLimits()
            timeLimitsCacheExpiry = now.addingTimeInterval(30)
        }

        // Find the limit for this app
        guard let limit = timeLimitsCache.first(where: { $0.appName == appName }),
              limit.dailyLimitMinutes > 0 else { return }

        let minutes = appMinutes[appName] ?? 0
        let threshold = Int(Double(limit.dailyLimitMinutes) * 1.1)
        guard minutes >= threshold else { return }

        // Check dedup: don't write if already exhausted for today
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: now)
        var exhausted = storage.readTimeLimitExhaustedApps()
        if exhausted.contains(where: { $0.appName == appName && $0.dateString == today }) {
            return
        }

        // Append new exhaustion entry
        let entry = TimeLimitExhaustedApp(
            timeLimitID: limit.id,
            appName: appName,
            tokenData: limit.tokenData,
            fingerprint: limit.fingerprint,
            exhaustedAt: now,
            dateString: today
        )
        exhausted.append(entry)
        try? storage.writeTimeLimitExhaustedApps(exhausted)

        // Update DNS blocklist: compute blocked domains for ALL exhausted apps
        var blockedDomains = Set<String>()
        for app in exhausted where app.dateString == today {
            blockedDomains.formUnion(DomainCategorizer.domainsForApp(app.appName))
        }
        try? storage.writeTimeLimitBlockedDomains(blockedDomains)

        // Force-refresh the in-memory blocked domains cache immediately
        timeLimitBlockedDomains = blockedDomains
        timeLimitBlockedExpiry = now.addingTimeInterval(5)

        NSLog("[DNSProxy] DNS time limit exhausted: \(appName) (\(minutes)m >= \(limit.dailyLimitMinutes)m * 1.1)")
    }

    /// Persist current app usage to App Group. Called from flushToAppGroup().
    private func flushAppUsageToAppGroup() {
        guard !appMinutes.isEmpty || !appWindows.isEmpty else { return }

        // Close any open windows older than 60s (count their minute)
        let now = Date()
        for (app, windowStart) in appWindows {
            if now.timeIntervalSince(windowStart) >= 60 {
                appMinutes[app, default: 0] += 1
                appWindows[app] = now
            }
        }

        let usage = DNSAppUsage(dateString: appUsageDateString, apps: appMinutes)
        if let data = try? JSONEncoder().encode(usage) {
            try? storage.writeRawData(data, forKey: "dnsAppUsage")
        }
    }

    /// Restore app usage from App Group on startup. Called from restoreFromAppGroup().
    private func restoreAppUsageFromAppGroup() {
        guard let data = storage.readRawData(forKey: "dnsAppUsage"),
              let saved = try? JSONDecoder().decode(DNSAppUsage.self, from: data) else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        guard saved.dateString == today else { return }

        // Restore: take max of in-memory and persisted (tunnel may have restarted mid-day)
        appUsageDateString = today
        for (app, minutes) in saved.apps {
            appMinutes[app] = max(appMinutes[app] ?? 0, minutes)
        }
    }

    // MARK: - Persistence

    func takeSnapshot(deviceID: DeviceID, familyID: FamilyID) -> DomainActivitySnapshot {
        statsLock.lock()
        let domains = Array(domainCounts.values)
        let total = totalQueries
        statsLock.unlock()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return DomainActivitySnapshot(deviceID: deviceID, familyID: familyID,
                                      date: fmt.string(from: Date()), domains: domains, totalQueries: total)
    }

    func flushToAppGroup() {
        statsLock.lock()
        let domains = Array(domainCounts.values)
        let total = totalQueries
        statsLock.unlock()
        guard !domains.isEmpty else { return }
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if let data = try? JSONEncoder().encode(domains) { defaults?.set(data, forKey: "dnsActivityDomains") }
        defaults?.set(total, forKey: "dnsActivityTotalQueries")
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        defaults?.set(fmt.string(from: Date()), forKey: "dnsActivityDate")
        defaults?.set(Date().timeIntervalSince1970, forKey: "dnsActivityUpdatedAt")
        flushAppUsageToAppGroup()
    }

    private func restoreFromAppGroup() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        guard defaults?.string(forKey: "dnsActivityDate") == fmt.string(from: Date()),
              let data = defaults?.data(forKey: "dnsActivityDomains"),
              let saved = try? JSONDecoder().decode([DomainHit].self, from: data) else { return }
        statsLock.lock()
        for hit in saved {
            if let e = domainCounts[hit.domain] { if hit.count > e.count { domainCounts[hit.domain] = hit } }
            else { domainCounts[hit.domain] = hit }
        }
        totalQueries = max(totalQueries, defaults?.integer(forKey: "dnsActivityTotalQueries") ?? 0)
        statsLock.unlock()
        restoreAppUsageFromAppGroup()
    }

    private func restoreKnownApps() {
        knownApps = Set(UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.stringArray(forKey: "knownAppDomains") ?? [])
    }

    func resetDaily() {
        statsLock.lock(); domainCounts.removeAll(); totalQueries = 0; statsLock.unlock()
        let d = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        d?.removeObject(forKey: "dnsActivityDomains"); d?.set(0, forKey: "dnsActivityTotalQueries")
        // Reset per-app time tracking
        appWindows.removeAll()
        appMinutes.removeAll()
        appUsageDateString = ""
        try? storage.writeRawData(nil, forKey: "dnsAppUsage")
    }

    func cleanupStalePendingQueries() {
        pendingLock.lock()
        _ = pending.count
        let now = Date()
        let stale = pending.filter { now.timeIntervalSince($0.value.at) >= 5 }
        pending = pending.filter { now.timeIntervalSince($0.value.at) < 5 }
        pendingLock.unlock()
        // Send REFUSED for stale queries so clients get immediate error
        for (_, entry) in stale {
            let refused = buildRefusedResponse(query: entry.query)
            writeResponse(refused, destIP: entry.ip, destPort: entry.port)
        }
        if !stale.isEmpty {
            NSLog("[DNSProxy] Cleaned \(stale.count) stale pending queries (\(pending.count) remaining)")
        }
    }

    // MARK: - Diagnostics

    /// Number of queries awaiting upstream response.
    var pendingCount: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending.count
    }

    /// Current upstream session state for diagnostic reporting.
    var upstreamSessionState: NWUDPSessionState? {
        upstreamSession?.state
    }
}
