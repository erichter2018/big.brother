import Foundation
import BigBrotherCore

/// Manages FamilyControls authorization lifecycle.
///
/// Responsibilities:
/// - Request .individual authorization during enrollment
/// - Monitor authorization status changes
/// - Log events when authorization is revoked
/// - Surface authorization state to the enforcement service
///
/// This manager wraps FamilyControls.AuthorizationCenter and provides
/// a clean interface that doesn't leak framework types into the rest
/// of the app.
protocol FamilyControlsManagerProtocol: Sendable {
    /// Current authorization status.
    var status: FCAuthorizationStatus { get }

    /// Request .individual authorization.
    /// Must be called with the user (parent) physically present.
    func requestAuthorization() async throws

    /// Start observing authorization status changes.
    /// Calls the handler when status changes (e.g., user revokes in Settings).
    func observeAuthorizationChanges(handler: @escaping @Sendable (FCAuthorizationStatus) -> Void)
}
