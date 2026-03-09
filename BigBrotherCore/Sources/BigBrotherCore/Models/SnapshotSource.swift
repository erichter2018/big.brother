import Foundation

/// What caused a PolicySnapshot to be generated.
public enum SnapshotSource: String, Codable, Sendable, Equatable {
    /// A remote command was applied (setMode, temporaryUnlock).
    case commandApplied

    /// A temporary unlock was started.
    case temporaryUnlockStarted

    /// A temporary unlock expired and the previous mode was restored.
    case temporaryUnlockExpired

    /// A schedule transition triggered a mode change.
    case scheduleTransition

    /// A sync pulled a newer policy from CloudKit.
    case syncUpdate

    /// App launch restoration re-evaluated state.
    case restoration

    /// FamilyControls authorization state changed.
    case authorizationChange

    /// Fail-safe mode was applied due to an error or missing state.
    case failSafe

    /// Device enrollment completed and initial policy was set.
    case enrollment

    /// Manual trigger (e.g., parent used local controls).
    case manual

    /// The very first snapshot created for this device.
    case initial
}
