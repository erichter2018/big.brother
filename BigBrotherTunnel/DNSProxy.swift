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

    /// In-memory domain activity aggregation.
    private var domainCounts: [String: DomainHit] = [:]
    private var totalQueries: Int = 0
    private let lock = NSLock()

    /// Pending DNS queries waiting for upstream response (keyed by transaction ID + source).
    private var pendingQueries: [UInt16: PendingQuery] = [:]
    private let queryLock = NSLock()

    private struct PendingQuery {
        let sourceIP: Data     // 4 bytes
        let sourcePort: UInt16
        let receivedAt: Date
    }

    /// The tunnel's own IP address (DNS queries arrive addressed to this).
    private let tunnelIP: Data = Data([198, 18, 0, 1])

    /// App Group storage for reading restrictions (safe search).
    private let storage: AppGroupStorage

    init(provider: NEPacketTunnelProvider, upstreamDNSServer: String, storage: AppGroupStorage) {
        self.provider = provider
        self.upstreamDNS = NWHostEndpoint(hostname: upstreamDNSServer, port: "53")
        self.storage = storage
    }

    // MARK: - Safe Search

    /// Maps search engine domains to their safe search IP addresses.
    /// When denyExplicitContent is enabled, DNS queries for these domains
    /// return the safe search IP instead of the real one.
    private static let safeSearchRedirects: [String: String] = [
        // Google → forcesafesearch.google.com
        "www.google.com": "216.239.38.120",
        "google.com": "216.239.38.120",
        // YouTube → restrictmoderate.youtube.com
        "www.youtube.com": "216.239.38.119",
        "youtube.com": "216.239.38.119",
        "m.youtube.com": "216.239.38.119",
        // Bing → strict.bing.com
        "www.bing.com": "204.79.197.220",
        "bing.com": "204.79.197.220",
        // DuckDuckGo → safe.duckduckgo.com
        "duckduckgo.com": "52.142.124.215",
        "www.duckduckgo.com": "52.142.124.215",
    ]

    /// Check if a domain should be redirected for safe search.
    /// Returns the safe IP if applicable, nil otherwise.
    private func safeSearchIP(for domain: String) -> String? {
        guard storage.readDeviceRestrictions()?.denyExplicitContent == true else { return nil }
        return Self.safeSearchRedirects[domain.lowercased()]
    }

    // MARK: - Lifecycle

    func start() {
        // Restore persisted counts from App Group so data survives tunnel restarts.
        restoreFromAppGroup()

        // Create UDP session to upstream DNS (bypasses tunnel via NEProvider base class)
        upstreamSession = provider?.createUDPSession(to: upstreamDNS, from: nil)
        upstreamSession?.setReadHandler({ [weak self] datagrams, error in
            guard let datagrams else { return }
            for data in datagrams {
                self?.handleUpstreamResponse(data)
            }
        }, maxDatagrams: 64)

        startReadingPackets()
        NSLog("[DNSProxy] Started — forwarding to \(upstreamDNS.hostname)")
    }

    func stop() {
        upstreamSession?.cancel()
        upstreamSession = nil
    }

    // MARK: - Packet Reading

    private func startReadingPackets() {
        provider?.packetFlow.readPackets { [weak self] packets, protocols in
            for packet in packets {
                self?.handleIncomingPacket(packet)
            }
            self?.startReadingPackets()
        }
    }

    // MARK: - Incoming DNS Query

    private func handleIncomingPacket(_ packet: Data) {
        // Minimum: 20 (IP) + 8 (UDP) + 12 (DNS header) = 40 bytes
        guard packet.count >= 40 else { return }

        // Parse IPv4 header
        let versionIHL = packet[0]
        let version = versionIHL >> 4
        guard version == 4 else { return } // IPv4 only

        let ihl = Int(versionIHL & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl + 8 else { return }

        // Check protocol = UDP (17)
        guard packet[9] == 17 else { return }

        // Source IP (bytes 12-15)
        let sourceIP = packet.subdata(in: 12..<16)

        // UDP header starts at IHL offset
        let udpStart = ihl
        let destPort = UInt16(packet[udpStart + 2]) << 8 | UInt16(packet[udpStart + 3])
        guard destPort == 53 else { return } // DNS only

        let sourcePort = UInt16(packet[udpStart]) << 8 | UInt16(packet[udpStart + 1])

        // DNS payload starts after UDP header (8 bytes)
        let dnsStart = udpStart + 8
        guard packet.count > dnsStart + 12 else { return }
        let dnsPayload = packet.subdata(in: dnsStart..<packet.count)

        // Parse DNS transaction ID
        let txnID = UInt16(dnsPayload[0]) << 8 | UInt16(dnsPayload[1])

        // Parse domain name from question section
        let domain = parseDNSQuestionDomain(dnsPayload)
        if let domain {
            recordDomainQuery(domain)
        }

        // Safe Search: if this domain should be redirected, return a spoofed response
        if let domain, let safeIP = safeSearchIP(for: domain) {
            let response = buildSafeSearchResponse(query: dnsPayload, ip: safeIP)
            let responsePacket = buildIPPacket(
                sourceIP: tunnelIP,
                destIP: sourceIP,
                sourcePort: 53,
                destPort: sourcePort,
                payload: response
            )
            provider?.packetFlow.writePackets([responsePacket], withProtocols: [AF_INET as NSNumber])
            return
        }

        // Store pending query for response routing
        queryLock.lock()
        pendingQueries[txnID] = PendingQuery(sourceIP: sourceIP, sourcePort: sourcePort, receivedAt: Date())
        queryLock.unlock()

        // Forward raw DNS payload to upstream
        upstreamSession?.writeDatagram(dnsPayload) { error in
            if let error {
                NSLog("[DNSProxy] Forward failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Upstream Response

    private func handleUpstreamResponse(_ data: Data) {
        guard data.count >= 12 else { return }

        // Parse transaction ID from response
        let txnID = UInt16(data[0]) << 8 | UInt16(data[1])

        queryLock.lock()
        let pending = pendingQueries.removeValue(forKey: txnID)
        queryLock.unlock()

        guard let pending else { return }

        // Build IP + UDP packet wrapping the DNS response
        let responsePacket = buildIPPacket(
            sourceIP: tunnelIP,
            destIP: pending.sourceIP,
            sourcePort: 53,
            destPort: pending.sourcePort,
            payload: data
        )

        // Write response back to the tunnel interface
        provider?.packetFlow.writePackets([responsePacket], withProtocols: [AF_INET as NSNumber])
    }

    // MARK: - DNS Parsing

    /// Extract the queried domain name from a DNS payload.
    private func parseDNSQuestionDomain(_ dns: Data) -> String? {
        guard dns.count > 12 else { return nil }

        // Question count (bytes 4-5)
        let qdCount = UInt16(dns[4]) << 8 | UInt16(dns[5])
        guard qdCount >= 1 else { return nil }

        // Domain name starts at byte 12
        var offset = 12
        var labels: [String] = []

        while offset < dns.count {
            let labelLen = Int(dns[offset])
            if labelLen == 0 { break } // End of domain name
            if labelLen > 63 { return nil } // Compression pointer or invalid

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

    /// Build a DNS response that returns the given IP for an A-record query.
    /// Copies the transaction ID and question section from the original query.
    private func buildSafeSearchResponse(query: Data, ip: String) -> Data {
        guard query.count >= 12 else { return query }

        // Parse IP string to 4 bytes
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return query }

        var response = Data()

        // Transaction ID (2 bytes) — copy from query
        response.append(query[0])
        response.append(query[1])

        // Flags: standard response, no error, recursion available
        response.append(0x81) // QR=1, Opcode=0, AA=0, TC=0, RD=1
        response.append(0x80) // RA=1, Z=0, RCODE=0

        // QDCOUNT = 1
        response.append(0x00)
        response.append(0x01)
        // ANCOUNT = 1
        response.append(0x00)
        response.append(0x01)
        // NSCOUNT = 0
        response.append(0x00)
        response.append(0x00)
        // ARCOUNT = 0
        response.append(0x00)
        response.append(0x00)

        // Question section — copy from query (starts at byte 12)
        // Find end of question: scan past domain name + 4 bytes (QTYPE + QCLASS)
        var offset = 12
        while offset < query.count {
            let len = query[offset]
            if len == 0 { offset += 1; break }
            offset += Int(len) + 1
        }
        offset += 4 // QTYPE (2) + QCLASS (2)

        // Copy question section
        if offset <= query.count {
            response.append(query.subdata(in: 12..<offset))
        }

        // Answer section: pointer to name in question + A record
        response.append(0xC0) // Pointer to offset 12 (domain name in question)
        response.append(0x0C)
        response.append(0x00) // TYPE = A (1)
        response.append(0x01)
        response.append(0x00) // CLASS = IN (1)
        response.append(0x01)
        response.append(0x00) // TTL = 300 seconds
        response.append(0x00)
        response.append(0x01)
        response.append(0x2C)
        response.append(0x00) // RDLENGTH = 4
        response.append(0x04)
        // RDATA = IP address
        for octet in octets {
            response.append(octet)
        }

        return response
    }

    // MARK: - IP Packet Construction

    private func buildIPPacket(sourceIP: Data, destIP: Data, sourcePort: UInt16, destPort: UInt16, payload: Data) -> Data {
        let udpLength = UInt16(8 + payload.count)
        let totalLength = UInt16(20 + 8 + payload.count)

        var packet = Data(count: Int(totalLength))

        // IP header (20 bytes)
        packet[0] = 0x45          // Version 4, IHL 5
        packet[1] = 0             // DSCP/ECN
        packet[2] = UInt8(totalLength >> 8)
        packet[3] = UInt8(totalLength & 0xFF)
        packet[4] = 0; packet[5] = 0   // Identification
        packet[6] = 0x40; packet[7] = 0 // Don't fragment
        packet[8] = 64            // TTL
        packet[9] = 17            // Protocol = UDP
        packet[10] = 0; packet[11] = 0  // Checksum (calculated below)

        // Source IP
        packet.replaceSubrange(12..<16, with: sourceIP)
        // Dest IP
        packet.replaceSubrange(16..<20, with: destIP)

        // IP header checksum
        var sum: UInt32 = 0
        for i in stride(from: 0, to: 20, by: 2) {
            sum += UInt32(packet[i]) << 8 | UInt32(packet[i + 1])
        }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        let checksum = ~UInt16(sum & 0xFFFF)
        packet[10] = UInt8(checksum >> 8)
        packet[11] = UInt8(checksum & 0xFF)

        // UDP header (8 bytes, starting at offset 20)
        packet[20] = UInt8(sourcePort >> 8)
        packet[21] = UInt8(sourcePort & 0xFF)
        packet[22] = UInt8(destPort >> 8)
        packet[23] = UInt8(destPort & 0xFF)
        packet[24] = UInt8(udpLength >> 8)
        packet[25] = UInt8(udpLength & 0xFF)
        packet[26] = 0; packet[27] = 0  // UDP checksum (0 = not computed)

        // DNS payload
        packet.replaceSubrange(28..<Int(totalLength), with: payload)

        return packet
    }

    // MARK: - Domain Activity Tracking

    private func recordDomainQuery(_ fullDomain: String) {
        let root = DomainCategorizer.rootDomain(fullDomain)

        // Skip infrastructure noise
        if DomainCategorizer.isNoise(fullDomain) || DomainCategorizer.isNoise(root) { return }

        // Use display domain to preserve meaningful subdomains
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

    // MARK: - Snapshot for Sync

    /// Take a snapshot of current activity for CloudKit sync.
    /// Does NOT reset counters — caller decides when to reset.
    func takeSnapshot(deviceID: DeviceID, familyID: FamilyID) -> DomainActivitySnapshot {
        lock.lock()
        let domains = Array(domainCounts.values)
        let total = totalQueries
        lock.unlock()

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return DomainActivitySnapshot(
            deviceID: deviceID,
            familyID: familyID,
            date: dateFormatter.string(from: Date()),
            domains: domains,
            totalQueries: total
        )
    }

    /// Flush to App Group storage so data survives tunnel restarts.
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

    /// Restore persisted counts from App Group after tunnel restart.
    private func restoreFromAppGroup() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        // Only restore if the persisted data is from today
        guard defaults?.string(forKey: "dnsActivityDate") == today,
              let data = defaults?.data(forKey: "dnsActivityDomains"),
              let saved = try? JSONDecoder().decode([DomainHit].self, from: data) else {
            return
        }

        lock.lock()
        for hit in saved {
            if let existing = domainCounts[hit.domain] {
                // Keep whichever has the higher count (in-memory may already have new queries)
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

    /// Reset daily counters (call at midnight).
    func resetDaily() {
        lock.lock()
        domainCounts.removeAll()
        totalQueries = 0
        lock.unlock()

        // Clear persisted data too
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        defaults?.removeObject(forKey: "dnsActivityDomains")
        defaults?.set(0, forKey: "dnsActivityTotalQueries")
    }

    /// Clean up stale pending queries older than 10 seconds.
    func cleanupStalePendingQueries() {
        let cutoff = Date().addingTimeInterval(-10)
        queryLock.lock()
        pendingQueries = pendingQueries.filter { $0.value.receivedAt > cutoff }
        queryLock.unlock()
    }
}
