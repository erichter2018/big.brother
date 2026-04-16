import Foundation
import Network
import NetworkExtension
import BigBrotherCore

/// Minimal DNS proxy: intercept queries, forward upstream, return responses.
/// Activity logging is fire-and-forget on a background queue.
///
/// ## Upstream transport: NWConnection, not NWUDPSession
///
/// Earlier versions used `NEPacketTunnelProvider.createUDPSession` which
/// returns an `NWUDPSession`. That API was introduced in iOS 9, is
/// effectively deprecated, and has a long tail of bugs around path
/// migration:
///   - Sessions stay `.ready` while silently bound to a dead interface
///     after wifi→cellular handoff (Simon's iPhone 17,4 bug, Apr 14 2026).
///   - Every interface swap on hotspot churned up dozens of write errors
///     requiring full session rebuilds (Sebastian's iPad, Apr 14 2026:
///     82 reconnects per handoff).
///   - No observable state for "iOS is temporarily handling a path
///     disruption — wait for it to recover." Every blip was indistinguishable
///     from a permanent failure.
///
/// `NWConnection` (Network framework, iOS 12+) is Apple's current API.
/// It handles path migration internally: when the active interface
/// changes, the connection rebinds its underlying socket without
/// surfacing to our code. It exposes a proper state machine including
/// `.waiting(error)` for transient disruptions and `.failed(error)` for
/// terminal ones — so we can distinguish "give iOS a moment" from
/// "we need a fresh connection." We observe the state and trigger
/// reconnect only when it actually fails.
///
/// NWConnection runs inside the NE process; iOS routes its traffic
/// around the tunnel automatically (same as NWUDPSession did) to avoid
/// the loop. No special `prohibitedInterfaceTypes` needed.
final class DNSProxy {

    private weak var provider: NEPacketTunnelProvider?
    /// Mutable upstream connection state. All four of `upstreamConnection`,
    /// `waitingEnteredAt`, `connectionCreatedAt`, and
    /// `currentConnectionReachedReady` are touched from multiple queues:
    ///   - `upstreamQueue` (NWConnection state handler + receive callbacks)
    ///   - `.global(qos: .userInitiated)` (5s liveness timer → `healthCheck`)
    ///   - the path-monitor queue (PacketTunnelProvider path change handler
    ///     calls `reconnectUpstream`)
    ///   - the NE framework's internal queues (reapplyNetworkSettings
    ///     completion calls `reconnectUpstream`)
    ///   - the packet-flow read loop (`forwardToUpstream` reads
    ///     `upstreamConnection.state` + sends on it)
    /// Without a lock, concurrent access is a Swift data race (not just
    /// theoretical — wifi↔cellular flaps on Simon's device produced the
    /// exact interleavings where `setupUpstreamConnection` writes
    /// `waitingEnteredAt = nil` on one queue while the state handler writes
    /// `waitingEnteredAt = Date()` on `upstreamQueue`, or `checkWaitingStuck`
    /// reads the field mid-write on a third queue). `upstreamStateLock`
    /// serializes every read/write. Never hold across an `NWConnection`
    /// method call or a reconnect — snapshot under the lock, release, act.
    private let upstreamStateLock = NSLock()
    /// Terminal flag. Set by `stop()`; once true, `setupUpstreamConnection`
    /// refuses to create a fresh connection and `healthCheck`/probe-timeout
    /// paths refuse to call `reconnectUpstream`. Prevents late-firing
    /// callbacks (probe-timeout closure, debounced path-monitor work,
    /// recovery-ladder dispatch) from resurrecting the upstream after the
    /// tunnel has asked us to tear down. Guarded by `upstreamStateLock`.
    private var stopped: Bool = false
    private var upstreamConnection: NWConnection?
    private let upstreamHost: Network.NWEndpoint.Host
    private let upstreamPort: Network.NWEndpoint.Port
    private let upstreamHostDescription: String
    /// Serial queue for all upstream connection callbacks (state updates,
    /// receive completions). Serial so we never process two callbacks
    /// concurrently — the pending-queue and onUpstreamResponse logic
    /// assumes single-threaded invocation from the upstream path.
    private let upstreamQueue = DispatchQueue(label: "fr.bigbrother.tunnel.dnsUpstream")
    /// Generation ID for the current upstream connection. Every
    /// `setupUpstreamConnection()` bumps this; callbacks from older
    /// connections check their captured generation against this and bail
    /// out, preventing a stale receive loop from clobbering the fresh
    /// connection's responses (same pattern as `readLoopGeneration` for
    /// the packet flow).
    private var upstreamGeneration: Int = 0
    private let upstreamGenerationLock = NSLock()
    /// When the current connection entered `.waiting` state, if any.
    /// Used to force a rebuild if iOS stays in `.waiting` for too long
    /// (usually it recovers in seconds; stuck beyond a few seconds
    /// means the path isn't coming back and we should cancel and
    /// create a new connection rather than keep queuing sends).
    private var waitingEnteredAt: Date?
    private let waitingStuckThreshold: TimeInterval = 8
    /// When the current connection was created. Used to apply a brief
    /// startup grace period where `.failed` doesn't trigger an immediate
    /// rebuild — a fresh NWConnection can transition through
    /// `.preparing → .failed → .preparing → .ready` during routine path
    /// setup (especially on mid-process install where routing is
    /// still coalescing). An instant rebuild loop in that window
    /// creates cascading failures that look worse than doing nothing.
    private var connectionCreatedAt: Date?
    private let startupGracePeriod: TimeInterval = 3
    /// Once the current connection reaches `.ready` at least once, flip
    /// this so later `.failed` transitions bypass the grace period —
    /// a connection that WAS working and now failed is a real wedge,
    /// rebuild immediately.
    private var currentConnectionReachedReady: Bool = false
    private let tunnelIP: Data = Data([198, 18, 0, 1])
    private let storage: AppGroupStorage

