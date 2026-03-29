import Foundation
import notify
import BigBrotherCore

/// Monitors device lock/unlock state via Darwin notification center.
/// Only runs on child devices. Tracks lock state for heartbeat reporting
/// and accumulates actual screen-on time (unlock→lock deltas) per day.
final class DeviceLockMonitor {
    static let shared = DeviceLockMonitor()

    private(set) var isDeviceLocked: Bool = true // Default locked until proven otherwise
    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID

    /// Callback for driving monitor — fires on every lock/unlock transition.
    var onLockStateChanged: ((Bool) -> Void)?

    // Screen time tracking
    private var lastUnlockAt: Date?
    private let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
    private let dateKey = "screenTimeDate"
    private let minutesKey = "screenTimeMinutes"
    private let secondsKey = "screenTimeAccumulatedSeconds"

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
            self?.handleLockTransition(locked: locked)
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
            if !isDeviceLocked {
                lastUnlockAt = Date()
            }
            #if DEBUG
            print("[DeviceLockMonitor] Initial state: \(state != 0 ? "locked" : "unlocked")")
            #endif
        }
    }

    // MARK: - Screen Time Tracking

    private func handleLockTransition(locked: Bool) {
        let today = todayString()

        if locked {
            // Screen locked — accumulate the unlock→lock delta
            if let unlockTime = lastUnlockAt {
                let sessionSeconds = Int(Date().timeIntervalSince(unlockTime))
                if sessionSeconds > 0 {
                    addScreenTime(seconds: sessionSeconds, date: today)
                }
            }
            lastUnlockAt = nil
        } else {
            // Screen unlocked — start tracking
            lastUnlockAt = Date()

            // Reset if it's a new day
            if defaults?.string(forKey: dateKey) != today {
                defaults?.set(today, forKey: dateKey)
                defaults?.set(0, forKey: secondsKey)
                defaults?.set(0, forKey: minutesKey)
            }
        }
    }

    private func addScreenTime(seconds: Int, date: String) {
        // Reset if day changed
        if defaults?.string(forKey: dateKey) != date {
            defaults?.set(date, forKey: dateKey)
            defaults?.set(0, forKey: secondsKey)
        }

        let accumulated = (defaults?.integer(forKey: secondsKey) ?? 0) + seconds
        defaults?.set(accumulated, forKey: secondsKey)
        defaults?.set(accumulated / 60, forKey: minutesKey)

        #if DEBUG
        print("[DeviceLockMonitor] Screen time: +\(seconds)s = \(accumulated / 60)m total today")
        #endif
    }

    /// Flush any in-progress session (call before heartbeat or on app background).
    func flushCurrentSession() {
        guard let unlockTime = lastUnlockAt, !isDeviceLocked else { return }
        let sessionSeconds = Int(Date().timeIntervalSince(unlockTime))
        if sessionSeconds > 0 {
            addScreenTime(seconds: sessionSeconds, date: todayString())
            lastUnlockAt = Date() // Reset session start to now
        }
    }

    private func todayString() -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    func stopMonitoring() {
        if notifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(notifyToken)
            notifyToken = NOTIFY_TOKEN_INVALID
        }
    }
}
