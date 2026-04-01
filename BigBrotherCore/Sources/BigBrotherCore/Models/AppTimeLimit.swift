import Foundation

/// A per-app daily time limit stored on the child device.
/// Contains the device-local ApplicationToken (as encoded Data) plus the
/// parent-configured daily budget. The fingerprint enables cross-device
/// reference without exposing the opaque token.
public struct AppTimeLimit: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var appName: String
    /// Encoded ApplicationToken — device-local, opaque.
    public let tokenData: Data
    /// Optional bundle identifier resolved from the token.
    public var bundleID: String?
    /// FNV-1a fingerprint of tokenData for cross-device matching.
    public let fingerprint: String
    /// Daily time budget in minutes. 0 = not yet configured by parent.
    public var dailyLimitMinutes: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        appName: String,
        tokenData: Data,
        bundleID: String? = nil,
        fingerprint: String,
        dailyLimitMinutes: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.appName = appName
        self.tokenData = tokenData
        self.bundleID = bundleID
        self.fingerprint = fingerprint
        self.dailyLimitMinutes = dailyLimitMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
