import Foundation

/// A command issued by a parent device, synced via CloudKit,
/// and processed by one or more child devices.
public struct RemoteCommand: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let familyID: FamilyID
    public let target: CommandTarget
    public let action: CommandAction
    /// Identifier of the parent device or name that issued this command.
    public let issuedBy: String
    public let issuedAt: Date
    /// Commands without explicit expiry default to 24 hours.
    public let expiresAt: Date?
    public var status: CommandStatus
    /// ED25519 signature (base64) over the canonical command payload.
    /// Set by the parent when sending mode commands. Verified by the child before applying.
    public var signatureBase64: String?

    public init(
        id: UUID = UUID(),
        familyID: FamilyID,
        target: CommandTarget,
        action: CommandAction,
        issuedBy: String,
        issuedAt: Date = Date(),
        expiresAt: Date? = nil,
        status: CommandStatus = .pending,
        signatureBase64: String? = nil
    ) {
        self.id = id
        self.familyID = familyID
        self.target = target
        self.action = action
        self.issuedBy = issuedBy
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt ?? issuedAt.addingTimeInterval(86400)
        self.status = status
        self.signatureBase64 = signatureBase64
    }
}

extension RemoteCommand: SignableCommand {}

/// What the command targets.
public enum CommandTarget: Codable, Sendable, Equatable {
    case device(DeviceID)
    case child(ChildProfileID)
    case allDevices
}

/// What the command does.
public enum CommandAction: Codable, Sendable, Equatable {
    case setMode(LockMode)
    case temporaryUnlock(durationSeconds: Int)
    case requestHeartbeat
    case requestAppConfiguration
    case unenroll
    /// Permanently allow a specific app that was requested via "Ask for More Time".
    /// The requestID references a pending unlock request stored on the child device.
    case allowApp(requestID: UUID)
    /// Permanently allow a specific app by its cached display name.
    /// The child resolves the app name back to a device-local ApplicationToken.
    case allowManagedApp(appName: String)
    /// Revoke a previously allowed app.
    case revokeApp(requestID: UUID)
    /// Re-block a managed app by its cached display name.
    /// The child resolves the app name back to a device-local ApplicationToken.
    case blockManagedApp(appName: String)
    /// Temporarily unlock a specific app for a limited time.
    /// The requestID references a pending unlock request stored on the child device.
    case temporaryUnlockApp(requestID: UUID, durationSeconds: Int)
    /// Set the display name for an app identified by its token fingerprint.
    /// Sent by the parent so the child's ShieldAction uses the correct name.
    case nameApp(fingerprint: String, name: String)
    /// Set device-level restrictions (app removal, explicit content, etc.).
    case setRestrictions(DeviceRestrictions)
    /// Revoke all allowed apps on the device (clears permanent + temporary allow lists).
    case revokeAllApps
    /// Open the always-allowed apps picker on the child device.
    case requestAlwaysAllowedSetup
    /// Unlock with penalty offset. Device stays locked for penaltySeconds first,
    /// then unlocks for (totalSeconds - penaltySeconds). If penalty is 0, unlocks immediately.
    case timedUnlock(totalSeconds: Int, penaltySeconds: Int)
    /// Clear any manual override and return to schedule-driven enforcement.
    /// If no schedule is assigned, defaults to dailyMode lock.
    case returnToSchedule
    /// Lock the device immediately and automatically return to schedule at the given date.
    /// The child registers a DeviceActivitySchedule to fire returnToSchedule at that time.
    case lockUntil(date: Date)
    /// Sync the parent PIN hash to child devices so local PIN unlock works.
    /// The base64 string is the PBKDF2 hash (salt + derived key combined).
    case syncPINHash(base64: String)
    /// Assign a schedule profile to this device. The child updates its own CloudKit record.
    case setScheduleProfile(profileID: UUID, versionDate: Date)
    /// Remove the schedule profile from this device.
    case clearScheduleProfile
    /// Set the daily self-unlock budget on this device.
    case setSelfUnlockBudget(count: Int)
    /// Set penalty timer data on this device.
    case setPenaltyTimer(seconds: Int?, endTime: Date?)
    /// Set the heartbeat monitoring profile on this device.
    case setHeartbeatProfile(profileID: UUID?)
    /// Set the list of allowed web domains (child applies via shield.webDomains).
    /// Empty array = block all web. nil domains in the array are ignored.
    case setAllowedWebDomains(domains: [String])
    /// Add a trusted command signing public key (base64).
    /// Sent by an existing parent when a new parent joins the family.
    /// The child appends it to their trusted keys list.
    case addTrustedSigningKey(publicKeyBase64: String)
    /// Send a text message from parent to child. Displayed as notification + persistent card.
    case sendMessage(text: String)
    /// Set the location tracking mode on this device (off, onDemand, continuous).
    case setLocationMode(LocationTrackingMode)
    /// Request the child device to report its current location immediately.
    case requestLocation
    /// Re-request all permissions (FamilyControls, Location). Used when parent has physical access to child device.
    case requestPermissions
    /// Set the home location for geofence-based app relaunch after force-quit.
    case setHomeLocation(latitude: Double, longitude: Double)
    /// Sync named places — child fetches from CloudKit and registers geofences.
    case syncNamedPlaces
    /// Request a diagnostic report — child collects state and uploads to CloudKit.
    case requestDiagnostics
    /// Enable or disable DNS-based safe search on the VPN tunnel.
    case setSafeSearch(enabled: Bool)
    /// Set driving safety settings (speed threshold, braking threshold, detection toggles).
    case setDrivingSettings(DrivingSettings)
    /// Block all internet traffic for a duration (seconds). 0 = unblock immediately.
    /// Handled directly by the VPN tunnel — works even when the main app is dead.
    case blockInternet(durationSeconds: Int)
    /// Open the time-limited apps picker on the child device.
    case requestTimeLimitSetup
    /// Grant extra time for an app that hit its daily limit.
    case grantExtraTime(appFingerprint: String, extraMinutes: Int)
    /// Remove a time limit from an app.
    case removeTimeLimit(appFingerprint: String)
    /// Block an app for the rest of today (mark as exhausted without waiting for threshold).
    case blockAppForToday(appFingerprint: String)

