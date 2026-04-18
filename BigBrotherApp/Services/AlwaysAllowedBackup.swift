import Foundation
import BigBrotherCore

/// Mirrors the child's always-allowed token set + per-app time limits to
/// `NSUbiquitousKeyValueStore` so they survive a full uninstall.
///
/// Why iCloud KVS: the App Group container and Keychain access group are
/// both cleared when the last app sharing them is uninstalled (iOS 10.3+).
/// NSUbiquitousKeyValueStore lives in the user's iCloud account, tied to
/// the bundle ID, so a reinstall picks back up the backed-up values.
///
/// Caveat — `ApplicationToken` is device-local opaque. The restored bytes
/// are valid only if the device issues matching tokens after the reinstall.
/// In practice the same bundle ID + same physical device + same app
/// re-authorization tends to produce stable tokens, but if Apple's
/// FamilyControls daemon re-issues them differently the restored data will
/// be rejected by enforcement and the parent will need to re-pick via the
/// FamilyActivityPicker. The backup is best-effort — a successful restore
/// skips the re-pick; a failed restore falls back to the existing manual
/// workflow.
///
/// Size budget: NSUbiquitousKeyValueStore allows 1MB total and 1MB per key.
/// `allowedAppTokens` is typically ≤50 tokens × ~100B each = ~5KB;
/// `appTimeLimits` is a similar scale. Well under budget.
enum AlwaysAllowedBackup {
    private enum KVSKey {
        static let allowedAppTokens = "bb.backup.allowedAppTokens"
        static let appTimeLimits = "bb.backup.appTimeLimits"
        /// Schema version so future changes can be detected/ignored safely.
        static let schemaVersion = "bb.backup.schemaVersion"
    }
    private static let currentSchemaVersion = 1

    /// App Group flag set once a restore has been attempted, so we don't
    /// re-restore on every launch (which would undo any user-initiated clear).
    private static let restoreAttemptedKey = "alwaysAllowedBackupRestoreAttempted"

    /// Mirror the current always-allowed + time-limit state to iCloud KVS.
    /// Safe to call often; writes are cheap. Called after any change to
    /// either storage blob.
    static func mirror(from storage: any SharedStorageProtocol) {
        let kvs = NSUbiquitousKeyValueStore.default

        if let tokenData = storage.readRawData(forKey: StorageKeys.allowedAppTokens) {
            kvs.set(tokenData, forKey: KVSKey.allowedAppTokens)
        } else {
            kvs.removeObject(forKey: KVSKey.allowedAppTokens)
        }

        let limits = storage.readAppTimeLimits()
        if !limits.isEmpty, let limitsData = try? JSONEncoder().encode(limits) {
            kvs.set(limitsData, forKey: KVSKey.appTimeLimits)
        } else {
            kvs.removeObject(forKey: KVSKey.appTimeLimits)
        }

        kvs.set(currentSchemaVersion, forKey: KVSKey.schemaVersion)
        kvs.synchronize()
    }

    /// Restore from iCloud KVS if this app install has never attempted a
    /// restore AND storage is empty. No-op otherwise. Returns true if
    /// anything was restored.
    ///
    /// Call during child-app launch setup, BEFORE the Monitor / Tunnel
    /// start reading state. Typically called from BigBrotherApp.setupOnLaunch.
    @discardableResult
    static func restoreIfNeeded(into storage: any SharedStorageProtocol) -> Bool {
        let defaults = UserDefaults.appGroup
        guard defaults?.bool(forKey: restoreAttemptedKey) != true else { return false }
        defaults?.set(true, forKey: restoreAttemptedKey)

        // Only restore if storage is actually empty — an existing install
        // with tokens locally should never be overwritten from iCloud KVS
        // (the local copy is authoritative).
        let hasTokensLocally = storage.readRawData(forKey: StorageKeys.allowedAppTokens) != nil
        let hasLimitsLocally = !storage.readAppTimeLimits().isEmpty
        if hasTokensLocally || hasLimitsLocally { return false }

        let kvs = NSUbiquitousKeyValueStore.default
        _ = kvs.synchronize()
        let version = kvs.longLong(forKey: KVSKey.schemaVersion)
        guard version == Int64(currentSchemaVersion) else {
            BBLog("[AlwaysAllowedBackup] skip restore: no/mismatched schema version (\(version))")
            return false
        }

        var restoredSomething = false
        if let tokenData = kvs.data(forKey: KVSKey.allowedAppTokens), !tokenData.isEmpty {
            try? storage.writeRawData(tokenData, forKey: StorageKeys.allowedAppTokens)
            BBLog("[AlwaysAllowedBackup] restored \(tokenData.count)B of allowedAppTokens from iCloud KVS")
            restoredSomething = true
        }
        if let limitsData = kvs.data(forKey: KVSKey.appTimeLimits),
           let limits = try? JSONDecoder().decode([AppTimeLimit].self, from: limitsData),
           !limits.isEmpty {
            try? storage.writeAppTimeLimits(limits)
            BBLog("[AlwaysAllowedBackup] restored \(limits.count) appTimeLimits from iCloud KVS")
            restoredSomething = true
        }
        return restoredSomething
    }

    /// Force a fresh restore attempt on next launch. Used by diagnostic
    /// "re-sync from backup" button or as a recovery knob if tokens get
    /// corrupted somehow.
    static func resetRestoreSentinel() {
        UserDefaults.appGroup?.removeObject(forKey: restoreAttemptedKey)
    }
}
