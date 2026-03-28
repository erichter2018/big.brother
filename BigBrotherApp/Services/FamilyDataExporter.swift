import Foundation
import BigBrotherCore
import CloudKit

/// Exports all family data as JSON for GDPR data portability (Article 20).
enum FamilyDataExporter {

    struct FamilyExport: Codable {
        let exportedAt: Date
        let familyID: String
        let children: [ChildProfile]
        let devices: [ChildDevice]
        let heartbeats: [DeviceHeartbeat]
        let events: [EventLogEntry]
        let commands: [RemoteCommand]
        let schedules: [Schedule]
        let scheduleProfiles: [ScheduleProfile]
    }

    static func exportAllData(
        cloudKit: CloudKitServiceProtocol,
        familyID: FamilyID
    ) async throws -> Data {
        let children = try await cloudKit.fetchChildProfiles(familyID: familyID)
        let devices = try await cloudKit.fetchDevices(familyID: familyID)
        let heartbeats = try await cloudKit.fetchLatestHeartbeats(familyID: familyID)
        let events = try await cloudKit.fetchEventLogs(familyID: familyID, since: Date.distantPast)
        let commands = try await cloudKit.fetchRecentCommands(familyID: familyID, since: Date.distantPast)
        let schedules = try await cloudKit.fetchSchedules(familyID: familyID)
        let profiles = try await cloudKit.fetchScheduleProfiles(familyID: familyID)

        let export = FamilyExport(
            exportedAt: Date(),
            familyID: familyID.rawValue,
            children: children,
            devices: devices,
            heartbeats: heartbeats,
            events: events,
            commands: commands,
            schedules: schedules,
            scheduleProfiles: profiles
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }
}
