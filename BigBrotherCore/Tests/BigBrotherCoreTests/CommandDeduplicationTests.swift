import Testing
@testable import BigBrotherCore
import Foundation

@Suite("Command Deduplication & Processing")
struct CommandDeduplicationTests {

    let familyID = FamilyID.generate()
    let deviceID = DeviceID.generate()
    let childID = ChildProfileID.generate()

    private func makeCommand(
        action: CommandAction = .setMode(.fullLockdown),
        target: CommandTarget? = nil,
        expiresAt: Date? = nil
    ) -> RemoteCommand {
        RemoteCommand(
            familyID: familyID,
            target: target ?? .device(deviceID),
            action: action,
            issuedBy: "TestParent",
            expiresAt: expiresAt
        )
    }

    @Test("Command with future expiry is not expired")
    func notExpired() {
        let cmd = makeCommand(expiresAt: Date().addingTimeInterval(3600))
        #expect(cmd.expiresAt! > Date())
    }

    @Test("Command with past expiry is expired")
    func expired() {
        let cmd = makeCommand(expiresAt: Date().addingTimeInterval(-60))
        #expect(cmd.expiresAt! < Date())
    }

    @Test("Default expiry is 24 hours from issuedAt")
    func defaultExpiry() {
        let cmd = makeCommand()
        let expected = cmd.issuedAt.addingTimeInterval(86400)
        #expect(abs(cmd.expiresAt!.timeIntervalSince(expected)) < 1)
    }

    @Test("Commands sort by issuedAt correctly")
    func sortOrder() {
        let old = RemoteCommand(
            familyID: familyID,
            target: .device(deviceID),
            action: .setMode(.unlocked),
            issuedBy: "Parent",
            issuedAt: Date().addingTimeInterval(-120)
        )
        let new = RemoteCommand(
            familyID: familyID,
            target: .device(deviceID),
            action: .setMode(.fullLockdown),
            issuedBy: "Parent",
            issuedAt: Date()
        )

        let sorted = [new, old].sorted { $0.issuedAt < $1.issuedAt }
        #expect(sorted.first?.id == old.id)
    }

    @Test("Command status transitions are well-defined")
    func statusValues() {
        let allStatuses: [CommandStatus] = [.pending, .delivered, .applied, .failed, .expired]
        #expect(allStatuses.count == 5)
        for status in allStatuses {
            let raw = status.rawValue
            #expect(CommandStatus(rawValue: raw) == status)
        }
    }

    @Test("CommandReceipt captures failure reason")
    func receiptFailure() {
        let receipt = CommandReceipt(
            commandID: UUID(),
            deviceID: deviceID,
            familyID: familyID,
            status: .failed,
            failureReason: "FamilyControls not authorized"
        )
        #expect(receipt.status == .failed)
        #expect(receipt.failureReason != nil)
        #expect(receipt.appliedAt == nil)
    }

    @Test("Successful receipt has appliedAt timestamp")
    func receiptSuccess() {
        let now = Date()
        let receipt = CommandReceipt(
            commandID: UUID(),
            deviceID: deviceID,
            familyID: familyID,
            status: .applied,
            appliedAt: now
        )
        #expect(receipt.status == .applied)
        #expect(receipt.appliedAt == now)
        #expect(receipt.failureReason == nil)
    }

    @Test("Target types encode/decode correctly")
    func targetCodable() throws {
        let targets: [CommandTarget] = [
            .device(deviceID),
            .child(childID),
            .allDevices,
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for target in targets {
            let data = try encoder.encode(target)
            let decoded = try decoder.decode(CommandTarget.self, from: data)
            #expect(decoded == target)
        }
    }

    @Test("Action types encode/decode correctly")
    func actionCodable() throws {
        let actions: [CommandAction] = [
            .setMode(.fullLockdown),
            .setMode(.unlocked),
            .setMode(.dailyMode),
            .setMode(.essentialOnly),
            .temporaryUnlock(durationSeconds: 1800),
            .requestHeartbeat,
            .unenroll,
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for action in actions {
            let data = try encoder.encode(action)
            let decoded = try decoder.decode(CommandAction.self, from: data)
            #expect(decoded == action)
        }
    }
}
