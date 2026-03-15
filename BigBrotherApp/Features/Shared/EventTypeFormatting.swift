import BigBrotherCore

/// User-friendly display names for event types.
extension EventType {
    var displayName: String {
        switch self {
        case .modeChanged: "Mode Changed"
        case .commandApplied: "Command Applied"
        case .commandFailed: "Command Failed"
        case .localPINUnlock: "Local PIN Unlock"
        case .enrollmentCompleted: "Enrollment Completed"
        case .enrollmentRevoked: "Enrollment Revoked"
        case .familyControlsAuthChanged: "Permissions Changed"
        case .heartbeatSent: "Heartbeat Sent"
        case .deviceOffline: "Device Offline"
        case .scheduleTriggered: "Schedule Started"
        case .scheduleEnded: "Schedule Ended"
        case .temporaryUnlockExpired: "Temp Unlock Expired"
        case .appLaunchBlocked: "App Blocked"
        case .policyReconciled: "Policy Reconciled"
        case .authorizationLost: "Authorization Lost"
        case .authorizationRestored: "Authorization Restored"
        case .temporaryUnlockStarted: "Temp Unlock Started"
        case .enforcementDegraded: "Enforcement Degraded"
        case .unlockRequested: "Unlock Requested"
        }
    }
}
