import Foundation
import UIKit
import BigBrotherCore

/// Monitors device lock/unlock state using public APIs.
/// Uses UIApplication protected data notifications (fires on lock/unlock).
///
/// Note: Screen time accumulation (unlock→lock deltas) is handled exclusively
/// by the VPN tunnel process, which reliably receives every transition even
/// when the main app is suspended by iOS.
final class DeviceLockMonitor {
    static let shared = DeviceLockMonitor()

    private(set) var isDeviceLocked: Bool = false
    private var observers: [NSObjectProtocol] = []

    /// Callback for driving monitor — fires on every lock/unlock transition.
    var onLockStateChanged: ((Bool) -> Void)?

    private init() {}

    func startMonitoring() {
        guard observers.isEmpty else { return }

        // Protected data becomes unavailable when device is locked (with passcode).
        let defaults = UserDefaults.appGroup

        let willResign = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isDeviceLocked = true
            self?.onLockStateChanged?(true)
            defaults?.set(true, forKey: "isDeviceLocked")
        }

        let didBecome = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isDeviceLocked = false
            self?.onLockStateChanged?(false)
            defaults?.set(false, forKey: "isDeviceLocked")
        }

        observers = [willResign, didBecome]

        // Set initial state from current protected data availability.
        isDeviceLocked = !UIApplication.shared.isProtectedDataAvailable
    }

    /// No-op — screen time is now tracked exclusively by the VPN tunnel.
    func flushCurrentSession() {}

    func stopMonitoring() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }
}
