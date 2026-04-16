import Foundation

/// Centralized cross-device app-identity matching.
///
/// ## Why this exists
///
/// The iOS FamilyControls `ApplicationToken` is opaque Data that is **device-
/// local**: the same app installed on two devices of the same Apple ID
/// produces different token bytes, hence different FNV-1a fingerprints. Our
/// cross-device "this is the same app" decision therefore cannot rely on
/// fingerprint alone.
///
/// `Application(token:).bundleIdentifier` is non-nil reliably only inside
/// the ShieldConfiguration and DeviceActivityReport extensions. It's
/// sometimes-nil from picker selection, and always-nil when reconstructing
/// from a saved token in the main app, Monitor, or ShieldAction. So
/// bundleID is a **bonus** identifier — treat as authoritative when
/// present on both sides, skip otherwise.
///
/// `Application(token:).localizedDisplayName` is iOS-provided (kids can't
/// fake "Instagram" as "Homework"), harvested during picker interactions
/// and persisted in our name cache. Normalized app name is therefore the
/// most widely-available cross-device identifier.
///
/// ## Match priority (identity decision)
///
/// 1. **Bundle ID** (both sides have it, normalized to lowercased/trimmed):
///    authoritative — bundle IDs don't collide across real apps.
/// 2. **Fingerprint, same-device only**: token fingerprints are device-
///    specific; matching cross-device would be a collision-prone coincidence
///    (2^-64) but still worth avoiding. When a device-ID scope is known,
///    we gate fingerprint match to within that scope.
/// 3. **Normalized app name** as a fallback, only when the name looks
///    usable (not "App", "unknown", "Temporary…", etc).
public enum AppIdentityMatcher {

    /// Lowercase + trim bundle ID. Returns nil when the bundle ID is
    /// empty/whitespace/absent — nil-on-nil comparisons must never pass.
    public static func normalizeBundleID(_ bundleID: String?) -> String? {
        guard let bid = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bid.isEmpty else {
            return nil
        }
        return bid.lowercased()
    }

    /// Case + diacritics-insensitive app-name canonicalization. Matches the
    /// child-side `CommandProcessorImpl.normalizeAppName` so parent and child
    /// always agree on name equality.
    public static func normalizeAppName(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reject names that aren't really names — placeholders, token dumps,
    /// and "Temporary…" / "Blocked app …" fallbacks. An app with a useless
    /// name must never match by name; it falls to bundleID/fingerprint.
    public static func isUsefulAppName(_ name: String) -> Bool {
        let normalized = normalizeAppName(name).lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.hasPrefix("app ") &&
            !normalized.hasPrefix("temporary") &&
            !normalized.hasPrefix("blocked app ") &&
            !normalized.contains("token(") &&
            !normalized.contains("data:") &&
            !normalized.contains("bytes)")
    }

    /// Comparable identity for a single "candidate" app — a pending review,
    /// an existing config, or anything else carrying (fingerprint, appName,
    /// bundleID, optional deviceID). Callers build these and compare
    /// with `AppIdentityMatcher.same(_:_:)`.
    public struct Candidate: Sendable, Equatable {
        public let bundleID: String?
        public let fingerprint: String?
        public let appName: String
        /// Device scope for the fingerprint. When nil, the fingerprint
        /// is not scoped (use with care — fingerprint matches only when
        /// BOTH sides have a nil scope OR matching scope).
        public let deviceID: DeviceID?

        public init(
            bundleID: String? = nil,
            fingerprint: String? = nil,
            appName: String,
            deviceID: DeviceID? = nil
        ) {
            self.bundleID = bundleID
            self.fingerprint = fingerprint
            self.appName = appName
            self.deviceID = deviceID
        }
    }

    /// Decide whether two app references identify the same app.
    ///
    /// Priority:
    /// 1. Bundle ID (authoritative). If both sides have one:
    ///    - Equal → MATCH. Return true immediately.
    ///    - Different → HARD REJECT. Do not fall through to name; the
    ///      display names of two distinct apps sometimes collide
    ///      (Apple's "Photos" vs a third-party "Photos"), and we must
    ///      not conflate them when the bundle IDs say they are not the
    ///      same app.
    /// 2. Fingerprint (same-device only). If both sides have fingerprints:
    ///    - Equal AND device scopes match (or at least one side is
    ///      nil-scoped) → match.
    ///    - Cross-device fingerprint equality is almost certainly a
    ///      coincidence (2^-64 collision on independent opaque blobs),
    ///      so it does not match when both sides have differing
    ///      non-nil deviceIDs.
    /// 3. Useful normalized app name (final fallback, only used when
    ///    the two sides haven't already decided via bundleID or
    ///    fingerprint).
    public static func same(_ a: Candidate, _ b: Candidate) -> Bool {
        // Step 1: bundle-ID comparison is authoritative when BOTH sides
        // have one. Equal → match; different → reject with no fallthrough.
        if let nba = normalizeBundleID(a.bundleID),
           let nbb = normalizeBundleID(b.bundleID) {
            return nba == nbb
        }
        if let fa = a.fingerprint, let fb = b.fingerprint, fa == fb {
            // Fingerprint matches within a single device scope. A nil
            // deviceID on either side is "unknown scope" — we permit the
            // match because same-device re-imports sometimes lack scope
            // info. Two non-nil differing deviceIDs with equal fingerprints
            // are a 2^-64 collision and deliberately skipped.
            if let da = a.deviceID, let db = b.deviceID {
                if da == db { return true }
            } else {
                return true
            }
        }
        return isUsefulAppName(a.appName) &&
            isUsefulAppName(b.appName) &&
            normalizeAppName(a.appName) == normalizeAppName(b.appName)
    }
}

// MARK: - Convenience bridges for our model types

public extension PendingAppReview {
    /// Identity candidate for this review. `deviceID` is always populated
    /// because reviews are always device-scoped.
    var identityCandidate: AppIdentityMatcher.Candidate {
        AppIdentityMatcher.Candidate(
            bundleID: bundleID,
            fingerprint: appFingerprint,
            appName: appName,
            deviceID: deviceID
        )
    }
}

public extension TimeLimitConfig {
    /// Identity candidate for this config. `deviceID` is nil for
    /// child-scoped (all-devices) configs, non-nil for per-device configs —
    /// which is exactly the scope gate fingerprint-matching needs.
    var identityCandidate: AppIdentityMatcher.Candidate {
        AppIdentityMatcher.Candidate(
            bundleID: bundleID,
            fingerprint: appFingerprint,
            appName: appName,
            deviceID: deviceID
        )
    }
}
