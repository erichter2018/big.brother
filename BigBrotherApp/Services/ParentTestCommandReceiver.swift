import Foundation
import BigBrotherCore

/// DEBUG-only Darwin notification receiver for the PARENT device.
///
/// Used by `test_shield_cycle.sh --mode production` to inject commands
/// through the REAL parent→CloudKit→child pipeline. The harness:
///   1. Writes the target child device CK_ID to a JSON file in the
///      parent's App Group via `devicectl device copy to`
///   2. Posts a fixed-name Darwin notification like
///      `fr.bigbrother.parenttest.locked`
///   3. This receiver reads the target file, calls
///      `AppState.sendCommand(target:action:)` exactly as a UI tap would
///   4. The command goes through CK → silent push → child
///
/// Uses fixed notification names (not dynamic/wildcard) because iOS's
/// Darwin notification center does not reliably deliver to wildcard
/// (`name: nil`) observers in sandboxed apps.
///
/// **Debug-only.** Compiled out of release builds.
#if DEBUG
enum ParentTestCommandReceiver {

    enum TestNotification: String, CaseIterable {
        case locked       = "fr.bigbrother.parenttest.locked"
        case restricted   = "fr.bigbrother.parenttest.restricted"
        case unlocked     = "fr.bigbrother.parenttest.unlocked"
        case lockedDown   = "fr.bigbrother.parenttest.lockedDown"
        case tempUnlock   = "fr.bigbrother.parenttest.tempUnlock300"

        var action: CommandAction {
            switch self {
            case .locked:     return .setMode(.locked)
            case .restricted: return .setMode(.restricted)
            case .unlocked:   return .setMode(.unlocked)
            case .lockedDown: return .setMode(.lockedDown)
            case .tempUnlock: return .temporaryUnlock(durationSeconds: 300)
            }
        }
    }

    /// Target file written by the harness to the App Group container via
    /// `devicectl device copy to --domain-type appGroupDataContainer`.
    /// Contains `{"targetDeviceID": "<CK_UUID>"}`.
    static let targetFileName = "bb_test_target.json"

    private static var installed = false

    static func install(appState: AppState) {
        guard !installed else { return }
        installed = true

        ParentTestCommandBox.shared.appState = appState

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(ParentTestCommandBox.shared).toOpaque()

        for notif in TestNotification.allCases {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, _, name, _, _ in
                    guard let name else { return }
                    let raw = name.rawValue as String
                    ParentTestCommandBox.shared.dispatch(name: raw)
                },
                notif.rawValue as CFString,
                nil,
                .deliverImmediately
            )
        }

        NSLog("[ParentTestCommandReceiver] Installed \(TestNotification.allCases.count) Darwin observers")
    }

    /// Read the target device CK_ID from the App Group file.
    static func readTarget() -> DeviceID? {
        guard let containerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier)
        else { return nil }
        let fileURL = containerURL.appendingPathComponent(targetFileName)
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = json["targetDeviceID"], !id.isEmpty
        else { return nil }
        return DeviceID(rawValue: id)
    }
}

final class ParentTestCommandBox {
    static let shared = ParentTestCommandBox()
    weak var appState: AppState?

    func dispatch(name: String) {
        guard let notif = ParentTestCommandReceiver.TestNotification(rawValue: name) else {
            NSLog("[ParentTestCommandReceiver] Unknown notification: \(name)")
            return
        }
        guard let appState else {
            NSLog("[ParentTestCommandReceiver] No appState — ignoring \(name)")
            return
        }
        guard let targetDevice = ParentTestCommandReceiver.readTarget() else {
            NSLog("[ParentTestCommandReceiver] No target file in App Group — ignoring \(name)")
            return
        }

        let action = notif.action
        NSLog("[ParentTestCommandReceiver] Dispatching \(action.displayDescription) → device \(targetDevice.rawValue.prefix(8))")

        Task { @MainActor in
            do {
                try await appState.sendCommand(target: .device(targetDevice), action: action)
                NSLog("[ParentTestCommandReceiver] Command sent successfully via CloudKit")
            } catch {
                NSLog("[ParentTestCommandReceiver] sendCommand FAILED: \(error.localizedDescription)")
            }
        }
    }
}
#endif
