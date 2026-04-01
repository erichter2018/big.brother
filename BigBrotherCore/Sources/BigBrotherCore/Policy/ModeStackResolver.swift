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
        if let temp = storage.readTemporaryUnlockState() {
            if temp.expiresAt > now {
                return Resolution(
                    mode: .unlocked,
                    isTemporary: true,
                    expiresAt: temp.expiresAt,
                    reason: "Temporary unlock (\(temp.origin.rawValue)), expires \(shortTime(temp.expiresAt))"
                )
            }
            // Expired — clean up and fall through to previous mode
            try? storage.clearTemporaryUnlockState()
        }

        // 2. Active timed unlock (penalty + unlock phases)?
        if let timed = storage.readTimedUnlockInfo() {
            if now < timed.unlockAt {
                // Penalty phase — device should be locked
                let penaltyMode = timed.previousMode ?? .restricted
                return Resolution(
                    mode: penaltyMode,
                    isTemporary: true,
                    expiresAt: timed.unlockAt,
                    reason: "Timed unlock penalty phase, unlocks at \(shortTime(timed.unlockAt))"
                )
            }
            if now < timed.lockAt {
                // Unlock phase — device is free
                return Resolution(
                    mode: .unlocked,
                    isTemporary: true,
                    expiresAt: timed.lockAt,
                    reason: "Timed unlock free phase, locks at \(shortTime(timed.lockAt))"
                )
            }
            // Fully expired — clean up and fall through
            try? storage.clearTimedUnlockInfo()
        }

        // 3. Schedule-driven mode?
        let isScheduleDriven = AppConstants.isScheduleDriven()

        if isScheduleDriven, let profile = storage.readActiveScheduleProfile() {
            let mode = profile.resolvedMode(at: now)
            return Resolution(
                mode: mode,
                isTemporary: false,
                expiresAt: nil,
                reason: "Schedule: \(profile.name) → \(mode.rawValue)"
            )
        }

        // 4. Explicit parent mode (non-schedule)
        if let snapshot = storage.readPolicySnapshot() {
            let mode = snapshot.effectivePolicy.resolvedMode
            return Resolution(
                mode: mode,
                isTemporary: false,
                expiresAt: nil,
                reason: "Policy snapshot: \(mode.rawValue)"
            )
        }

        // 5. No state at all — safe default
        return Resolution(
            mode: .restricted,
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
