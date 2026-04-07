import Foundation

/// A structured log entry for an enforcement or system event.
/// Created locally (by app or extension), queued in App Group storage,
/// and synced to CloudKit when connectivity is available.
public struct EventLogEntry: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let deviceID: DeviceID
    public let familyID: FamilyID
    public let eventType: EventType
    public let details: String?
    public let timestamp: Date
    /// Upload lifecycle state for this entry.
    public var uploadState: EventUploadState

    /// Backward-compatible convenience property.
    public var synced: Bool { uploadState == .uploaded }

    public init(
        id: UUID = UUID(),
        deviceID: DeviceID,
        familyID: FamilyID,
        eventType: EventType,
        details: String? = nil,
        timestamp: Date = Date(),
        uploadState: EventUploadState = .pending
    ) {
        self.id = id
        self.deviceID = deviceID
        self.familyID = familyID
        self.eventType = eventType
        self.details = details
        self.timestamp = timestamp
        self.uploadState = uploadState
    }
}

// MARK: - Codable (backward-compatible with old `synced: Bool` format)

extension EventLogEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, deviceID, familyID, eventType, details, timestamp, uploadState, synced
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        deviceID = try container.decode(DeviceID.self, forKey: .deviceID)
        familyID = try container.decode(FamilyID.self, forKey: .familyID)
        eventType = try container.decode(EventType.self, forKey: .eventType)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        timestamp = try container.decode(Date.self, forKey: .timestamp)

        // Try new format first, fall back to old `synced: Bool`
        if let state = try? container.decode(EventUploadState.self, forKey: .uploadState) {
            uploadState = state
        } else if let wasSynced = try? container.decode(Bool.self, forKey: .synced) {
            uploadState = wasSynced ? .uploaded : .pending
        } else {
            uploadState = .pending
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(familyID, forKey: .familyID)
        try container.encode(eventType, forKey: .eventType)
        try container.encodeIfPresent(details, forKey: .details)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(uploadState, forKey: .uploadState)
    }
}

public enum EventType: String, Codable, Sendable, Equatable {
    case modeChanged
    case commandApplied
    case commandFailed
    case localPINUnlock
    case enrollmentCompleted
    case enrollmentRevoked
    case familyControlsAuthChanged
    case heartbeatSent
    case deviceOffline
    case scheduleTriggered
    case scheduleEnded
    case temporaryUnlockExpired
    case appLaunchBlocked
    case policyReconciled
    // Phase 2.5 additions
    case authorizationLost
    case authorizationRestored
    case temporaryUnlockStarted
    case enforcementDegraded
    case unlockRequested
    // Driving safety events
    case speedingDetected
    case phoneWhileDriving
    case hardBrakingDetected
    case namedPlaceArrival
    case namedPlaceDeparture
    case tripCompleted
    case sosAlert
    case selfUnlockUsed
    case newAppDetected
    // App time limits
    case timeLimitExhausted
    case timeLimitExtended
    case timeLimitSetupCompleted
    // DNS verification
    case appNameDeception
    case appNameVerified
}
