import Testing
@testable import BigBrotherCore
import Foundation

@Suite("PolicySnapshot Persistence")
struct PolicySnapshotTests {

    @Test("PolicySnapshot serialization roundtrip")
    func roundtrip() throws {
        let effective = EffectivePolicy(
            resolvedMode: .restricted,
            shieldedCategoriesData: Data(),
            allowedAppTokensData: Data([0x01, 0x02]),
            warnings: [.someSystemAppsCannotBeBlocked, .tokensMissingForDevice],
            policyVersion: 7
        )
        let profile = ChildProfile(
            familyID: FamilyID.generate(),
            name: "Simon"
        )
        let snapshot = PolicySnapshot(
            effectivePolicy: effective,
            childProfile: profile,
            writerVersion: 42
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PolicySnapshot.self, from: data)

        #expect(decoded.effectivePolicy.resolvedMode == .restricted)
        #expect(decoded.effectivePolicy.policyVersion == 7)
        #expect(decoded.effectivePolicy.warnings.count == 2)
        #expect(decoded.childProfile?.name == "Simon")
        #expect(decoded.writerVersion == 42)
    }

    @Test("PolicySnapshot write and read via storage")
    func fileRoundtrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = AppGroupStorage(containerURL: tempDir)

        let effective = EffectivePolicy(
            resolvedMode: .locked,
            warnings: [.familyControlsNotAuthorized],
            policyVersion: 3
        )
        let snapshot = PolicySnapshot(effectivePolicy: effective)

        try storage.writePolicySnapshot(snapshot)
        let read = storage.readPolicySnapshot()

        #expect(read != nil)
        #expect(read?.effectivePolicy.resolvedMode == .locked)
        #expect(read?.effectivePolicy.policyVersion == 3)
    }

    @Test("Reading non-existent snapshot returns nil")
    func missingSnapshot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = AppGroupStorage(containerURL: tempDir)
        #expect(storage.readPolicySnapshot() == nil)
    }

    @Test("Overwriting snapshot replaces previous")
    func overwrite() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = AppGroupStorage(containerURL: tempDir)

        let snap1 = PolicySnapshot(
            effectivePolicy: EffectivePolicy(resolvedMode: .unlocked, policyVersion: 1)
        )
        let snap2 = PolicySnapshot(
            effectivePolicy: EffectivePolicy(resolvedMode: .locked, policyVersion: 2)
        )

        try storage.writePolicySnapshot(snap1)
        try storage.writePolicySnapshot(snap2)

        let read = storage.readPolicySnapshot()
        #expect(read?.effectivePolicy.resolvedMode == .locked)
        #expect(read?.effectivePolicy.policyVersion == 2)
    }
}
