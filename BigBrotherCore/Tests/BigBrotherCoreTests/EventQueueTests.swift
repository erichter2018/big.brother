import Testing
@testable import BigBrotherCore
import Foundation

@Suite("Event Queue Persistence")
struct EventQueueTests {

    let deviceID = DeviceID.generate()
    let familyID = FamilyID.generate()

    private func makeStorage() throws -> AppGroupStorage {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return AppGroupStorage(containerURL: tempDir)
    }

    @Test("Append and read event logs")
    func appendAndRead() throws {
        let storage = try makeStorage()

        let entry1 = EventLogEntry(
            deviceID: deviceID,
            familyID: familyID,
            eventType: .modeChanged,
            details: "Changed to fullLockdown"
        )
        let entry2 = EventLogEntry(
            deviceID: deviceID,
            familyID: familyID,
            eventType: .heartbeatSent
        )

        try storage.appendEventLog(entry1)
        try storage.appendEventLog(entry2)

        let pending = storage.readPendingEventLogs()
        #expect(pending.count == 2)
        #expect(pending[0].eventType == .modeChanged)
        #expect(pending[1].eventType == .heartbeatSent)
    }

    @Test("Clear synced logs removes only specified IDs")
    func clearSynced() throws {
        let storage = try makeStorage()

        let entry1 = EventLogEntry(deviceID: deviceID, familyID: familyID, eventType: .modeChanged)
        let entry2 = EventLogEntry(deviceID: deviceID, familyID: familyID, eventType: .heartbeatSent)
        let entry3 = EventLogEntry(deviceID: deviceID, familyID: familyID, eventType: .localPINUnlock)

        try storage.appendEventLog(entry1)
        try storage.appendEventLog(entry2)
        try storage.appendEventLog(entry3)

        // Clear only the first two.
        try storage.clearSyncedEventLogs(ids: [entry1.id, entry2.id])

        let remaining = storage.readPendingEventLogs()
        #expect(remaining.count == 1)
        #expect(remaining[0].id == entry3.id)
    }

    @Test("Empty queue returns empty array")
    func emptyQueue() throws {
        let storage = try makeStorage()
        #expect(storage.readPendingEventLogs().isEmpty)
    }

    @Test("Shield config roundtrip")
    func shieldConfig() throws {
        let storage = try makeStorage()

        let config = ShieldConfig(
            title: "Full Lockdown",
            message: "Everything is restricted.",
            showRequestButton: true
        )
        try storage.writeShieldConfiguration(config)

        let read = storage.readShieldConfiguration()
        #expect(read?.title == "Full Lockdown")
        #expect(read?.message == "Everything is restricted.")
        #expect(read?.showRequestButton == true)
    }
}
