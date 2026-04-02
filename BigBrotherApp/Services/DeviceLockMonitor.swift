import Foundation
import notify
import BigBrotherCore

/// Monitors device lock/unlock state via Darwin notification center.
/// Only runs on child devices. Tracks lock state for heartbeat reporting.
///
/// Note: Screen time accumulation (unlock→lock deltas) is handled exclusively
/// by the VPN tunnel process, which reliably receives every transition even
/// when the main app is suspended by iOS.
final class DeviceLockMonitor {
    static let shared = DeviceLockMonitor()

    private(set) var isDeviceLocked: Bool = true // Default locked until proven otherwise
    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID

    /// Callback for driving monitor — fires on every lock/unlock transition.
    var onLockStateChanged: ((Bool) -> Void)?

    private init() {}

    func startMonitoring() {
        guard notifyToken == NOTIFY_TOKEN_INVALID else { return }

        // Register for com.apple.springboard.lockstate.
        // State 0 = unlocked, != 0 = locked.
        notify_register_dispatch(
            "com.apple.springboard.lockstate",
            &notifyToken,
            DispatchQueue.main
        ) { [weak self] token in
            var state: UInt64 = 0
            notify_get_state(token, &state)
            let locked = state != 0
            self?.isDeviceLocked = locked
            self?.onLockStateChanged?(locked)
            #if DEBUG
            print("[DeviceLockMonitor] Lock state changed: \(locked ? "locked" : "unlocked")")
            #endif
        }

        // Query initial state immediately — the callback only fires on transitions.
        if notifyToken != NOTIFY_TOKEN_INVALID {
            var state: UInt64 = 0
            notify_get_state(notifyToken, &state)
            isDeviceLocked = state != 0
            #if DEBUG
            print("[DeviceLockMonitor] Initial state: \(state != 0 ? "locked" : "unlocked")")
            #endif
        }
    }

    /// No-op — screen time is now tracked exclusively by the VPN tunnel.
    func flushCurrentSession() {}

    func stopMonitoring() {
        if notifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(notifyToken)
            notifyToken = NOTIFY_TOKEN_INVALID
        }
    }
}
