import Testing
@testable import BigBrotherCore
import Foundation

@Suite("PolicyResolver")
struct PolicyResolverTests {

    let deviceID = DeviceID.generate()
    let familyID = FamilyID.generate()
    let childProfileID = ChildProfileID.generate()

    private func makePolicy(
        mode: LockMode,
        temporaryUnlockUntil: Date? = nil,
        version: Int64 = 1
    ) -> Policy {
        Policy(
            targetDeviceID: deviceID,
            mode: mode,
            temporaryUnlockUntil: temporaryUnlockUntil,
            version: version
        )
    }

    private func makeCapabilities(
        authorized: Bool = true,
        online: Bool = true
    ) -> DeviceCapabilities {
        DeviceCapabilities(
            familyControlsAuthorized: authorized,
            isOnline: online
        )
    }

    // MARK: - Base Mode Resolution

    @Test("Unlocked mode resolves to unlocked")
    func unlockedMode() {
        let policy = makePolicy(mode: .unlocked)
        let result = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: nil,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities()
        )
        #expect(result.resolvedMode == .unlocked)
        #expect(result.shieldedCategoriesData == nil)
    }

    @Test("Full lockdown shields all categories")
    func fullLockdown() {
        let policy = makePolicy(mode: .fullLockdown)
        let result = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: nil,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities()
        )
        #expect(result.resolvedMode == .fullLockdown)
        #expect(result.shieldedCategoriesData == Data())
    }

    // MARK: - Temporary Unlock Priority

    @Test("Temporary unlock overrides base mode")
    func temporaryUnlockOverrides() {
        let future = Date().addingTimeInterval(1800)
        let policy = makePolicy(mode: .fullLockdown, temporaryUnlockUntil: future)
        let result = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: nil,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities()
        )
        #expect(result.resolvedMode == .unlocked)
        #expect(result.isTemporaryUnlock == true)
        #expect(result.temporaryUnlockExpiresAt == future)
    }

    @Test("Expired temporary unlock falls through to base mode")
    func expiredTemporaryUnlock() {
        let past = Date().addingTimeInterval(-60)
        let policy = makePolicy(mode: .fullLockdown, temporaryUnlockUntil: past)
        let result = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: nil,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities()
        )
        #expect(result.resolvedMode == .fullLockdown)
        #expect(result.isTemporaryUnlock == false)
    }

    // MARK: - Capability Warnings

    @Test("Warning when FamilyControls not authorized")
    func familyControlsWarning() {
        let policy = makePolicy(mode: .dailyMode)
        let result = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: nil,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities(authorized: false)
        )
        #expect(result.warnings.contains(.familyControlsNotAuthorized))
    }

    @Test("Warning when device is offline")
    func offlineWarning() {
        let policy = makePolicy(mode: .dailyMode)
        let result = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: nil,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities(online: false)
        )
        #expect(result.warnings.contains(.offlineUsingCachedPolicy))
    }

    // MARK: - Schedule Override

    @Test("Active schedule overrides base mode")
    func scheduleOverride() {
        let policy = makePolicy(mode: .unlocked)
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        _ = calendar.component(.minute, from: now)
        _ = calendar.component(.weekday, from: now)

        let schedule = Schedule(
            childProfileID: childProfileID,
            familyID: familyID,
            name: "Test Schedule",
            mode: .fullLockdown,
            daysOfWeek: Set(DayOfWeek.allCases),
            startTime: DayTime(hour: max(0, hour - 1), minute: 0),
            endTime: DayTime(hour: min(23, hour + 1), minute: 59)
        )

        let result = PolicyResolver.resolve(
            basePolicy: policy,
            schedule: schedule,
            currentTime: now,
            alwaysAllowedTokensData: nil,
            alwaysAllowedCategories: [],
            capabilities: makeCapabilities()
        )
        #expect(result.resolvedMode == .fullLockdown)
    }
}
