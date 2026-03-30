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

    // Pending queries: txnID → (sourceIP, sourcePort)
    private var pending: [UInt16: (ip: Data, port: UInt16)] = [:]
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
    private var knownApps: Set<String> = []

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
        upstreamSession = provider?.createUDPSession(to: upstreamDNS, from: nil)
        upstreamSession?.setReadHandler({ [weak self] datagrams, _ in
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

    /// Recreate the upstream session (call after network changes).
    func recreateSession() {
        let old = upstreamSession
        upstreamSession = provider?.createUDPSession(to: upstreamDNS, from: nil)
        upstreamSession?.setReadHandler({ [weak self] datagrams, _ in
            guard let datagrams else { return }
            for d in datagrams { self?.onUpstreamResponse(d) }
        }, maxDatagrams: 64)
        old?.cancel()
        NSLog("[DNSProxy] Session recreated")
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

        // Safe search: instant local reply
        if let domain, let ip = checkSafeSearch(domain) {
            let resp = buildDNSResponse(query: dns, ip: ip)
            writeResponse(resp, destIP: srcIP, destPort: srcPort)
            bgLog(domain)
            return
        }

        // Store pending, forward upstream
        pendingLock.lock()
        pending[txn] = (ip: srcIP, port: srcPort)
        // Cap pending to prevent unbounded growth
        if pending.count > 300 { pending.removeAll() }
        pendingLock.unlock()

        upstreamSession?.writeDatagram(dns) { error in
            if error != nil {
                // Session might be dead — will be recreated on wake()
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

    // MARK: - Safe Search

    private func checkSafeSearch(_ domain: String) -> String? {
        let now = Date()
        if now >= safeSearchExpiry {
            let r = storage.readDeviceRestrictions()?.denyExplicitContent == true
            let t = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.bool(forKey: "safeSearchEnabled") ?? false
            safeSearchOn = r || t
            safeSearchExpiry = now.addingTimeInterval(30)
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

        // New app detection
        if let appName = DomainCategorizer.appName(for: root), !knownApps.contains(appName) {
            knownApps.insert(appName)
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.set(Array(knownApps), forKey: "knownAppDomains")
            var p = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.stringArray(forKey: "newAppDetections") ?? []
            p.append(appName)
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.set(p, forKey: "newAppDetections")
            NSLog("[DNSProxy] New app: \(appName)")
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
    }

    private func restoreKnownApps() {
        knownApps = Set(UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.stringArray(forKey: "knownAppDomains") ?? [])
    }

    func resetDaily() {
        statsLock.lock(); domainCounts.removeAll(); totalQueries = 0; statsLock.unlock()
        let d = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        d?.removeObject(forKey: "dnsActivityDomains"); d?.set(0, forKey: "dnsActivityTotalQueries")
    }

    func cleanupStalePendingQueries() {
        pendingLock.lock()
        if pending.count > 100 { pending.removeAll() }
        pendingLock.unlock()
    }
}
