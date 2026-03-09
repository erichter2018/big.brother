import Testing
@testable import BigBrotherCore
import Foundation

@Suite("EnrollmentInvite")
struct EnrollmentInviteTests {

    let familyID = FamilyID.generate()
    let childID = ChildProfileID.generate()

    @Test("Valid invite before expiration")
    func validInvite() {
        let invite = EnrollmentInvite(
            code: "A3K9M2X7",
            familyID: familyID,
            childProfileID: childID
        )
        #expect(invite.isValid)
        #expect(!invite.isExpired)
        #expect(!invite.used)
    }

    @Test("Expired invite is not valid")
    func expiredInvite() {
        let past = Date().addingTimeInterval(-3600)
        let invite = EnrollmentInvite(
            code: "TESTCODE",
            familyID: familyID,
            childProfileID: childID,
            createdAt: past,
            expiresAt: past.addingTimeInterval(1800)
        )
        #expect(invite.isExpired)
        #expect(!invite.isValid)
    }

    @Test("Used invite is not valid")
    func usedInvite() {
        let invite = EnrollmentInvite(
            code: "USEDCODE",
            familyID: familyID,
            childProfileID: childID,
            used: true,
            usedByDeviceID: DeviceID.generate()
        )
        #expect(!invite.isValid)
        #expect(invite.used)
    }

    @Test("Custom expiry honored")
    func customExpiry() {
        let customExpiry = Date().addingTimeInterval(60) // 1 minute
        let invite = EnrollmentInvite(
            code: "SHORTEXP",
            familyID: familyID,
            childProfileID: childID,
            expiresAt: customExpiry
        )
        #expect(invite.isValid)
        #expect(invite.expiresAt == customExpiry)
    }

    @Test("Default expiry is 30 minutes")
    func defaultExpiry() {
        let now = Date()
        let invite = EnrollmentInvite(
            code: "DEFAULT1",
            familyID: familyID,
            childProfileID: childID,
            createdAt: now
        )
        let expected = now.addingTimeInterval(1800)
        #expect(abs(invite.expiresAt.timeIntervalSince(expected)) < 1)
    }
}
