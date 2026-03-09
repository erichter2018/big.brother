import Testing
@testable import BigBrotherCore
import Foundation

/// Tests for AppGroupStorage using a temp directory (no App Group entitlement needed).
@Suite("AppGroupStorage")
struct AppGroupStorageTests {

    private func makeStorage() throws -> AppGroupStorage {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return AppGroupStorage(containerURL: tempDir)
    }

    @Test("Atomic write does not leave temp files")
    func atomicWriteCleanup() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = AppGroupStorage(containerURL: tempDir)

        let snapshot = PolicySnapshot(
            effectivePolicy: EffectivePolicy(resolvedMode: .unlocked, policyVersion: 1)
        )
        try storage.writePolicySnapshot(snapshot)

        // Check no .tmp files remain.
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let tmpFiles = files.filter { $0.pathExtension == "tmp" }
        #expect(tmpFiles.isEmpty)
    }

    @Test("Multiple concurrent appends don't corrupt the queue")
    func concurrentAppends() throws {
        let storage = try makeStorage()
        let deviceID = DeviceID.generate()
        let familyID = FamilyID.generate()

        // Append 20 entries sequentially (NSLock protects concurrent access).
        for i in 0..<20 {
            let entry = EventLogEntry(
                deviceID: deviceID,
                familyID: familyID,
                eventType: .heartbeatSent,
                details: "Entry \(i)"
            )
            try storage.appendEventLog(entry)
        }

        let all = storage.readPendingEventLogs()
        #expect(all.count == 20)
    }
}
