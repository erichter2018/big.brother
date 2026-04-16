import Foundation
import FamilyControls
import BigBrotherCore

/// Concrete wrapper around FamilyControls.AuthorizationCenter.
///
/// **Only `.individual` auth.** No fallback to `.child`. (b432.)
///
/// **Why `.individual` exclusively:**
/// On `.child` auth, the device's ManagedSettingsStore is co-written by Apple's
/// iCloud Screen Time sync from the Family Sharing parent's device. "Most
/// restrictive wins" means our `clearAllSettings()` cannot remove shields the
/// iCloud sync added. This caused a full week of daemon-corruption symptoms
/// (b330–b430 chasing this). `.individual` auth is exclusive to this app per
/// device, immune to Family Sharing Screen Time sync, and was introduced in
/// iOS 16 specifically for "any device, including self-managed."
///
/// **No fallback to `.child`** because falling back puts us right back in the
/// broken state we're trying to escape. If `.individual` fails (which research
/// shows has no confirmed real-device cases on iOS 17+), we fail LOUDLY so the
/// parent investigates immediately rather than silently degrading enforcement.
/// The kid has no FC auth in that case, the parent dashboard surfaces "FC not
/// authorized," and a reinstall is the documented recovery path.
///
/// **Tamper protection:** Screen Time passcode (set per-child) blocks the kid
/// from getting into Settings > Screen Time > Apps With Screen Time Access at
/// all, so the loss of `.child`'s implicit revoke protection doesn't matter
/// in practice. App removal protection is still applied via `denyAppRemoval`
/// from the default ManagedSettingsStore in EnforcementServiceImpl.
///
/// Persists which type was granted so the heartbeat reports authMode and the
/// parent dashboard can show a "needs migration" banner if a child device is
/// still on legacy `.child` auth from a pre-b431 install.
final class FamilyControlsManagerImpl: FamilyControlsManagerProtocol, @unchecked Sendable {

    private var changeHandler: (@Sendable (FCAuthorizationStatus) -> Void)?
    private let storage: (any SharedStorageProtocol)?
    /// Background task observing `AuthorizationCenter.authorizationStatus`
    /// via Observation. Replaces the older Combine `.sink` subscription +
    /// `AnyCancellable` pattern — iOS 17's Observation framework lets us
    /// use `withObservationTracking` to observe any `@Observable` without
    /// Combine. Cancelling this task is the only way to stop observing,
    /// which matches how `AnyCancellable` worked.
    private var observationTask: Task<Void, Never>?

    /// Persisted in UserDefaults so it survives app restarts.
    private static let authTypeKey = "fr.bigbrother.authorizationType"
    private static let authFailReasonKey = "fr.bigbrother.childAuthFailReason"

    init(storage: (any SharedStorageProtocol)? = nil) {
        self.storage = storage
    }

