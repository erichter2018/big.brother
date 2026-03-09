import Foundation
import BigBrotherCore

/// Orchestrates a full sync cycle between local state and CloudKit.
///
/// Responsibilities:
/// - Pull pending commands and apply them
/// - Push heartbeats
/// - Sync event logs
/// - Fetch updated policies
/// - Update device status
///
/// Called by:
/// - App foreground timer
/// - Background fetch handler
/// - Silent push notification handler
protocol SyncCoordinatorProtocol {
    /// Run a full sync cycle. Order:
    /// 1. Fetch and process pending commands
    /// 2. Send heartbeat
    /// 3. Sync event logs
    /// 4. Fetch latest policy
    func performFullSync() async throws

    /// Lightweight sync: just process commands and send heartbeat.
    /// Used for background fetch where time is limited.
    func performQuickSync() async throws
}
