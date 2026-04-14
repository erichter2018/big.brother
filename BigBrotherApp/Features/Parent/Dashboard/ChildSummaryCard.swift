import SwiftUI
import CoreLocation
import BigBrotherCore

/// Compact child card for the parent dashboard.
/// Glassmorphic card with avatar ring, status lines, and single contextual pill button.
struct ChildSummaryCard: View {
    let child: ChildProfile
    let devices: [ChildDevice]
    let heartbeats: [DeviceHeartbeat]
    let dominantMode: LockMode
    let isSending: Bool
    let countdown: String?
    let lockDownCountdown: String?
    let remainingSeconds: Int?
    let penaltyTimer: String?
    let isPenaltyRunning: Bool
    let selfUnlocksUsed: Int?
    let selfUnlockBudget: Int?
    let avatarHexColor: String?
    let avatarImageUrl: String?
    let unlockOrigin: TemporaryUnlockOrigin?
    let isHeartbeatConfirmed: Bool
    let mismatchedDeviceTypes: [String]  // "iphone", "ipad" — which devices have mode mismatch
    let isInPenaltyPhase: Bool
    let penaltyWindowCountdown: String?  // countdown of full unlock window during penalty
    let isScheduleActive: Bool
    let scheduleLabel: String?      // e.g. "Middle School Schedule"
    let scheduleStatus: String?     // e.g. "Locked until 3:00 PM"
    let scheduleStatusIsFree: Bool
    let onLock: (LockDuration) -> Void
    let onUnlock: (Int) -> Void
    let onUnlockWithTimer: ((Int) -> Void)?
    let onSchedule: () -> Void
    var hasPendingRequests: Bool = false
    let debugMode: Bool
    var namedPlaces: [NamedPlace]?
    @State private var locationExpanded = false

    // MARK: - Pre-computed values (computed once per render, not per-property)

