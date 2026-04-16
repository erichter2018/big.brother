import Foundation
import Network
import BigBrotherCore

/// Dedicated DNS resolver for control-plane domains (CloudKit, APNs, Apple
/// ID).  Runs its own NWConnection pool to hardcoded public resolvers,
/// completely independent of the main DNSProxy upstream.  This guarantees
/// that parent commands can always reach the device even when the main
/// upstream is filtered, wedged, or blackholed.
///
/// Design goals:
/// - Never drop a query silently — always reply (real answer or SERVFAIL).
/// - Kaminsky spoof defense: validate response txn ID matches query.
/// - Bounded resource usage: admission control on in-flight queries,
///   connection-idle timeout, per-query timeout.
final class FastPathResolver {

    // MARK: - Configuration

    private static let upstreams: [(host: String, port: UInt16)] = [
        ("1.1.1.1", 53),    // Cloudflare — primary
        ("8.8.8.8", 53),    // Google — secondary
        ("9.9.9.9", 53),    // Quad9 — tertiary
    ]
    private static let queryTimeout: TimeInterval = 3
    private static let connectionIdleTimeout: TimeInterval = 30
    private static let maxInflight: Int = 64

    // MARK: - Types

    /// Bookkeeping for one in-flight query.
    private struct PendingQuery {
        let clientIP: Data
        let clientPort: UInt16
        let originalTxn: UInt16
        let query: Data
        let deadline: Date
    }

    // MARK: - State (all access on `queue`)

    private let queue = DispatchQueue(label: "fr.bigbrother.fastpath", qos: .userInitiated)
    private let writeResponse: (Data, Data, UInt16) -> Void

    /// Current NWConnection per upstream index and its generation counter.
    /// Generation counters prevent stale completion handlers from writing
    /// to a recycled connection.
    private var connections: [Int: NWConnection] = [:]
    private var connectionGenerations: [Int: UInt64] = [:]
    private var nextGeneration: UInt64 = 1

    /// Liveness timer fires when a connection has been idle too long.
    private var idleTimers: [Int: DispatchSourceTimer] = [:]

    /// In-flight queries keyed by the proxy-assigned txn ID we sent
    /// upstream.  NOT the client's original txn ID (clients can collide).
    private var pending: [UInt16: PendingQuery] = [:]
    private var nextTxnID: UInt16 = 1

    /// Index into `upstreams` for round-robin on failure.
    private var currentUpstream: Int = 0

    // MARK: - Init

    /// - Parameter writeResponse: Callback to send a DNS response back to
    ///   the client.  Parameters: (responsePayload, destinationIP, destinationPort).
    ///   May be called from `queue`.
    init(writeResponse: @escaping (Data, Data, UInt16) -> Void) {
        self.writeResponse = writeResponse
    }

    // MARK: - Lifecycle

    private var stopped = false

    func start() {
        queue.async { [weak self] in
            self?.stopped = false
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            for (_, conn) in self.connections {
                conn.cancel()
            }
            self.connections.removeAll()
            self.connectionGenerations.removeAll()
            for (_, timer) in self.idleTimers {
                timer.cancel()
            }
            self.idleTimers.removeAll()
            for (txn, pq) in self.pending {
                self.sendSERVFAIL(originalTxn: pq.originalTxn, clientIP: pq.clientIP, clientPort: pq.clientPort)
                self.pending.removeValue(forKey: txn)
            }
        }
    }

    // MARK: - Public API

    /// Resolve a DNS query for a critical domain via the dedicated upstream
    /// pool.  Always delivers exactly one response (real or SERVFAIL) via
    /// the `writeResponse` callback.
    ///
    /// - Parameters:
    ///   - query: Raw DNS query bytes (header + question + optional EDNS).
    ///   - clientIP: 4-byte IPv4 address of the client (for the response).
    ///   - clientPort: UDP source port of the client.
    ///   - originalTxn: The client's DNS transaction ID (restored in the
    ///     response so the stub resolver recognizes it).
    func resolve(query: Data, clientIP: Data, clientPort: UInt16, originalTxn: UInt16) {
        queue.async { [weak self] in
            self?._resolve(query: query, clientIP: clientIP, clientPort: clientPort, originalTxn: originalTxn)
        }
    }

