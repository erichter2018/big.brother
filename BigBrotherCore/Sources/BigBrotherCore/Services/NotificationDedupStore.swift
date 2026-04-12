import Foundation

/// Shared read-modify-write dedup state for parent-app local notifications.
///
/// Three notification services in the app (safety events, unlock requests,
/// app review requests) all post local notifications in response to CloudKit
/// pushes and periodic refreshes. Each one needs to:
///   1. Skip events it has already notified for (by event ID / UUID).
///   2. Collapse semantic duplicates — same kid, same app, same kind of
///      event — within a configurable recency window, even when the event
///      IDs differ (e.g., the kid's phone and iPad both fire a
///      "new app detected" event for the same app).
///
/// Previously each service re-implemented this by reading a UserDefaults
/// string array, iterating the events, posting, and writing back. Any two
/// of these services calling `checkAndNotify` in parallel — trivially
/// easy to trigger when a CloudKit push wakes the app while a view model
/// is also refreshing — would read the same old state, each decide "not
/// yet notified", and both post. Fixing it one service at a time left
/// the other two to drift.
///
/// `NotificationDedupStore` centralizes the pattern. Each service owns one
/// instance with its own UserDefaults key pair and window settings. Callers
/// run a block via `withLock` that receives a mutable `DedupState`; the
/// block is serialized across all calls on that store, and any changes to
/// `state` are persisted atomically on return.
public final class NotificationDedupStore {

    public struct Configuration {
        public let notifiedIDsKey: String
        public let contentKeysKey: String
        public let defaults: UserDefaults
        public let maxNotifiedIDs: Int
        public let maxContentKeys: Int

        public init(
            notifiedIDsKey: String,
            contentKeysKey: String,
            defaults: UserDefaults = .standard,
            maxNotifiedIDs: Int = 500,
            maxContentKeys: Int = 200
        ) {
            self.notifiedIDsKey = notifiedIDsKey
            self.contentKeysKey = contentKeysKey
            self.defaults = defaults
            self.maxNotifiedIDs = maxNotifiedIDs
            self.maxContentKeys = maxContentKeys
        }
    }

    private let lock = NSLock()
    private let config: Configuration

    public init(configuration: Configuration) {
        self.config = configuration
    }

    /// Run `body` with exclusive access to the dedup state. The block
    /// receives a mutable `DedupState` snapshot loaded from persistent
    /// storage. Any insertions made inside the block are written back
    /// (with size capping) before the lock is released. Post notifications
    /// OUTSIDE this block to avoid holding the lock across async UN calls.
    public func withLock<T>(_ body: (inout DedupState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }

        let now = Date().timeIntervalSince1970
        var state = DedupState(
            notifiedIDs: Set(config.defaults.stringArray(forKey: config.notifiedIDsKey) ?? []),
            contentKeys: (config.defaults.dictionary(forKey: config.contentKeysKey) as? [String: Double]) ?? [:],
            now: now
        )

        let result = body(&state)

        if state.notifiedIDs.count > config.maxNotifiedIDs {
            state.notifiedIDs = Set(state.notifiedIDs.suffix(config.maxNotifiedIDs))
        }
        if state.contentKeys.count > config.maxContentKeys {
            state.contentKeys = Dictionary(
                uniqueKeysWithValues:
                    state.contentKeys
                        .sorted { $0.value > $1.value }
                        .prefix(config.maxContentKeys)
                        .map { ($0.key, $0.value) }
            )
        }
        config.defaults.set(Array(state.notifiedIDs), forKey: config.notifiedIDsKey)
        config.defaults.set(state.contentKeys, forKey: config.contentKeysKey)

        return result
    }
}

/// Mutable view of dedup state passed into `NotificationDedupStore.withLock`.
/// Callers check membership via `hasNotified` / `isRecentContentKey`, then
/// commit their decision by calling `markNotified` and/or `recordContentKey`.
public struct DedupState {
    public var notifiedIDs: Set<String>
    public var contentKeys: [String: Double]
    public let now: TimeInterval

    public init(notifiedIDs: Set<String>, contentKeys: [String: Double], now: TimeInterval) {
        self.notifiedIDs = notifiedIDs
        self.contentKeys = contentKeys
        self.now = now
        // GC content keys older than the longest-plausible window (24h).
        // Services with shorter windows still enforce their own check on read.
        self.contentKeys = self.contentKeys.filter { now - $0.value < 86_400 }
    }

    public func hasNotified(_ id: String) -> Bool {
        notifiedIDs.contains(id)
    }

    public mutating func markNotified(_ id: String) {
        notifiedIDs.insert(id)
    }

    /// True if `key` was recorded within the last `window` seconds.
    public func isRecentContentKey(_ key: String, within window: TimeInterval) -> Bool {
        guard let last = contentKeys[key] else { return false }
        return now - last < window
    }

    public mutating func recordContentKey(_ key: String) {
        contentKeys[key] = now
    }
}
