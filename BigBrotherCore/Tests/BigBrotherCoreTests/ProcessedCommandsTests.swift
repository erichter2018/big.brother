import Testing
@testable import BigBrotherCore
import Foundation

@Suite("Processed Commands Storage")
struct ProcessedCommandsTests {

    private func makeStorage() throws -> AppGroupStorage {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return AppGroupStorage(containerURL: tempDir)
    }

    @Test("Mark and read processed command IDs")
    func markAndRead() throws {
        let storage = try makeStorage()
        let id1 = UUID()
        let id2 = UUID()

        try storage.markCommandProcessed(id1)
        try storage.markCommandProcessed(id2)

        let ids = storage.readProcessedCommandIDs()
        #expect(ids.contains(id1))
        #expect(ids.contains(id2))
        #expect(ids.count == 2)
    }

    @Test("Duplicate marking is idempotent")
    func idempotent() throws {
        let storage = try makeStorage()
        let id = UUID()

        try storage.markCommandProcessed(id)
        try storage.markCommandProcessed(id)
        try storage.markCommandProcessed(id)

        let ids = storage.readProcessedCommandIDs()
        #expect(ids.count == 1)
    }

    @Test("Pruning removes old entries")
    func pruning() throws {
        let storage = try makeStorage()

        let id1 = UUID()
        let id2 = UUID()

        try storage.markCommandProcessed(id1)
        try storage.markCommandProcessed(id2)

        // Prune everything older than 1 second from now (in the future)
        // Since entries were just created, pruning with a future cutoff removes all.
        let futureCutoff = Date().addingTimeInterval(1)
        try storage.pruneProcessedCommands(olderThan: futureCutoff)

        let ids = storage.readProcessedCommandIDs()
        #expect(ids.isEmpty)
    }

    @Test("Empty storage returns empty set")
    func emptyStorage() throws {
        let storage = try makeStorage()
        #expect(storage.readProcessedCommandIDs().isEmpty)
    }
}
