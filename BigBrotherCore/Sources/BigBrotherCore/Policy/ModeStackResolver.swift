import Foundation

/// Stateless, idempotent mode resolution from the App Group stack files.
///
/// Reads TemporaryUnlockState, TimedUnlockInfo, schedule profile, and PolicySnapshot
/// to compute what mode the device should be in RIGHT NOW. Any process (main app,
/// Monitor extension, VPN tunnel) can call this and get the same deterministic answer.
///
/// This function is STRICTLY READ-ONLY — it never writes to App Group or UserDefaults.
/// Multiple processes (main app, Monitor, tunnel) call this concurrently; any writes
/// would create cross-process races. Cleanup of expired state is done by the command
/// processor via cleanupExpiredLockUntil().
///
/// ## Relationship to other "mode" concepts
///
/// The codebase has several overlapping notions of "what mode is the device in":
///
/// - `ModeStackResolver.resolve(storage:)` → **THIS** — the authoritative
///   answer to "what mode SHOULD the device be in right now, accounting for
///   the full stack of overrides." Every enforcement decision, every heartbeat
///   that reports the current mode, every DNS-blackhole check should come
///   through here.
///
/// - `PolicySnapshot.effectivePolicy.resolvedMode` — the mode at the moment
///   the snapshot was COMMITTED. May be stale relative to lockUntil / timed
///   unlock / temporary unlock expiries. Read this only when you specifically
///   want "the mode the writer meant when they committed the snapshot"
///   (e.g., dashboards showing snapshot history, auditing a past decision).
///
/// - `ExtensionSharedState.currentMode` — the monitor's cached view of the
///   mode at the last `apply()`. Used by the monitor as a shield-selection
///   cache and by the tunnel's `seedBlockReasonsOnStart` as a seed signal
///   when no resolver call has run yet. Do NOT read this as "what mode is
///   the device in" — it will drift from the resolver's answer.
///
/// - `ScheduleProfile.resolvedMode(at:)` — a LAYER inside the resolver. Only
///   reflects the schedule, not temporary overrides. Read directly only when
///   you specifically need "what the schedule alone says" (e.g., heartbeat's
///   `scheduleResolvedMode` field, which is explicitly separate from
///   `currentMode`).
///
/// - `EffectivePolicy.isTemporaryUnlock` — a BOOL on the snapshot that
///   means "this snapshot represents a temporary override to unlocked",
///   distinct from `Resolution.isTemporary` which is true for ANY temporary
///   resolution. See EffectivePolicy.swift for the trap that bit us in b460.
///
/// Rule of thumb: if you're asking "what mode is the device in?" call
/// `resolve()`. If you're asking "what does this specific component
/// think?" read that component's field directly.
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
    /// Pure read-only resolver — no side effects, no writes.
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
        if let temp, !temp.isExpired(at: now) {
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
        // READ-ONLY: resolve() must never write to UserDefaults. Multiple processes
        // call this concurrently. Cleanup is done by cleanupExpiredLockUntil().
        let defaults = UserDefaults.appGroup
        if let _ = defaults?.string(forKey: "lockUntilPreviousMode") {
            if let expiryInterval = defaults?.object(forKey: "lockUntilExpiresAt") as? Double {
                let expiresAt = Date(timeIntervalSince1970: expiryInterval)
                if expiresAt > now {
                    let lockUntilMode = defaults?.string(forKey: "lockUntilPreviousMode") ?? "restricted"
                    return Resolution(
                        mode: .restricted,
                        controlAuthority: .lockUntil,
                        isTemporary: true,
                        expiresAt: expiresAt,
                        reason: "lockUntil active until \(shortTime(expiresAt)) (reverts to \(lockUntilMode))"
                    )
                }
                // Expired — fall through to schedule/snapshot. Cleanup happens elsewhere.
            } else {
                // Legacy: no expiry stored. Treat as 24h failsafe without writing.
                let failsafeExpiry = now.addingTimeInterval(AppConstants.defaultCommandExpirySeconds)
                let lockUntilMode = defaults?.string(forKey: "lockUntilPreviousMode") ?? "restricted"
                return Resolution(
                    mode: .restricted,
                    controlAuthority: .lockUntil,
                    isTemporary: true,
                    expiresAt: failsafeExpiry,
                    reason: "lockUntil active (reverts to \(lockUntilMode)), 24h failsafe (no persisted expiry)"
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
            let mode = profile.lockedMode == .unlocked ? .restricted : profile.lockedMode
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

    /// Clean up expired lockUntil state from UserDefaults.
    /// Call ONLY from the main app's command processor — not from extensions.
    public static func cleanupExpiredLockUntil(now: Date = Date()) {
        let defaults = UserDefaults.appGroup
        guard defaults?.string(forKey: "lockUntilPreviousMode") != nil else { return }
        if let expiryInterval = defaults?.object(forKey: "lockUntilExpiresAt") as? Double {
            let expiresAt = Date(timeIntervalSince1970: expiryInterval)
            if expiresAt <= now {
                defaults?.removeObject(forKey: "lockUntilPreviousMode")
                defaults?.removeObject(forKey: "lockUntilExpiresAt")
            }
        }
    }

    private static func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }
}