    var status: FCAuthorizationStatus {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .approved:
            return .authorized
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    var isChildAuthorization: Bool {
        // App group entitlement is required for the app to function at all;
        // if it's nil here something is fundamentally broken. Fail safe
        // (returns false = .individual auth) rather than crashing.
        UserDefaults.appGroup?.string(forKey: Self.authTypeKey) == "child"
    }

    func requestAuthorization() async throws {
        guard let defaults = UserDefaults.appGroup else {
            throw FamilyControlsError.authorizationCanceled
        }

        // b431: Critical guard. AuthorizationCenter.requestAuthorization() is
        // a no-op on an already-approved device — it returns immediately
        // without doing anything. If we BLINDLY called requestAuthorization(.individual)
        // on a device that was previously approved as .child, the call would
        // succeed and our code would mistakenly persist "individual" even though
        // the underlying auth is still .child.
        //
        // To actually flip from .child → .individual, the FC auth needs to be
        // revoked first (either by parent toggling Family Sharing > Screen Time
        // > Apps With Screen Time Access > BB OFF, or by reinstalling the app).
        // Then this method runs again with status == .notDetermined and the
        // new flow can take effect.
        let currentStatus = AuthorizationCenter.shared.authorizationStatus
        let existingAuthType = defaults.string(forKey: Self.authTypeKey)
        if currentStatus == .approved {
            if let existingAuthType {
                // Already approved with a known type — no-op. Don't lie about it.
                try? storage?.appendDiagnosticEntry(DiagnosticEntry(
                    category: .auth,
                    message: "requestAuthorization no-op (already approved as \(existingAuthType))",
                    details: "In-place upgrade not possible — auth type can only change via revoke + re-auth (toggle Family Sharing FC off, or reinstall app)."
                ))
                return
            } else {
                // Already approved but type is unknown (e.g., user granted via
                // Settings without going through our prompt, or UserDefaults
                // got cleared). We have no way to introspect the actual type
                // through Apple's API — assume the legacy default (.child)
                // and mark for migration to surface in the parent dashboard.
                defaults.set("child", forKey: Self.authTypeKey)
                UserDefaults.standard.set("child", forKey: Self.authTypeKey)
                defaults.set(true, forKey: "fr.bigbrother.childAuthNeedsMigration")
                defaults.set(Date().timeIntervalSince1970, forKey: "fr.bigbrother.childAuthNeedsMigrationAt")
                try? storage?.appendDiagnosticEntry(DiagnosticEntry(
                    category: .auth,
                    message: "Auth already approved with unknown type — defaulting to .child + marking for migration",
                    details: "Reinstall to migrate to .individual."
                ))
                return
            }
        }

        // b432: ONLY .individual auth. No fallback to .child. See class doc.
        // The .child path was the entire root cause of the b330-b430 corruption
        // saga; falling back to it on `.individual` failure would silently put
        // us back in the broken state. Better to fail loudly and force the
        // parent to investigate (reinstall, check iCloud, etc.) than to
        // silently degrade.
        //
        // b465 timing: this call is the source of the "huge delay during
        // family permission" that the user reported. It can take 5-10s on
        // real devices because Apple's daemon does Family Sharing / iCloud
        // negotiation behind the scenes — unavoidable on our side. We log
        // the wall-clock duration so future debug sessions can tell
        // instantly whether the delay is inside Apple's call or our code.
        let authStartedAt = Date()
        NSLog("[BigBrother] requestAuthorization(.individual) START")
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            let elapsed = Date().timeIntervalSince(authStartedAt)
            NSLog("[BigBrother] requestAuthorization(.individual) SUCCESS in \(String(format: "%.2f", elapsed))s")
            defaults.set("individual", forKey: Self.authTypeKey)
            UserDefaults.standard.set("individual", forKey: Self.authTypeKey)
            defaults.removeObject(forKey: Self.authFailReasonKey)
            // Clear any legacy migration flag from a pre-b431 install.
            defaults.removeObject(forKey: "fr.bigbrother.childAuthNeedsMigration")
            try? storage?.appendDiagnosticEntry(DiagnosticEntry(
                category: .auth,
                message: "Authorized as .individual in \(String(format: "%.2f", elapsed))s"
            ))
            return
        } catch {
            let elapsed = Date().timeIntervalSince(authStartedAt)
            NSLog("[BigBrother] requestAuthorization(.individual) FAILED in \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
            // Map the error to a human-readable reason and surface it loudly.
            // No fallback — this is a terminal failure. Parent must investigate.
            let reason: String
            let errorDesc = "\(error)"
            if errorDesc.contains("invalidAccountType") || errorDesc.contains("invalid") {
                reason = ".individual auth rejected by Apple (invalidAccountType). Investigate device iCloud state — reinstall or sign out/in."
            } else if errorDesc.contains("authorizationCanceled") || errorDesc.contains("cancel") {
                reason = "User canceled the .individual auth prompt. Open Big Brother again and approve."
            } else if errorDesc.contains("restricted") {
                reason = "Device restriction blocks .individual auth (likely MDM profile e.g. OurPact). Remove the profile and retry."
            } else if errorDesc.contains("authorizationConflict") || errorDesc.contains("conflict") {
                reason = "Another parental control app holds Family Controls auth. Uninstall the other app and retry."
            } else if errorDesc.contains("network") {
                reason = "Network error during .individual auth — will retry next launch."
            } else {
                reason = ".individual auth failed: \(error.localizedDescription)"
            }
            defaults.set(reason, forKey: Self.authFailReasonKey)
            try? storage?.appendDiagnosticEntry(DiagnosticEntry(
                category: .auth,
                message: ".individual auth FAILED — no fallback, surfacing error",
                details: reason
            ))
            throw error
        }
    }

    func observeAuthorizationChanges(handler: @escaping @Sendable (FCAuthorizationStatus) -> Void) {
        self.changeHandler = handler
        observationTask?.cancel()

        // Poll-based observation. The previous implementation used
        // `withObservationTracking` + `withCheckedContinuation` to watch
        // `AuthorizationCenter.shared.authorizationStatus`. That approach
        // leaked its continuation on EVERY launch (the runtime warning
        // "observeAuthorizationChanges leaked its continuation") because
        // the `onChange` closure only fires when the property ACTUALLY
        // changes — if it never changes, the continuation never resumes.
        // Worse: the combination of `withObservationTracking` registering
        // an internal observer on `AuthorizationCenter` while enforcement
        // code simultaneously reads the same property on the main actor
        // appeared to cause a ~3-second-then-freeze deadlock on Olivia's
        // device (b594-b599, every launch).
        //
        // Replaced with a simple 10-second poll. FamilyControls auth
        // changes are rare (user grants/revokes in Settings, MDM changes).
        // A 10s detection delay is acceptable. No continuation, no
        // observation tracking, no deadlock risk.
        observationTask = Task { @MainActor [weak self] in
            var lastStatus: FCAuthorizationStatus?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                let current = self.status
                if let last = lastStatus, last != current {
                    self.updateAuthorizationHealth(newStatus: current)
                    self.changeHandler?(current)
                }
                lastStatus = current
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    private static func mapStatus(_ s: AuthorizationStatus) -> FCAuthorizationStatus {
        switch s {
        case .notDetermined: return .notDetermined
        case .approved: return .authorized
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    // MARK: - Private

    private func updateAuthorizationHealth(newStatus: FCAuthorizationStatus) {
        guard let storage else { return }

        let authState: AuthorizationState
        switch newStatus {
        case .authorized: authState = .authorized
        case .denied: authState = .denied
        case .notDetermined: authState = .notDetermined
        }

        let currentHealth = storage.readAuthorizationHealth() ?? .unknown
        let updatedHealth = currentHealth.withTransition(to: authState)
        try? storage.writeAuthorizationHealth(updatedHealth)

        if updatedHealth.currentState != currentHealth.currentState {
            try? storage.appendDiagnosticEntry(DiagnosticEntry(
                category: .auth,
                message: "Authorization changed: \(currentHealth.currentState.rawValue) → \(updatedHealth.currentState.rawValue)"
            ))

            // Clear persisted auth type on genuine revocation so PermissionFixerView re-appears.
            // b432: Must clear BOTH App Group and standard defaults — success
            // paths write to both, so revoke must clear both. Otherwise the
            // heartbeat (which reads UserDefaults.standard for isChildAuthorization)
            // would keep reporting stale auth state for revoked devices.
            if authState == .denied {
                UserDefaults.appGroup?
                    .removeObject(forKey: Self.authTypeKey)
                UserDefaults.standard.removeObject(forKey: Self.authTypeKey)
                try? storage.appendDiagnosticEntry(DiagnosticEntry(
                    category: .auth,
                    message: "FamilyControls authorization revoked — cleared persisted auth type (both stores)"
                ))
            }
        }
    }
}
