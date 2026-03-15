import Foundation

/// An app that has been temporarily allowed by the parent for a limited time.
///
/// Created by CommandProcessor when processing `.temporaryUnlockApp`.
/// Read by ShieldAction and ShieldConfiguration extensions to check
/// whether a specific app should be allowed through the shield.
public struct TemporaryAllowedAppEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// The original unlock request ID (for correlation).
    public let requestID: UUID
    /// Encoded ApplicationToken data (device-local, opaque).
    public let tokenData: Data
    /// Human-readable app name.
    public let appName: String
    /// Bundle identifier for the app (fallback for category-level shielding).
    public let bundleID: String?
    /// When this temporary access expires.
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        tokenData: Data,
        appName: String,
        bundleID: String? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.requestID = requestID
        self.tokenData = tokenData
        self.appName = appName
        self.bundleID = bundleID
        self.expiresAt = expiresAt
    }

    /// Whether this entry is still valid (not expired).
    public var isValid: Bool {
        expiresAt > Date()
    }
}
