import Foundation

/// Categories for structured backend diagnostic entries.
public enum DiagnosticCategory: String, Codable, Sendable, CaseIterable {
    case enrollment
    case command
    case auth
    case enforcement
    case heartbeat
    case restoration
    case temporaryUnlock
    case eventUpload
    case storage
    case shieldAction
    case shieldConfig
    case activityReport
    case tokenNameResearch
}

/// A single structured diagnostic log entry.
///
/// Stored locally in App Group storage for retrieval by
/// a future diagnostics UI. Not synced to CloudKit (that's EventLogEntry's job).
public struct DiagnosticEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let category: DiagnosticCategory
    public let message: String
    public let details: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        category: DiagnosticCategory,
        message: String,
        details: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.message = message
        self.details = details
        self.timestamp = timestamp
    }
}