    /// Dedicated resolver for control-plane domains (CloudKit, APNs, Apple
    /// ID). Runs fully independent of the main upstream connection above —
    /// see `FastPathResolver` for the rationale. Initialized in `init` and
    /// its lifecycle is owned by DNSProxy (start/stop wired through).
    private var fastPathResolver: FastPathResolver!

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
    /// Upstream txn IDs for client queries use the range [0, probeTxnBase).
    /// IDs at or above `probeTxnBase` are reserved for active health probes
    /// (see `activeProbe()`) so probe responses can be identified without a
    /// parallel lookup table.
    private static let probeTxnBase: UInt16 = 0xFFF0
    private var nextUpstreamTxn: UInt16 = UInt16.random(in: 0..<probeTxnBase)

    /// Active health probes keyed by their upstream txn ID. Value is the
    /// time the probe was written to upstream; a scheduled check
    /// `probeTimeoutSeconds` later looks the txn up — if it's still here,
    /// the probe timed out and we treat the upstream as wedged (dead
    /// interface / stale NWUDPSession).
    private var outstandingProbes: [UInt16: Date] = [:]
    private let probeLock = NSLock()
    private var nextProbeTxn: UInt16 = probeTxnBase
    /// Floor on probe cadence — prevents double-probe on back-to-back ticks
    /// without blocking the normal 5s fast-path tick from firing one each
    /// time the "recent activity" check fails.
    private var lastProbeAt: Date = .distantPast
    private let probeMinInterval: TimeInterval = 4
    private let probeTimeoutSeconds: TimeInterval = 2.5
    /// Last time we saw a real upstream response (client query or probe).
    /// Used to skip probes when client traffic is proof-of-life — under
    /// active browsing the probe is a no-op, only firing during idle or
    /// suspected-wedge windows.
    private var lastUpstreamResponseAt: Date = .distantPast
    private let upstreamActivityWindow: TimeInterval = 5

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

    /// DNS kill-switch cache. When the cached value is `false`, `onPacket`
    /// skips ALL filtering gates (blackhole, enforcement, time-limit,
    /// safe-search) and forwards the query as-is. Fast-path (critical
    /// domains) runs BEFORE this check and is unaffected. Cache refreshes
    /// every `dnsFilteringCacheTTL` seconds so a remote re-enable command
    /// takes effect promptly without paying a disk read on every packet.
    /// Both read and refresh happen inline on the packet-flow queue —
    /// single-threaded — no lock needed.
    ///
    /// This path is PURE: no App Group writes from the read side. Auto-
    /// re-enable is performed by the tunnel's liveness timer (see
    /// `PacketTunnelProvider.maintainDNSFilteringAutoReenable`). Keeping
    /// the read side side-effect-free means concurrent readers + a
    /// concurrent writer (fresh disable command) can't race on App Group
    /// and clobber each other's writes.
    private var dnsFilteringEnabledCache: Bool = true
    private var dnsFilteringCacheExpiry: Date = .distantPast
    private let dnsFilteringCacheTTL: TimeInterval = 3

    private func refreshDNSFilteringCache() {
        let now = Date()
        guard now >= dnsFilteringCacheExpiry else { return }
        let persisted = DNSFilteringState.read(from: UserDefaults.appGroup)
        dnsFilteringEnabledCache = persisted.effective(now: now).enabled
        dnsFilteringCacheExpiry = now.addingTimeInterval(dnsFilteringCacheTTL)
    }

