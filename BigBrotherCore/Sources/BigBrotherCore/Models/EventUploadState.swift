import Foundation

/// Upload lifecycle state for a queued event log entry.
public enum EventUploadState: String, Codable, Sendable, Equatable {
    /// Queued locally, not yet attempted.
    case pending

    /// Upload in progress.
    case uploading

    /// Successfully uploaded to CloudKit.
    case uploaded

    /// Upload attempted but failed. Will be retried.
    case failed
}
