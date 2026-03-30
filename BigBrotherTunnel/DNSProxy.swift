import Foundation
import NetworkExtension
import BigBrotherCore

/// Lightweight DNS proxy that intercepts DNS queries on the tunnel interface,
/// logs domain names for activity tracking, and forwards to upstream DNS servers.
///
/// Architecture:
/// 1. Tunnel sets DNS to its own IP (198.18.0.1)
/// 2. iOS sends DNS queries as IP packets on the tunnel interface
/// 3. We parse the domain name from each query
/// 4. Forward the raw DNS payload to upstream via NWUDPSession
/// 5. Write the response back as an IP packet on the tunnel interface
final class DNSProxy {

    private weak var provider: NEPacketTunnelProvider?
    private var upstreamSession: NWUDPSession?
    private let upstreamDNS: NWHostEndpoint
    private var sessionObservation: NSKeyValueObservation?
    private var lastSessionRecreate: Date = .distantPast

    /// Pending DNS queries keyed by transaction ID.
    /// Simple UInt16 key — collisions are rare and the O(1) lookup is critical.
    private var pendingQueries: [UInt16: PendingQuery] = [:]
    private let queryLock = NSLock()

    private struct PendingQuery {
        let sourceIP: Data     // 4 bytes
        let sourcePort: UInt16
    }

    /// In-memory domain activity aggregation.
    private var domainCounts: [String: DomainHit] = [:]
    private var totalQueries: Int = 0
    private let lock = NSLock()

    /// Apps already seen (persisted in App Group) — keyed by app name.
    private var knownApps: Set<String> = []
    private let appLock = NSLock()

    /// Set by PacketTunnelProvider when screen lock state changes.
    /// When true, DNS queries are still forwarded but NOT counted as usage activity.
    var isDeviceLocked: Bool = false

    /// Cached safe search state — refreshed every 30 seconds instead of on every query.
    private var cachedSafeSearchEnabled: Bool = false
    private var safeSearchCacheExpiry: Date = .distantPast

    /// The tunnel's own IP address (DNS queries arrive addressed to this).
    private let tunnelIP: Data = Data([198, 18, 0, 1])

    /// App Group storage for reading restrictions (safe search).
    private let storage: AppGroupStorage

    /// Background queue for domain recording (off the packet-handling path).
    private let recordingQueue = DispatchQueue(label: "dns.recording", qos: .utility)

    init(provider: NEPacketTunnelProvider, upstreamDNSServer: String, storage: AppGroupStorage) {
        self.provider = provider
        self.upstreamDNS = NWHostEndpoint(hostname: upstreamDNSServer, port: "53")
        self.storage = storage
    }

    // MARK: - Safe Search

    /// Maps search engine domains to their safe search IP addresses.
    private static let safeSearchRedirects: [String: String] = [
        "www.google.com": "216.239.38.120",
        "google.com": "216.239.38.120",
        "www.youtube.com": "216.239.38.120",
        "youtube.com": "216.239.38.120",
        "m.youtube.com": "216.239.38.120",
        "www.bing.com": "204.79.197.220",
        "bing.com": "204.79.197.220",
        "duckduckgo.com": "52.142.124.215",
        "www.duckduckgo.com": "52.142.124.215",
    ]

    private func safeSearchIP(for domain: String) -> String? {
        let now = Date()
        if now >= safeSearchCacheExpiry {
            let restrictionEnabled = storage.readDeviceRestrictions()?.denyExplicitContent == true
            let toggleEnabled = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .bool(forKey: "safeSearchEnabled") ?? false
            cachedSafeSearchEnabled = restrictionEnabled || toggleEnabled
            safeSearchCacheExpiry = now.addingTimeInterval(30)
        }
        guard cachedSafeSearchEnabled else { return nil }
        return Self.safeSearchRedirects[domain.lowercased()]
    }

    // MARK: - Lifecycle

    func start() {
        restoreFromAppGroup()
        restoreKnownApps()
        createUpstreamSession()
        startReadingPackets()
        NSLog("[DNSProxy] Started — forwarding to \(upstreamDNS.hostname)")
    }

    func stop() {
        sessionObservation?.invalidate()
        sessionObservation = nil
        upstreamSession?.cancel()
        upstreamSession = nil
    }

