import Testing
import Foundation
@testable import BigBrotherCore

/// Tests verifying deployment configuration constants and shared storage assumptions.
///
/// These tests validate that identifiers, keys, and storage file conventions
/// are consistent and properly defined. They catch configuration drift that
/// could cause build or runtime failures on physical devices.
@Suite("Deployment Readiness")
struct DeploymentReadinessTests {

    // MARK: - App Constants

    @Test("App Group identifier is correctly formatted")
    func appGroupIdentifier() {
        #expect(AppConstants.appGroupIdentifier == "group.fr.bigbrother.shared")
        #expect(AppConstants.appGroupIdentifier.hasPrefix("group."))
    }

    @Test("CloudKit container identifier is correctly formatted")
    func cloudKitContainerIdentifier() {
        #expect(AppConstants.cloudKitContainerIdentifier == "iCloud.fr.bigbrother.app")
        #expect(AppConstants.cloudKitContainerIdentifier.hasPrefix("iCloud."))
    }

    @Test("Keychain access group is correctly formatted")
    func keychainAccessGroup() {
        #expect(AppConstants.keychainAccessGroup == "fr.bigbrother.shared")
    }

    @Test("Bundle identifiers follow expected hierarchy")
    func bundleIdentifierHierarchy() {
        let app = AppConstants.appBundleID
        #expect(app == "fr.bigbrother.app")
        #expect(AppConstants.monitorBundleID == "\(app).monitor")
        #expect(AppConstants.shieldBundleID == "\(app).shield")
        #expect(AppConstants.shieldActionBundleID == "\(app).shield-action")
    }

    @Test("ManagedSettings store names are distinct")
    func managedSettingsStoreNames() {
        let names = [
            AppConstants.managedSettingsStoreBase,
            AppConstants.managedSettingsStoreSchedule,
            AppConstants.managedSettingsStoreTempUnlock,
        ]
        #expect(Set(names).count == 3, "Store names must be unique")
    }

    // MARK: - Storage Keys

    @Test("Keychain keys use consistent prefix")
    func keychainKeyPrefixes() {
        let keychainKeys = [
            StorageKeys.deviceRole,
            StorageKeys.enrollmentState,
            StorageKeys.parentState,
            StorageKeys.parentPINHash,
            StorageKeys.familyID,
            StorageKeys.pinLockoutState,
        ]
        for key in keychainKeys {
            #expect(key.hasPrefix("fr.bigbrother.keychain."), "Keychain key '\(key)' missing prefix")
        }
    }

    @Test("UserDefaults keys use consistent prefix")
    func userDefaultsKeyPrefixes() {
        let udKeys = [
            StorageKeys.onboardingCompleted,
            StorageKeys.lastAppliedMode,
            StorageKeys.enforcementLastAppliedAt,
            StorageKeys.failSafeApplied,
        ]
        for key in udKeys {
            #expect(key.hasPrefix("fr.bigbrother."), "UserDefaults key '\(key)' missing prefix")
        }
    }

    // MARK: - Shared Storage File Consistency

    @Test("All AppGroupStorage files can be written and read")
    func storageFileRoundTrips() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = AppGroupStorage(containerURL: tempDir)

        // Policy snapshot
        let policy = EffectivePolicy(resolvedMode: .dailyMode, policyVersion: 1)
        let snapshot = PolicySnapshot(source: .initial, effectivePolicy: policy)
        try storage.writePolicySnapshot(snapshot)
        #expect(storage.readPolicySnapshot() != nil)

        // Shield config
        let config = ShieldConfig(title: "Test", message: "Msg")
        try storage.writeShieldConfiguration(config)
        #expect(storage.readShieldConfiguration()?.title == "Test")

        // Extension shared state
        let extState = ExtensionSharedState(
            currentMode: .essentialOnly,
            isTemporaryUnlock: false,
            authorizationAvailable: true,
            enforcementDegraded: false,
            shieldConfig: config,
            policyVersion: 1
        )
        try storage.writeExtensionSharedState(extState)
        #expect(storage.readExtensionSharedState()?.currentMode == .essentialOnly)

        // Authorization health
        let auth = AuthorizationHealth.unknown.withTransition(to: .authorized)
        try storage.writeAuthorizationHealth(auth)
        #expect(storage.readAuthorizationHealth()?.isAuthorized == true)

        // Heartbeat status
        let hb = HeartbeatStatus.initial.recordingSuccess()
        try storage.writeHeartbeatStatus(hb)
        #expect(storage.readHeartbeatStatus()?.isHealthy == true)

        // Temporary unlock state
        let tempUnlock = TemporaryUnlockState(
            origin: .localPINUnlock,
            previousMode: .dailyMode,
            expiresAt: Date().addingTimeInterval(1800)
        )
        try storage.writeTemporaryUnlockState(tempUnlock)
        #expect(storage.readTemporaryUnlockState()?.previousMode == .dailyMode)

        // Diagnostic entry
        let diag = DiagnosticEntry(category: .enforcement, message: "test")
        try storage.appendDiagnosticEntry(diag)
        #expect(storage.readDiagnosticEntries(category: nil).count == 1)
    }

    // MARK: - Extension Read Path

    @Test("Extension reads same data that app writes")
    func extensionReadPathConsistency() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Simulate app writing
        let appStorage = AppGroupStorage(containerURL: tempDir)
        let extState = ExtensionSharedState(
            currentMode: .essentialOnly,
            isTemporaryUnlock: false,
            authorizationAvailable: true,
            enforcementDegraded: false,
            shieldConfig: ShieldConfig(title: "Shield", message: "Blocked"),
            policyVersion: 42
        )
        try appStorage.writeExtensionSharedState(extState)

        // Simulate extension reading (same container URL)
        let extensionStorage = AppGroupStorage(containerURL: tempDir)
        let readState = extensionStorage.readExtensionSharedState()
        #expect(readState != nil)
        #expect(readState?.currentMode == .essentialOnly)
        #expect(readState?.policyVersion == 42)
        #expect(readState?.shieldConfig.title == "Shield")
    }

    // MARK: - Configuration Sanity

    @Test("Heartbeat interval is reasonable")
    func heartbeatInterval() {
        #expect(AppConstants.heartbeatIntervalSeconds >= 60, "Heartbeat too frequent")
        #expect(AppConstants.heartbeatIntervalSeconds <= 600, "Heartbeat too infrequent")
    }

    @Test("PIN lockout duration is reasonable")
    func pinLockoutDuration() {
        #expect(AppConstants.pinLockoutDurationSeconds >= 60, "Lockout too short")
        #expect(AppConstants.pinLockoutDurationSeconds <= 3600, "Lockout too long")
    }

    @Test("Event queue max size is bounded")
    func eventQueueBounds() {
        #expect(AppConstants.eventQueueMaxSize >= 100)
        #expect(AppConstants.eventQueueMaxSize <= 10000)
    }

    @Test("Command expiry is 24 hours")
    func commandExpiry() {
        #expect(AppConstants.defaultCommandExpirySeconds == 86400)
    }

    @Test("Enrollment code length matches character set entropy")
    func enrollmentCodeEntropy() {
        let charCount = Defaults.enrollmentCodeCharacterSet.count
        let codeLength = AppConstants.enrollmentCodeLength
        // Minimum entropy: 30^8 ≈ 6.5 × 10^11 (660 billion combinations)
        let combinations = pow(Double(charCount), Double(codeLength))
        #expect(combinations > 1e11, "Enrollment code space too small")
    }
}
