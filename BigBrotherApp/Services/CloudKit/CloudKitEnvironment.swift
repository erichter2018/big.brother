import Foundation
import CloudKit
import BigBrotherCore

/// Validates CloudKit environment availability and iCloud account status.
///
/// Used on app launch to detect and surface CloudKit-related issues
/// before attempting any sync or CRUD operations.
enum CloudKitEnvironment {

    /// Result of environment validation.
    enum Status: Equatable {
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case unknown(String)
    }

    /// Check iCloud account status on this device.
    /// Returns `.available` if the user is signed in and CloudKit is usable.
    /// Times out after 5 seconds to prevent blocking app launch (e.g., in Simulator).
    static func checkAccountStatus() async -> Status {
        do {
            return try await withThrowingTaskGroup(of: Status.self) { group in
                group.addTask {
                    let status = try await CKContainer(
                        identifier: AppConstants.cloudKitContainerIdentifier
                    ).accountStatus()

                    switch status {
                    case .available:
                        return .available
                    case .noAccount:
                        return .noAccount
                    case .restricted:
                        return .restricted
                    case .temporarilyUnavailable:
                        return .temporarilyUnavailable
                    case .couldNotDetermine:
                        return .unknown("Could not determine iCloud account status")
                    @unknown default:
                        return .unknown("Unknown iCloud account status")
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    return .unknown("CloudKit check timed out")
                }
                guard let first = try await group.next() else {
                    return .unknown("CloudKit check returned no result")
                }
                group.cancelAll()
                return first
            }
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Human-readable description of the CloudKit status for diagnostics/UI.
    static func statusDescription(_ status: Status) -> String {
        switch status {
        case .available:
            return "iCloud account available"
        case .noAccount:
            return "No iCloud account signed in. Sign in via Settings > Apple ID."
        case .restricted:
            return "iCloud is restricted on this device (parental controls or MDM)."
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable. Try again later."
        case .unknown(let detail):
            return "iCloud status unknown: \(detail)"
        }
    }

    /// Verify the CloudKit container is reachable by performing a lightweight operation.
    /// Returns true if the container responded successfully.
    static func verifyContainerReachable() async -> Bool {
        let container = CKContainer(identifier: AppConstants.cloudKitContainerIdentifier)
        do {
            _ = try await container.publicCloudDatabase.allSubscriptions()
            return true
        } catch {
            return false
        }
    }
}