    // MARK: - Internal Resolution

    private func _resolve(query: Data, clientIP: Data, clientPort: UInt16, originalTxn: UInt16) {
        guard !stopped else {
            sendSERVFAIL(originalTxn: originalTxn, clientIP: clientIP, clientPort: clientPort)
            return
        }
        guard pending.count < Self.maxInflight else {
            NSLog("[FastPath] admission control: %d in-flight, dropping", pending.count)
            sendSERVFAIL(originalTxn: originalTxn, clientIP: clientIP, clientPort: clientPort)
            return
        }

        // Allocate a proxy-side txn ID to avoid collisions between clients.
        let proxyTxn = allocateTxnID()

        // Rewrite the query's txn ID to our proxy txn.
        var rewritten = query
        guard rewritten.count >= 2 else {
            sendSERVFAIL(originalTxn: originalTxn, clientIP: clientIP, clientPort: clientPort)
            return
        }
        rewritten[rewritten.startIndex] = UInt8(proxyTxn >> 8)
        rewritten[rewritten.startIndex + 1] = UInt8(proxyTxn & 0xFF)

        let entry = PendingQuery(
            clientIP: clientIP,
            clientPort: clientPort,
            originalTxn: originalTxn,
            query: rewritten,
            deadline: Date().addingTimeInterval(Self.queryTimeout)
        )
        pending[proxyTxn] = entry

        // Schedule a per-query timeout.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.queryTimeout)
        timer.setEventHandler { [weak self] in
            timer.cancel()
            self?.handleQueryTimeout(proxyTxn: proxyTxn)
        }
        timer.resume()

        // Send via current upstream, trying the next on connection failure.
        sendToUpstream(query: rewritten, proxyTxn: proxyTxn, attempt: 0)
    }

