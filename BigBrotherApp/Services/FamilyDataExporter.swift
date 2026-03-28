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
        let commandReceipts: [CommandReceipt]
        let schedules: [Schedule]
        let scheduleProfiles: [ScheduleProfile]
        let heartbeatProfiles: [HeartbeatProfile]
        let namedPlaces: [NamedPlace]
        let diagnosticReports: [DiagnosticReport]
        let enrollmentInvites: [EnrollmentInvite]
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
        let receipts = try await cloudKit.fetchReceipts(familyID: familyID, since: Date.distantPast)
        let schedules = try await cloudKit.fetchSchedules(familyID: familyID)
        let profiles = try await cloudKit.fetchScheduleProfiles(familyID: familyID)
        let heartbeatProfiles = try await cloudKit.fetchHeartbeatProfiles(familyID: familyID)
        let namedPlaces = try await cloudKit.fetchNamedPlaces(familyID: familyID)
        let invites = try await cloudKit.fetchParentInvites(familyID: familyID)

        // Diagnostic reports are per-device, so fetch for each known device.
        var allDiagnostics: [DiagnosticReport] = []
        for device in devices {
            if let reports = try? await cloudKit.fetchDiagnosticReports(deviceID: device.id) {
                allDiagnostics.append(contentsOf: reports)
            }
        }

        let export = FamilyExport(
            exportedAt: Date(),
            familyID: familyID.rawValue,
            children: children,
            devices: devices,
            heartbeats: heartbeats,
            events: events,
            commands: commands,
            commandReceipts: receipts,
            schedules: schedules,
            scheduleProfiles: profiles,
            heartbeatProfiles: heartbeatProfiles,
            namedPlaces: namedPlaces,
            diagnosticReports: allDiagnostics,
            enrollmentInvites: invites
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }
}
