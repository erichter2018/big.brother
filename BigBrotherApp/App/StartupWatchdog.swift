import Foundation
import Darwin
import BigBrotherCore

// File-scoped globals referenced by the SIGUSR1 handler.
// A @convention(c) closure cannot capture Swift statics, so these live
// at module scope where they can be read inside the signal handler.
private var bbBacktraceLogFD: Int32 = -1
private var bbBacktraceFrames: [UnsafeMutableRawPointer?] = Array(repeating: nil, count: 64)

private let bbSIGUSR1Handler: @convention(c) (Int32) -> Void = { _ in
    let fd = bbBacktraceLogFD
    guard fd >= 0 else { return }
    let count = bbBacktraceFrames.withUnsafeMutableBufferPointer { buf -> Int32 in
        backtrace(buf.baseAddress, 64)
    }
    let header = "\n=== MAIN-THREAD BACKTRACE (SIGUSR1) ===\n"
    _ = header.withCString { cstr in
        Darwin.write(fd, cstr, strlen(cstr))
    }
    bbBacktraceFrames.withUnsafeMutableBufferPointer { buf in
        backtrace_symbols_fd(buf.baseAddress, count, fd)
    }
    let footer = "=== END BACKTRACE ===\n"
    _ = footer.withCString { cstr in
        Darwin.write(fd, cstr, strlen(cstr))
    }
    fsync(fd)
}

/// Synchronous checkpoint + main-thread stall detector.
///
/// Writes to Documents/launch_log.txt so the data survives a frozen main
/// thread and can be pulled from the device via `scripts/pull_launch_log.sh`.
///
/// Architecture:
/// 1. Every 100ms, a DispatchSourceTimer on the main queue updates a
///    heartbeat timestamp.
/// 2. A dedicated pthread (outside GCD) checks that heartbeat every 250ms.
///    If main has been silent for >750ms, the watchdog thread writes a
///    STALL line with the current checkpoint name — letting us see exactly
///    which main-thread operation was in flight when the hang started.
/// 3. Checkpoints are written via a serial DispatchQueue (not `async` from
///    main) so entries from main and from the watchdog don't interleave
///    and always land in the file even if main freezes immediately after
///    the checkpoint() call.
///
/// Replaces the earlier `_LaunchLog` helper in BigBrotherApp.swift.
enum StartupWatchdog {
    private static let url: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("launch_log.txt")

    private static let lock = NSLock()
    private static var started = false
    private static var currentCheckpoint: String = "startup"
    private static var checkpointStartedAt: Double = 0
    private static var lastMainCheckpoint: String = "startup"
    private static var lastMainCheckpointAt: Double = 0
    private static var mainLastPulseAt: Double = 0
    private static var lastStallLogAt: Double = 0
    private static var stallCount: Int = 0
    private static var mainTimer: DispatchSourceTimer?
    private static var watchdogThread: Thread?

    private static let writeQueue = DispatchQueue(label: "StartupWatchdog.write", qos: .utility)

    /// Main thread's pthread_t, captured on start(). Used to raise SIGUSR1
    /// on main when a stall is detected, so the signal handler can write
    /// the main-thread backtrace out of a wedged syscall.
    private static var mainPThread: pthread_t?

    /// Call as the very first line of App.init(). Truncates the log file.
    static func start(build: Int) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        let now = CFAbsoluteTimeGetCurrent()
        mainLastPulseAt = now
        checkpointStartedAt = now
        lock.unlock()

        write("=== Launch \(Date()) build=\(build) ===", truncate: true)
        log("watchdog armed — stall threshold 750ms")

        // Capture main thread's pthread so we can raise SIGUSR1 on it from
        // the watchdog thread. pthread_main_np() would require being on main
        // (which we are during start()), but pthread_self() is equivalent here.
        mainPThread = pthread_self()

