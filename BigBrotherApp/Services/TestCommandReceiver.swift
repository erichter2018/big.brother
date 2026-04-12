import Foundation
import BigBrotherCore

/// Debug-only Darwin notification receiver used by `test_shield_cycle.sh`
/// to inject mode-change commands directly into the child device without
/// going through CloudKit.
///
/// **Why this exists:** the CloudKit REST API's public `ckAPIToken` auth
/// mode is read-only for `BBRemoteCommand` writes — the parent app uses
/// iCloud user authentication to write commands, which isn't available
/// from a shell script. To automate shield testing we need a side-channel
/// that can trigger commands on a specific device from the development
/// Mac, without requiring the CloudKit round-trip.
///
/// Darwin notifications (the Mach-level pub/sub system) fit: `xcrun
/// devicectl device notification post --device <name> --name <key>` posts
/// a named notification to the device, and any running process with a
/// registered observer receives it. Each well-known name below maps to a
/// specific CommandAction the test harness wants to exercise. The action
/// is applied via the existing `CommandProcessor.processCommand` path so
/// the test still exercises the full mode-change pipeline end-to-end
/// (snapshot commit → enforcement.apply → shield write → heartbeat).
///
/// **Debug-only.** Compiled out of release builds so the injection
/// surface isn't shipped to App Store users.
#if DEBUG
enum TestCommandReceiver {

    /// Known test notification names. Adding a new one is a one-line change
    /// here + one case in `dispatch()` + the script sends it.
    enum TestNotification: String, CaseIterable {
        case setModeLocked      = "fr.bigbrother.test.setMode.locked"
        case setModeRestricted  = "fr.bigbrother.test.setMode.restricted"
        case setModeUnlocked    = "fr.bigbrother.test.setMode.unlocked"
        case setModeLockedDown  = "fr.bigbrother.test.setMode.lockedDown"
        case tempUnlock5m       = "fr.bigbrother.test.tempUnlock.300"
        case requestHeartbeat   = "fr.bigbrother.test.requestHeartbeat"

        var action: CommandAction {
            switch self {
            case .setModeLocked:     return .setMode(.locked)
            case .setModeRestricted: return .setMode(.restricted)
            case .setModeUnlocked:   return .setMode(.unlocked)
            case .setModeLockedDown: return .setMode(.lockedDown)
            case .tempUnlock5m:      return .temporaryUnlock(durationSeconds: 300)
            case .requestHeartbeat:  return .requestHeartbeat
            }
        }
    }

    /// Install CFNotificationCenter observers for every TestNotification.
    /// Call once, on main-thread, from AppDelegate.didFinishLaunching.
    /// Safe to call multiple times (the underlying API dedups by observer
    /// + name, but we also guard via a one-shot flag).
    private static var installed = false

    @MainActor
    static func install(appState: AppState) {
        guard !installed else { return }
        installed = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(TestCommandReceiverBox.shared).toOpaque()

        // Capture appState weakly via the shared box so the C-style callback
        // can reach back into Swift and dispatch the received action.
        TestCommandReceiverBox.shared.appState = appState

        for notif in TestNotification.allCases {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, _, name, _, _ in
                    guard let name else { return }
                    let raw = name.rawValue as String
                    Task { @MainActor in
                        TestCommandReceiverBox.shared.dispatch(name: raw)
                    }
                },
                notif.rawValue as CFString,
                nil,
                .deliverImmediately
            )
        }
        NSLog("[TestCommandReceiver] Installed \(TestNotification.allCases.count) Darwin observers")
        // Diagnostic trace so the parent-side harness can verify the receiver is alive.
        let storage = AppGroupStorage()
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "TestCommandReceiver: installed \(TestNotification.allCases.count) Darwin observers"
        ))
        UserDefaults.appGroup?
            .set(Date().timeIntervalSince1970, forKey: "testCommandReceiverInstalledAt")
    }
}

/// Boxed reference so the C-style CFNotificationCenter callback can reach
/// the appState. Holds a weak reference and acts as the dispatcher.
@MainActor
final class TestCommandReceiverBox {
    static let shared = TestCommandReceiverBox()
    weak var appState: AppState?

    func dispatch(name: String) {
        let storage = AppGroupStorage()
        guard let notif = TestCommandReceiver.TestNotification(rawValue: name) else {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "TestCommandReceiver: unknown notification \(name)"
            ))
            return
        }
        guard let appState, let commandProcessor = appState.commandProcessor as? CommandProcessorImpl else {
            NSLog("[TestCommandReceiver] \(name): no commandProcessor available")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "TestCommandReceiver RX \(name) — NO commandProcessor"
            ))
            return
        }

        NSLog("[TestCommandReceiver] Received \(name) → dispatching \(notif.action)")
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "TestCommandReceiver RX \(name) → \(notif.action)"
        ))

        // Synthesize a RemoteCommand with the test action and hand it to
        // the real command processor. The "from" field is a sentinel so
        // audit logs can distinguish test injections from real parent
        // commands, and the ID is unique per invocation so dedup doesn't
        // swallow back-to-back test shots.
        guard let enrollment = appState.enrollmentState else {
            NSLog("[TestCommandReceiver] \(name): no enrollment state")
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .enforcement,
                message: "TestCommandReceiver RX \(name) — NO enrollment"
            ))
            return
        }

        let command = RemoteCommand(
            id: UUID(),
            familyID: enrollment.familyID,
            target: .device(enrollment.deviceID),
            action: notif.action,
            issuedBy: "test_shield_cycle",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            status: .pending,
            signatureBase64: nil
        )

        // Chain: process the command, THEN send the heartbeat inline.
        //
        // Why inline: the harness fires setMode and requestHeartbeat
        // back-to-back as two separate Darwin notifications. Each
        // notification spawns its own Task on MainActor, and the ordering
        // between those tasks is NOT guaranteed — the second Task may
        // run before the first has finished applying the command, and
        // the resulting heartbeat reports stale mode. Awaiting sendNow
        // in the same Task guarantees the heartbeat sees post-command
        // state, eliminating the race.
        let hbService = appState.heartbeatService
        Task {
            await commandProcessor.processTestCommand(command)
            try? await hbService?.sendNow(force: true)
        }
    }
}
#endif
