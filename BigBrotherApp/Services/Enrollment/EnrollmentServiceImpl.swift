import Foundation
import BigBrotherCore
#if canImport(UIKit)
import UIKit
#endif

/// Concrete enrollment service. Handles the full lifecycle:
/// - Parent creates enrollment invites
/// - Child redeems codes and registers devices
/// - Unenrollment cleanup
final class EnrollmentServiceImpl: EnrollmentServiceProtocol {

    private let cloudKit: any CloudKitServiceProtocol
    private let keychain: any KeychainProtocol
    private let storage: any SharedStorageProtocol

    init(
        cloudKit: any CloudKitServiceProtocol,
        keychain: any KeychainProtocol = KeychainManager(),
        storage: any SharedStorageProtocol = AppGroupStorage()
    ) {
        self.cloudKit = cloudKit
        self.keychain = keychain
        self.storage = storage
    }

    // MARK: - EnrollmentServiceProtocol

    func createInvite(
        for childProfileID: ChildProfileID,
        familyID: FamilyID
    ) async throws -> EnrollmentInvite {
        let code = CodeGenerator.generate()

        // Read the parent's command signing public key to deliver to the enrolling device.
        // SECURITY: Never include the private key in CloudKit records.
        // Each parent generates their own keypair; children trust multiple public keys.
        let publicKeyBase64: String? = {
            guard let pubKeyData = try? keychain.getData(forKey: StorageKeys.commandSigningPublicKey) else { return nil }
            return pubKeyData.base64EncodedString()
        }()

        let invite = EnrollmentInvite(
            code: code,
            familyID: familyID,
            childProfileID: childProfileID,
            commandSigningPublicKeyBase64: publicKeyBase64
        )
        try await cloudKit.saveEnrollmentInvite(invite)
        return invite
    }

    func validateCode(_ code: String) async throws -> EnrollmentInvite? {
        let normalized = code.uppercased().trimmingCharacters(in: .whitespaces)
        guard let invite = try await cloudKit.fetchEnrollmentInvite(code: normalized) else {
            return nil
        }
        return invite.isValid ? invite : nil
    }

    func completeEnrollment(
        invite: EnrollmentInvite,
        deviceDisplayName: String,
        modelIdentifier: String,
        osVersion: String
    ) async throws -> ChildEnrollmentState {
        let deviceID = DeviceID.generate()

        // Create device record in CloudKit.
        let device = ChildDevice(
            id: deviceID,
            childProfileID: invite.childProfileID,
            familyID: invite.familyID,
            displayName: deviceDisplayName,
            modelIdentifier: modelIdentifier,
            osVersion: osVersion
        )
        // Mark the invite as used BEFORE creating the device to prevent race conditions
        // where two devices could enroll with the same code simultaneously.
        // Best-effort because child can't modify parent-created records in CloudKit
        // public database due to ownership restrictions.
        try? await cloudKit.markInviteUsed(code: invite.code, deviceID: deviceID)

        try await cloudKit.saveDevice(device)

        // Persist enrollment state to Keychain.
        let enrollment = ChildEnrollmentState(
            deviceID: deviceID,
            childProfileID: invite.childProfileID,
            familyID: invite.familyID
        )
        try keychain.set(enrollment, forKey: StorageKeys.enrollmentState)
        try keychain.set(DeviceRole.child, forKey: StorageKeys.deviceRole)

        // Store familyID for extensions that need it.
        try keychain.set(invite.familyID, forKey: StorageKeys.familyID)

        // Store parent's command signing public key for signature verification.
        // Stored as a JSON array of base64 keys to support multiple parents.
        if let pubKeyBase64 = invite.commandSigningPublicKeyBase64 {
            var existingKeys: [String] = {
                guard let data = try? keychain.getData(forKey: StorageKeys.commandSigningPublicKey),
                      let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
                return keys
            }()
            if !existingKeys.contains(pubKeyBase64) {
                existingKeys.append(pubKeyBase64)
            }
            if let data = try? JSONEncoder().encode(existingKeys) {
                try? keychain.setData(data, forKey: StorageKeys.commandSigningPublicKey)
            }
        }

        // Cache enrollment IDs in App Group so extensions can create events
        // without Keychain access (which can fail in extension context).
        let cachedIDs = CachedEnrollmentIDs(deviceID: deviceID, familyID: invite.familyID)
        if let data = try? JSONEncoder().encode(cachedIDs) {
            try? AppGroupStorage().writeRawData(data, forKey: StorageKeys.cachedEnrollmentIDs)
        }

        return enrollment
    }

    func unenroll() async throws {
        // Read current enrollment before clearing.
        if let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) {
            // Delete device record from CloudKit (best effort).
            try? await cloudKit.deleteDevice(enrollment.deviceID)
        }

        // Clear Keychain state.
        try? keychain.delete(forKey: StorageKeys.enrollmentState)
        try? keychain.delete(forKey: StorageKeys.deviceRole)
        try? keychain.delete(forKey: StorageKeys.familyID)
        try? keychain.delete(forKey: StorageKeys.parentPINHash)
    }

    // MARK: - Device Info Helpers

    /// Get the current device's model identifier (e.g., "iPhone15,2").
    static var currentModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: systemInfo.machine)) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
    }

    /// Get a display name for this device.
    static var currentDeviceDisplayName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Unknown Device"
        #endif
    }

    /// Get the current OS version string.
    static var currentOSVersion: String {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