    /// Delegates to `CriticalDomains.matches` — single source of truth. The
    /// previous implementation kept a separate local list that drifted out
    /// of sync with `CriticalDomains.suffixes` (round-3 audit flagged three
    /// domains missing from the copy). Fast path at top of `onPacket`
    /// intercepts these first, so in practice this check runs only when
    /// the fast path falls back to the slow path — but when it DOES run,
    /// it must recognize exactly the same names the fast path does.
    private func isCloudKitDomain(_ domain: String) -> Bool {
        CriticalDomains.matches(domain)
    }
    private var knownApps: Set<String> = []
    /// b461: lock around all knownApps access (check + insert + persist +
    /// pending-list append). See recordDomain comments for rationale.
    private let knownAppsLock = NSLock()

    /// Called when a known app domain is seen. Parameters: (appName, rootDomain, timestamp)
    var onAppDomainSeen: ((String, String, Date) -> Void)?

    /// Domains always allowed through the blackhole — Apple infrastructure for
    /// CloudKit commands, APNS push delivery, and iCloud sync. Delegates to
    /// `CriticalDomains.matches` — single source of truth with label-boundary
    /// match semantics. Previously kept a separate list that had already
    /// drifted out of sync with the fast-path list on ship day.
    private func isBlackholeExempt(_ domain: String) -> Bool {
        CriticalDomains.matches(domain)
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
        self.upstreamHost = Network.NWEndpoint.Host(upstreamDNSServer)
        self.upstreamPort = Network.NWEndpoint.Port(integerLiteral: 53)
        self.upstreamHostDescription = upstreamDNSServer
        self.storage = storage
        // Closure captures `self` weakly via the writeResponse indirection
        // so we don't form a retain cycle. The closure is invoked from the
        // FastPathResolver's own queue; `writeResponse` hops to packetFlow
        // which is thread-safe, so no extra dispatching is needed.
        self.fastPathResolver = FastPathResolver(writeResponse: { [weak self] payload, destIP, destPort in
            self?.writeResponse(payload, destIP: destIP, destPort: destPort)
        })
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
        setupUpstreamConnection(reason: "start")
        fastPathResolver.start()
        let gen = startReadLoopInternal()
        NSLog("[DNSProxy] Started → \(upstreamHostDescription) (readLoop gen=\(gen)), fastPath active")
    }

    /// Telemetry-only hook for "a read/write on the upstream failed." The
    /// actual reconnect decision lives in the connection's
    /// `stateUpdateHandler` — NWConnection reports its state transitions
    /// authoritatively, so we don't double-trigger rebuilds off individual
    /// send errors. This is called from the send completion handler to
    /// record that something went wrong; state handler will fire `.failed`
    /// shortly after if it's terminal.
    func markUpstreamUnhealthy() {
        TunnelTelemetry.update { $0.dnsUpstreamWriteErrors += 1 }
    }

    func stop() {
        // Bump generation first so any in-flight receive callbacks from the
        // cancelled connection drain without re-queuing.
        bumpUpstreamGeneration()
        upstreamStateLock.lock()
        stopped = true
        let conn = upstreamConnection
        upstreamConnection = nil
        waitingEnteredAt = nil
        connectionCreatedAt = nil
        currentConnectionReachedReady = false
        upstreamStateLock.unlock()
        conn?.cancel()
        fastPathResolver.stop()
        // Invalidate the running read loop so its next completion drains
        // out. We don't need to actively cancel `readPackets` — Apple
        // doesn't expose that — but bumping the generation guarantees
        // that whatever callback eventually fires will stop recursing.
        readLoopLock.lock()
        readLoopGeneration += 1
        readLoopLock.unlock()
    }

    // MARK: - Upstream Connection Management (NWConnection)

    /// Bump the upstream generation counter. Every new connection gets a
    /// fresh generation; in-flight receive callbacks from older
    /// connections compare their captured gen to this and drain out.
    /// Callers that need the new generation should read it back after
    /// bumping.
    @discardableResult
    private func bumpUpstreamGeneration() -> Int {
        upstreamGenerationLock.lock()
        upstreamGeneration += 1
        let gen = upstreamGeneration
        upstreamGenerationLock.unlock()
        return gen
    }

    private var currentUpstreamGeneration: Int {
        upstreamGenerationLock.lock()
        defer { upstreamGenerationLock.unlock() }
        return upstreamGeneration
    }

