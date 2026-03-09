import Foundation
import BigBrotherCore

/// Structured event logging with local queue and CloudKit sync.
///
/// Events are written immediately to App Group storage (so extensions
/// can also append events). The main app periodically flushes the
/// queue to CloudKit.
///
/// Important events that trigger parent notifications:
/// - .localPINUnlock
/// - .familyControlsAuthChanged (revoked)
/// - .enrollmentRevoked
protocol EventLoggerProtocol {
    /// Log an event locally. Appends to the App Group event queue.
    func log(_ eventType: EventType, details: String?)

    /// Sync all pending (un-synced) events to CloudKit.
    /// Marks synced events so they are not re-uploaded.
    func syncPendingEvents() async throws

    /// Read all pending events (for debugging or display).
    func pendingEvents() -> [EventLogEntry]
}