    /// Verify the upstream session is still healthy. Called on tunnel wake.
    func verifySession() {
        guard let session = upstreamSession else {
            createUpstreamSession()
            return
        }
        if session.state == .failed || session.state == .cancelled || session.state == .invalid {
            NSLog("[DNSProxy] Session unhealthy (\(session.state.rawValue)) — recreating")
            createUpstreamSession()
        }
    }

    private func createUpstreamSession() {
        // Throttle: don't recreate more than once per 3 seconds
        let now = Date()
        guard now.timeIntervalSince(lastSessionRecreate) > 3 else { return }
        lastSessionRecreate = now

        sessionObservation?.invalidate()
        // Don't cancel old session — let it drain. Just stop observing it.

        guard let provider else { return }

        let session = provider.createUDPSession(to: upstreamDNS, from: nil)
        session.setReadHandler({ [weak self] datagrams, error in
            guard let datagrams else { return }
            for data in datagrams {
                self?.handleUpstreamResponse(data)
            }
        }, maxDatagrams: 64)

        sessionObservation = session.observe(\.state, options: [.new]) { [weak self] sess, _ in
            if sess.state == .failed {
                NSLog("[DNSProxy] Upstream session failed — will recreate on next query")
                // Don't recreate here — let the next incoming query trigger it.
                // This avoids recreation loops when there's no network.
            } else if sess.state == .ready {
                NSLog("[DNSProxy] Upstream session ready")
            }
        }

        upstreamSession = session
        NSLog("[DNSProxy] Created new upstream session to \(upstreamDNS.hostname)")
    }

    // MARK: - Packet Reading

