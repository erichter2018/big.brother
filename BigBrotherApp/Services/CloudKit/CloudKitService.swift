import Foundation
import CloudKit
import BigBrotherCore

/// CloudKit operations for all record types.
///
/// Uses the public database with familyID-based partitioning.
/// All queries filter by familyID to scope records to this family.
protocol CloudKitServiceProtocol: Sendable {

    // MARK: - Child Profiles

    func fetchChildProfiles(familyID: FamilyID) async throws -> [ChildProfile]
    func saveChildProfile(_ profile: ChildProfile) async throws
    func deleteChildProfile(_ id: ChildProfileID) async throws

    // MARK: - Devices

    func fetchDevices(familyID: FamilyID) async throws -> [ChildDevice]
    func fetchDevices(childProfileID: ChildProfileID) async throws -> [ChildDevice]
    func saveDevice(_ device: ChildDevice) async throws
    func updateDeviceFields(deviceID: DeviceID, fields: [String: CKRecordValue?]) async throws
    func deleteDevice(_ id: DeviceID) async throws

    // MARK: - Commands

    func pushCommand(_ command: RemoteCommand) async throws
    func fetchPendingCommands(
        deviceID: DeviceID,
        childProfileID: ChildProfileID,
        familyID: FamilyID
    ) async throws -> [RemoteCommand]
    func fetchPendingModeCommands(familyID: FamilyID, target: CommandTarget) async throws -> [RemoteCommand]
    func updateCommandStatus(_ commandID: UUID, status: CommandStatus) async throws
    func deleteCommand(_ commandID: UUID) async throws
    func saveReceipt(_ receipt: CommandReceipt) async throws
    func fetchReceipts(familyID: FamilyID, since: Date) async throws -> [CommandReceipt]
    func fetchRecentCommands(familyID: FamilyID, since: Date) async throws -> [RemoteCommand]

    // MARK: - Enrollment

    func saveEnrollmentInvite(_ invite: EnrollmentInvite) async throws
    func fetchEnrollmentInvite(code: String) async throws -> EnrollmentInvite?
    func markInviteUsed(code: String, deviceID: DeviceID) async throws
    func fetchParentInvites(familyID: FamilyID) async throws -> [EnrollmentInvite]
    func revokeInvite(code: String) async throws

    // MARK: - Heartbeat

    func sendHeartbeat(_ heartbeat: DeviceHeartbeat) async throws
    func fetchLatestHeartbeats(familyID: FamilyID) async throws -> [DeviceHeartbeat]
    func fetchHeartbeats(familyID: FamilyID, since: Date) async throws -> [DeviceHeartbeat]

    // MARK: - Events

    /// Upload event log entries. Returns the set of event IDs that succeeded.
    @discardableResult
    func syncEventLogs(_ entries: [EventLogEntry]) async throws -> Set<UUID>
    func fetchEventLogs(familyID: FamilyID, since: Date) async throws -> [EventLogEntry]
    func fetchEventLogs(familyID: FamilyID, since: Date, types: Set<EventType>) async throws -> [EventLogEntry]
    func deleteEventLog(_ id: UUID) async throws

    // MARK: - Policy

    func savePolicy(_ policy: Policy) async throws
    func fetchPolicy(deviceID: DeviceID) async throws -> Policy?

    // MARK: - Schedules

    func fetchSchedules(childProfileID: ChildProfileID) async throws -> [Schedule]
    func fetchSchedules(familyID: FamilyID) async throws -> [Schedule]
    func saveSchedule(_ schedule: Schedule) async throws
    func deleteSchedule(_ id: UUID, familyID: FamilyID) async throws

    // MARK: - Heartbeat Profiles

    func fetchHeartbeatProfiles(familyID: FamilyID) async throws -> [HeartbeatProfile]
    func saveHeartbeatProfile(_ profile: HeartbeatProfile) async throws
    func deleteHeartbeatProfile(_ id: UUID) async throws

    // MARK: - Schedule Profiles

    func fetchScheduleProfiles(familyID: FamilyID) async throws -> [ScheduleProfile]
    func saveScheduleProfile(_ profile: ScheduleProfile) async throws
    func deleteScheduleProfile(_ id: UUID) async throws

    // MARK: - Location

    func saveLocationBreadcrumb(_ location: DeviceLocation) async throws
    func fetchLocationBreadcrumbs(deviceID: DeviceID, since: Date) async throws -> [DeviceLocation]
    func purgeLocationBreadcrumbs(deviceID: DeviceID, olderThan: Date) async throws

    // MARK: - Named Places

    func fetchNamedPlaces(familyID: FamilyID) async throws -> [NamedPlace]
    func saveNamedPlace(_ place: NamedPlace) async throws
    func deleteNamedPlace(_ id: UUID) async throws

    // MARK: - Diagnostic Reports

    func saveDiagnosticReport(_ report: DiagnosticReport) async throws
    func fetchDiagnosticReports(deviceID: DeviceID) async throws -> [DiagnosticReport]

    // MARK: - Time Limit Configs

    func fetchTimeLimitConfigs(childProfileID: ChildProfileID) async throws -> [TimeLimitConfig]
    func saveTimeLimitConfig(_ config: TimeLimitConfig) async throws
    func deleteTimeLimitConfig(_ id: UUID) async throws

    func fetchPendingAppReviews(childProfileID: ChildProfileID) async throws -> [PendingAppReview]
    func savePendingAppReview(_ review: PendingAppReview) async throws
    func deletePendingAppReview(_ id: UUID) async throws

    // MARK: - Cleanup

    /// Delete old records of the given type matching a predicate.
    /// Pass `limit` to cap the number of deletions per call (prevents quota spikes).
    func deleteRecords(type: String, predicate: NSPredicate, limit: Int?) async throws -> Int

    // MARK: - Subscriptions

    /// Set up CKQuerySubscriptions for near-real-time command delivery.
    func setupSubscriptions(familyID: FamilyID, deviceID: DeviceID?) async throws

    /// Fetch enforcement log entries for a family since a given date.
    func fetchEnforcementLogs(familyID: FamilyID, since: Date) async throws -> [CKRecord]
}

extension CloudKitServiceProtocol {
    /// Convenience overload without limit (deletes all matching records).
    func deleteRecords(type: String, predicate: NSPredicate) async throws -> Int {
        try await deleteRecords(type: type, predicate: predicate, limit: nil)
    }
}
