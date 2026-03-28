import Testing
@testable import BigBrotherCore
import Foundation

@Suite("PINHasher")
struct PINHasherTests {

    let hasher = PINHasher()

    @Test("Hash and verify correct PIN succeeds")
    func hashAndVerify() throws {
        let pin = "123456"
        let hash = try #require(hasher.hash(pin: pin))
        #expect(hasher.verify(pin: pin, against: hash))
    }

    @Test("Wrong PIN fails verification")
    func wrongPIN() throws {
        let hash = try #require(hasher.hash(pin: "123456"))
        #expect(!hasher.verify(pin: "654321", against: hash))
    }

    @Test("Empty PIN returns nil")
    func emptyPIN() throws {
        #expect(hasher.hash(pin: "") == nil)
        let dummyHash = try #require(hasher.hash(pin: "1234"))
        #expect(!hasher.verify(pin: "", against: dummyHash))
    }

    @Test("Different hashes for same PIN (random salt)")
    func differentSalts() throws {
        let pin = "123456"
        let hash1 = try #require(hasher.hash(pin: pin))
        let hash2 = try #require(hasher.hash(pin: pin))
        #expect(hash1.salt != hash2.salt)
        #expect(hash1.derivedKey != hash2.derivedKey)
        // But both should verify
        #expect(hasher.verify(pin: pin, against: hash1))
        #expect(hasher.verify(pin: pin, against: hash2))
    }

    @Test("Combined data roundtrip")
    func combinedRoundtrip() throws {
        let pin = "987654"
        let original = try #require(hasher.hash(pin: pin))
        let combined = original.combined

        guard let restored = PINHasher.PINHash(combined: combined) else {
            Issue.record("Failed to restore PINHash from combined data")
            return
        }

        #expect(restored.salt == original.salt)
        #expect(restored.derivedKey == original.derivedKey)
        #expect(hasher.verify(pin: pin, against: restored))
    }

    @Test("Invalid combined data returns nil")
    func invalidCombinedData() {
        let shortData = Data([0x01, 0x02, 0x03])
        #expect(PINHasher.PINHash(combined: shortData) == nil)
    }
}
