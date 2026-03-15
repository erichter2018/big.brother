import Foundation
import BigBrotherCore

/// Manages FamilyControls authorization lifecycle.
///
/// Tries `.child` authorization first (stronger — requires Family Sharing).
/// Falls back to `.individual` if `.child` fails (e.g., device not in
/// Family Sharing group, or shares parent Apple ID).
///
/// This manager wraps FamilyControls.AuthorizationCenter and provides
/// a clean interface that doesn't leak framework types into the rest
/// of the app.
protocol FamilyControlsManagerProtocol: Sendable {
    /// Current authorization status.
    var status: FCAuthorizationStatus { get }

    /// Whether the current authorization is `.child` (stronger, supports system restrictions).
    /// False means `.individual` (self-regulation only).
    var isChildAuthorization: Bool { get }

    /// Request authorization — tries `.child` first, falls back to `.individual`.
    func requestAuthorization() async throws

    /// Start observing authorization status changes.
    func observeAuthorizationChanges(handler: @escaping @Sendable (FCAuthorizationStatus) -> Void)
}
