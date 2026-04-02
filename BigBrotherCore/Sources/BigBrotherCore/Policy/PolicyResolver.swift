import Foundation

/// Pure policy resolution engine. No side effects, no framework dependencies.
///
/// Combines the base policy, active schedule, temporary unlock state,
/// always-allowed apps, and device capabilities to produce an EffectivePolicy.
///
/// Priority (highest to lowest):
///   1. Temporary unlock (if active and not expired) → .unlocked
///   2. Schedule override (if a schedule is active at current time) → schedule.mode
///   3. Base policy mode (the manually set mode) → policy.mode
///
/// Within any resolved mode, alwaysAllowed apps from the child profile
/// are merged in as exceptions to shielding.
public struct PolicyResolver {

    /// Resolve the effective policy from all inputs.
    ///
    /// - Parameters:
    ///   - basePolicy: The intended policy set by the parent.
    ///   - schedule: The active schedule, if any, for this child.
    ///   - currentTime: The current date/time (injected for testability).
    ///   - alwaysAllowedTokensData: Serialized device-local app tokens
    ///     that are always allowed regardless of mode.
    ///   - alwaysAllowedCategories: Category identifiers that are always allowed.
    ///   - capabilities: Current device capability state.
    ///
    /// - Returns: The resolved EffectivePolicy ready to be applied.
    public static func resolve(
        basePolicy: Policy,
        schedule: Schedule?,
        currentTime: Date = Date(),
        alwaysAllowedTokensData: Data?,
        alwaysAllowedCategories: Set<String>,
        capabilities: DeviceCapabilities,
        controlAuthority: ControlAuthority? = nil,
        deviceRestrictions: DeviceRestrictions? = nil
    ) -> EffectivePolicy {

        var warnings: [CapabilityWarning] = []
        var isTemporaryUnlock = false
        var temporaryUnlockExpiresAt: Date?

        // --- Step 1: Determine resolved mode ---

        let resolvedMode: LockMode

        // Priority 1: Temporary unlock
        if let tempUntil = basePolicy.temporaryUnlockUntil, tempUntil > currentTime {
            resolvedMode = .unlocked
            isTemporaryUnlock = true
            temporaryUnlockExpiresAt = tempUntil
        }
        // Priority 2: Active schedule
        else if let schedule, schedule.isActive,
                Self.isScheduleActive(schedule, at: currentTime) {
            resolvedMode = schedule.mode
        }
        // Priority 3: Base policy
        else {
            resolvedMode = basePolicy.mode
        }

        // --- Step 2: Compute shielding data ---

        let shieldedCategoriesData: Data?
        let allowedAppTokensData: Data?

        switch resolvedMode {
        case .unlocked:
            // No shielding at all.
            shieldedCategoriesData = nil
            allowedAppTokensData = nil

        case .restricted:
            // Shield all categories; allowed apps are the exceptions.
            shieldedCategoriesData = Data()
            allowedAppTokensData = alwaysAllowedTokensData

        case .locked, .lockedDown:
            // Shield all categories; essential + always-allowed are exceptions.
            // The actual essential token resolution happens in the enforcement layer
            // because it requires FamilyControls framework types.
            // lockedDown is identical shielding to essentialOnly (internet block is via VPN).
            shieldedCategoriesData = Data()
            allowedAppTokensData = alwaysAllowedTokensData
            warnings.append(.someSystemAppsCannotBeBlocked)
        }

        // --- Step 3: Capability warnings ---

        if !capabilities.familyControlsAuthorized {
            warnings.append(.familyControlsNotAuthorized)
        }

        if !capabilities.isOnline {
            warnings.append(.offlineUsingCachedPolicy)
        }

        if resolvedMode != .unlocked && alwaysAllowedTokensData == nil {
            warnings.append(.tokensMissingForDevice)
        }

        return EffectivePolicy(
            resolvedMode: resolvedMode,
            controlAuthority: controlAuthority,
            isTemporaryUnlock: isTemporaryUnlock,
            temporaryUnlockExpiresAt: temporaryUnlockExpiresAt,
            shieldedCategoriesData: shieldedCategoriesData,
            allowedAppTokensData: allowedAppTokensData,
            deviceRestrictions: deviceRestrictions,
            warnings: warnings,
            policyVersion: basePolicy.version,
            resolvedAt: currentTime
        )
    }

    // MARK: - Schedule Evaluation

    /// Determine whether a schedule is active at the given time.
    /// Supports both same-day (08:00–15:00) and cross-midnight (22:00–06:00) schedules.
    static func isScheduleActive(_ schedule: Schedule, at date: Date) -> Bool {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let now = DayTime(hour: hour, minute: minute)

        if schedule.startTime < schedule.endTime {
            // Same-day schedule (e.g., 08:00–15:00)
            guard let day = DayOfWeek(rawValue: weekday),
                  schedule.daysOfWeek.contains(day) else { return false }
            return now >= schedule.startTime && now < schedule.endTime
        } else {
            // Cross-midnight schedule (e.g., 22:00–06:00)
            guard let today = DayOfWeek(rawValue: weekday) else { return false }
            // Evening portion: check today's day
            if now >= schedule.startTime && schedule.daysOfWeek.contains(today) {
                return true
            }
            // Morning portion: check yesterday's day
            if now < schedule.endTime {
                guard let previousDate = calendar.date(byAdding: .day, value: -1, to: date),
                      let prevDay = DayOfWeek(rawValue: calendar.component(.weekday, from: previousDate)) else { return false }
                return schedule.daysOfWeek.contains(prevDay)
            }
            return false
        }
    }
}

/// Device capability state used by PolicyResolver to generate warnings.
public struct DeviceCapabilities: Codable, Sendable, Equatable {
    public let familyControlsAuthorized: Bool
    /// Always false for most system apps — provided for documentation.
    public let canBlockSystemApps: Bool
    public let isOnline: Bool

    public init(
        familyControlsAuthorized: Bool,
        canBlockSystemApps: Bool = false,
        isOnline: Bool = true
    ) {
        self.familyControlsAuthorized = familyControlsAuthorized
        self.canBlockSystemApps = canBlockSystemApps
        self.isOnline = isOnline
    }
}
