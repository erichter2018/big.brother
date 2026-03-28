import Foundation
import CloudKit

/// Converts CloudKit errors into user-friendly messages.
enum CloudKitErrorHelper {

    static func userMessage(for error: Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure:
                return "No internet connection. Check your network and try again."
            case .serviceUnavailable, .serverResponseLost:
                return "iCloud is temporarily unavailable. Try again in a moment."
            case .notAuthenticated:
                return "Sign in to iCloud in Settings to continue."
            case .quotaExceeded:
                return "iCloud storage is full. Free up space in Settings."
            case .requestRateLimited:
                return "Too many requests. Wait a moment and try again."
            case .zoneBusy:
                return "iCloud is busy. Try again in a moment."
            case .permissionFailure:
                return "iCloud permission denied. Check Settings > Apple ID > iCloud."
            case .unknownItem:
                return "Setting up — this may take a few seconds. Try again shortly."
            default:
                return "Something went wrong with iCloud. Try again."
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "No internet connection. Check your network and try again."
        }

        return "Something went wrong. Please try again."
    }
}
