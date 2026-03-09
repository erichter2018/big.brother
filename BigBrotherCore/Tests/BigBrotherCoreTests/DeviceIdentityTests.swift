import Testing
@testable import BigBrotherCore
import Foundation

@Suite("Device Identity & Enrollment State")
struct DeviceIdentityTests {

    @Test("DeviceID generates unique values")
    func uniqueDeviceIDs() {
        let id1 = DeviceID.generate()
        let id2 = DeviceID.generate()
        #expect(id1 != id2)
    }

    @Test("ChildEnrollmentState persists through MockKeychain")
    func enrollmentPersistence() throws {
        let keychain = MockKeychain()
        let enrollment = ChildEnrollmentState(
            deviceID: DeviceID.generate(),
            childProfileID: ChildProfileID.generate(),
            familyID: FamilyID.generate()
        )

        try keychain.set(enrollment, forKey: StorageKeys.enrollmentState)

        let loaded = try keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        )
        #expect(loaded != nil)
        #expect(loaded?.deviceID == enrollment.deviceID)
        #expect(loaded?.childProfileID == enrollment.childProfileID)
        #expect(loaded?.familyID == enrollment.familyID)
    }

    @Test("Two devices with same Apple ID get distinct DeviceIDs")
    func distinctDevicesOnSameAppleID() throws {
        let familyID = FamilyID.generate()
        let childID = ChildProfileID.generate()

        // Simulate two devices enrolling under the same child profile.
        let device1 = ChildDevice(
            id: DeviceID.generate(),
            childProfileID: childID,
            familyID: familyID,
            displayName: "Simon's iPhone",
            modelIdentifier: "iPhone15,2",
            osVersion: "17.0.0"
        )
        let device2 = ChildDevice(
            id: DeviceID.generate(),
            childProfileID: childID,
            familyID: familyID,
            displayName: "Simon's iPad",
            modelIdentifier: "iPad14,1",
            osVersion: "17.0.0"
        )

        // Same child profile, different device IDs.
        #expect(device1.id != device2.id)
        #expect(device1.childProfileID == device2.childProfileID)
        #expect(device1.familyID == device2.familyID)
    }

    @Test("DeviceRole persists through MockKeychain")
    func rolePersistence() throws {
        let keychain = MockKeychain()

        try keychain.set(DeviceRole.child, forKey: StorageKeys.deviceRole)
        let loaded = try keychain.get(DeviceRole.self, forKey: StorageKeys.deviceRole)
        #expect(loaded == .child)

        try keychain.set(DeviceRole.parent, forKey: StorageKeys.deviceRole)
        let updated = try keychain.get(DeviceRole.self, forKey: StorageKeys.deviceRole)
        #expect(updated == .parent)
    }

    @Test("ParentState stores familyID correctly")
    func parentState() throws {
        let keychain = MockKeychain()
        let familyID = FamilyID.generate()
        let state = ParentState(familyID: familyID)

        try keychain.set(state, forKey: StorageKeys.parentState)
        let loaded = try keychain.get(ParentState.self, forKey: StorageKeys.parentState)

        #expect(loaded?.familyID == familyID)
    }

    @Test("Keychain delete removes value")
    func keychainDelete() throws {
        let keychain = MockKeychain()
        try keychain.set(DeviceRole.child, forKey: StorageKeys.deviceRole)
        #expect(keychain.contains(key: StorageKeys.deviceRole))

        try keychain.delete(forKey: StorageKeys.deviceRole)
        #expect(!keychain.contains(key: StorageKeys.deviceRole))
    }

    @Test("MockKeychain reset clears everything")
    func keychainReset() throws {
        let keychain = MockKeychain()
        try keychain.set(DeviceRole.child, forKey: StorageKeys.deviceRole)
        try keychain.set(FamilyID.generate(), forKey: StorageKeys.familyID)

        keychain.reset()

        #expect(!keychain.contains(key: StorageKeys.deviceRole))
        #expect(!keychain.contains(key: StorageKeys.familyID))
    }
}
