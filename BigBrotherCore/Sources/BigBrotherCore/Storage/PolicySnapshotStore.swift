import Foundation

/// Result of attempting to commit a new PolicySnapshot.
public enum SnapshotCommitResult: Sendable, Equatable {
    /// The snapshot was committed successfully.
    case committed(PolicySnapshot)

    /// The snapshot was rejected because its generation is not newer
    /// than the current snapshot (concurrent write race).
    case rejectedAsStale(currentGeneration: Int64)

    /// The new snapshot is identical to the current one (same fingerprint)
    /// and the source doesn't require forced commit.
    case unchanged
}

/// Manages versioned PolicySnapshot persistence with commit semantics.
///
/// Ensures:
/// - Monotonic generation numbers
/// - Stale snapshot rejection (concurrent writes detected)
/// - History buffer for audit/diagnostics
/// - Atomic persistence via underlying SharedStorageProtocol
///
/// This is the authoritative store for the current policy state.
/// All policy changes should flow through this store.
public final class PolicySnapshotStore: @unchecked Sendable {

    private let storage: any SharedStorageProtocol
    private let lock = NSLock()

    public init(storage: any SharedStorageProtocol) {
        self.storage = storage
    }

    // MARK: - Read

    /// Load the current snapshot from persistent storage.
    public func loadCurrentSnapshot() -> PolicySnapshot? {
        storage.readPolicySnapshot()
    }

    /// The generation of the current snapshot, or 0 if none exists.
    public func currentGeneration() -> Int64 {
        loadCurrentSnapshot()?.generation ?? 0
    }

    /// Load the snapshot transition history buffer.
    public func loadHistory() -> [SnapshotTransition] {
        storage.readSnapshotHistory()
    }

    // MARK: - Commit

    /// Attempt to commit a new snapshot.
    ///
    /// Enforces:
    /// - Generation must be strictly greater than current.
    /// - If fingerprints match and source doesn't force commit, returns `.unchanged`.
    /// - Records a SnapshotTransition on successful commit.
    ///
    /// Thread-safe via cross-process file lock (SnapshotFileLock).
    public func commit(_ snapshot: PolicySnapshot) throws -> SnapshotCommitResult {
        try SnapshotFileLock.withLock {
            let current = storage.readPolicySnapshot()

            // Staleness check: generation must increase
            if let current, snapshot.generation <= current.generation {
                return .rejectedAsStale(currentGeneration: current.generation)
            }

            // No-op detection: skip if fingerprint matches and source is routine
            if let current, current.policyFingerprint == snapshot.policyFingerprint {
                if !Self.alwaysCommitSources.contains(snapshot.source) {
                    return .unchanged
                }
            }

            // Persist the new snapshot
            try storage.writePolicySnapshot(snapshot)

            // Derive scheduleDrivenMode from the snapshot's control authority.
            // This keeps the UserDefaults flag consistent without producers writing it directly.
            UserDefaults.appGroup?
                .set(snapshot.effectivePolicy.effectiveAuthority == .schedule, forKey: "scheduleDrivenMode")

            // Record transition
            if let current {
                let transition = SnapshotTransition.between(from: current, to: snapshot)
                try? appendTransition(transition)
            }

            // Update extension shared state — but don't overwrite if the Monitor extension
            // wrote a newer version (e.g., schedule transition applied after this snapshot).
            // Use policyVersion instead of timestamps to avoid clock-skew races.
            let existingExt = storage.readExtensionSharedState()
            let monitorOwnsState: Bool
            if let ext = existingExt {
                monitorOwnsState = ext.policyVersion > snapshot.effectivePolicy.policyVersion
            } else {
                monitorOwnsState = false
            }
            // Version downgrade detection: warn if we're writing over a higher policyVersion.
            // This can happen if Monitor or Tunnel committed a newer version between reads.
            // Don't block the write (generation already increased), but make it visible.
            if let current, current.effectivePolicy.policyVersion > snapshot.effectivePolicy.policyVersion {
                #if DEBUG
                print("[BigBrother] ⚠️ PolicySnapshotStore.commit: policyVersion downgrade \(current.effectivePolicy.policyVersion) → \(snapshot.effectivePolicy.policyVersion)")
                #endif
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .enforcement,
                    message: "Snapshot policyVersion downgrade: \(current.effectivePolicy.policyVersion) → \(snapshot.effectivePolicy.policyVersion)"
                ))
            }

            if !monitorOwnsState {
                let extState = ExtensionSharedState(
                    currentMode: snapshot.effectivePolicy.resolvedMode,
                    isTemporaryUnlock: snapshot.effectivePolicy.isTemporaryUnlock,
                    temporaryUnlockExpiresAt: snapshot.effectivePolicy.temporaryUnlockExpiresAt,
                    authorizationAvailable: snapshot.authorizationHealth?.isAuthorized ?? true,
                    enforcementDegraded: snapshot.authorizationHealth?.enforcementDegraded ?? false,
                    shieldConfig: shieldConfig(for: snapshot),
                    policyVersion: snapshot.effectivePolicy.policyVersion
                )
                try? storage.writeExtensionSharedState(extState)
            }

            // Update shield config
            try? storage.writeShieldConfiguration(shieldConfig(for: snapshot))

            return .committed(snapshot)
        }
    }

    /// Generate the next generation number based on the current state.
    /// Thread-safe.
    public func nextGeneration() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return (storage.readPolicySnapshot()?.generation ?? 0) + 1
    }

    /// Mark the current snapshot as applied (enforcement confirmed).
    public func markApplied(at time: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }

        guard var snapshot = storage.readPolicySnapshot() else { return }
        snapshot.appliedAt = time
        try storage.writePolicySnapshot(snapshot)
    }

    // MARK: - Private

    /// Sources that should always produce a commit even if fingerprint matches.
    /// These represent important lifecycle events worth recording.
    ///
    /// `.commandApplied` is included so that a parent-issued setMode that
    /// resolves to the current mode (e.g., locked → locked because the kid is
    /// already locked, or restricted → locked because of force-mode override)
    /// still triggers `enforcement.apply` and a Monitor refresh. Without this,
    /// repeat parent commands silently no-op even when the actual shield state
    /// has drifted from the snapshot — so the user sends "lock" and nothing
    /// happens because the snapshot already said "locked".
    private static let alwaysCommitSources: Set<SnapshotSource> = [
        .restoration,
        .authorizationChange,
        .failSafe,
        .temporaryUnlockExpired,
        .commandApplied,
    ]

    private func appendTransition(_ transition: SnapshotTransition) throws {
        var history = storage.readSnapshotHistory()
        history.append(transition)

        // Prune to max size
        if history.count > AppConstants.snapshotHistoryMaxEntries {
            let overflow = history.count - AppConstants.snapshotHistoryMaxEntries
            history.removeFirst(overflow)
        }

        try storage.writeSnapshotHistory(history)
    }

    private func shieldConfig(for snapshot: PolicySnapshot) -> ShieldConfig {
        let mode = snapshot.effectivePolicy.resolvedMode
        let message: String
        switch mode {
        case .unlocked:
            message = "This app should be accessible."
        case .restricted:
            message = "This app is not in your allowed list. Ask a parent to unlock it."
        case .locked:
            message = "Only essential apps are available right now."
        case .lockedDown:
            message = "Device is locked down. Only essential apps, no internet."
        }
        return ShieldConfig(
            title: mode.displayName,
            message: message,
            showRequestButton: mode != .unlocked
        )
    }
}
