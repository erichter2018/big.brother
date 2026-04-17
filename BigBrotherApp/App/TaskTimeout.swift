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
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let state = DeadlineState(continuation: cont)
        // Strong `state` captures keep the one-shot alive until both tasks
        // finish. Weak capture would deallocate state between the closure
        // returning and the tasks firing, leaking the continuation and
        // hanging the caller. The tasks drop their reference when they
        // complete, and state's continuation is already resumed by then.
        let worker = Task.detached {
            await operation()
            state.resumeIfNeeded()
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            state.resumeIfNeeded(cancel: worker)
        }
    }
}

/// Thread-safe one-shot continuation resumer. Used by `withDeadline`.
private final class DeadlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<Void, Never>

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    /// Resume the continuation at most once. If this is the first call,
    /// resume; subsequent calls are no-ops. If `cancel` is non-nil and
    /// this call wins the race, cancel that task (best-effort — the task
    /// may be wedged and ignore cancellation).
    func resumeIfNeeded(cancel: Task<Void, Never>? = nil) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        guard shouldResume else { return }
        cancel?.cancel()
        continuation.resume()
    }
}
