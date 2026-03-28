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
        let hash = try #require(hasher.hash(pin: pin))
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
        let hash = try #require(hasher.hash(pin: "123456"))
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
        let hash1 = try #require(hasher.hash(pin: "111111"))
        try keychain.setData(hash1.combined, forKey: StorageKeys.parentPINHash)

        // Change PIN.
        let hash2 = try #require(hasher.hash(pin: "222222"))
        try keychain.setData(hash2.combined, forKey: StorageKeys.parentPINHash)

        // Old PIN should fail.
        let storedData = try keychain.getData(forKey: StorageKeys.parentPINHash)!
        let storedHash = PINHasher.PINHash(combined: storedData)!

        #expect(!hasher.verify(pin: "111111", against: storedHash))
        #expect(hasher.verify(pin: "222222", against: storedHash))
    }

    @Test("Short PINs work (4 digits)")
    func shortPIN() throws {
        let pin = "1234"
        let hash = try #require(hasher.hash(pin: pin))
        #expect(hasher.verify(pin: pin, against: hash))
    }

    @Test("Long PINs work (8 digits)")
    func longPIN() throws {
        let pin = "12345678"
        let hash = try #require(hasher.hash(pin: pin))
        #expect(hasher.verify(pin: pin, against: hash))
    }

    @Test("Empty PIN returns nil and fails verification")
    func emptyPIN() throws {
        #expect(hasher.hash(pin: "") == nil)
        #expect(!hasher.verify(pin: "", against: try #require(hasher.hash(pin: "1234"))))
    }
}