    /// Build and start a fresh `NWConnection` to the upstream DNS server.
    /// Cancels any existing connection first. Called from `start()` and
    /// `reconnectUpstream()`.
    private func setupUpstreamConnection(reason: String) {
        // UDP parameters. We intentionally DON'T set
        // `prohibitedInterfaceTypes` — iOS excludes the NE process's own
        // traffic from the tunnel automatically, so NWConnection here
        // behaves the same as NWUDPSession did: goes through the system
        // networking stack, not through our own packet flow.
        let parameters = NWParameters.udp
        // Allow expired DNS entries during brief outages — better to
        // connect with a slightly stale resolution than to error out.
        parameters.expiredDNSBehavior = .allow
        // Disable multipath — we only want one interface at a time, matching
        // the NWUDPSession behavior. iOS still migrates to a new interface
        // when the active one dies.
        parameters.multipathServiceType = .disabled

        // Bump generation and build the new connection before touching any
        // state. Once the generation is bumped, any pending callback from
        // the prior connection — including the `.cancelled` we're about to
        // trigger — will fail its `generation == currentUpstreamGeneration`
        // check and drain out without mutating shared state.
        let gen = bumpUpstreamGeneration()
        let connection = NWConnection(host: upstreamHost, port: upstreamPort, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleUpstreamStateChange(state, generation: gen, reason: reason)
        }

        // Atomic swap: install the new connection + reset state under lock,
        // snapshot the old one for cancellation. Cancel OUTSIDE the lock —
        // NWConnection.cancel() is non-blocking but we still don't want to
        // block any other queue waiting on the state lock while iOS unwinds
        // the old connection. The `stopped` check inside the lock closes the
        // TOCTOU window: if `stop()` raced in between the generation bump and
        // the install, we cancel the freshly-built connection here and bail
        // without touching shared state. No resurrection possible.
        upstreamStateLock.lock()
        if stopped {
            upstreamStateLock.unlock()
            connection.cancel()
            NSLog("[DNSProxy] setupUpstreamConnection racing stop — discarding fresh connection (reason=\(reason))")
            return
        }
        let oldConnection = upstreamConnection
        upstreamConnection = connection
        waitingEnteredAt = nil
        connectionCreatedAt = Date()
        currentConnectionReachedReady = false
        upstreamStateLock.unlock()

        oldConnection?.cancel()
        connection.start(queue: upstreamQueue)

        // Kick off the receive loop. It's a recursive self-scheduling chain;
        // each `receiveMessage` returns one datagram, we hand it off and
        // re-arm.
        receiveNextUpstream(on: connection, generation: gen)

        NSLog("[DNSProxy] Upstream connection created (gen=\(gen), reason=\(reason))")
    }

