import Foundation
import BigBrotherCore

/// Processes incoming remote commands on a child device.
///
/// Flow:
/// 1. Fetch pending commands from CloudKit (device-targeted, child-targeted, global)
/// 2. Filter to commands relevant to this device
/// 3. Sort by issuedAt (oldest first)
/// 4. Skip expired commands (create expired receipt)
/// 5. Apply each command (update policy, trigger enforcement)
/// 6. Create receipt for each processed command
///
/// Called by:
/// - SyncCoordinator during sync cycles
/// - Silent push notification handler
/// - Manual refresh
protocol CommandProcessorProtocol {
    /// Fetch and process all pending commands for this device.
    func processIncomingCommands() async throws

    /// Process a single command. Returns the receipt.
    func process(_ command: RemoteCommand) async throws -> CommandReceipt
}
