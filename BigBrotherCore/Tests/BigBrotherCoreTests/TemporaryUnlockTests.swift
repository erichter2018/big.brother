import Testing
@testable import BigBrotherCore
import Foundation

@Suite("Temporary Unlock")
struct TemporaryUnlockTests {

    let deviceID = DeviceID.generate()
    let familyID = FamilyID.generate()

    private func makeCapabilities(authorized: Bool = true) -> DeviceCapabilities {
        DeviceCapabilities(familyControlsAuthorized: authorized, isOnline: true)
    }

    @Test("Active temporary unlock resolves to unlocked")
    func activeTempUnlock() {
        let future = Date().addingTimeInterval(1800)
        let policy = Policy(
            targetDeviceID: deviceID,
            mode: .fullLockdown,
            temporaryUnlockUntil: future
        )

        let effective = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: nil,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities()
        )

        #expect(effective.resolvedMode == .unlocked)
        #expect(effective.isTemporaryUnlock)
        #expect(effective.temporaryUnlockExpiresAt == future)
        #expect(effective.shieldedCategoriesData == nil) // no shielding
    }

    @Test("Expired temporary unlock falls to base mode")
    func expiredTempUnlock() {
        let past = Date().addingTimeInterval(-60)
        let policy = Policy(
            targetDeviceID: deviceID,
            mode: .fullLockdown,
            temporaryUnlockUntil: past
        )

        let effective = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: nil,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities()
        )

        #expect(effective.resolvedMode == .fullLockdown)
        #expect(!effective.isTemporaryUnlock)
        #expect(effective.temporaryUnlockExpiresAt == nil)
    }

    @Test("Temporary unlock overrides schedule")
    func tempUnlockOverridesSchedule() {
        let future = Date().addingTimeInterval(1800)
        let policy = Policy(
            targetDeviceID: deviceID,
            mode: .dailyMode,
            temporaryUnlockUntil: future
        )

        // Create a schedule that would normally apply.
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let schedule = Schedule(
            childProfileID: ChildProfileID.generate(),
            familyID: familyID,
            name: "Test",
            mode: .fullLockdown,
            daysOfWeek: Set(DayOfWeek.allCases),
            startTime: DayTime(hour: max(0, hour - 1), minute: 0),
            endTime: DayTime(hour: min(23, hour + 1), minute: 59)
        )

        let effective = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: schedule,
            currentTime: now,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities()
        )

        // Temp unlock wins over schedule.
        #expect(effective.resolvedMode == .unlocked)
        #expect(effective.isTemporaryUnlock)
    }

    @Test("EffectivePolicy temp unlock persists through snapshot")
    func snapshotRoundtrip() throws {
        let future = Date().addingTimeInterval(1800)
        let effective = EffectivePolicy(
            resolvedMode: .unlocked,
            isTemporaryUnlock: true,
            temporaryUnlockExpiresAt: future,
            policyVersion: 5
        )
        let snapshot = PolicySnapshot(effectivePolicy: effective)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PolicySnapshot.self, from: data)

        #expect(decoded.effectivePolicy.isTemporaryUnlock)
        #expect(decoded.effectivePolicy.temporaryUnlockExpiresAt != nil)
        #expect(abs(decoded.effectivePolicy.temporaryUnlockExpiresAt!.timeIntervalSince(future)) < 0.01)
    }
}