    // Thread-safe date formatting via Date.FormatStyle (replaces non-thread-safe static DateFormatter)

    /// Stable key for command deduplication. Unlike `displayDescription`, this is based
    /// on the enum case name and doesn't vary with parameter values, so two commands of
    /// the same type always collapse correctly.
    public var deduplicationKey: String {
        switch self {
        case .setMode: return "setMode"
        case .temporaryUnlock: return "temporaryUnlock"
        case .requestHeartbeat: return "requestHeartbeat"
        case .requestAppConfiguration: return "requestAppConfiguration"
        case .unenroll: return "unenroll"
        case .allowApp(let id): return "allowApp.\(id)"
        case .allowManagedApp(let name): return "allowManagedApp.\(name)"
        case .revokeApp(let id): return "revokeApp.\(id)"
        case .blockManagedApp(let name): return "blockManagedApp.\(name)"
        case .temporaryUnlockApp(let id, _): return "temporaryUnlockApp.\(id)"
        case .nameApp(let fp, _): return "nameApp.\(fp)"
        case .setRestrictions: return "setRestrictions"
        case .revokeAllApps: return "revokeAllApps"
        case .requestAlwaysAllowedSetup: return "requestAlwaysAllowedSetup"
        case .timedUnlock: return "timedUnlock"
        case .returnToSchedule: return "returnToSchedule"
        case .lockUntil: return "lockUntil"
        case .syncPINHash: return "syncPINHash"
        case .setScheduleProfile: return "setScheduleProfile"
        case .clearScheduleProfile: return "clearScheduleProfile"
        case .setSelfUnlockBudget: return "setSelfUnlockBudget"
        case .setPenaltyTimer: return "setPenaltyTimer"
        case .setHeartbeatProfile: return "setHeartbeatProfile"
        case .setAllowedWebDomains: return "setAllowedWebDomains"
        case .addTrustedSigningKey: return "addTrustedSigningKey"
        case .sendMessage: return "sendMessage"
        case .setLocationMode: return "setLocationMode"
        case .requestLocation: return "requestLocation"
        case .requestPermissions: return "requestPermissions"
        case .setHomeLocation: return "setHomeLocation"
        case .syncNamedPlaces: return "syncNamedPlaces"
        case .requestDiagnostics: return "requestDiagnostics"
        case .setSafeSearch: return "setSafeSearch"
        case .setDrivingSettings: return "setDrivingSettings"
        case .blockInternet: return "blockInternet"
        case .requestTimeLimitSetup: return "requestTimeLimitSetup"
        case .grantExtraTime(let fp, _): return "grantExtraTime.\(fp)"
        case .removeTimeLimit(let fp): return "removeTimeLimit.\(fp)"
        case .blockAppForToday(let fp): return "blockAppForToday.\(fp)"
        }
    }

