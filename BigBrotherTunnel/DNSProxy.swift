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

    // Pending queries keyed by a PROXY-owned upstream txn ID, not the
    // client's original DNS txn ID. Clients can and do reuse txn IDs — two
    // browsers might both pick 0x1234 at the same instant. Keying on just
    // the client ID used to collide and drop one of the queries (or worse,
    // deliver Safari's response to Chrome). b457: allocate a monotonic
    // proxy ID, rewrite bytes [0..1] of the query before sending upstream,
    // then on response we look up by the proxy ID and restore the original
    // client txn ID before forwarding.
    //
    // `originalTxn` is the 16-bit ID the client originally used; we
    // remember it so the response can be built with the value the client
    // will recognize.
    private struct PendingEntry {
        let ip: Data
        let port: UInt16
        let at: Date
        let query: Data
        let originalTxn: UInt16
    }
    private var pending: [UInt16: PendingEntry] = [:]
    private let pendingLock = NSLock()
    private var nextUpstreamTxn: UInt16 = UInt16.random(in: 0...UInt16.max)

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

    private var resolvedModeCache: LockMode = .restricted
    private var resolvedModeCacheExpiry: Date = .distantPast

    private func refreshModeCache() {
        let now = Date()
        guard now >= resolvedModeCacheExpiry else { return }
        resolvedModeCache = ModeStackResolver.resolve(storage: storage).mode
        resolvedModeCacheExpiry = now.addingTimeInterval(3)
    }

    private static let ckDomainSuffixes = [
        "apple-cloudkit.com", "icloud-content.com", "icloud.com",
        "apple.com", "mzstatic.com", "push.apple.com"
    ]

    private func isCloudKitDomain(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        for suffix in Self.ckDomainSuffixes {
            if lower == suffix || lower.hasSuffix("." + suffix) { return true }
        }
        return false
    }
    private var knownApps: Set<String> = []
    /// b461: lock around all knownApps access (check + insert + persist +
    /// pending-list append). See recordDomain comments for rationale.
    private let knownAppsLock = NSLock()

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

    /// Match the domain against an exemption ONLY at DNS label boundaries.
    /// The previous implementation used plain `hasSuffix`, which lets
    /// `evilicloud.com` falsely match `icloud.com` — a trivial blackhole
    /// bypass. Correct matching requires the exemption to be either the
    /// whole domain or immediately preceded by a dot.
    private func isBlackholeExempt(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        for suffix in Self.blackholeExemptSuffixes {
            if lower == suffix { return true }
            if lower.hasSuffix("." + suffix) { return true }
        }
        return false
    }

    // DNS-based per-app time tracking.
    //
    // `appWindows` and `appMinutes` are mutated on `bgQueue` (via
    // `trackAppMinute`) and read/cleared from other threads (`flushToAppGroup`,
    // `resetDaily`, `restoreAppUsageFromAppGroup`). Unsynchronized Dictionary
    // access across threads in Swift is UB — the only reason this hadn't
    // crashed loudly is dumb luck. Guard all access with `appUsageLock`.
    private var appWindows: [String: Date] = [:]     // app name -> current 60s window start
    private var appMinutes: [String: Int] = [:]       // app name -> accumulated active minutes today
    private var appUsageDateString: String = ""        // "yyyy-MM-dd" for daily reset
    private let appUsageLock = NSLock()
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
        // b457: take blocklistLock for parity with the refresh path — start()
        // races against the 5s refresh if the tunnel restarts while a flush is
        // in-flight from another subsystem.
        blocklistLock.lock()
        enforcementBlockedDomains = storage.readEnforcementBlockedDomains()
        enforcementBlockedExpiry = Date().addingTimeInterval(5)
        timeLimitBlockedDomains = storage.readTimeLimitBlockedDomains()
        timeLimitBlockedExpiry = Date().addingTimeInterval(5)
        blocklistLock.unlock()
        upstreamSession = provider?.createUDPSession(to: upstreamDNS, from: nil)
        upstreamSession?.setReadHandler({ [weak self] datagrams, error in
            if let error {
                NSLog("[DNSProxy] Upstream read error: \(error.localizedDescription)")
                // b457: a read error usually means the underlying socket is
                // bound to a dead interface (classic wifi→cell handoff).
                // Drop the session immediately so the next query triggers a
                // fresh one in the right network context.
                self?.markUpstreamUnhealthy()
            }
            guard let datagrams else { return }
            for d in datagrams { self?.onUpstreamResponse(d) }
        }, maxDatagrams: 64)
        let gen = startReadLoopInternal()
        NSLog("[DNSProxy] Started → \(upstreamDNS.hostname) (readLoop gen=\(gen))")
    }

    /// Record that the upstream session hit an error and should be reconnected
    /// on the very next query. Without this, transient errors caused by
    /// interface changes were silently logged and recovery waited for the
    /// 30-second health check.
    private var upstreamNeedsReconnect: Bool = false
    private let reconnectLock = NSLock()

    func markUpstreamUnhealthy() {
        reconnectLock.lock()
        upstreamNeedsReconnect = true
        reconnectLock.unlock()
    }

    /// Check the reconnect flag and, if set, rebuild the upstream session
    /// before forwarding the next query. Called from the onPacket forwarding
    /// path so a single error triggers recovery immediately on the next
    /// inbound DNS query — no 30-second wait for healthCheck.
    private func reconnectIfFlagged() {
        reconnectLock.lock()
        let needs = upstreamNeedsReconnect
        upstreamNeedsReconnect = false
        reconnectLock.unlock()
        if needs {
            NSLog("[DNSProxy] upstreamNeedsReconnect flag set — rebinding session")
            reconnectUpstream()
        }
    }

    func stop() {
        upstreamSession?.cancel()
        upstreamSession = nil
        // Invalidate the running read loop so its next completion drains
        // out. We don't need to actively cancel `readPackets` — Apple
        // doesn't expose that — but bumping the generation guarantees
        // that whatever callback eventually fires will stop recursing.
        readLoopLock.lock()
        readLoopGeneration += 1
        readLoopLock.unlock()
    }

    /// Start a fresh read loop chain, superseding any previous one.
    /// Called after `reapplyNetworkSettings` completes so the new packet
    /// flow has an active reader — but without leaving the old chain
    /// running in parallel (the generation check in `readLoop` drains it).
    func startReadLoop() {
        startReadLoopInternal()
    }

    /// Periodic health check — call from the tunnel's liveness timer.
    /// Detects stale upstream sessions and reconnects.
    @discardableResult
    func healthCheck() -> Bool {
        guard let session = upstreamSession else {
            NSLog("[DNSProxy] Health: no upstream session — reconnecting")
            reconnectUpstream()
            return false
        }
        // Session stuck in non-ready state
        if session.state == .cancelled || session.state == .failed {
            NSLog("[DNSProxy] Health: upstream session \(session.state.rawValue) — reconnecting")
            reconnectUpstream()
            return false
        }
        // Check for query blackhole: many pending queries = responses not arriving
        pendingLock.lock()
        let count = pending.count
        let oldest = pending.values.min(by: { $0.at < $1.at })?.at
        pendingLock.unlock()
        if count > 20, let oldest, Date().timeIntervalSince(oldest) > 3 {
            NSLog("[DNSProxy] Health: \(count) pending queries (oldest \(Int(Date().timeIntervalSince(oldest)))s) — upstream may be dead, reconnecting")
            reconnectUpstream()
            return false
        }
        return true
    }

    /// Recreate the upstream UDP session after a network change (WiFi↔cellular).
    /// The old NWUDPSession becomes invalid when the network path changes.
    func reconnectUpstream() {
        upstreamSession?.cancel()
        upstreamSession = provider?.createUDPSession(to: upstreamDNS, from: nil)
        upstreamSession?.setReadHandler({ [weak self] datagrams, error in
            if let error {
                NSLog("[DNSProxy] Upstream read error after reconnect: \(error.localizedDescription)")
                self?.markUpstreamUnhealthy()
            }
            guard let datagrams else { return }
            for d in datagrams { self?.onUpstreamResponse(d) }
        }, maxDatagrams: 64)
        // Drain orphaned queries with REFUSED so clients get an immediate error
        // instead of waiting for a timeout that never comes. Use the original
        // client txn ID so the browser can demux the refused back to the
        // right in-flight request.
        pendingLock.lock()
        let orphaned = pending
        pending.removeAll()
        pendingLock.unlock()
        if !orphaned.isEmpty {
            for (_, entry) in orphaned {
                let refused = buildRefusedResponseWithOriginalTxn(entry: entry)
                writeResponse(refused, destIP: entry.ip, destPort: entry.port)
            }
            NSLog("[DNSProxy] Upstream reconnected → \(upstreamDNS.hostname) (\(orphaned.count) orphaned queries refused)")
        } else {
            NSLog("[DNSProxy] Upstream reconnected → \(upstreamDNS.hostname)")
        }
    }

    // MARK: - Packet Loop

    /// Generation counter. Incremented each time a fresh read-loop chain is
    /// started (from `start()` or `startReadLoop()`). Each recursive
    /// invocation captures its birth generation and bails out of the
    /// recursion if a newer generation has been started since — so older
    /// chains naturally drain out once their pending `readPackets`
    /// completion fires.
    ///
    /// Why this matters: `packetFlow.readPackets { ... readLoop() }` is a
    /// recursive self-scheduling chain. The old code had no ownership
    /// guard. Every `reapplyNetworkSettings` completion called
    /// `dnsProxy?.startReadLoop()` which unconditionally re-entered
    /// `readLoop()`, creating a brand new concurrent chain. On the 5-second
    /// fast path, a single `setTunnelNetworkSettings` timeout sets
    /// `networkSettingsNeedRetry = true` and the retry fires reapply →
    /// `startReadLoop()` → another chain — every 5 seconds, indefinitely.
    /// After a few minutes, dozens of chains were all sharing
    /// `packetFlow.readPackets`, which is undefined behavior in
    /// NEPacketTunnelFlow and caused DNS delivery to wedge. The tunnel's
    /// own CloudKit DNS lookups then failed with `CKErrorDomain 3`
    /// (networkUnavailable) in an endless loop. Reboot fixed it; recovery
    /// ladder couldn't because `cancelTunnelWithError` restart re-hit the
    /// same bootstrap sequence that immediately spawned 2 chains.
    private var readLoopGeneration: Int = 0
    private let readLoopLock = NSLock()

    /// Begin a fresh read loop, superseding any older chains. Returns the
    /// new generation ID for debug logging.
    @discardableResult
    private func startReadLoopInternal() -> Int {
        readLoopLock.lock()
        readLoopGeneration += 1
        let myGen = readLoopGeneration
        readLoopLock.unlock()
        readLoop(generation: myGen)
        return myGen
    }

    private func readLoop(generation: Int) {
        provider?.packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            // Supersession check: if a newer read loop has been started
            // while we were waiting on this completion, drop out so only
            // the newest chain drives the packet flow.
            self.readLoopLock.lock()
            let currentGen = self.readLoopGeneration
            self.readLoopLock.unlock()
            if currentGen != generation {
                NSLog("[DNSProxy] readLoop gen=\(generation) superseded by gen=\(currentGen) — draining")
                return
            }
            for p in packets { self.onPacket(p) }
            self.readLoop(generation: generation)
        }
    }

    // MARK: - Incoming Query

    private func onPacket(_ packet: Data) {
        // Parse IPv4 + UDP + DNS minimum
        guard packet.count >= 40, packet[0] >> 4 == 4, packet[9] == 17 else { return }
        let ihl = Int(packet[0] & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl + 8 else { return }

        // b457: honor the IP header totalLength and UDP length fields
        // instead of trusting packet.count. A truncated packet could have
        // a UDP length field larger than the remaining bytes, which would
        // then be read as oversized DNS payload; conversely, a packet with
        // trailing garbage would have extra bytes the DNS parser tried to
        // interpret. Also reject fragments — we can't safely handle them.
        let ipTotalLen = Int(packet[2]) << 8 | Int(packet[3])
        let fragFlagsOffset = Int(packet[6]) << 8 | Int(packet[7])
        let moreFragments = (fragFlagsOffset & 0x2000) != 0
        let fragmentOffset = fragFlagsOffset & 0x1FFF
        guard !moreFragments, fragmentOffset == 0 else { return }
        guard ipTotalLen >= ihl + 8, ipTotalLen <= packet.count else { return }

        let udp = ihl
        guard UInt16(packet[udp+2]) << 8 | UInt16(packet[udp+3]) == 53 else { return }

        // UDP length = UDP header (8) + payload, MUST fit inside what the
        // IP header said. A crafted packet could claim udpLen > ipTotalLen
        // and make us read past the packet end.
        let udpLen = Int(packet[udp+4]) << 8 | Int(packet[udp+5])
        guard udpLen >= 8, udp + udpLen <= ipTotalLen else { return }

        let srcIP = packet.subdata(in: 12..<16)
        let srcPort = UInt16(packet[udp]) << 8 | UInt16(packet[udp+1])
        let dns = packet.subdata(in: (udp+8)..<(udp+udpLen))
        guard dns.count >= 12 else { return }
        let txn = UInt16(dns[0]) << 8 | UInt16(dns[1])
        let domain = parseDomain(dns)

        refreshModeCache()
        // GATE: unlocked mode = forward everything, zero blocking.
        // Checked here (the single DNS decision point) so stale blocklist
        // files can never cause blocking in unlocked mode.
        let currentMode = resolvedModeCache
        let domainIsCloudKit = domain.map { isCloudKitDomain($0) } ?? false

        if currentMode != .unlocked {
            if let domain, !domainIsCloudKit, isEnforcementBlocked(domain) {
                let resp = buildRefusedResponse(query: dns)
                writeResponse(resp, destIP: srcIP, destPort: srcPort)
                bgLog(domain)
                return
            }

            if let domain, !domainIsCloudKit, isTimeLimitBlocked(domain) {
                let resp = buildRefusedResponse(query: dns)
                writeResponse(resp, destIP: srcIP, destPort: srcPort)
                bgLog(domain)
                return
            }
        }

        if isBlackholeMode, let domain, !isBlackholeExempt(domain), !domainIsCloudKit {
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

        // 5. Forward upstream.
        //
        // b457: allocate a proxy-owned upstream txn ID so colliding client
        // txn IDs don't smash each other in the pending map. Build a copy
        // of the query with bytes [0..1] rewritten to the proxy ID and send
        // that upstream. The original client txn ID is stashed in the
        // pending entry and restored when the response comes back.
        pendingLock.lock()
        let now = Date()
        // Find a free upstream ID — almost always succeeds on the first
        // try because we start at a random offset and 65k slots are rare
        // to exhaust with our 300-entry cap.
        var upstreamTxn: UInt16 = nextUpstreamTxn
        var attempts = 0
        while pending[upstreamTxn] != nil && attempts < 65536 {
            upstreamTxn &+= 1
            attempts += 1
        }
        if attempts >= 65536 {
            // Pending map is completely full (should be impossible with the
            // 300 cap). Drop the query rather than corrupt state.
            pendingLock.unlock()
            NSLog("[DNSProxy] pending table full (65k) — dropping query")
            return
        }
        nextUpstreamTxn = upstreamTxn &+ 1
        pending[upstreamTxn] = PendingEntry(
            ip: srcIP, port: srcPort, at: now, query: dns, originalTxn: txn
        )
        // Evict queries older than 5 seconds (timed out) and cap at 300
        if pending.count > 100 {
            let stale = pending.filter { now.timeIntervalSince($0.value.at) >= 5 }
            for (_, entry) in stale {
                let refused = buildRefusedResponseWithOriginalTxn(entry: entry)
                writeResponse(refused, destIP: entry.ip, destPort: entry.port)
            }
            pending = pending.filter { now.timeIntervalSince($0.value.at) < 5 }
        }
        if pending.count > 300 {
            let sorted = pending.sorted { $0.value.at < $1.value.at }
            let keepFrom = sorted.count / 2
            let dropped = Array(sorted.prefix(keepFrom))
            for kv in dropped {
                let refused = buildRefusedResponseWithOriginalTxn(entry: kv.value)
                writeResponse(refused, destIP: kv.value.ip, destPort: kv.value.port)
            }
            pending = Dictionary(uniqueKeysWithValues: sorted.suffix(from: keepFrom).map { ($0.key, $0.value) })
        }
        pendingLock.unlock()

        // Build the upstream datagram with the proxy txn ID stamped in.
        var upstreamDns = dns
        upstreamDns[0] = UInt8(upstreamTxn >> 8)
        upstreamDns[1] = UInt8(upstreamTxn & 0xFF)

        // Eager reconnect: if a prior read/write raised an error, the flag was
        // set and the very next query rebuilds the session before forwarding.
        // This turns "30s healthCheck timer recovery" into "first-query-
        // after-error recovery" — exactly what you want during a wifi flap.
        reconnectIfFlagged()

        // Check session health before forwarding
        if let session = upstreamSession {
            if session.state == .cancelled || session.state == .failed {
                NSLog("[DNSProxy] Upstream session dead (state=\(session.state.rawValue)) — reconnecting")
                reconnectUpstream()
            }
        }

        upstreamSession?.writeDatagram(upstreamDns) { [weak self] error in
            if let error {
                NSLog("[DNSProxy] Upstream write failed: \(error.localizedDescription)")
                // b457: write errors also indicate a dead session. Flag so
                // the next query reconnects before forwarding.
                self?.markUpstreamUnhealthy()
            }
        }

        // Log async
        if let domain { bgLog(domain) }
    }

    /// Build a REFUSED response using the pending entry's ORIGINAL client
    /// txn ID (not the proxy upstream ID). Used for stale-query eviction
    /// so the client sees a refused with its own txn ID and doesn't wait
    /// forever for a response that's never coming.
    private func buildRefusedResponseWithOriginalTxn(entry: PendingEntry) -> Data {
        var restored = entry.query
        if restored.count >= 2 {
            restored[0] = UInt8(entry.originalTxn >> 8)
            restored[1] = UInt8(entry.originalTxn & 0xFF)
        }
        return buildRefusedResponse(query: restored)
    }

    // MARK: - Upstream Response

    private func onUpstreamResponse(_ data: Data) {
        guard data.count >= 12 else { return }
        // The response comes back with the proxy-owned upstream txn ID we
        // stamped on the outbound query. Look up the pending entry by that
        // ID, then rewrite the response's txn bytes to the client's
        // original ID before delivering.
        let upstreamTxn = UInt16(data[0]) << 8 | UInt16(data[1])

        pendingLock.lock()
        let p = pending.removeValue(forKey: upstreamTxn)
        pendingLock.unlock()

        guard let p else { return }

        var restored = data
        restored[0] = UInt8(p.originalTxn >> 8)
        restored[1] = UInt8(p.originalTxn & 0xFF)
        writeResponse(restored, destIP: p.ip, destPort: p.port)
    }

    private func writeResponse(_ payload: Data, destIP: Data, destPort: UInt16) {
        let pkt = buildIPPacket(srcIP: tunnelIP, dstIP: destIP, srcPort: 53, dstPort: destPort, payload: payload)
        // b457: buildIPPacket returns empty on size/length failures.
        guard !pkt.isEmpty else { return }
        provider?.packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
    }

    // MARK: - Time Limit Domain Blocking

    // b457: `blocklistLock` guards the in-proxy cached blocklists and their
    // expiry timestamps. Previously these Sets were read from the packetFlow
    // thread (`onPacket`) and mutated from bgQueue (`checkTimeLimitExhaustionLocked`)
    // and the 5-second refresh path inside `isTimeLimitBlocked` itself —
    // unsynchronized. Concurrent Swift Set access is UB: crashes or, worse,
    // torn reads where a domain pops in and out of the blocked set for a
    // single packet-flow tick.
    private var timeLimitBlockedDomains: Set<String> = []
    private var timeLimitBlockedExpiry: Date = .distantPast
    private var enforcementBlockedDomains: Set<String> = []
    private var enforcementBlockedExpiry: Date = .distantPast
    private let blocklistLock = NSLock()

    /// Check if a domain should be blocked because its app's time limit is exhausted.
    private func isTimeLimitBlocked(_ domain: String) -> Bool {
        let now = Date()
        blocklistLock.lock()
        if now >= timeLimitBlockedExpiry {
            let resolution = ModeStackResolver.resolve(storage: storage)
            if resolution.mode == .unlocked {
                timeLimitBlockedDomains = []
            } else {
                timeLimitBlockedDomains = storage.readTimeLimitBlockedDomains()
            }
            timeLimitBlockedExpiry = now.addingTimeInterval(5)
        }
        if timeLimitBlockedDomains.isEmpty {
            blocklistLock.unlock()
            return false
        }
        let root = DomainCategorizer.rootDomain(domain)
        let hit = timeLimitBlockedDomains.contains(root)
        blocklistLock.unlock()
        return hit
    }

    /// Called from `checkTimeLimitExhaustionLocked` (bgQueue) to force-refresh
    /// the blocklist after a new exhaustion entry. Thread-safe.
    private func updateTimeLimitBlocklistLocked(_ domains: Set<String>, expiry: Date) {
        blocklistLock.lock()
        timeLimitBlockedDomains = domains
        timeLimitBlockedExpiry = expiry
        blocklistLock.unlock()
    }

    // MARK: - Enforcement Domain Blocking

    /// Check if a domain should be blocked because its app is shielded (not allowed).
    /// Blocks web versions of apps so kids can't bypass shield.applications via Safari.
    private func isEnforcementBlocked(_ domain: String) -> Bool {
        let now = Date()
        blocklistLock.lock()
        if now >= enforcementBlockedExpiry {
            let resolution = ModeStackResolver.resolve(storage: storage)
            if resolution.mode == .unlocked {
                enforcementBlockedDomains = []
            } else {
                enforcementBlockedDomains = storage.readEnforcementBlockedDomains()
            }
            enforcementBlockedExpiry = now.addingTimeInterval(5)
        }
        if enforcementBlockedDomains.isEmpty {
            blocklistLock.unlock()
            return false
        }
        let root = DomainCategorizer.rootDomain(domain)
        let hit = enforcementBlockedDomains.contains(root)
        blocklistLock.unlock()
        return hit
    }

    // MARK: - Safe Search

    private func checkSafeSearch(_ domain: String) -> String? {
        let now = Date()
        if now >= safeSearchExpiry {
            let r = storage.readDeviceRestrictions()?.denyExplicitContent == true
            let t = UserDefaults.appGroup?.bool(forKey: "safeSearchEnabled") ?? false
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

        // b457: validate the question section before building the response.
        // Previously, a malformed query could produce a response with
        // QDCOUNT=1 / ANCOUNT=1 but no question section copied, leaving the
        // answer's `0xC0 0x0C` name pointer pointing at garbage. Clients
        // reject or hang on that. Parse the QNAME walk ourselves with
        // bounds checks; if it doesn't form a valid terminated name plus
        // 4 bytes of QTYPE/QCLASS, fall back to REFUSED.
        var walk = 12
        while walk < query.count {
            let labelLen = Int(query[walk])
            if labelLen == 0 { walk += 1; break }
            if labelLen > 63 {
                // Compression pointer or invalid length — we don't handle
                // compression in safe-search rewriting, drop to REFUSED.
                return buildRefusedResponse(query: query)
            }
            walk += 1 + labelLen
            if walk > query.count { return buildRefusedResponse(query: query) }
        }
        // Require 4 more bytes for QTYPE + QCLASS.
        let qnameEnd = walk
        guard qnameEnd + 4 <= query.count else {
            return buildRefusedResponse(query: query)
        }
        let questionEnd = qnameEnd + 4

        var r = Data()
        r.append(contentsOf: [query[0], query[1]])           // txn ID
        r.append(contentsOf: [0x81, 0x80])                    // flags
        r.append(contentsOf: [0,1, 0,1, 0,0, 0,0])           // counts
        // Copy the validated question section verbatim.
        r.append(query[12..<questionEnd])

        // Answer
        r.append(contentsOf: [0xC0, 0x0C, 0,1, 0,1, 0,0,1,0x2C, 0,4])
        for o in octets { r.append(o) }
        return r
    }

    // MARK: - IP Packet Builder

    private func buildIPPacket(srcIP: Data, dstIP: Data, srcPort: UInt16, dstPort: UInt16, payload: Data) -> Data {
        // b457: bounds checks. UInt16(28 + payload.count) traps on
        // payload.count > 65507 — reachable if an upstream DNS server
        // returns an oversized response (EDNS0 / DNSSEC with large chains,
        // or adversarial payloads). Trap == tunnel process crash == kid
        // loses internet until OS restarts the extension. Similarly, the
        // srcIP/dstIP slices must be exactly 4 bytes each or the
        // replaceSubrange calls below corrupt the header.
        guard payload.count <= 65507 else {
            NSLog("[DNSProxy] buildIPPacket: payload too large (\(payload.count)B) — dropping")
            return Data()
        }
        guard srcIP.count == 4, dstIP.count == 4 else {
            NSLog("[DNSProxy] buildIPPacket: bad IP length src=\(srcIP.count) dst=\(dstIP.count)")
            return Data()
        }
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

        // New app detection + per-app time tracking.
        //
        // b461: atomicize the (contains → insert → persist → append-to-pending)
        // sequence under knownAppsLock. `recordDomain` already runs on the
        // serial `bgQueue`, but `restoreKnownApps()` runs on the tunnel
        // startup thread, and a future caller that isn't on bgQueue would
        // race the check. Also, re-read the `newAppDetections` list with
        // a fresh UserDefaults fetch right before writing — minimizes the
        // lost-update window if the main-app heartbeat flush ran between
        // our initial check and our write.
        let appName = DomainCategorizer.appName(for: root)
        if let appName {
            knownAppsLock.lock()
            let isNew = !knownApps.contains(appName)
            if isNew {
                knownApps.insert(appName)
                let defaults = UserDefaults.appGroup
                defaults?.set(Array(knownApps), forKey: "knownAppDomains")
                // Fresh-read newAppDetections right before the append to
                // shrink the cross-process race against the main app's
                // flushNewAppDetections (which reads then removes the key).
                var p = defaults?.stringArray(forKey: "newAppDetections") ?? []
                if !p.contains(appName) {
                    p.append(appName)
                    defaults?.set(p, forKey: "newAppDetections")
                }
                NSLog("[DNSProxy] New app: \(appName)")
            }
            knownAppsLock.unlock()
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
    ///
    /// b457: holds `appUsageLock` across the whole body so concurrent reads
    /// from `flushToAppGroup` / `resetDaily` don't race on `appWindows` /
    /// `appMinutes`. Previously this was unsynchronized — only surviving
    /// because the two callers rarely overlapped in practice.
    ///
    /// b457 also tightens the "phantom minute" bug: previously, if an app
    /// emitted one DNS query, went silent for an hour, then emitted another,
    /// the second query would find a stale `appWindows[appName]` entry
    /// `>= 60s` old and credit the app with a "minute" of activity that
    /// never happened. Fix: only count as an active minute if the gap is
    /// in the plausible active-session window (60–75s). Beyond that, treat
    /// it as a fresh session and reset the window without crediting time.
    private func trackAppMinute(_ appName: String) {
        let now = Date()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: now)

        appUsageLock.lock()
        defer { appUsageLock.unlock() }

        // Day rollover: reset all tracking
        if today != appUsageDateString {
            appWindows.removeAll()
            appMinutes.removeAll()
            appUsageDateString = today
        }

        if let windowStart = appWindows[appName] {
            let gap = now.timeIntervalSince(windowStart)
            if gap >= 60 && gap < 75 {
                // Sustained activity: window rolled from at-least-60s to
                // under-75s. Credit a minute, open a new window.
                appMinutes[appName, default: 0] += 1
                appWindows[appName] = now
                checkTimeLimitExhaustionLocked(appName)
            } else if gap >= 75 {
                // Too long a gap — this isn't sustained activity, it's a
                // new session. Reset the window without crediting.
                appWindows[appName] = now
            }
            // Otherwise (0 <= gap < 60): window still open, nothing to do.
        } else {
            // No open window — start one
            appWindows[appName] = now
        }
    }

    /// Check if an app has exceeded its time limit (with 10% buffer for DNS noise).
    /// If exhausted, write to the same pathway the Monitor uses (TimeLimitExhaustedApp).
    ///
    /// **PRECONDITION:** caller must already hold `appUsageLock`. Reading
    /// `appMinutes[appName]` without the lock would race against the
    /// bgQueue writer in `trackAppMinute`.
    private func checkTimeLimitExhaustionLocked(_ appName: String) {
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

        let resolution = ModeStackResolver.resolve(storage: storage)
        if resolution.mode == .unlocked {
            try? storage.writeTimeLimitBlockedDomains([])
            updateTimeLimitBlocklistLocked([], expiry: now.addingTimeInterval(5))
        } else {
            var blockedDomains = Set<String>()
            for app in exhausted where app.dateString == today {
                blockedDomains.formUnion(DomainCategorizer.domainsForApp(app.appName))
            }
            try? storage.writeTimeLimitBlockedDomains(blockedDomains)
            updateTimeLimitBlocklistLocked(blockedDomains, expiry: now.addingTimeInterval(5))
        }

        NSLog("[DNSProxy] DNS time limit exhausted: \(appName) (\(minutes)m >= \(limit.dailyLimitMinutes)m * 1.1)")
    }

    /// Persist current app usage to App Group. Called from flushToAppGroup().
    ///
    /// b457: only serializes the current count — does NOT credit new minutes.
    /// Previously the flush path iterated open windows and credited a minute
    /// for anything aged past 60s, which was wrong in two ways:
    ///   1. A "minute" should require an actual incoming DNS query after 60s
    ///      of window time (sustained activity). Crediting on a timer tick
    ///      instead of on a query event over-counts idle apps that happened
    ///      to have a stale window entry.
    ///   2. The old flush also reset `appWindows[app] = now` on any aged
    ///      entry, reopening the window indefinitely even when the app had
    ///      gone silent. Next flush 60s later would credit another minute.
    ///      Repeat for hours. Apps with ~zero real traffic could "exhaust"
    ///      their daily limit from nothing but DNS-noise leftovers.
    ///
    /// `trackAppMinute` on the bgQueue writer is the ONLY place that credits
    /// minutes — and only when a fresh query arrives. Flush just serializes
    /// the current state.
    private func flushAppUsageToAppGroup() {
        appUsageLock.lock()
        defer { appUsageLock.unlock() }

        guard !appMinutes.isEmpty else { return }

        let usage = DNSAppUsage(dateString: appUsageDateString, apps: appMinutes)
        if let data = try? JSONEncoder().encode(usage) {
            try? storage.writeRawData(data, forKey: "dnsAppUsage")
        }
    }

    /// Restore app usage from App Group on startup. Called from restoreFromAppGroup().
    /// b457: also takes appUsageLock for consistency even though this runs at
    /// start() before bgQueue has work queued.
    private func restoreAppUsageFromAppGroup() {
        guard let data = storage.readRawData(forKey: "dnsAppUsage"),
              let saved = try? JSONDecoder().decode(DNSAppUsage.self, from: data) else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        guard saved.dateString == today else { return }

        appUsageLock.lock()
        defer { appUsageLock.unlock() }
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
        let defaults = UserDefaults.appGroup
        if let data = try? JSONEncoder().encode(domains) { defaults?.set(data, forKey: "dnsActivityDomains") }
        defaults?.set(total, forKey: "dnsActivityTotalQueries")
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        defaults?.set(fmt.string(from: Date()), forKey: "dnsActivityDate")
        defaults?.set(Date().timeIntervalSince1970, forKey: "dnsActivityUpdatedAt")
        flushAppUsageToAppGroup()
    }

    private func restoreFromAppGroup() {
        let defaults = UserDefaults.appGroup
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
        knownAppsLock.lock()
        knownApps = Set(UserDefaults.appGroup?.stringArray(forKey: "knownAppDomains") ?? [])
        knownAppsLock.unlock()
    }

    func resetDaily() {
        statsLock.lock(); domainCounts.removeAll(); totalQueries = 0; statsLock.unlock()
        let d = UserDefaults.appGroup
        d?.removeObject(forKey: "dnsActivityDomains"); d?.set(0, forKey: "dnsActivityTotalQueries")
        // Reset per-app time tracking — b457: synchronized with the bgQueue
        // writer. Without this the UB was a real crash waiting to happen on
        // day rollover when a query arrived at the same instant.
        appUsageLock.lock()
        appWindows.removeAll()
        appMinutes.removeAll()
        appUsageDateString = ""
        appUsageLock.unlock()
        try? storage.writeRawData(nil, forKey: "dnsAppUsage")
    }

    func cleanupStalePendingQueries() {
        pendingLock.lock()
        let now = Date()
        let stale = pending.filter { now.timeIntervalSince($0.value.at) >= 5 }
        pending = pending.filter { now.timeIntervalSince($0.value.at) < 5 }
        pendingLock.unlock()
        // Send REFUSED for stale queries so clients get immediate error.
        // Use the original client txn ID so the client's DNS resolver can
        // actually match the refused response to its in-flight request.
        for (_, entry) in stale {
            let refused = buildRefusedResponseWithOriginalTxn(entry: entry)
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
