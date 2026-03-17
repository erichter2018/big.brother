import Foundation
import Observation
import BigBrotherCore

struct ManagedAppControl: Identifiable {
    let appName: String
    let isAllowed: Bool

    var id: String {
        appName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Observable
final class DeviceDetailViewModel: CommandSendable {
    let appState: AppState
    var device: ChildDevice

    var isSendingCommand = false
    var commandFeedback: String?
    var isCommandError = false

    init(appState: AppState, device: ChildDevice) {
        self.appState = appState
        self.device = device
    }

    var heartbeat: DeviceHeartbeat? {
        appState.latestHeartbeats.first { $0.deviceID == device.id }
    }

    // MARK: - Actions (target this specific device)

    func setMode(_ mode: LockMode) async {
        await performCommand(.setMode(mode), target: .device(device.id))
    }

    func temporaryUnlock(seconds: Int = 24 * 3600) async {
        await performCommand(.temporaryUnlock(durationSeconds: seconds), target: .device(device.id))
    }

    func requestHeartbeat() async {
        await performCommand(.requestHeartbeat, target: .device(device.id))
    }

    func requestAppConfiguration() async {
        await performCommand(.requestAppConfiguration, target: .device(device.id))
    }

    /// Approved apps for this specific device.
    var approvedAppsForDevice: [ApprovedApp] {
        appState.approvedApps(for: device.id)
    }

    /// Managed apps reported by the child device's current picker selection.
    var managedApps: [ManagedAppControl] {
        guard let names = heartbeat?.blockedAppNames, !names.isEmpty else { return [] }

        let allowedNames = Set(approvedAppsForDevice.map(\.appName).map(Self.normalizeAppName))
        var uniqueNames: [String] = []
        var seen = Set<String>()

        for name in names {
            let normalized = Self.normalizeAppName(name)
            guard Self.isUsefulAppName(normalized), seen.insert(normalized).inserted else { continue }
            uniqueNames.append(name)
        }

        return uniqueNames
            .map { name in
                ManagedAppControl(
                    appName: name,
                    isAllowed: allowedNames.contains(Self.normalizeAppName(name))
                )
            }
            .sorted { lhs, rhs in
                if lhs.isAllowed != rhs.isAllowed {
                    return !lhs.isAllowed && rhs.isAllowed
                }
                return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
            }
    }

    /// Revoke a previously approved app on this device.
    func revokeApp(_ app: ApprovedApp) async {
        await blockManagedApp(named: app.appName)
    }

    func allowManagedApp(named appName: String) async {
        await performCommand(.allowManagedApp(appName: appName), target: .device(device.id))
        guard !isCommandError else { return }
        appState.addApprovedApp(ApprovedApp(
            id: UUID(),
            appName: appName,
            deviceID: device.id
        ))
    }

    func blockManagedApp(named appName: String) async {
        await performCommand(.blockManagedApp(appName: appName), target: .device(device.id))
        guard !isCommandError else { return }
        appState.removeApprovedApp(appName: appName, deviceID: device.id)
    }

    /// Assign (or clear) a heartbeat monitoring profile for this device.
    func assignProfile(_ profileID: UUID?) async {
        device.heartbeatProfileID = profileID

        do {
            try await appState.sendCommand(
                target: .device(device.id),
                action: .setHeartbeatProfile(profileID: profileID)
            )
            if let idx = appState.childDevices.firstIndex(where: { $0.id == device.id }) {
                appState.childDevices[idx].heartbeatProfileID = profileID
            }
        } catch {
            commandFeedback = "Failed to save profile: \(error.localizedDescription)"
            isCommandError = true
        }
    }

    /// Assign (or clear) a schedule profile for this device via remote command.
    func assignScheduleProfile(_ profileID: UUID?) async {
        let profileVersion: Date?
        if let profileID,
           let profile = appState.scheduleProfiles.first(where: { $0.id == profileID }) {
            profileVersion = profile.updatedAt
        } else {
            profileVersion = nil
        }
        device.scheduleProfileID = profileID
        device.scheduleProfileVersion = profileVersion

        do {
            if let profileID {
                try await appState.sendCommand(
                    target: .device(device.id),
                    action: .setScheduleProfile(profileID: profileID, versionDate: profileVersion ?? Date())
                )
            } else {
                try await appState.sendCommand(
                    target: .device(device.id),
                    action: .clearScheduleProfile
                )
            }
            if let idx = appState.childDevices.firstIndex(where: { $0.id == device.id }) {
                appState.childDevices[idx].scheduleProfileID = profileID
                appState.childDevices[idx].scheduleProfileVersion = profileVersion
            }
        } catch {
            commandFeedback = "Failed to save schedule profile: \(error.localizedDescription)"
            isCommandError = true
        }
    }

    /// Send unenroll command to the device, then delete the device record.
    func unenrollAndDeleteDevice() async {
        // Send unenroll command so the child device clears its local state.
        await performCommand(.unenroll, target: .device(device.id))

        // Delete the device record from CloudKit.
        guard let cloudKit = appState.cloudKit else { return }
        do {
            try await cloudKit.deleteDevice(device.id)
            appState.childDevices.removeAll { $0.id == device.id }
        } catch {
            commandFeedback = "Failed to delete device: \(error.localizedDescription)"
            isCommandError = true
        }
    }

    /// Delete the device record without sending an unenroll command.
    func deleteDevice() async {
        guard let cloudKit = appState.cloudKit else { return }
        do {
            try await cloudKit.deleteDevice(device.id)
            appState.childDevices.removeAll { $0.id == device.id }
        } catch {
            commandFeedback = "Failed to delete device: \(error.localizedDescription)"
            isCommandError = true
        }
    }

    func refresh() async {
        try? await appState.refreshDashboard()
        // Update local device reference.
        if let updated = appState.childDevices.first(where: { $0.id == device.id }) {
            device = updated
        }
    }

    private static func normalizeAppName(_ appName: String) -> String {
        appName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUsefulAppName(_ normalizedName: String) -> Bool {
        !normalizedName.isEmpty &&
        normalizedName != "app" &&
        normalizedName != "an app" &&
        normalizedName != "unknown" &&
        normalizedName != "unknown app" &&
        !normalizedName.hasPrefix("blocked app ") &&
        !normalizedName.contains("token(") &&
        !normalizedName.contains("data:") &&
        !normalizedName.contains("bytes)")
    }
}