    private func sendToUpstream(query: Data, proxyTxn: UInt16, attempt: Int) {
        guard attempt < Self.upstreams.count else {
            // All upstreams exhausted — SERVFAIL.
            if let entry = pending.removeValue(forKey: proxyTxn) {
                sendSERVFAIL(originalTxn: entry.originalTxn, clientIP: entry.clientIP, clientPort: entry.clientPort)
            }
            return
        }

        let idx = (currentUpstream + attempt) % Self.upstreams.count
        let conn = getOrCreateConnection(index: idx)
        let gen = connectionGenerations[idx] ?? 0

        conn.send(content: query, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    NSLog("[FastPath] send error upstream %d: %@", idx, error.localizedDescription)
                    self.teardownConnection(index: idx)
                    self.sendToUpstream(query: query, proxyTxn: proxyTxn, attempt: attempt + 1)
                    return
                }
                self.receiveResponse(index: idx, generation: gen, proxyTxn: proxyTxn, attempt: attempt)
            }
        })
    }

    private func receiveResponse(index: Int, generation: UInt64, proxyTxn: UInt16, attempt: Int) {
        guard let conn = connections[index], connectionGenerations[index] == generation else {
            // Connection was recycled — retry on next upstream.
            sendToUpstream(query: pending[proxyTxn]?.query ?? Data(), proxyTxn: proxyTxn, attempt: attempt + 1)
            return
        }

        conn.receive(minimumIncompleteLength: 12, maximumLength: 65535) { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                // Stale generation — ignore.
                guard self.connectionGenerations[index] == generation else { return }

                if let error {
                    NSLog("[FastPath] recv error upstream %d: %@", index, error.localizedDescription)
                    self.teardownConnection(index: index)
                    if self.pending[proxyTxn] != nil {
                        self.sendToUpstream(query: self.pending[proxyTxn]!.query, proxyTxn: proxyTxn, attempt: attempt + 1)
                    }
                    return
                }

                guard let data, data.count >= 12 else {
                    if self.pending[proxyTxn] != nil {
                        self.sendToUpstream(query: self.pending[proxyTxn]!.query, proxyTxn: proxyTxn, attempt: attempt + 1)
                    }
                    return
                }

                // Kaminsky defense: validate txn ID in response matches what
                // we sent.  Discard spoofed packets silently.
                let responseTxn = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
                guard responseTxn == proxyTxn else {
                    NSLog("[FastPath] txn mismatch: expected %04X got %04X — possible spoof", proxyTxn, responseTxn)
                    // Don't retry — just wait for the real response or timeout.
                    return
                }

                guard let entry = self.pending.removeValue(forKey: proxyTxn) else {
                    // Already timed out or answered.
                    return
                }

                // Restore the client's original txn ID and deliver.
                var response = data
                response[response.startIndex] = UInt8(entry.originalTxn >> 8)
                response[response.startIndex + 1] = UInt8(entry.originalTxn & 0xFF)
                self.writeResponse(response, entry.clientIP, entry.clientPort)

                // Reset idle timer — connection is alive.
                self.resetIdleTimer(index: index)

                // Promote this upstream to primary on success.
                self.currentUpstream = index
            }
        }
    }

    // MARK: - Connection Pool

    private func getOrCreateConnection(index: Int) -> NWConnection {
        if let existing = connections[index] {
            return existing
        }

        let upstream = Self.upstreams[index]
        let conn = NWConnection(
            host: NWEndpoint.Host(upstream.host),
            port: NWEndpoint.Port(integerLiteral: upstream.port),
            using: .udp
        )

        let gen = nextGeneration
        nextGeneration += 1
        connectionGenerations[index] = gen

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                guard self.connectionGenerations[index] == gen else { return }
                switch state {
                case .failed, .cancelled:
                    NSLog("[FastPath] connection %d state: %@", index, "\(state)")
                    self.teardownConnection(index: index)
                default:
                    break
                }
            }
        }

        conn.start(queue: queue)
        connections[index] = conn
        resetIdleTimer(index: index)

        return conn
    }

    private func teardownConnection(index: Int) {
        idleTimers[index]?.cancel()
        idleTimers.removeValue(forKey: index)

        if let conn = connections.removeValue(forKey: index) {
            conn.cancel()
        }
        connectionGenerations.removeValue(forKey: index)
    }

    // MARK: - Idle Timer

    private func resetIdleTimer(index: Int) {
        idleTimers[index]?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.connectionIdleTimeout)
        timer.setEventHandler { [weak self] in
            timer.cancel()
            guard let self else { return }
            self.queue.async {
                NSLog("[FastPath] idle timeout for upstream %d", index)
                self.teardownConnection(index: index)
            }
        }
        timer.resume()
        idleTimers[index] = timer
    }

    // MARK: - Timeout Handling

    private func handleQueryTimeout(proxyTxn: UInt16) {
        guard let entry = pending.removeValue(forKey: proxyTxn) else {
            return  // Already completed.
        }
        NSLog("[FastPath] query timeout txn=%04X", proxyTxn)
        sendSERVFAIL(originalTxn: entry.originalTxn, clientIP: entry.clientIP, clientPort: entry.clientPort)
    }

    // MARK: - SERVFAIL

    private func sendSERVFAIL(originalTxn: UInt16, clientIP: Data, clientPort: UInt16) {
        let response = DNSMessage.headerOnlyResponse(
            txnID: originalTxn,
            flagsHigh: 0x81,  // QR=1, RD=1
            flagsLow: 0x02    // RCODE=2 (SERVFAIL)
        )
        writeResponse(response, clientIP, clientPort)
    }

    // MARK: - Txn ID Allocation

    /// Allocate a unique proxy-side transaction ID.  Skips IDs that are
    /// already in-flight to avoid collisions.
    private func allocateTxnID() -> UInt16 {
        var id = nextTxnID
        var attempts = 0
        while pending[id] != nil && attempts < 65535 {
            id &+= 1
            if id == 0 { id = 1 }  // Skip 0 — some resolvers treat it specially.
            attempts += 1
        }
        nextTxnID = id &+ 1
        if nextTxnID == 0 { nextTxnID = 1 }
        return id
    }
}
