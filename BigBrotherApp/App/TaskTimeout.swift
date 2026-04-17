import Foundation

/// Run an async operation with a wall-clock deadline. Returns when either
/// the operation finishes OR the deadline elapses, whichever comes first.
/// The operation keeps running in the background after the deadline — the
/// timeout only releases the caller.
///
/// Motivation: CloudKit calls (fetchEventLogs, fetchChildProfiles, etc.)
/// can hang indefinitely when `cloudd` is wedged on a device. Without a
/// deadline, `.refreshable { await viewModel.refresh() }` leaves the
/// pull-to-refresh spinner spinning forever.
///
/// Implementation note: we can NOT use `withThrowingTaskGroup` here. A task
/// group's scope exit awaits ALL child tasks before returning, so if the
/// worker is wedged in an XPC that doesn't respect cancellation, the group
/// scope blocks waiting for it — defeating the deadline. Instead, we spawn
/// two unstructured `Task.detached`s and use a continuation resumed by
/// whichever completes first. The wedged worker is left running in the
/// background (iOS will clean it up when its task becomes unreachable or
/// when the XPC eventually times out), and the caller is released on time.
///
/// Usage:
///   ```
///   .refreshable {
///       await withDeadline(30) { await viewModel.loadDashboard() }
///   }
///   ```
@Sendable
func withDeadline(_ seconds: Double, _ operation: @escaping @Sendable () async -> Void) async {
    let callStart = CFAbsoluteTimeGetCurrent()
    StartupWatchdog.log(String(format: "withDeadline(%.1fs) entered", seconds))
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let state = DeadlineState(continuation: cont, callStart: callStart)
        let worker = Task.detached {
            await operation()
            state.resumeIfNeeded(source: "worker")
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            state.resumeIfNeeded(source: "sleep", cancel: worker)
        }
    }
    StartupWatchdog.log(String(format: "withDeadline exited (total %.2fs)", CFAbsoluteTimeGetCurrent() - callStart))
}

/// Thread-safe one-shot continuation resumer. Used by `withDeadline`.
private final class DeadlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<Void, Never>
    private let callStart: CFAbsoluteTime

    init(continuation: CheckedContinuation<Void, Never>, callStart: CFAbsoluteTime) {
        self.continuation = continuation
        self.callStart = callStart
    }

    func resumeIfNeeded(source: String, cancel: Task<Void, Never>? = nil) {
        let elapsed = CFAbsoluteTimeGetCurrent() - callStart
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        if shouldResume {
            StartupWatchdog.log(String(format: "withDeadline resume by %@ at %.2fs", source, elapsed))
            cancel?.cancel()
            continuation.resume()
        } else {
            StartupWatchdog.log(String(format: "withDeadline %@ late at %.2fs (no-op)", source, elapsed))
        }
    }
}
