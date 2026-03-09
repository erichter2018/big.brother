import Foundation

/// Outcome of processing a single remote command.
/// Used for logging, receipt posting, and diagnostics.
public enum CommandProcessingResult: Sendable, Equatable {
    /// Command was successfully applied to enforcement.
    case applied

    /// Command was already processed (deduplication).
    case ignoredDuplicate

    /// Command had expired before processing.
    case ignoredExpired

    /// Command failed validation (malformed, wrong target, etc).
    case failedValidation(reason: String)

    /// Command passed validation but execution failed.
    case failedExecution(reason: String)

    /// Whether this result should generate a CloudKit receipt.
    public var shouldPostReceipt: Bool {
        switch self {
        case .applied, .failedValidation, .failedExecution:
            return true
        case .ignoredDuplicate, .ignoredExpired:
            return false
        }
    }

    /// The CommandStatus to record in the receipt.
    public var receiptStatus: CommandStatus? {
        switch self {
        case .applied: return .applied
        case .failedValidation, .failedExecution: return .failed
        case .ignoredExpired: return .expired
        case .ignoredDuplicate: return nil
        }
    }

    /// Human-readable reason for logging.
    public var logReason: String {
        switch self {
        case .applied: return "Applied successfully"
        case .ignoredDuplicate: return "Ignored: duplicate"
        case .ignoredExpired: return "Ignored: expired"
        case .failedValidation(let reason): return "Validation failed: \(reason)"
        case .failedExecution(let reason): return "Execution failed: \(reason)"
        }
    }
}
