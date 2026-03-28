import Foundation
import notify

/// Monitors device lock/unlock state via Darwin notification center.
/// Only runs on child devices. The primary use is reporting lock state
/// in the heartbeat so the parent can see if the screen is on/off.
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

    func stopMonitoring() {
        if notifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(notifyToken)
            notifyToken = NOTIFY_TOKEN_INVALID
        }
    }
}
