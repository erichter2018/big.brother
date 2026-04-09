import Foundation

/// Stateless, idempotent mode resolution from the App Group stack files.
///
/// Reads TemporaryUnlockState, TimedUnlockInfo, schedule profile, and PolicySnapshot
/// to compute what mode the device should be in RIGHT NOW. Any process (main app,
/// Monitor extension, VPN tunnel) can call this and get the same deterministic answer.
///
/// Also cleans up expired temporary state as a side effect — if a temp unlock expired
/// but the Monitor missed the callback, calling this function fixes the state.
public enum ModeStackResolver {

    public struct Resolution {
        /// The mode the device should be in right now.
        public let mode: LockMode
        /// Who is driving this mode.
        public let controlAuthority: ControlAuthority
        /// Whether this is a temporary mode (will revert when it expires).
        public let isTemporary: Bool
        /// If temporary, when it expires.
        public let expiresAt: Date?
        /// Explanation of why this mode was chosen (for diagnostics).
        public let reason: String
    }

    /// Resolve the current mode from the stack of state files in App Group storage.
    /// Cleans up expired temporary state as a side effect.
    public static func resolve(storage: any SharedStorageProtocol, now: Date = Date()) -> Resolution {

        // 1. Active temporary unlock (parent-initiated, PIN, or self-unlock)?
        // READ-ONLY: ModeStackResolver must NEVER delete temp unlock files.
        // Multiple processes call this (main app, Monitor, tunnel). If the Monitor
        // reads stale file data and deletes the file while the main app just wrote
        // a new temp unlock, the new data is lost. Cleanup is done by the command
        // processor (setMode, returnToSchedule) which owns the state.
        //
        // Try the direct file first, then fall back to the snapshot's embedded copy.
        // The file read can fail silently in extension contexts (App Group file locks,
        // iOS data protection, CFPrefsPlistSource detach). The snapshot is a single
        // atomic JSON file that's more reliably readable.
        let temp: TemporaryUnlockState? = storage.readTemporaryUnlockState()
            ?? storage.readPolicySnapshot()?.temporaryUnlockState
        if let temp, temp.expiresAt > now {
            return Resolution(
                mode: .unlocked,
                controlAuthority: temp.origin == .selfUnlock ? .selfUnlock : .temporaryUnlock,
                isTemporary: true,
                expiresAt: temp.expiresAt,
                reason: "Temporary unlock (\(temp.origin.rawValue)), expires \(shortTime(temp.expiresAt))"
            )
        }

        // 2. Active timed unlock (penalty + unlock phases)?
        // READ-ONLY: same principle as temp unlock — never delete from ModeStackResolver.
        if let timed = storage.readTimedUnlockInfo() {
            if now < timed.unlockAt {
                // Penalty phase — device MUST be locked regardless of previousMode.
                return Resolution(
                    mode: .restricted,
                    controlAuthority: .timedUnlock,
                    isTemporary: true,
                    expiresAt: timed.unlockAt,
                    reason: "Timed unlock penalty phase, unlocks at \(shortTime(timed.unlockAt))"
                )
            } else if now < timed.lockAt {
                // Unlock phase — device is free
                return Resolution(
                    mode: .unlocked,
                    controlAuthority: .timedUnlock,
                    isTemporary: true,
                    expiresAt: timed.lockAt,
                    reason: "Timed unlock free phase, locks at \(shortTime(timed.lockAt))"
                )
            }
            // Expired — fall through (command processor handles cleanup)
        }

        // 3. Active lockUntil? (parent locked device until a specific time)
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if let lockUntilMode = defaults?.string(forKey: "lockUntilPreviousMode") {
            // Check persisted expiry — if past, self-heal by clearing the flag.
            if let expiryInterval = defaults?.object(forKey: "lockUntilExpiresAt") as? Double {
                let expiresAt = Date(timeIntervalSince1970: expiryInterval)
                if expiresAt <= now {
                    // Expired — clean up and fall through to schedule/snapshot.
                    defaults?.removeObject(forKey: "lockUntilPreviousMode")
                    defaults?.removeObject(forKey: "lockUntilExpiresAt")
                } else {
                    return Resolution(
                        mode: .restricted,
                        controlAuthority: .lockUntil,
                        isTemporary: true,
                        expiresAt: expiresAt,
                        reason: "lockUntil active until \(shortTime(expiresAt)) (reverts to \(lockUntilMode))"
                    )
                }
            } else {
                // Legacy: no expiry stored. Apply a 24-hour failsafe so the device
                // doesn't stay locked forever if the DeviceActivity schedule was lost.
                let failsafeExpiry = now.addingTimeInterval(AppConstants.defaultCommandExpirySeconds)
                defaults?.set(failsafeExpiry.timeIntervalSince1970, forKey: "lockUntilExpiresAt")
                return Resolution(
                    mode: .restricted,
                    controlAuthority: .lockUntil,
                    isTemporary: true,
                    expiresAt: failsafeExpiry,
                    reason: "lockUntil active (reverts to \(lockUntilMode)), 24h failsafe applied"
                )
            }
        }

        // 4. Explicit parent command? (setMode — overrides schedule until returnToSchedule)
        //    If the snapshot was set by a parent command (not a schedule transition),
        //    it takes priority. This ensures "set restricted" stays restricted even
        //    when the schedule says "locked" at night.
        if let snapshot = storage.readPolicySnapshot() {
            let authority = snapshot.effectivePolicy.controlAuthority ?? .parentManual
            if authority == .parentManual {
                let mode = snapshot.effectivePolicy.resolvedMode
                return Resolution(
                    mode: mode,
                    controlAuthority: .parentManual,
                    isTemporary: false,
                    expiresAt: nil,
                    reason: "Parent command: \(mode.rawValue)"
                )
            }
        }

        // 5. Schedule-driven mode?
        let isScheduleDriven = AppConstants.isScheduleDriven()

        if isScheduleDriven, let profile = storage.readActiveScheduleProfile() {
            let mode = profile.resolvedMode(at: now)
            return Resolution(
                mode: mode,
                controlAuthority: .schedule,
                isTemporary: false,
                expiresAt: nil,
                reason: "Schedule: \(profile.name) → \(mode.rawValue)"
            )
        }

        // 5b. Schedule-driven is OFF but we have a schedule profile.
        // After returnToSchedule, the snapshot has .schedule authority with a
        // point-in-time resolvedMode (e.g., "locked" from a locked window).
        // With schedule-driven OFF, use the profile's lockedMode (the default
        // outside any window) instead of the stale snapshot mode.
        if !isScheduleDriven, let profile = storage.readActiveScheduleProfile() {
            let mode = profile.lockedMode
            return Resolution(
                mode: mode,
                controlAuthority: .schedule,
                isTemporary: false,
                expiresAt: nil,
                reason: "Schedule (manual): \(profile.name) → \(mode.rawValue)"
            )
        }

        // 6. Other snapshot (no schedule profile available)
        if let snapshot = storage.readPolicySnapshot() {
            let mode = snapshot.effectivePolicy.resolvedMode
            let authority = snapshot.effectivePolicy.controlAuthority ?? .schedule
            return Resolution(
                mode: mode,
                controlAuthority: authority,
                isTemporary: false,
                expiresAt: nil,
                reason: "Policy snapshot: \(mode.rawValue)"
            )
        }

        // 7. No state at all — safe default
        return Resolution(
            mode: .restricted,
            controlAuthority: .failSafe,
            isTemporary: false,
            expiresAt: nil,
            reason: "No state — defaulting to restricted"
        )
    }

    private static func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }
}