        // Open the log fd for the signal handler — we can't open files from
        // an async-signal context, so keep an fd ready.
        if let u = url {
            let path = u.path
            bbBacktraceLogFD = path.withCString { cpath in
                open(cpath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            }
        }

        // Install SIGUSR1 handler for main-thread backtrace capture.
        // Signal handlers must be async-signal-safe; backtrace() and
        // backtrace_symbols_fd() are both documented-safe on Darwin.
        var action = sigaction()
        action.__sigaction_u.__sa_handler = bbSIGUSR1Handler
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGUSR1, &action, nil)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(100))
        timer.setEventHandler {
            let t = CFAbsoluteTimeGetCurrent()
            lock.lock()
            mainLastPulseAt = t
            lock.unlock()
        }
        timer.activate()
        mainTimer = timer

        let t = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let now = CFAbsoluteTimeGetCurrent()
                lock.lock()
                let gap = now - mainLastPulseAt
                let mcp = lastMainCheckpoint
                let mcpAge = now - lastMainCheckpointAt
                let cp = currentCheckpoint
                let sinceLast = now - lastStallLogAt
                let shouldLog = gap > 0.75 && sinceLast >= 1.0
                if shouldLog {
                    lastStallLogAt = now
                    stallCount += 1
                }
                let seq = stallCount
                lock.unlock()
                if shouldLog {
                    write(stamp() + String(format: "[STALL #%d] main silent %.2fs — mainCp=%@ mainCpAge=%.2fs globalCp=%@", seq, gap, mcp, mcpAge, cp))
                    // First, fifth, tenth stall — capture main backtrace.
                    // Don't capture on every stall since signal overhead can
                    // actually disturb main's state.
                    if seq == 1 || seq == 5 || seq == 10 || seq == 20 {
                        if let p = mainPThread {
                            _ = pthread_kill(p, SIGUSR1)
                        }
                    }
                }
            }
        }
        t.name = "StartupWatchdog"
        t.qualityOfService = .utility
        t.start()
        watchdogThread = t
    }

    /// Mark the start of a potentially-blocking operation. Thread-aware:
    /// when called from the main thread, updates the main-checkpoint slot
    /// (what the stall line reports). From background threads, only the
    /// global slot changes — so off-main Task.detached work doesn't
    /// falsely become the "cause" of a main-thread stall.
    static func checkpoint(_ name: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let onMain = Thread.isMainThread
        lock.lock()
        currentCheckpoint = name
        checkpointStartedAt = now
        if onMain {
            lastMainCheckpoint = name
            lastMainCheckpointAt = now
        }
        lock.unlock()
        write(stamp() + (onMain ? "cp(main): " : "cp(bg): ") + name)
    }

    /// Mark the end of a checkpoint and record elapsed time.
    static func complete(_ name: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let onMain = Thread.isMainThread
        lock.lock()
        let elapsed = now - checkpointStartedAt
        currentCheckpoint = "idle"
        if onMain {
            lastMainCheckpoint = "idle-after-" + name
            lastMainCheckpointAt = now
        }
        lock.unlock()
        write(stamp() + String(format: "cp %@ done: %@ (%.3fs)", onMain ? "(main)" : "(bg)", name, elapsed))
    }

    /// Free-form log entry.
    static func log(_ msg: String) {
        write(stamp() + msg)
    }

    private static func stamp() -> String {
        let d = Date()
        let ref = d.timeIntervalSince1970
        let whole = Int64(ref)
        let ms = Int((ref - Double(whole)) * 1000)
        let fmt = DateFormatter.hms
        return fmt.string(from: d) + String(format: ".%03d ", ms)
    }

    private static func write(_ line: String, truncate: Bool = false) {
        BBLog("[BB] \(line)")
        guard let url else { return }
        let data = Data((line + "\n").utf8)
        writeQueue.async {
            if truncate || !FileManager.default.fileExists(atPath: url.path) {
                try? data.write(to: url)
                return
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        }
    }
}

private extension DateFormatter {
    static let hms: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
