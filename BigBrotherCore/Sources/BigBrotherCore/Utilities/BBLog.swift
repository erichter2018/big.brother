import Foundation
import os.log

/// Unified logging entry point. Replaces scattered `NSLog` calls with
/// OSLog-backed output so messages surface in Console.app with a
/// well-known subsystem (`fr.bigbrother.app`) and a file-derived
/// category. Messages are emitted at `.notice` level (persisted to
/// disk, visible in Console by default) to match `NSLog`'s prior
/// behavior. Interpolated values are marked `.public` so they aren't
/// redacted as `<private>` in logs — this matches the prior `NSLog`
/// visibility and is appropriate because we log operational state
/// (device IDs, modes, timestamps), not user PII.
public func BBLog(_ message: String, file: String = #fileID) {
    BBLogRegistry.logger(for: file).notice("\(message, privacy: .public)")
}

/// Error-level variant for paths that signal a real failure.
/// Distinct from `BBLog` so Console filtering by "Errors" surfaces
/// just the real problems rather than every notice-level line.
public func BBLogError(_ message: String, file: String = #fileID) {
    BBLogRegistry.logger(for: file).error("\(message, privacy: .public)")
}

/// Caches one `Logger` per `#fileID` so we don't allocate a new
/// `os.Logger` on every call while still keeping per-file categories
/// for easy filtering in Console.
enum BBLogRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Logger] = [:]

    static func logger(for fileID: String) -> Logger {
        let category = BBLogRegistry.categoryFromFileID(fileID)
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[category] { return existing }
        let created = Logger(subsystem: "fr.bigbrother.app", category: category)
        cache[category] = created
        return created
    }

    /// `#fileID` looks like "BigBrotherCore/BBLog.swift" — reduce to "BBLog"
    /// so Console's category column stays readable.
    private static func categoryFromFileID(_ fileID: String) -> String {
        let last = (fileID as NSString).lastPathComponent
        if last.hasSuffix(".swift") {
            return String(last.dropLast(6))
        }
        return last
    }
}