    /// Handle state transitions from the upstream connection. This is the
    /// single source of truth for "is the upstream healthy?" — replaces
    /// the old `upstreamNeedsReconnect` flag that every send-error call
    /// site had to remember to set.
    private func handleUpstreamStateChange(_ state: NWConnection.State, generation: Int, reason: String) {
        // If a newer connection has been created while this callback was
        // queued, drop — our opinions about this (old) connection are no
        // longer relevant.
        guard generation == currentUpstreamGeneration else { return }

        switch state {
        case .ready:
            upstreamStateLock.lock()
            waitingEnteredAt = nil
            currentConnectionReachedReady = true
            upstreamStateLock.unlock()
            NSLog("[DNSProxy] Upstream state → ready (gen=\(generation))")

        case .preparing:
            NSLog("[DNSProxy] Upstream state → preparing (gen=\(generation))")

        case .waiting(let error):
            // Transient: iOS is trying to recover path connectivity. Sends
            // in this state are queued internally until iOS reports ready
            // or failed. Record the entry time so we can force a rebuild
            // if we stay stuck here — but DON'T tear down on entry. Most
            // `.waiting` transitions resolve in a fraction of a second
            // during a handoff.
            upstreamStateLock.lock()
            if waitingEnteredAt == nil {
                waitingEnteredAt = Date()
            }
            upstreamStateLock.unlock()
            NSLog("[DNSProxy] Upstream state → waiting: \(error.debugDescription) (gen=\(generation))")

        case .failed(let error):
            // Startup grace period: if this connection never reached
            // `.ready` and is within `startupGracePeriod` of creation,
            // schedule a delayed rebuild instead of looping immediately.
            // Prevents the early-failure cycle observed on b548 where
            // brand-new connections would go .preparing → .failed → rebuild
            // → .preparing → .failed in a tight loop during the first
            // few seconds of a tunnel restart.
            upstreamStateLock.lock()
            let startupAge = connectionCreatedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let reachedReady = currentConnectionReachedReady
            upstreamStateLock.unlock()
            if !reachedReady && startupAge < startupGracePeriod {
                NSLog("[DNSProxy] Upstream state → failed during startup (\(Int(startupAge))s, gen=\(generation)) — delaying rebuild")
                markUpstreamUnhealthy()
                let delay = startupGracePeriod - startupAge + 0.5
                upstreamQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    // Only rebuild if we're still the current generation —
                    // otherwise something else already handled it.
                    guard generation == self.currentUpstreamGeneration else { return }
                    NSLog("[DNSProxy] Startup grace expired (gen=\(generation)) — reconnecting")
                    self.reconnectUpstream()
                }
                break
            }
            // Terminal — connection is dead. Trigger rebuild.
            NSLog("[DNSProxy] Upstream state → failed: \(error.debugDescription) (gen=\(generation)) — reconnecting")
            markUpstreamUnhealthy()
            reconnectUpstream()

        case .cancelled:
            // Expected during our own tear-down. No action.
            NSLog("[DNSProxy] Upstream state → cancelled (gen=\(generation))")

        case .setup:
            break

        @unknown default:
            break
        }
    }

    /// Recursive receive loop. NWConnection's `receiveMessage` returns one
    /// datagram per call; we process it, then re-arm. Errors bail the loop
    /// — the state handler will have already triggered reconnect for the
    /// root cause.
    private func receiveNextUpstream(on connection: NWConnection, generation: Int) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            // Drop stale callbacks from a superseded connection.
            guard generation == self.currentUpstreamGeneration else { return }

            if let error {
                NSLog("[DNSProxy] Upstream receive error: \(error.debugDescription) (gen=\(generation))")
                // Don't recall — state handler will fire failed/cancelled
                // and rebuild will schedule a fresh receive loop on the
                // new connection. Recalling here would race with rebuild.
                return
            }
            if let content {
                self.onUpstreamResponse(content)
            }
            // Re-arm — we'll be called again for the next datagram. This
            // is the NWConnection equivalent of `setReadHandler`'s
            // implicit continuous delivery.
            self.receiveNextUpstream(on: connection, generation: generation)
        }
    }

    /// Periodic safety net — if the connection has been in `.waiting` for
    /// longer than `waitingStuckThreshold`, force a rebuild. iOS normally
    /// recovers in seconds; staying stuck means the path isn't coming
    /// back and new sends are just queuing indefinitely. Called from
    /// `healthCheck()`.
    private func checkWaitingStuck() {
        upstreamStateLock.lock()
        let enteredAt = waitingEnteredAt
        upstreamStateLock.unlock()
        guard let enteredAt,
              Date().timeIntervalSince(enteredAt) > waitingStuckThreshold else {
            return
        }
        NSLog("[DNSProxy] Upstream stuck in .waiting for \(Int(Date().timeIntervalSince(enteredAt)))s — forcing reconnect")
        // `setupUpstreamConnection` (called via `reconnectUpstream`) will
        // reset `waitingEnteredAt` under the lock — no need to clear here.
        reconnectUpstream()
    }

    /// Start a fresh read loop chain, superseding any previous one.
    /// Called after `reapplyNetworkSettings` completes so the new packet
    /// flow has an active reader — but without leaving the old chain
    /// running in parallel (the generation check in `readLoop` drains it).
    func startReadLoop() {
        startReadLoopInternal()
    }

    /// Periodic health check — call from the tunnel's liveness timer.
    /// NWConnection handles most recovery internally via its state
    /// machine, so this is mostly a safety net for two cases:
    ///   1. Connection was never created (shouldn't happen post-`start()`).
    ///   2. Connection stuck in `.waiting` longer than iOS typically
    ///      takes to recover a path change.
    /// Plus the active probe (catches rare cases where state stays `.ready`
    /// but packets stop flowing — much less likely with NWConnection, but
    /// kept as belt-and-suspenders).
    @discardableResult
    func healthCheck() -> Bool {
        upstreamStateLock.lock()
        let hasConn = upstreamConnection != nil
        upstreamStateLock.unlock()
        guard hasConn else {
            NSLog("[DNSProxy] Health: no upstream connection — creating")
            reconnectUpstream()
            return false
        }
        // Connection stuck in .waiting past the threshold — force a rebuild
        // rather than continuing to queue sends against a path iOS can't
        // establish.
        checkWaitingStuck()
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
        // Active probe — safety net for the rare case where state stays
        // `.ready` but traffic stops flowing. NWConnection should make this
        // very rare, but zero cost to keep.
        runActiveProbe()
        return true
    }

    /// Recreate the upstream connection. Called when the state handler
    /// reports `.failed`, when `healthCheck()` detects a stuck `.waiting`,
    /// or from probe timeouts. NWConnection migrates paths internally for
    /// routine interface swaps — this path is for terminal failures only.
    func reconnectUpstream() {
        // Drop any in-flight probes — they were sent via the old connection
        // and their responses won't arrive on the new one. Also reset the
        // proof-of-life timestamp so the next fast-path tick fires a probe
        // to validate the fresh connection.
        probeLock.lock()
        outstandingProbes.removeAll()
        lastProbeAt = .distantPast
        lastUpstreamResponseAt = .distantPast
        probeLock.unlock()

        // Telemetry: count every reconnect regardless of trigger.
        TunnelTelemetry.update { telemetry in
            telemetry.dnsReconnects += 1
            telemetry.lastReconnectAt = Date().timeIntervalSince1970
        }

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
        }

        setupUpstreamConnection(reason: "reconnect")
        if !orphaned.isEmpty {
            NSLog("[DNSProxy] Upstream reconnected → \(upstreamHostDescription) (\(orphaned.count) orphaned queries refused)")
        } else {
            NSLog("[DNSProxy] Upstream reconnected → \(upstreamHostDescription)")
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

        // FAST PATH — control-plane domains (CloudKit, APNs, Apple ID).
        //
        // Routed to FastPathResolver BEFORE any policy/blackhole/blocklist
        // check. These domains MUST resolve for the parent to reach the
        // device remotely. We don't care about the current mode, whether
        // the main upstream connection is wedged, or whether some blacklist
        // got corrupted — FastPathResolver has its own connection pool and
        // fails open with SERVFAIL (never drops). The main proxy's state
        // cannot affect this code path.
        //
        // Suffix match at DNS label boundaries — see CriticalDomains for
        // the list and why plain hasSuffix isn't safe.
        if let domain, CriticalDomains.matches(domain) {
            fastPathResolver.resolve(
                query: dns,
                clientIP: srcIP,
                clientPort: srcPort,
                originalTxn: txn
            )
            bgLog(domain)
            return
        }

        // KILL SWITCH — parent can remotely disable all DNS filtering when
        // the tunnel is making things worse (rare, but see
        // `project_fast_path_plan.md` Part 2 for rationale). When disabled:
        // skip blackhole, enforcement, time-limit, and safe-search gates and
        // forward straight upstream. Fast-path for critical domains above is
        // unaffected. Shields (ManagedSettings) are unaffected. Activity
        // logging continues so diagnostics still work during the outage
        // window. Auto-re-enables via the checkpoint in
        // `resolvedDNSFilteringEnabled`.
        refreshDNSFilteringCache()
        if dnsFilteringEnabledCache {
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

            if isBlackholeMode, currentMode != .unlocked, let domain, !isBlackholeExempt(domain), !domainIsCloudKit {
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
        while (pending[upstreamTxn] != nil || upstreamTxn >= Self.probeTxnBase) && attempts < 65536 {
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
        // Advance pointer but never into the reserved probe range.
        let advanced = upstreamTxn &+ 1
        nextUpstreamTxn = advanced >= Self.probeTxnBase ? 0 : advanced
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

        // If the connection is in a terminal state, rebuild before
        // sending. NWConnection's state handler normally beats us to this,
        // but there's a brief window between `.failed` and our rebuild
        // where a query could race in.
        upstreamStateLock.lock()
        let sendConnection = upstreamConnection
        upstreamStateLock.unlock()
        if let sendConnection, case .failed = sendConnection.state {
            NSLog("[DNSProxy] Upstream connection in .failed state — reconnecting before forward")
            reconnectUpstream()
        }

        // NWConnection's internal queue handles sends in `.preparing` and
        // `.waiting` states — they're held until the connection becomes
        // ready. We don't need to buffer on our side. Completion handler
        // fires when OS accepts (contentProcessed) or when the connection
        // errors out.
        //
        // Capture generation at send time so completions from sends
        // issued to a since-cancelled connection (pending sends that
        // drain on `.cancel()`) don't inflate the write-error counter.
        // State handler remains the authoritative signal for "connection
        // is dead."
        //
        // Re-read `upstreamConnection` under the lock AFTER the reconnect
        // branch above — if `.failed` triggered a rebuild, we want the
        // fresh connection, not the dead one we just inspected.
        let sendGen = currentUpstreamGeneration
        upstreamStateLock.lock()
        let liveConnection = upstreamConnection
        upstreamStateLock.unlock()
        liveConnection?.send(
            content: upstreamDns,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    guard let self,
                          sendGen == self.currentUpstreamGeneration else { return }
                    NSLog("[DNSProxy] Upstream send failed: \(error.debugDescription)")
                    self.markUpstreamUnhealthy()
                }
            }
        )

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
        let upstreamTxn = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])

        // Any upstream response — probe or real — is proof the session is
        // healthy on the current interface. Update the liveness timestamp
        // so the probe scheduler can skip unnecessary probes during active
        // browsing.
        probeLock.lock()
        lastUpstreamResponseAt = Date()
        probeLock.unlock()

        // Active health probe response — clear the outstanding entry, never
        // forward to a client.
        if upstreamTxn >= Self.probeTxnBase {
            probeLock.lock()
            outstandingProbes.removeValue(forKey: upstreamTxn)
            probeLock.unlock()
            return
        }

        pendingLock.lock()
        let p = pending.removeValue(forKey: upstreamTxn)
        pendingLock.unlock()

        guard let p else { return }

        var restored = data
        restored[0] = UInt8(p.originalTxn >> 8)
        restored[1] = UInt8(p.originalTxn & 0xFF)
        writeResponse(restored, destIP: p.ip, destPort: p.port)
    }

    // MARK: - Active Health Probe
    //
    // An upstream NWUDPSession can sit in `.ready` state while being silently
    // bound to a dead interface (e.g., after a wifi→cellular handoff on
    // iPhone17,4). No existing heuristic catches that: writeDatagram's
    // completion succeeds because the packet is queued into the kernel, but
    // the packet never reaches the upstream and no response ever returns.
    // The pending-queue-stall check (>20 stale for 3s) fails to fire once
    // clients back off. Simon hit this on 2026-04-14 losing internet for
    // ~15 minutes until APNs push woke the main app and reset the stack.
    //
    // Fix: `runActiveProbe()` fires from the 5s fast-path tick. If the
    // upstream has responded to anything — client query or earlier probe —
    // within the last `upstreamActivityWindow` seconds, we have proof of
    // life and skip the probe entirely. Otherwise send a tiny DNS query for
    // "dns.google" using a reserved txn ID range and schedule a
    // `probeTimeoutSeconds` timeout. If the response doesn't come back,
    // the session is wedged and we trigger `reconnectUpstream()`.
    //
    // End-to-end worst-case detection: one fast-path tick (≤5s) + probe
    // timeout (2.5s) = ~7.5s. Amortized cost during active browsing: zero
    // probes fired, because real client responses keep
    // `lastUpstreamResponseAt` fresh.

    /// Fire a synthetic DNS probe if the upstream has been silent longer
    /// than `upstreamActivityWindow`. Call on the 5s fast-path tick via
    /// `healthCheck()` — the timeout check runs on a dispatch-after so
    /// this method returns immediately.
    func runActiveProbe() {
        upstreamStateLock.lock()
        let connection = upstreamConnection
        upstreamStateLock.unlock()
        guard let connection else { return }
        // Don't probe a connection that's already in a terminal state —
        // state handler already triggered rebuild. Also skip `.setup` /
        // `.preparing` since the connection hasn't had a chance to
        // establish yet.
        switch connection.state {
        case .failed, .cancelled, .setup, .preparing:
            return
        default:
            break
        }

        let now = Date()
        // Proof-of-life shortcut — if real client traffic got a response
        // recently, the connection is obviously healthy. Skip the probe to
        // keep probe rate near-zero during active browsing.
        probeLock.lock()
        let lastResponse = lastUpstreamResponseAt
        probeLock.unlock()
        if now.timeIntervalSince(lastResponse) < upstreamActivityWindow {
            return
        }
        // Floor the cadence at `probeMinInterval` so two adjacent fast-path
        // ticks can't both fire a probe.
        if now.timeIntervalSince(lastProbeAt) < probeMinInterval { return }
        lastProbeAt = now

        probeLock.lock()
        let txn = nextProbeTxn
        // Reserve up to 16 concurrent probe IDs (0xFFF0..0xFFFF); wrap around.
        if outstandingProbes[txn] != nil {
            // Previous probe at this slot is still outstanding — replace it
            // with "timed out" semantics by continuing past it. The scheduled
            // check for the old txn will find it missing and ignore it.
            outstandingProbes.removeValue(forKey: txn)
        }
        let next = txn &+ 1
        nextProbeTxn = next < Self.probeTxnBase ? Self.probeTxnBase : next
        outstandingProbes[txn] = now
        probeLock.unlock()

        let query = Self.buildProbeQuery(txn: txn)
        let sendGen = currentUpstreamGeneration
        connection.send(
            content: query,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    guard let self,
                          sendGen == self.currentUpstreamGeneration else { return }
                    NSLog("[DNSProxy] Probe send failed: \(error.debugDescription)")
                    self.markUpstreamUnhealthy()
                }
            }
        )

        // Capture txn for the timeout check.
        let probedTxn = txn
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + probeTimeoutSeconds) { [weak self] in
            guard let self else { return }
            self.probeLock.lock()
            let stillOutstanding = self.outstandingProbes.removeValue(forKey: probedTxn) != nil
            self.probeLock.unlock()
            if stillOutstanding {
                NSLog("[DNSProxy] Active probe timed out after \(self.probeTimeoutSeconds)s — upstream wedged, reconnecting")
                TunnelTelemetry.update { telemetry in
                    telemetry.dnsProbeTimeouts += 1
                    telemetry.lastProbeTimeoutAt = Date().timeIntervalSince1970
                }
                self.reconnectUpstream()
            }
        }
    }

    /// Build a minimal DNS query for `dns.google` (A record, standard RD=1)
    /// with the given transaction ID. Upstream (1.1.1.1 or 185.228.168.168)
    /// responds in <100ms under normal conditions; we treat a 2.5s timeout
    /// as "the interface underneath the NWUDPSession is dead."
    private static func buildProbeQuery(txn: UInt16) -> Data {
        var q = Data()
        q.append(UInt8(txn >> 8))
        q.append(UInt8(txn & 0xFF))
        q.append(contentsOf: [0x01, 0x00]) // flags: standard query, RD=1
        q.append(contentsOf: [0x00, 0x01]) // QDCOUNT = 1
        q.append(contentsOf: [0x00, 0x00]) // ANCOUNT
        q.append(contentsOf: [0x00, 0x00]) // NSCOUNT
        q.append(contentsOf: [0x00, 0x00]) // ARCOUNT
        // QNAME: "dns.google"
        q.append(0x03)
        q.append(contentsOf: "dns".utf8)
        q.append(0x06)
        q.append(contentsOf: "google".utf8)
        q.append(0x00)
        q.append(contentsOf: [0x00, 0x01]) // QTYPE = A
        q.append(contentsOf: [0x00, 0x01]) // QCLASS = IN
        return q
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
        guard dns.count > 12, (UInt16(dns[dns.startIndex + 4]) << 8 | UInt16(dns[dns.startIndex + 5])) >= 1 else { return nil }
        var off = 12
        var labels: [String] = []
        while off < dns.count {
            let len = Int(dns[dns.startIndex + off])
            if len == 0 { break }
            if len > 63 { return nil }
            off += 1
            guard off + len <= dns.count else { return nil }
            let labelData = dns.subdata(in: (dns.startIndex + off)..<(dns.startIndex + off + len))
            if let s = String(data: labelData, encoding: .ascii) { labels.append(s) }
            off += len
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }

    // MARK: - DNS Response Builder

    /// Build a REFUSED DNS response. Works for any query type (A, AAAA, etc.)
    /// by returning the query's own question section with RCODE=5 (REFUSED).
    ///
    /// Uses `DNSMessage.truncateToQuestion` to strip any EDNS OPT / additional
    /// bytes that would otherwise trail the response even after ARCOUNT is
    /// zeroed. Strict stubs treat trailing garbage as malformed and drop
    /// the response. Parity with FastPathResolver's SERVFAIL path.
    private func buildRefusedResponse(query: Data) -> Data {
        // We need at least 12 bytes for the header we're about to synthesize.
        // A truncated packet (<12) that reached here shouldn't happen in
        // practice because onPacket already guards `dns.count >= 12`, but
        // force-indexing bytes 0 and 1 on a shorter buffer would crash.
        // Minimum safe: 2 bytes to preserve the txn ID; fall through to
        // the header-only synthesized response which zero-initializes.
        if query.count < 2 {
            return DNSMessage.headerOnlyResponse(txnID: 0, flagsHigh: 0x81, flagsLow: 0x05)
        }
        guard query.count >= 12 else {
            let txnID = UInt16(query[query.startIndex]) << 8 | UInt16(query[query.startIndex + 1])
            return DNSMessage.headerOnlyResponse(txnID: txnID, flagsHigh: 0x81, flagsLow: 0x05)
        }
        var r: Data
        if let truncated = DNSMessage.truncateToQuestion(query) {
            r = truncated
        } else {
            // Malformed question — return header-only REFUSED rather than
            // echoing bad bytes forward.
            let txnID = UInt16(query[query.startIndex]) << 8 | UInt16(query[query.startIndex + 1])
            return DNSMessage.headerOnlyResponse(txnID: txnID, flagsHigh: 0x81, flagsLow: 0x05)
        }
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

    /// DNS-based time limit check — disabled at b529. DeviceActivity
    /// milestones (Monitor extension) are the sole authority for
    /// exhausting time-limited apps. DNS tracking overcounts because
    /// background ad SDKs generate queries when the app isn't actively
    /// in use. Stub kept so callers compile; prior implementation lives
    /// in git history (commit 18a70ec "DNS time-limit exhaustion disabled").
    private func checkTimeLimitExhaustionLocked(_ appName: String) {
        // Intentionally empty — see doc comment.
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

    /// Current upstream connection state for diagnostic reporting.
    var upstreamConnectionState: NWConnection.State? {
        upstreamStateLock.lock()
        let conn = upstreamConnection
        upstreamStateLock.unlock()
        return conn?.state
    }
}