    /// Holds values that are expensive to compute and used in multiple places.
    /// Computed once at the start of `body` to avoid redundant iteration.
    private var precomputed: PrecomputedValues {
        let deviceIDs = Set(devices.map(\.id))
        let childHeartbeats = heartbeats.filter { deviceIDs.contains($0.deviceID) }

        // hasAnyPermissionIssue
        var permissionIssue = false
        for device in devices {
            guard let hb = heartbeats.first(where: { $0.deviceID == device.id }) else { continue }
            if !hb.familyControlsAuthorized { permissionIssue = true; break }
            if let loc = hb.locationAuthorization, loc != "always" { permissionIssue = true; break }
            if hb.tunnelConnected == false { permissionIssue = true; break }
            if hb.motionAuthorized == false { permissionIssue = true; break }
            if hb.notificationsAuthorized == false { permissionIssue = true; break }
        }

        // isOnOldBuild / tunnelOnlyUpdated
        // Both old: full "…". Tunnel updated but app hasn't launched yet: grey "…".
        let builds = childHeartbeats.compactMap(\.appBuildNumber)
        let mainBuilds = childHeartbeats.compactMap(\.mainAppLastLaunchedBuild)
        let onOldBuild = (builds.min() ?? AppConstants.appBuildNumber) < AppConstants.appBuildNumber
            || (mainBuilds.min() ?? AppConstants.appBuildNumber) < AppConstants.appBuildNumber
        let tunnelCurrent = (builds.max() ?? 0) >= AppConstants.appBuildNumber
        let appStillOld = (mainBuilds.min() ?? AppConstants.appBuildNumber) < AppConstants.appBuildNumber
        let tunnelOnlyUpdated = onOldBuild && tunnelCurrent && appStillOld

        // isShieldMismatch — flag when shields are genuinely down.
        // No age filter: if a heartbeat reports shields-down in a restrictive mode,
        // show the alert immediately. With 5-minute heartbeat intervals, catching a
        // transient mid-transition blip is near-impossible. Hiding real failures
        // (Olivia b265: shields down for hours, dashboard silent) is far worse than
        // a rare false positive that self-corrects on the next heartbeat.
        var shieldMismatch = false
        if countdown == nil && dominantMode != .unlocked {
            for device in devices {
                if let hb = heartbeats.first(where: { $0.deviceID == device.id }),
                   hb.currentMode != .unlocked {
                    if let expires = hb.temporaryUnlockExpiresAt, expires > Date() { continue }

                    let confirmedDown = hb.shieldsActive == false && hb.shieldCategoryActive != true
                    let inferredDown = hb.heartbeatSource == "vpnTunnel" && hb.shieldsActive == nil

                    if confirmedDown || inferredDown {
                        shieldMismatch = true
                        break
                    }
                }
            }
        }

        // isAppForceClosed
        var appForceClosed = false
        if let hb = childHeartbeats.first {
            let heartbeatAge = Date().timeIntervalSince(hb.timestamp)
            let threshold: TimeInterval = dominantMode == .unlocked ? 7200 : 3600
            if heartbeatAge > threshold, let monitorActive = hb.monitorLastActiveAt {
                appForceClosed = Date().timeIntervalSince(monitorActive) < 7200
            }
        }

        var deviceHeartbeats: [(isPhone: Bool, age: TimeInterval, isLocked: Bool?)] = []
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }) {
                let isPhone = device.modelIdentifier.lowercased().contains("iphone")
                deviceHeartbeats.append((
                    isPhone: isPhone,
                    age: Date().timeIntervalSince(hb.timestamp),
                    isLocked: hb.isDeviceLocked
                ))
            }
        }
        // Phones always first, then iPads; within each group, freshest heartbeat first.
        deviceHeartbeats.sort { a, b in
            if a.isPhone != b.isPhone { return a.isPhone }
            return a.age < b.age
        }
        let heartbeatAge = deviceHeartbeats.first?.age

        // jailbreak info (used in tertiaryLine)
        let jailbreakReasons = devices.compactMap { dev in heartbeats.first(where: { $0.deviceID == dev.id })?.jailbreakReason }
        let hasJailbreak = !jailbreakReasons.isEmpty || devices.compactMap({ dev in heartbeats.first(where: { $0.deviceID == dev.id })?.jailbreakDetected }).contains(true)

        // Internet blocked — any device with DNS blackhole active
        let internetBlocked = childHeartbeats.contains { $0.internetBlocked == true }
        let internetBlockedReason = childHeartbeats.first(where: { $0.internetBlocked == true })?.internetBlockedReason

        // DNS domain blocking — selective blocking of app domains via VPN (fallback when shields are down)
        let dnsBlockedCount = childHeartbeats.compactMap(\.dnsBlockedDomainCount).max() ?? 0

        // Per-device alerts for multi-device children
        var deviceAlerts: [DeviceAlert] = []
        for device in devices {
            guard let hb = heartbeats.first(where: { $0.deviceID == device.id }) else { continue }
            let isIPad = device.modelIdentifier.lowercased().contains("ipad")

            let shouldBeShielded = hb.currentMode != .unlocked
            let devShieldsDown = shouldBeShielded && hb.shieldsActive == false && hb.shieldCategoryActive != true
            if devShieldsDown, let exp = hb.temporaryUnlockExpiresAt, exp > Date() { continue }

            let devInternetBlocked = hb.internetBlocked == true
            let devDnsCount = hb.dnsBlockedDomainCount ?? 0
            let devFCDegraded = hb.fcAuthDegraded == true

            if devShieldsDown || devInternetBlocked {
                deviceAlerts.append(DeviceAlert(
                    id: device.id,
                    isIPad: isIPad,
                    shieldsDown: devShieldsDown,
                    fcAuthDegraded: devFCDegraded,
                    internetBlocked: devInternetBlocked,
                    internetBlockedReason: hb.internetBlockedReason,
                    dnsBlockedCount: devDnsCount
                ))
            }
        }

        // FC auth degradation — any device reporting degraded auth
        let fcAuthDegraded = childHeartbeats.contains { $0.fcAuthDegraded == true }

        return PrecomputedValues(
            hasAnyPermissionIssue: permissionIssue,
            isOnOldBuild: onOldBuild,
            isTunnelOnlyUpdated: tunnelOnlyUpdated,
            isShieldMismatch: shieldMismatch,
            isFCAuthDegraded: fcAuthDegraded,
            isAppForceClosed: appForceClosed,
            latestHeartbeatAge: heartbeatAge,
            deviceHeartbeats: deviceHeartbeats,
            jailbreakReasons: jailbreakReasons,
            hasJailbreak: hasJailbreak,
            isInternetBlocked: internetBlocked,
            internetBlockedReason: internetBlockedReason,
            dnsBlockedDomainCount: dnsBlockedCount,
            deviceAlerts: deviceAlerts
        )
    }

    private struct DeviceAlert: Identifiable {
        let id: DeviceID
        let isIPad: Bool
        let shieldsDown: Bool
        let fcAuthDegraded: Bool
        let internetBlocked: Bool
        let internetBlockedReason: String?
        let dnsBlockedCount: Int
    }

    private struct PrecomputedValues {
        let hasAnyPermissionIssue: Bool
        let isOnOldBuild: Bool
        let isTunnelOnlyUpdated: Bool
        let isShieldMismatch: Bool
        let isFCAuthDegraded: Bool
        let isAppForceClosed: Bool
        let latestHeartbeatAge: TimeInterval?
        let deviceHeartbeats: [(isPhone: Bool, age: TimeInterval, isLocked: Bool?)]
        let jailbreakReasons: [String]
        let hasJailbreak: Bool
        let isInternetBlocked: Bool
        let internetBlockedReason: String?
        let dnsBlockedDomainCount: Int
        let deviceAlerts: [DeviceAlert]
    }

    var body: some View {
        let cached = precomputed

        VStack(spacing: 0) {
            // Top section: centered avatar + name
            VStack(spacing: 4) {
                avatarWithRing

                HStack(spacing: 3) {
                    if cached.hasAnyPermissionIssue {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    (
                        Text(child.name)
                            .foregroundColor(cached.isInternetBlocked || cached.isShieldMismatch ? .red : .primary)
                        + (cached.isOnOldBuild
                            ? Text("…").foregroundColor(cached.isTunnelOnlyUpdated ? .gray.opacity(0.4) : (cached.isInternetBlocked || cached.isShieldMismatch ? .red : .primary))
                            : Text(""))
                    )
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    if hasPendingRequests {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                    }
                }

                // Self-unlock dots (filled = remaining, empty = used)
                selfUnlockDots
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .padding(.bottom, 2)

            // Primary status — centered, slightly larger
            statusLine
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

            // Detail info — one concept per line, consistent alignment
            VStack(alignment: .leading, spacing: 4) {
                // Row 1: Critical alerts (shields down, internet blocked, jailbreak)
                // Show per-device when child has multiple devices, aggregate otherwise.
                if devices.count > 1 {
                    ForEach(cached.deviceAlerts) { alert in
                        if alert.shieldsDown {
                            infoRow(icon: "shield.slash", color: .red) {
                                HStack(spacing: 3) {
                                    Image(systemName: alert.isIPad ? "ipad" : "iphone")
                                        .font(.system(size: 9))
                                    Text(alert.fcAuthDegraded ? "FC auth degraded — needs Screen Time toggle" : "shields down")
                                        .fontWeight(.semibold)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.7)
                                }
                                .foregroundStyle(.red)
                            }
                        }
                        if alert.internetBlocked && dominantMode != .lockedDown {
                            infoRow(icon: "wifi.slash", color: .red) {
                                HStack(spacing: 3) {
                                    Image(systemName: alert.isIPad ? "ipad" : "iphone")
                                        .font(.system(size: 9))
                                    Text(alert.internetBlockedReason ?? "internet blocked")
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                .foregroundStyle(.red)
                            }
                        }
                    }
                } else {
                    if cached.isShieldMismatch {
                        infoRow(icon: "shield.slash", color: .red) {
                            Text(cached.isFCAuthDegraded ? "FC auth degraded — needs Screen Time toggle" : "shields down")
                                .foregroundStyle(.red)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    if cached.isInternetBlocked && dominantMode != .lockedDown {
                        infoRow(icon: "wifi.slash", color: .red) {
                            if let reason = cached.internetBlockedReason, !reason.isEmpty {
                                Text(reason)
                                    .foregroundStyle(.red)
                                    .fontWeight(.semibold)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                            } else {
                                Text("internet blocked")
                                    .foregroundStyle(.red)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
                if cached.hasJailbreak {
                    infoRow(icon: "exclamationmark.shield.fill", color: .red) {
                        Text("jailbreak detected")
                            .foregroundStyle(.red)
                    }
                }

                // Row 2: Penalty timer (if active)
                penaltyLine

                // Row 3: Screen time
                screenTimeLine

                // Row 4: Device health (heartbeat + lock state)
                heartbeatLine(cached: cached)

                // Row 5: Location
                locationLine
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: mutedModeColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardAccessibilityLabel(cached: cached))
    }

    // MARK: - Context Menu (replaces pill button)

    @ViewBuilder
    var contextMenuActions: some View {
        if isUnlocked {
            if let remaining = remainingSeconds, remaining > 0 {
                Button { onUnlock(remaining + 15 * 60) } label: {
                    Label("+15 minutes", systemImage: "plus.circle")
                }
                Button { onUnlock(remaining + 30 * 60) } label: {
                    Label("+30 minutes", systemImage: "plus.circle")
                }
                Button { onUnlock(remaining + 3600) } label: {
                    Label("+1 hour", systemImage: "plus.circle")
                }
                Divider()
            }
            Button { onLock(.indefinite) } label: {
                Label("Lock", systemImage: "lock.fill")
            }
            Button { onLock(.returnToSchedule) } label: {
                Label("Back to schedule", systemImage: "calendar.badge.clock")
            }
        } else {
            Button { onUnlock(15 * 60) } label: { Label("Unlock 15 min", systemImage: "clock") }
            Button { onUnlock(1 * 3600) } label: { Label("Unlock 1 hour", systemImage: "clock") }
            Button { onUnlock(5400) } label: { Label("Unlock 1.5 hours", systemImage: "clock") }
            Button { onUnlock(2 * 3600) } label: { Label("Unlock 2 hours", systemImage: "clock") }
            Divider()
            Button { onUnlock(Self.secondsUntilMidnight) } label: { Label("Until midnight", systemImage: "moon.fill") }
            Button { onUnlock(24 * 3600) } label: { Label("24 hours", systemImage: "clock.badge.checkmark") }
            if let onUnlockWithTimer {
                Divider()
                Button { onUnlockWithTimer(1 * 3600) } label: { Label("1 hour + timer", systemImage: "timer") }
                Button { onUnlockWithTimer(2 * 3600) } label: { Label("2 hours + timer", systemImage: "timer") }
            }
            Divider()
            Button { onLock(.returnToSchedule) } label: {
                Label("Back to schedule", systemImage: "calendar.badge.clock")
            }
        }
    }

    // MARK: - Mode Badge

    private var modeBadgeLabel: String {
        switch dominantMode {
        case .unlocked: return countdown ?? "Unlocked"
        case .restricted: return "Restricted"
        case .locked: return "Locked"
        case .lockedDown:
            if let cd = lockDownCountdown { return "Locked Down \(cd)" }
            return "Locked Down"
        }
    }

    private var modeBadgeIcon: String {
        switch dominantMode {
        case .unlocked: return "lock.open.fill"
        case .restricted: return "lock.fill"
        case .locked: return "shield.fill"
        case .lockedDown: return "wifi.slash"
        }
    }

    @ViewBuilder
    private var modeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: modeBadgeIcon)
                .font(.system(size: 9))
            Text(modeBadgeLabel)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(mutedModeColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(mutedModeColor.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Status Detail (compact)

    @ViewBuilder
    private var statusDetail: some View {
        if dominantMode == .lockedDown, let cd = lockDownCountdown {
            HStack(spacing: 2) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 9))
                Text("Internet off \(cd)")
            }
            .font(.system(size: 11))
            .foregroundStyle(Self.mutedRed)
        } else if isInPenaltyPhase {
            HStack(spacing: 2) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9))
                if let timer = penaltyTimer {
                    Text(timer)
                } else {
                    Text("Penalty")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Self.mutedOrange)
        } else if isScheduleActive, let scheduleStatus {
            Text(scheduleStatus)
                .font(.system(size: 11))
                .foregroundStyle(scheduleStatusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else if let loc = locationInfo {
            HStack(spacing: 2) {
                Image(systemName: "location.fill")
                    .font(.system(size: 8))
                Text(loc.address)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Text(" ")
                .font(.system(size: 11))
        }
    }

    // MARK: - Alerts Row (compact)

    @ViewBuilder
    private func alertsRow(cached: PrecomputedValues) -> some View {
        let hasJailbreak = cached.hasJailbreak
        let hasShieldMismatch = cached.isShieldMismatch
        let hasForceClosed = cached.isAppForceClosed

        if hasJailbreak || hasShieldMismatch || hasForceClosed {
            HStack(spacing: 4) {
                if hasShieldMismatch {
                    Image(systemName: "shield.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }
                if hasJailbreak {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }
                if hasForceClosed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Self.mutedOrange)
                }
            }
        }
    }

    // MARK: - Avatar with Glow

    @ViewBuilder
    private var avatarWithRing: some View {
        avatarContent
            .background(
                Circle()
                    .fill(modeColor.opacity(0.5))
                    .blur(radius: 14)
                    .scaleEffect(1.25)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatarContent: some View {
        // Priority: CloudKit photo > CloudKit emoji > Firebase photo > initials
        if let base64 = child.avatarPhotoBase64,
           let data = Data(base64Encoded: base64),
           let uiImage = UIImage(data: data) {
            // CloudKit photo avatar
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(Circle())
        } else if let base64 = avatarImageUrl,
                  let data = Data(base64Encoded: base64),
                  let uiImage = UIImage(data: data) {
            // Firebase photo fallback
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(Circle())
        } else if let emoji = child.avatarEmoji, !emoji.isEmpty {
            // Emoji avatar on colored circle
            ZStack {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: 72, height: 72)
                Text(emoji)
                    .font(.system(size: 36))
            }
        } else {
            // Initials fallback
            let initials = String(child.name.prefix(1)).uppercased()
            ZStack {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: 72, height: 72)
                Text(initials)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }
        }
    }

    private var avatarGradient: LinearGradient {
        // Priority: CloudKit color > Firebase color > deterministic hash
        let hex = child.avatarColor ?? avatarHexColor
        if let hex, let color = Color(hex: hex) {
            return LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let colors: [(Color, Color)] = [
            (.blue, .cyan), (.purple, .pink), (.green, .mint),
            (.orange, .yellow), (.indigo, .purple), (.teal, .green)
        ]
        let index = abs(child.id.rawValue.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }) % colors.count
        let pair = colors[index]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Status Line (Line 2)

    @ViewBuilder
    private var statusLine: some View {
        if isInPenaltyPhase {
            VStack(spacing: 2) {
                Text("Unlock pending timer")
                    .font(.system(size: 12))
                    .foregroundStyle(Self.mutedOrange)
                if let windowCountdown = penaltyWindowCountdown {
                    Text(windowCountdown)
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Self.mutedOrange)
                }
            }
            .accessibilityElement(children: .combine)
        } else if dominantMode == .lockedDown, let cd = lockDownCountdown {
            HStack(spacing: 4) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 13))
                Text("Locked Down \u{00B7} \(cd) left")
                    .font(.system(size: 13))
                    .foregroundStyle(Self.mutedRed)
            }
            .accessibilityElement(children: .combine)
        } else if dominantMode == .lockedDown {
            modeBadge
        } else if let countdown {
            HStack(spacing: 4) {
                mismatchIndicator
                let label: String = {
                    switch unlockOrigin {
                    case .selfUnlock: return "Self-unlocked"
                    case .localPINUnlock: return "PIN unlocked"
                    case .remoteCommand: return "Unlocked"
                    case .none: return "Unlocked"
                    }
                }()
                Text("\(label) \u{00B7} \(countdown) left")
                    .font(.system(size: 13))
                    .foregroundStyle(Self.mutedGreen)
            }
            .accessibilityElement(children: .combine)
        } else if isScheduleActive {
            HStack(spacing: 3) {
                mismatchIndicator
                if let scheduleStatus {
                    let statusColor = scheduleStatusColor
                    Text(scheduleStatus)
                        .foregroundColor(statusColor)
                        .font(.system(size: 13))
                        .lineLimit(1)
                } else {
                    Text(dominantMode.displayName)
                        .font(.system(size: 13))
                        .foregroundStyle(Self.mutedOrange)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 3) {
                mismatchIndicator
                Text(dominantMode.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(mutedModeColor)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Self-Unlock Dots

    @ViewBuilder
    private var selfUnlockDots: some View {
        if let used = selfUnlocksUsed, let budget = selfUnlockBudget, budget > 0 {
            HStack(spacing: 4) {
                ForEach(0..<budget, id: \.self) { i in
                    Circle()
                        .fill(i < (budget - used) ? Self.mutedTeal : Color(.systemGray4))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityLabel("\(max(0, budget - used)) of \(budget) self-unlocks remaining")
        }
    }

    // MARK: - Penalty Timer

    @ViewBuilder
    private var penaltyLine: some View {
        if let penaltyTimer {
            infoRow(icon: isPenaltyRunning ? "timer" : "hourglass", color: Self.mutedRed) {
                Text(penaltyTimer)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                Text("remaining")
                    .foregroundStyle(Self.mutedRed)
            }
        }
    }

    // MARK: - Screen Time

    @ViewBuilder
    private var screenTimeLine: some View {
        if let minutes = screenTimeMinutes {
            let hours = minutes / 60
            let mins = minutes % 60
            let display = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
            infoRow(icon: "hourglass", color: .secondary) {
                Text("screen time \(display)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Heartbeat (device health)

    @ViewBuilder
    private func heartbeatLine(cached: PrecomputedValues) -> some View {
        if cached.latestHeartbeatAge != nil {
            if cached.isAppForceClosed {
                infoRow(icon: "exclamationmark.triangle.fill", color: Self.mutedOrange) {
                    Text("app not running")
                        .foregroundStyle(Self.mutedOrange)
                    lockIcon
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(cached.deviceHeartbeats.enumerated()), id: \.offset) { _, dh in
                        HStack(spacing: 2) {
                            if let locked = dh.isLocked {
                                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(locked ? .secondary : .yellow)
                            }
                            Image(systemName: dh.isPhone ? "iphone" : "ipad")
                                .font(.caption2)
                                .foregroundStyle(dh.age < 600 ? .green : .secondary)
                            Text(dh.age < 30 ? "now" : formatAge(dh.age))
                                .font(.caption2)
                                .foregroundStyle(dh.age < 600 ? Color.secondary : Color.orange)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var lockIcon: some View {
        if let locked = isDeviceLocked {
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 9))
                .foregroundColor(locked ? .secondary : .yellow)
        }
    }

    // MARK: - Location Line (Line 5) — iPhone only

    @ViewBuilder
    private var locationLine: some View {
        if let loc = locationInfo {
            infoRow(icon: "location.fill", color: Self.mutedBlue) {
                // Address + " · age" is ONE Text so the timestamp wraps with
                // the address instead of sticking to the first line while
                // the rest of the address overflows below it. Movement icon
                // stays on the first baseline via HStack alignment so it
                // doesn't jump to a new row when the address wraps.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(loc.address) \u{00B7} \(formatAge(loc.age))")
                        .foregroundStyle(.secondary)
                        .lineLimit(locationExpanded ? nil : 1)
                        .truncationMode(.middle)
                    if let movement = movementIndicator {
                        Image(systemName: movement.icon)
                            .font(.system(size: 9))
                            .foregroundStyle(movement.color)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: locationExpanded)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { locationExpanded.toggle() }
                }
            }
        } else if isLocationExpected {
            infoRow(icon: "location.slash.fill", color: Self.mutedRed) {
                Text("location disabled")
                    .foregroundStyle(Self.mutedRed)
            }
        }
    }

    /// True if location tracking is configured for this child but no location data is arriving from the iPhone.
    private var isLocationExpected: Bool {
        guard let device = locationDevice ?? devices.first,
              let hb = heartbeats.first(where: { $0.deviceID == device.id }) else { return false }
        // Location is "expected but missing" if:
        // - device has a heartbeat (any age) AND
        // - location auth is denied/restricted OR no location data exists
        if let auth = hb.locationAuthorization, auth == "denied" || auth == "restricted" {
            return true
        }
        let isOnline = Date().timeIntervalSince(hb.timestamp) < 300
        return isOnline && hb.latitude == nil
    }

    /// The best device for location: prefer iPhone, fall back to any device with location data.
    private var locationDevice: ChildDevice? {
        // Prefer iPhone
        if let iphone = devices.first(where: { $0.modelIdentifier.hasPrefix("iPhone") }) {
            return iphone
        }
        // Fall back to any device that has location in its heartbeat
        return devices.first { dev in
            heartbeats.first(where: { $0.deviceID == dev.id })?.locationTimestamp != nil
        }
    }

    /// Latest location data from heartbeats (preferring iPhone, falling back to iPad).
    /// Resolves to named place (Home, School, etc.) if the child is near one.
    /// Movement indicator from the location device's heartbeat.
    private var movementIndicator: (icon: String, color: Color)? {
        guard let device = locationDevice,
              let hb = heartbeats.first(where: { $0.deviceID == device.id }),
              // Only show if heartbeat is recent (< 5 min)
              Date().timeIntervalSince(hb.timestamp) < 300 else { return nil }
        if hb.isDriving == true {
            return ("car.fill", .orange)
        }
        if let speed = hb.currentSpeed, speed > 1.0 { // > ~2 mph
            return ("figure.walk", .blue)
        }
        return nil
    }

    private var locationInfo: (address: String, age: TimeInterval)? {
        guard let device = locationDevice,
              let hb = heartbeats.first(where: { $0.deviceID == device.id }),
              let locTime = hb.locationTimestamp else { return nil }

        // Try to resolve to a named place
        if let lat = hb.latitude, let lon = hb.longitude {
            if let placeName = resolveNamedPlace(latitude: lat, longitude: lon, device: device) {
                return (placeName, Date().timeIntervalSince(locTime))
            }
        }

        guard let address = hb.locationAddress else { return nil }
        return (address, Date().timeIntervalSince(locTime))
    }

    /// Check if coordinates are near home or a named place.
    private func resolveNamedPlace(latitude: Double, longitude: Double, device: ChildDevice) -> String? {
        let loc = CLLocation(latitude: latitude, longitude: longitude)

        // Check home
        let latKey = "homeLatitude.\(device.id.rawValue)"
        let lonKey = "homeLongitude.\(device.id.rawValue)"
        if let homeLat = UserDefaults.standard.object(forKey: latKey) as? Double,
           let homeLon = UserDefaults.standard.object(forKey: lonKey) as? Double {
            let home = CLLocation(latitude: homeLat, longitude: homeLon)
            if loc.distance(from: home) < 150 {
                return "Home"
            }
        }

        // Check named places (cached in parent state)
        if let places = namedPlaces {
            for place in places {
                let placeLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                if loc.distance(from: placeLoc) < max(place.radiusMeters, 300) {
                    return place.name
                }
            }
        }

        return nil
    }

    /// Screen time minutes from the child's heartbeat.
    /// Only trusts values from app heartbeats (not tunnel), sent today.
    private var screenTimeMinutes: Int? {
        let todayStart = Calendar.current.startOfDay(for: Date())
        // Accept screen time from ANY heartbeat source — the tunnel is now the
        // sole screen time tracker, so tunnel heartbeats are authoritative.
        // Pick the highest value across all devices (most accurate for multi-device kids).
        var best: Int?
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }),
               let minutes = hb.screenTimeMinutes,
               hb.timestamp >= todayStart,
               minutes > (best ?? 0) {
                best = minutes
            }
        }
        return best
    }

    /// Whether the child's device is currently locked (preferring iPhone).
    private var isDeviceLocked: Bool? {
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }),
               let locked = hb.isDeviceLocked {
                return locked
            }
        }
        return nil
    }

    private func formatAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }

    // MARK: - Pill Button

    @ViewBuilder
    private var pillButton: some View {
        if isUnlocked {
            // Show "Lock" button with extend options
            Menu {
                if let remaining = remainingSeconds, remaining > 0 {
                    Button { onUnlock(remaining + 15 * 60) } label: {
                        Label("+15 minutes", systemImage: "plus.circle")
                    }
                    Button { onUnlock(remaining + 30 * 60) } label: {
                        Label("+30 minutes", systemImage: "plus.circle")
                    }
                    Button { onUnlock(remaining + 3600) } label: {
                        Label("+1 hour", systemImage: "plus.circle")
                    }
                    Divider()
                }
                Button { onLock(.indefinite) } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                Button { onLock(.returnToSchedule) } label: {
                    Label("Back to schedule", systemImage: "calendar.badge.clock")
                }
            } label: {
                pillLabel("Lock", icon: "lock.fill")
            } primaryAction: {
                onLock(.indefinite)
            }
            .accessibilityLabel("Lock \(child.name)")
            .accessibilityHint("Tap to lock. Long press for more options.")
        } else {
            // Show "Unlock" button
            Menu {
                if let remaining = remainingSeconds, remaining > 0 {
                    Button { onUnlock(remaining + 15 * 60) } label: {
                        Label("+15 minutes", systemImage: "plus.circle")
                    }
                    Divider()
                }
                Button { onUnlock(15 * 60) } label: { Label("15 minutes", systemImage: "clock") }
                Button { onUnlock(1 * 3600) } label: { Label("1 hour", systemImage: "clock") }
                Button { onUnlock(5400) } label: { Label("1.5 hours", systemImage: "clock") }
                Button { onUnlock(2 * 3600) } label: { Label("2 hours", systemImage: "clock") }
                Divider()
                Button { onUnlock(Self.secondsUntilMidnight) } label: { Label("Until midnight", systemImage: "moon.fill") }
                Button { onUnlock(24 * 3600) } label: { Label("24 hours", systemImage: "clock.badge.checkmark") }
                if let onUnlockWithTimer {
                    Divider()
                    Button { onUnlockWithTimer(1 * 3600) } label: { Label("1 hour + timer", systemImage: "timer") }
                    Button { onUnlockWithTimer(2 * 3600) } label: { Label("2 hours + timer", systemImage: "timer") }
                }
                Divider()
                Button { onLock(.returnToSchedule) } label: {
                    Label("Back to schedule", systemImage: "calendar.badge.clock")
                }
            } label: {
                pillLabel("Unlock", icon: "lock.open.fill")
            } primaryAction: {
                if let remaining = remainingSeconds, remaining > 0 {
                    onUnlock(remaining + 15 * 60)
                } else {
                    onUnlock(15 * 60)
                }
            }
            .accessibilityLabel("Unlock \(child.name)")
            .accessibilityHint("Tap to unlock for 15 minutes. Long press for more options.")
        }
    }

    @ViewBuilder
    private func pillLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
        .clipShape(Capsule())
    }

    // MARK: - Accessibility

    private func cardAccessibilityLabel(cached: PrecomputedValues) -> String {
        var parts: [String] = [child.name]

        // Mode
        parts.append(dominantMode.displayName)

        // Countdown / schedule info
        if isInPenaltyPhase {
            parts.append("Locked, confirming")
        } else if let countdown {
            let origin: String = {
                switch unlockOrigin {
                case .selfUnlock: return "Self-unlocked"
                case .localPINUnlock: return "PIN unlocked"
                case .remoteCommand: return "Unlocked"
                case .none: return "Unlocked"
                }
            }()
            parts.append("\(origin), \(countdown) left")
        } else if let scheduleLabel, isScheduleActive {
            parts.append(scheduleLabel)
            if let scheduleStatus {
                parts.append(scheduleStatus)
            }
        }

        // Online status
        if let lastSeen = cached.latestHeartbeatAge {
            if lastSeen < 30 {
                parts.append("Online")
            } else if cached.isAppForceClosed {
                parts.append("Warning, app not running")
            } else {
                parts.append("Offline, last seen \(formatAge(lastSeen))")
            }
        }

        // Penalty timer
        if let penaltyTimer {
            parts.append("Penalty: \(penaltyTimer)")
        }

        // Self-unlocks
        if let used = selfUnlocksUsed, let budget = selfUnlockBudget, budget > 0 {
            let remaining = max(0, budget - used)
            parts.append("\(remaining) of \(budget) self-unlocks remaining")
        }

        if !isHeartbeatConfirmed {
            parts.append("Not yet confirmed")
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Mismatch Indicator

    /// Grey clock with optional device type icons showing which devices have a mode mismatch.
    @ViewBuilder
    private var mismatchIndicator: some View {
        if !isHeartbeatConfirmed {
            HStack(spacing: 1) {
                Image(systemName: "clock")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                if devices.count > 1 && !mismatchedDeviceTypes.isEmpty {
                    ForEach(Array(Set(mismatchedDeviceTypes)).sorted(), id: \.self) { type in
                        Image(systemName: type == "ipad" ? "ipad" : "iphone")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    // MARK: - Info Row Helper (consistent icon alignment)

    @ViewBuilder
    private func infoRow<Content: View>(icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color)
                .frame(width: 12, alignment: .center)
            content()
        }
    }

    private var isUnlocked: Bool {
        dominantMode == .unlocked
    }

    // Note: isAppForceClosed, isOnOldBuild, hasAnyPermissionIssue, isShieldMismatch,
    // latestHeartbeatAge, and jailbreak checks are now pre-computed once per render
    // cycle in the `precomputed` property and passed via PrecomputedValues.

    /// Vivid color — used only for avatar glow.
    private var modeColor: Color {
        switch dominantMode {
        case .unlocked: return .green
        case .restricted: return .blue
        case .locked: return .purple
        case .lockedDown: return .red
        }
    }

    /// Muted color — used for text, pill buttons, left border.
    private var mutedModeColor: Color {
        switch dominantMode {
        case .unlocked: return Color(.systemGreen).opacity(0.7)
        case .restricted: return Color(.systemBlue).opacity(0.7)
        case .locked: return Color(.systemPurple).opacity(0.7)
        case .lockedDown: return Color(.systemRed).opacity(0.7)
        }
    }

    /// Color for schedule status text, derived from the label prefix.
    private var scheduleStatusColor: Color {
        guard let scheduleStatus else { return Self.mutedBlue }
        if scheduleStatusIsFree { return Self.mutedGreen }
        if scheduleStatus.hasPrefix("Locked Down") { return Self.mutedRed }
        if scheduleStatus.hasPrefix("Locked") { return Self.mutedPurple }
        // "Restricted" or anything else
        return Self.mutedBlue
    }

    private static let mutedGreen = Color(.systemGreen).opacity(0.7)
    private static let mutedBlue = Color(.systemBlue).opacity(0.7)
    private static let mutedPurple = Color(.systemPurple).opacity(0.7)
    private static let mutedOrange = Color(.systemOrange).opacity(0.7)
    private static let mutedTeal = Color(.systemTeal).opacity(0.7)
    private static let mutedRed = Color(red: 1.0, green: 0.45, blue: 0.4).opacity(0.8)

    static var secondsUntilMidnight: Int { Date.secondsUntilMidnight }
}

// MARK: - Color from Hex

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - Liquid Glass / Material Fallback

extension View {
    /// Apply iOS 26 Liquid Glass effect when available, falling back to
    /// a material + border treatment on older iOS versions.
    @ViewBuilder
    func if_iOS26GlassEffect(fallbackMaterial: Material = .ultraThinMaterial, borderColor: Color) -> some View {
        if #available(iOS 26, *) {
            self
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(fallbackMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(borderColor.opacity(0.3), lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    func if_iOS26GlassCapsule(fallbackMaterial: Material = .ultraThinMaterial, borderColor: Color) -> some View {
        if #available(iOS 26, *) {
            self
                .clipShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
                .background(fallbackMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(borderColor.opacity(0.2), lineWidth: 1))
        }
    }
}
