import Testing
@testable import BigBrotherCore
import Foundation

@Suite("PIN Verification Path")
struct PINVerificationPathTests {

    let hasher = PINHasher()

    @Test("PIN hash stored in keychain verifies correctly")
    func keychainRoundtrip() throws {
        let keychain = MockKeychain()
        let pin = "547832"

        // Hash and store.
        let hash = hasher.hash(pin: pin)
        try keychain.setData(hash.combined, forKey: StorageKeys.parentPINHash)

        // Retrieve and verify.
        let storedData = try keychain.getData(forKey: StorageKeys.parentPINHash)
        #expect(storedData != nil)

        let storedHash = PINHasher.PINHash(combined: storedData!)
        #expect(storedHash != nil)
        #expect(hasher.verify(pin: pin, against: storedHash!))
    }

    @Test("Wrong PIN fails verification through keychain")
    func wrongPINFromKeychain() throws {
        let keychain = MockKeychain()
        let hash = hasher.hash(pin: "123456")
        try keychain.setData(hash.combined, forKey: StorageKeys.parentPINHash)

        let storedData = try keychain.getData(forKey: StorageKeys.parentPINHash)!
        let storedHash = PINHasher.PINHash(combined: storedData)!

        #expect(!hasher.verify(pin: "654321", against: storedHash))
        #expect(!hasher.verify(pin: "000000", against: storedHash))
        #expect(!hasher.verify(pin: "123457", against: storedHash))
    }

    @Test("PIN change replaces old hash")
    func pinChange() throws {
        let keychain = MockKeychain()

        // Set initial PIN.
        let hash1 = hasher.hash(pin: "111111")
        try keychain.setData(hash1.combined, forKey: StorageKeys.parentPINHash)

        // Change PIN.
        let hash2 = hasher.hash(pin: "222222")
        try keychain.setData(hash2.combined, forKey: StorageKeys.parentPINHash)

        // Old PIN should fail.
        let storedData = try keychain.getData(forKey: StorageKeys.parentPINHash)!
        let storedHash = PINHasher.PINHash(combined: storedData)!

        #expect(!hasher.verify(pin: "111111", against: storedHash))
        #expect(hasher.verify(pin: "222222", against: storedHash))
    }

    @Test("Short PINs work (4 digits)")
    func shortPIN() {
        let pin = "1234"
        let hash = hasher.hash(pin: pin)
        #expect(hasher.verify(pin: pin, against: hash))
    }

    @Test("Long PINs work (8 digits)")
    func longPIN() {
        let pin = "12345678"
        let hash = hasher.hash(pin: pin)
        #expect(hasher.verify(pin: pin, against: hash))
    }

    @Test("Empty PIN doesn't crash")
    func emptyPIN() {
        let hash = hasher.hash(pin: "")
        #expect(hasher.verify(pin: "", against: hash))
        #expect(!hasher.verify(pin: "1", against: hash))
    }
}
