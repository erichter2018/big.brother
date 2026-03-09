import Foundation
import BigBrotherCore

/// Manages the device enrollment lifecycle.
///
/// Parent side:
/// - Create enrollment invites (generate code, save to CloudKit)
/// - View pending/used invites
///
/// Child side:
/// - Validate enrollment code
/// - Complete enrollment (register device, store state in Keychain)
/// - Request FamilyControls authorization
protocol EnrollmentServiceProtocol {
    /// Generate a new enrollment code for a child profile.
    /// Creates an EnrollmentInvite in CloudKit. Code valid for 30 minutes.
    func createInvite(for childProfileID: ChildProfileID, familyID: FamilyID) async throws -> EnrollmentInvite

    /// Validate an enrollment code entered on a child device.
    /// Returns the invite if valid (not expired, not used).
    func validateCode(_ code: String) async throws -> EnrollmentInvite?

    /// Complete enrollment on a child device.
    /// - Generates a DeviceID
    /// - Stores enrollment state in Keychain
    /// - Creates ChildDevice record in CloudKit
    /// - Marks the invite as used
    /// - Sets DeviceRole to .child
    func completeEnrollment(
        invite: EnrollmentInvite,
        deviceDisplayName: String,
        modelIdentifier: String,
        osVersion: String
    ) async throws -> ChildEnrollmentState

    /// Unenroll this device. Clears enforcement, Keychain state,
    /// and marks device as unenrolled in CloudKit.
    func unenroll() async throws
}