    private func startReadingPackets() {
        provider?.packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            for packet in packets {
                self.handleIncomingPacket(packet)
            }
            self.startReadingPackets()
        }
    }

    // MARK: - Incoming DNS Query

    private func handleIncomingPacket(_ packet: Data) {
        guard packet.count >= 40 else { return }

        let versionIHL = packet[0]
        guard versionIHL >> 4 == 4 else { return }

        let ihl = Int(versionIHL & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl + 8 else { return }
        guard packet[9] == 17 else { return } // UDP only

        let sourceIP = packet.subdata(in: 12..<16)

        let udpStart = ihl
        let destPort = UInt16(packet[udpStart + 2]) << 8 | UInt16(packet[udpStart + 3])
        guard destPort == 53 else { return }

        let sourcePort = UInt16(packet[udpStart]) << 8 | UInt16(packet[udpStart + 1])

        let dnsStart = udpStart + 8
        guard packet.count > dnsStart + 12 else { return }
        let dnsPayload = packet.subdata(in: dnsStart..<packet.count)

        let txnID = UInt16(dnsPayload[0]) << 8 | UInt16(dnsPayload[1])
        let domain = parseDNSQuestionDomain(dnsPayload)

        // Safe Search: instant local response, no upstream needed
        if let domain, let safeIP = safeSearchIP(for: domain) {
            let response = buildSafeSearchResponse(query: dnsPayload, ip: safeIP)
            let responsePacket = buildIPPacket(
                sourceIP: tunnelIP, destIP: sourceIP,
                sourcePort: 53, destPort: sourcePort, payload: response
            )
            provider?.packetFlow.writePackets([responsePacket], withProtocols: [AF_INET as NSNumber])
            recordAsync(domain)
            return
        }

        // Store pending query for response routing (O(1) lookup by txnID)
        queryLock.lock()
        pendingQueries[txnID] = PendingQuery(sourceIP: sourceIP, sourcePort: sourcePort)
        queryLock.unlock()

        // Recreate session if it's dead (lazy — only when we actually need it)
        if let session = upstreamSession,
           session.state == .failed || session.state == .cancelled {
            createUpstreamSession()
        }

        // Forward to upstream DNS
        upstreamSession?.writeDatagram(dnsPayload) { error in
            if let error {
                NSLog("[DNSProxy] Forward failed: \(error.localizedDescription)")
            }
        }

        // Record activity on background queue (doesn't block packet handling)
        if let domain {
            recordAsync(domain)
        }
    }

    /// Record domain activity off the packet-handling path.
    private func recordAsync(_ domain: String) {
        recordingQueue.async { [weak self] in
            self?.recordDomainQuery(domain)
        }
    }

    // MARK: - Upstream Response

    private func handleUpstreamResponse(_ data: Data) {
        guard data.count >= 12 else { return }

        let txnID = UInt16(data[0]) << 8 | UInt16(data[1])

        queryLock.lock()
        let pending = pendingQueries.removeValue(forKey: txnID)
        queryLock.unlock()

        guard let pending else { return }

        let responsePacket = buildIPPacket(
            sourceIP: tunnelIP, destIP: pending.sourceIP,
            sourcePort: 53, destPort: pending.sourcePort, payload: data
        )
        provider?.packetFlow.writePackets([responsePacket], withProtocols: [AF_INET as NSNumber])
    }

    // MARK: - DNS Parsing

    private func parseDNSQuestionDomain(_ dns: Data) -> String? {
        guard dns.count > 12 else { return nil }

        let qdCount = UInt16(dns[4]) << 8 | UInt16(dns[5])
        guard qdCount >= 1 else { return nil }

        var offset = 12
        var labels: [String] = []

        while offset < dns.count {
            let labelLen = Int(dns[offset])
            if labelLen == 0 { break }
            if labelLen > 63 { return nil }

            offset += 1
            guard offset + labelLen <= dns.count else { return nil }

            if let label = String(data: dns.subdata(in: offset..<offset + labelLen), encoding: .ascii) {
                labels.append(label)
            }
            offset += labelLen
        }

        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }

    // MARK: - Safe Search Response

    private func buildSafeSearchResponse(query: Data, ip: String) -> Data {
        guard query.count >= 12 else { return query }

        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return query }

        var response = Data()
        response.append(query[0])
        response.append(query[1])
        response.append(contentsOf: [0x81, 0x80])  // Flags: QR=1, RD=1, RA=1
        response.append(contentsOf: [0x00, 0x01])  // QDCOUNT = 1
        response.append(contentsOf: [0x00, 0x01])  // ANCOUNT = 1
        response.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // NSCOUNT, ARCOUNT = 0

        // Copy question section from query
        var offset = 12
        while offset < query.count {
            let len = query[offset]
            if len == 0 { offset += 1; break }
            offset += Int(len) + 1
        }
        offset += 4
        if offset <= query.count {
            response.append(query.subdata(in: 12..<offset))
        }

        // Answer: pointer to name + A record
        response.append(contentsOf: [0xC0, 0x0C])  // Pointer to domain name
        response.append(contentsOf: [0x00, 0x01])  // TYPE = A
        response.append(contentsOf: [0x00, 0x01])  // CLASS = IN
        response.append(contentsOf: [0x00, 0x00, 0x01, 0x2C])  // TTL = 300
        response.append(contentsOf: [0x00, 0x04])  // RDLENGTH = 4
        for octet in octets { response.append(octet) }

        return response
    }

    // MARK: - IP Packet Construction

    private func buildIPPacket(sourceIP: Data, destIP: Data, sourcePort: UInt16, destPort: UInt16, payload: Data) -> Data {
        let udpLength = UInt16(8 + payload.count)
        let totalLength = UInt16(20 + 8 + payload.count)

        var packet = Data(count: Int(totalLength))

        packet[0] = 0x45; packet[1] = 0
        packet[2] = UInt8(totalLength >> 8); packet[3] = UInt8(totalLength & 0xFF)
        packet[4] = 0; packet[5] = 0
        packet[6] = 0x40; packet[7] = 0
        packet[8] = 64; packet[9] = 17
        packet[10] = 0; packet[11] = 0

        packet.replaceSubrange(12..<16, with: sourceIP)
        packet.replaceSubrange(16..<20, with: destIP)

        var sum: UInt32 = 0
        for i in stride(from: 0, to: 20, by: 2) {
            sum += UInt32(packet[i]) << 8 | UInt32(packet[i + 1])
        }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        let checksum = ~UInt16(sum & 0xFFFF)
        packet[10] = UInt8(checksum >> 8); packet[11] = UInt8(checksum & 0xFF)

        packet[20] = UInt8(sourcePort >> 8); packet[21] = UInt8(sourcePort & 0xFF)
        packet[22] = UInt8(destPort >> 8); packet[23] = UInt8(destPort & 0xFF)
        packet[24] = UInt8(udpLength >> 8); packet[25] = UInt8(udpLength & 0xFF)
        packet[26] = 0; packet[27] = 0

        packet.replaceSubrange(28..<Int(totalLength), with: payload)
        return packet
    }

    // MARK: - Domain Activity Tracking

    private func recordDomainQuery(_ fullDomain: String) {
        let root = DomainCategorizer.rootDomain(fullDomain)
        if DomainCategorizer.isNoise(fullDomain) { return }
        guard !isDeviceLocked else { return }

        checkForNewApp(root)

        let display = DomainCategorizer.displayDomain(fullDomain)
        let (flagged, category) = DomainCategorizer.categorize(root)
        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let slot = DomainHit.slotIndex(hour: comps.hour ?? 0, minute: comps.minute ?? 0)

        lock.lock()
        totalQueries += 1
        if var existing = domainCounts[display] {
            existing.count += 1
            existing.lastSeen = now
            var slots = existing.slotCounts ?? [:]
            slots[slot, default: 0] += 1
            existing.slotCounts = slots
            if flagged && !existing.flagged {
                existing.flagged = true
                existing.category = category
            }
            domainCounts[display] = existing
        } else {
            domainCounts[display] = DomainHit(
                domain: display, count: 1,
                firstSeen: now, lastSeen: now,
                flagged: flagged, category: category,
                slotCounts: [slot: 1]
            )
        }
        lock.unlock()
    }

    // MARK: - New App Detection

    private func checkForNewApp(_ rootDomain: String) {
        guard let appName = DomainCategorizer.appName(for: rootDomain) else { return }

        appLock.lock()
        let isNew = !knownApps.contains(appName)
        if isNew { knownApps.insert(appName) }
        appLock.unlock()

        guard isNew else { return }

        persistKnownApps()

        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        var pending = defaults?.stringArray(forKey: "newAppDetections") ?? []
        pending.append(appName)
        defaults?.set(pending, forKey: "newAppDetections")

        NSLog("[DNSProxy] New app activity detected: \(appName) (\(rootDomain))")
    }

    private func persistKnownApps() {
        appLock.lock()
        let apps = Array(knownApps)
        appLock.unlock()
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(apps, forKey: "knownAppDomains")
    }

    private func restoreKnownApps() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let saved = defaults?.stringArray(forKey: "knownAppDomains") ?? []
        appLock.lock()
        knownApps = Set(saved)
        appLock.unlock()
        if !saved.isEmpty {
            NSLog("[DNSProxy] Restored \(saved.count) known apps")
        }
    }

    // MARK: - Snapshot for Sync

    func takeSnapshot(deviceID: DeviceID, familyID: FamilyID) -> DomainActivitySnapshot {
        lock.lock()
        let domains = Array(domainCounts.values)
        let total = totalQueries
        lock.unlock()

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return DomainActivitySnapshot(
            deviceID: deviceID, familyID: familyID,
            date: dateFormatter.string(from: Date()),
            domains: domains, totalQueries: total
        )
    }

    func flushToAppGroup() {
        lock.lock()
        let domains = Array(domainCounts.values)
        let total = totalQueries
        lock.unlock()

        guard !domains.isEmpty else { return }

        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if let data = try? JSONEncoder().encode(domains) {
            defaults?.set(data, forKey: "dnsActivityDomains")
        }
        defaults?.set(total, forKey: "dnsActivityTotalQueries")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        defaults?.set(dateFormatter.string(from: Date()), forKey: "dnsActivityDate")
        defaults?.set(Date().timeIntervalSince1970, forKey: "dnsActivityUpdatedAt")
    }

    private func restoreFromAppGroup() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        guard defaults?.string(forKey: "dnsActivityDate") == today,
              let data = defaults?.data(forKey: "dnsActivityDomains"),
              let saved = try? JSONDecoder().decode([DomainHit].self, from: data) else {
            return
        }

        lock.lock()
        for hit in saved {
            if let existing = domainCounts[hit.domain] {
                if hit.count > existing.count {
                    domainCounts[hit.domain] = hit
                }
            } else {
                domainCounts[hit.domain] = hit
            }
        }
        let savedTotal = defaults?.integer(forKey: "dnsActivityTotalQueries") ?? 0
        totalQueries = max(totalQueries, savedTotal)
        lock.unlock()

        NSLog("[DNSProxy] Restored \(saved.count) domains from App Group (\(savedTotal) total queries)")
    }

    func resetDaily() {
        lock.lock()
        domainCounts.removeAll()
        totalQueries = 0
        lock.unlock()

        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.removeObject(forKey: "dnsActivityDomains")
        defaults?.set(0, forKey: "dnsActivityTotalQueries")
    }

    func cleanupStalePendingQueries() {
        queryLock.lock()
        if pendingQueries.count > 200 {
            pendingQueries.removeAll()
        }
        queryLock.unlock()
    }
}
