import Foundation
import DeviceActivity
import BigBrotherCore

/// DEBUG-only Darwin notification receiver that lives in the VPN tunnel
/// extension. Used by `test_shield_cycle.sh --background` to change modes
/// WITHOUT waking the main app — the whole point is to exercise the
/// "main app is suspended or dead" code path that real production commands
/// hit when the parent flips a mode and the kid's device hasn't opened the
/// app in minutes/hours.
///
/// **Why a separate receiver from the main app's `TestCommandReceiver`:**
/// CFNotificationCenterGetDarwinNotifyCenter delivers Darwin notifications
/// to every process with a registered observer. If the main app is awake
/// and listening on the same notification names, it would race the tunnel
/// and we'd stop testing the background path. By using a distinct
/// `fr.bigbrother.test.bg.*` prefix that ONLY the tunnel observes, the
/// harness can unambiguously target the tunnel even when the main app
/// happens to be alive in the background.
///
/// **Shape:** mirrors the main app's TestCommandReceiver — a set of
/// well-known Darwin notifications, a boxed dispatcher, and a writeable
/// `apply(mode:)` path that reuses the tunnel's existing snapshot/DNS/
/// Monitor-signal plumbing from `handleModeCommandFromTunnel`.
///
/// **Debug-only.** Compiled out of release builds.
#if DEBUG
enum TunnelTestCommandReceiver {

    /// Well-known notification names. The `.bg.` infix distinguishes these
    /// from the main app's `.fg.` names so both receivers can coexist in
    /// the same process family without racing.
    enum TestNotification: String, CaseIterable {
        case setModeLocked      = "fr.bigbrother.test.bg.setMode.locked"
        case setModeRestricted  = "fr.bigbrother.test.bg.setMode.restricted"
        case setModeUnlocked    = "fr.bigbrother.test.bg.setMode.unlocked"
        case setModeLockedDown  = "fr.bigbrother.test.bg.setMode.lockedDown"
        case tempUnlock5m       = "fr.bigbrother.test.bg.tempUnlock.300"
        case requestHeartbeat   = "fr.bigbrother.test.bg.requestHeartbeat"

        // VPN recovery testing — wifi-only devices can't do a real
        // interface transition, so these hooks exercise the same code
        // paths deterministically from the harness.
        case recoverReapply        = "fr.bigbrother.test.bg.recover.reapply"
        case recoverStaleTransport = "fr.bigbrother.test.bg.recover.staleTransport"

        /// The LockMode this notification maps to, or nil for non-mode commands.
        var mode: LockMode? {
            switch self {
            case .setModeLocked:     return .locked
            case .setModeRestricted: return .restricted
            case .setModeUnlocked:   return .unlocked
            case .setModeLockedDown: return .lockedDown
            case .tempUnlock5m:      return .unlocked
            case .requestHeartbeat, .recoverReapply, .recoverStaleTransport:
                return nil
            }
        }

        /// Label used for audit trail entries and snapshot triggers.
        var actionType: String {
            switch self {
            case .setModeLocked, .setModeRestricted, .setModeUnlocked, .setModeLockedDown:
                return "setMode"
            case .tempUnlock5m:          return "temporaryUnlock"
            case .requestHeartbeat:      return "requestHeartbeat"
            case .recoverReapply:        return "recoverReapply"
            case .recoverStaleTransport: return "recoverStaleTransport"
            }
        }

        /// Duration in seconds for temporary unlock commands. Non-unlock
        /// notifications return nil.
        var tempUnlockDurationSeconds: Int? {
            switch self {
            case .tempUnlock5m: return 300
            default:            return nil
            }
        }
    }

    private static var installed = false

    /// Register CFNotificationCenter observers for every TestNotification.
    /// Call once, from `PacketTunnelProvider.startTunnel` after the tunnel
    /// is fully up. Safe to call multiple times (the `installed` flag
    /// short-circuits). Holds a weak reference to the provider so the
    /// observer can't outlive it.
    static func install(provider: PacketTunnelProvider) {
        guard !installed else { return }
        installed = true

        TunnelTestCommandBox.shared.provider = provider

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(TunnelTestCommandBox.shared).toOpaque()

        for notif in TestNotification.allCases {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, _, name, _, _ in
                    guard let name else { return }
                    let raw = name.rawValue as String
                    TunnelTestCommandBox.shared.dispatch(name: raw)
                },
                notif.rawValue as CFString,
                nil,
                .deliverImmediately
            )
        }

        BBLog("[TunnelTestCommandReceiver] Installed \(TestNotification.allCases.count) Darwin observers (tunnel)")
        let storage = AppGroupStorage()
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "TunnelTestCommandReceiver: installed \(TestNotification.allCases.count) Darwin observers"
        ))
        UserDefaults.appGroup?
            .set(Date().timeIntervalSince1970, forKey: AppGroupKeys.tunnelTestCommandReceiverInstalledAt)
    }
}

/// Boxed reference so the CFNotificationCenter C-callback can reach back
/// into the tunnel provider. Holds a weak reference to avoid keeping the
/// provider alive past `stopTunnel`.
final class TunnelTestCommandBox {
    static let shared = TunnelTestCommandBox()
    weak var provider: PacketTunnelProvider?

    /// CFNotificationCenter delivers callbacks on a CF runloop thread.
    /// We don't need MainActor here because the tunnel provider isn't
    /// main-actor isolated — we hop to a Task for async work and let the
    /// provider serialize state changes internally via the same locks
    /// that its own CK command poller uses.
    func dispatch(name: String) {
        let storage = AppGroupStorage()
        guard let notif = TunnelTestCommandReceiver.TestNotification(rawValue: name) else {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "TunnelTestCommandReceiver: unknown notification \(name)"
            ))
            return
        }
        guard let provider else {
            BBLog("[TunnelTestCommandReceiver] \(name): no provider available")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "TunnelTestCommandReceiver RX \(name) — NO provider"
            ))
            return
        }

        BBLog("[TunnelTestCommandReceiver] Received \(name) → dispatching")
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "TunnelTestCommandReceiver RX \(name)"
        ))

        // Dispatch off the CF runloop thread so we can await asynchronous
        // work (heartbeat upload, CK record writes) without blocking the
        // notification pump.
        Task {
            await provider.handleTunnelTestNotification(notif)
        }
    }
}
#endif
