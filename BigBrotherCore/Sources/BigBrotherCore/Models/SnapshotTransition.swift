import Foundation

/// A record of what changed between two consecutive PolicySnapshots.
/// Stored in a limited history buffer for diagnostics and audit.
public struct SnapshotTransition: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let fromGeneration: Int64
    public let toGeneration: Int64
    public let fromMode: LockMode
    public let toMode: LockMode
    public let source: SnapshotSource
    public let timestamp: Date
    /// Human-readable descriptions of what changed.
    public let changes: [String]

    public init(
        id: UUID = UUID(),
        fromGeneration: Int64,
        toGeneration: Int64,
        fromMode: LockMode,
        toMode: LockMode,
        source: SnapshotSource,
        timestamp: Date = Date(),
        changes: [String] = []
    ) {
        self.id = id
        self.fromGeneration = fromGeneration
        self.toGeneration = toGeneration
        self.fromMode = fromMode
        self.toMode = toMode
        self.source = source
        self.timestamp = timestamp
        self.changes = changes
    }

    /// Compute a transition between two snapshots, summarizing what changed.
    public static func between(
        from previous: PolicySnapshot,
        to current: PolicySnapshot
    ) -> SnapshotTransition {
        var changes: [String] = []

        let prevMode = previous.effectivePolicy.resolvedMode
        let currMode = current.effectivePolicy.resolvedMode
        if prevMode != currMode {
            changes.append("Mode: \(prevMode.rawValue) → \(currMode.rawValue)")
        }

        if previous.effectivePolicy.isTemporaryUnlock != current.effectivePolicy.isTemporaryUnlock {
            if current.effectivePolicy.isTemporaryUnlock {
                changes.append("Temporary unlock started")
            } else {
                changes.append("Temporary unlock ended")
            }
        }

        let prevAuth = previous.authorizationHealth?.currentState
        let currAuth = current.authorizationHealth?.currentState
        if prevAuth != currAuth {
            changes.append("Authorization: \(prevAuth?.rawValue ?? "nil") → \(currAuth?.rawValue ?? "nil")")
        }

        if previous.effectivePolicy.policyVersion != current.effectivePolicy.policyVersion {
            changes.append("Policy version: \(previous.effectivePolicy.policyVersion) → \(current.effectivePolicy.policyVersion)")
        }

        if changes.isEmpty {
            changes.append("Snapshot refreshed (no policy change)")
        }

        return SnapshotTransition(
            fromGeneration: previous.generation,
            toGeneration: current.generation,
            fromMode: prevMode,
            toMode: currMode,
            source: current.source,
            timestamp: current.createdAt,
            changes: changes
        )
    }
}
