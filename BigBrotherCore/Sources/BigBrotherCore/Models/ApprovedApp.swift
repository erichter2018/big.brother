import Foundation

/// An app that has been permanently approved by a parent for a specific device.
///
/// Stored on the parent side to track which apps have been approved,
/// enabling the parent to view and revoke approvals.
public struct ApprovedApp: Codable, Sendable, Identifiable, Equatable {
    /// Local tracking identifier for parent-side UI state.
    public let id: UUID
    /// Human-readable app name.
    public let appName: String
    /// The device this approval is for.
    public let deviceID: DeviceID
    /// When the parent approved this app.
    public let approvedAt: Date

    public init(
        id: UUID,
        appName: String,
        deviceID: DeviceID,
        approvedAt: Date = Date()
    ) {
        self.id = id
        self.appName = appName
        self.deviceID = deviceID
        self.approvedAt = approvedAt
    }
}