    /// Whether this action changes the device-wide lock mode.
    /// Mode commands supersede each other — only the latest pending one matters.
    /// Per-app commands (allowApp, blockManagedApp, etc.) are NOT mode commands.
    public var isModeCommand: Bool {
        switch self {
        case .setMode, .temporaryUnlock, .timedUnlock, .lockUntil, .returnToSchedule:
            return true
        default:
            return false
        }
    }

    /// Human-readable description for UI feedback.
    public var displayDescription: String {
        switch self {
        case .setMode(let mode):
            return "Set mode to \(mode.displayName)"
        case .temporaryUnlock(let seconds):
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            let duration: String
            if hours > 0 && mins > 0 {
                duration = "\(hours)h \(mins)m"
            } else if hours > 0 {
                duration = "\(hours)h"
            } else if mins > 0 {
                duration = "\(mins)m"
            } else {
                duration = "\(seconds)s"
            }
            return "Temporary unlock (\(duration))"
        case .requestHeartbeat:
            return "Heartbeat request"
        case .requestAppConfiguration:
            return "App configuration request"
        case .unenroll:
            return "Unenroll"
        case .allowApp:
            return "Allow app permanently"
        case .allowManagedApp(let appName):
            return "Allow \(appName)"
        case .revokeApp:
            return "Revoke app access"
        case .blockManagedApp(let appName):
            return "Block \(appName)"
        case .temporaryUnlockApp(_, let seconds):
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            let duration: String
            if hours > 0 && mins > 0 {
                duration = "\(hours)h \(mins)m"
            } else if hours > 0 {
                duration = "\(hours)h"
            } else if mins > 0 {
                duration = "\(mins)m"
            } else {
                duration = "\(seconds)s"
            }
            return "Unlock app (\(duration))"
        case .nameApp(_, let name):
            return "Name app: \(name)"
        case .setRestrictions:
            return "Update device restrictions"
        case .revokeAllApps:
            return "Revoke all allowed apps"
        case .requestAlwaysAllowedSetup:
            return "Configure always-allowed apps"
        case .timedUnlock(let total, let penalty):
            let totalMin = total / 60
            let penaltyMin = penalty / 60
            return "Timed unlock (\(totalMin)m total, \(penaltyMin)m penalty)"
        case .returnToSchedule:
            return "Return to schedule"
        case .lockUntil(let date):
            return "Lock until \(date.formatted(.dateTime.hour().minute()))"
        case .syncPINHash:
            return "Sync parent PIN"
        case .setScheduleProfile:
            return "Set schedule profile"
        case .clearScheduleProfile:
            return "Clear schedule profile"
        case .setSelfUnlockBudget(let count):
            return "Set self-unlock budget to \(count)"
        case .setPenaltyTimer:
            return "Update penalty timer"
        case .setHeartbeatProfile:
            return "Set heartbeat profile"
        case .setAllowedWebDomains(let domains):
            return domains.isEmpty ? "Block all web" : "Allow \(domains.count) web domain(s)"
        case .addTrustedSigningKey:
            return "Add trusted parent key"
        case .sendMessage(let text):
            let preview = String(text.prefix(40))
            return "Message: \(preview)\(text.count > 40 ? "..." : "")"
        case .setLocationMode(let mode):
            return "Set location tracking to \(mode.rawValue)"
        case .requestLocation:
            return "Request current location"
        case .requestPermissions:
            return "Re-request all permissions"
        case .setHomeLocation:
            return "Set home geofence"
        case .syncNamedPlaces:
            return "Sync named places"
        case .setDrivingSettings(let s):
            return "Set driving safety (speed limit: \(Int(s.speedThresholdMPH)) mph)"
        case .blockInternet(let seconds):
            if seconds <= 0 { return "Unblock internet" }
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return h > 0 ? "Block internet (\(h)h \(m)m)" : "Block internet (\(m)m)"
        case .requestDiagnostics:
            return "Request diagnostic report"
        case .setSafeSearch(let enabled):
            return enabled ? "Enable safe search" : "Disable safe search"
        case .requestTimeLimitSetup:
            return "Set up app time limits"
        case .grantExtraTime(_, let mins):
            return "Grant \(mins) extra minutes"
        case .removeTimeLimit:
            return "Remove app time limit"
        case .blockAppForToday:
            return "Block app for today"
        }
    }
}

/// Duration options for the lock action menu.
public enum LockDuration: Sendable, Equatable {
    case untilMidnight
    case indefinite
    case hours(Int)
    case returnToSchedule
}

/// Monotonic status transitions: pending → delivered → applied | failed | expired.
/// A command never goes backward in status.
public enum CommandStatus: String, Codable, Sendable, Equatable {
    case pending
    case delivered
    case applied
    case failed
    case expired
}
