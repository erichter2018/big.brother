import Foundation

/// A pending "Ask for More Time" request from a child device.
///
/// Created by the ShieldAction extension when a child taps "Ask for More Time".
/// Stored locally with the opaque ApplicationToken data so the token never
/// leaves the device. Only the app name and request ID go to CloudKit.
///
/// When the parent approves (via `.allowApp(requestID:)`), the CommandProcessor
/// looks up this request to find the cached token and adds it to the allow list.
public struct PendingUnlockRequest: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Human-readable app name (from ShieldConfiguration cache).
    public let appName: String
    /// Encoded ApplicationToken data (device-local, opaque).
    public let tokenData: Data
    /// When the child tapped "Ask for More Time".
    public let requestedAt: Date

    public init(
        id: UUID = UUID(),
        appName: String,
        tokenData: Data,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.appName = appName
        self.tokenData = tokenData
        self.requestedAt = requestedAt
    }
}
