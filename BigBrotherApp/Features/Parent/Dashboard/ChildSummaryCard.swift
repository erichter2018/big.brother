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
    let remainingSeconds: Int?
    let penaltyTimer: String?
    let isPenaltyRunning: Bool
    let selfUnlocksUsed: Int?
    let selfUnlockBudget: Int?
    let avatarHexColor: String?
    let avatarImageUrl: String?
    let unlockOrigin: TemporaryUnlockOrigin?
    let isHeartbeatConfirmed: Bool
    let isInPenaltyPhase: Bool
    let isScheduleActive: Bool
    let scheduleLabel: String?      // e.g. "Middle School Schedule"
    let scheduleStatus: String?     // e.g. "Locked until 3:00 PM"
    let scheduleStatusIsFree: Bool
    let onLock: (LockDuration) -> Void
    let onUnlock: (Int) -> Void
    let onUnlockWithTimer: ((Int) -> Void)?
    let onSchedule: () -> Void
    let debugMode: Bool
    var namedPlaces: [NamedPlace]?

    var body: some View {
        HStack(spacing: 12) {
            // Avatar with mode ring
            avatarWithRing

            // Name + status lines
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if hasAnyPermissionIssue {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                    Text(child.name + (isOnOldBuild ? "…" : ""))
                        .font(.headline)
                        .lineLimit(1)
                }

                statusLine

                tertiaryLine

                usageAndHeartbeatLine

                locationLine
            }

            Spacer(minLength: 0)

            // Single contextual pill button
            pillButton
                .disabled(isSending)
                .opacity(isSending ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 16,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                    .fill(mutedModeColor.opacity(0.4))
                    .frame(width: 2)
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardAccessibilityLabel)
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
        if let base64 = avatarImageUrl,
           let data = Data(base64Encoded: base64),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    @ViewBuilder
    private var avatarFallback: some View {
        let initials = String(child.name.prefix(1)).uppercased()
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: 56, height: 56)
            Text(initials)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
    }

    private var avatarGradient: LinearGradient {
        if let hex = avatarHexColor, let color = Color(hex: hex) {
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
            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(Self.mutedOrange)
                if let timer = penaltyTimer {
                    Text("Penalty \u{00B7} \(timer)")
                        .font(.caption)
                        .foregroundStyle(Self.mutedOrange)
                } else {
                    Text("Penalty active")
                        .font(.caption)
                        .foregroundStyle(Self.mutedOrange)
                }
            }
            .accessibilityElement(children: .combine)
        } else if let countdown {
            HStack(spacing: 4) {
                if !isHeartbeatConfirmed {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                let label: String = {
                    switch unlockOrigin {
                    case .selfUnlock: return "Self-unlocked"
                    case .localPINUnlock: return "PIN unlocked"
                    case .remoteCommand: return "Unlocked"
                    case .none: return "Unlocked"
                    }
                }()
                Text("\(label) \u{00B7} \(countdown) left")
                    .font(.caption)
                    .foregroundStyle(Self.mutedGreen)
            }
            .accessibilityElement(children: .combine)
        } else if isScheduleActive {
            HStack(spacing: 3) {
                if !isHeartbeatConfirmed {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                if let scheduleStatus {
                    let statusColor = scheduleStatusIsFree ? Self.mutedGreen : scheduleStatus.hasPrefix("Essential") ? Self.mutedPurple : Self.mutedBlue
                    (Text(scheduleStatus).foregroundColor(statusColor)
                     + Text(" (by schedule)").foregroundColor(Self.mutedOrange))
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text(dominantMode.displayName)
                        .font(.caption)
                        .foregroundStyle(Self.mutedOrange)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 3) {
                if !isHeartbeatConfirmed {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                Text(dominantMode.displayName)
                    .font(.caption)
                    .foregroundStyle(mutedModeColor)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Tertiary Line (Line 3): Penalty + Self-Unlocks + Jailbreak

    /// True when heartbeat says locked but ManagedSettingsStore shields are actually down.
    /// Excludes active temporary unlocks — shields are supposed to be down during those.
    /// True if any of this child's devices has a permission that isn't correctly set.
    private var hasAnyPermissionIssue: Bool {
        for device in devices {
            guard let hb = heartbeats.first(where: { $0.deviceID == device.id }) else { continue }
            if !hb.familyControlsAuthorized { return true }
            if let loc = hb.locationAuthorization, loc != "always" { return true }
            if hb.tunnelConnected == false { return true }
            if hb.motionAuthorized == false { return true }
            if hb.notificationsAuthorized == false { return true }
        }
        return false
    }

    private var isShieldMismatch: Bool {
        // If the parent dashboard shows an active unlock countdown, shields are supposed to be down.
        if countdown != nil || dominantMode == .unlocked {
            return false
        }
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }),
               hb.currentMode != .unlocked,
               hb.shieldsActive == false {
                // Don't flag during active temp unlock (per-device check too)
                if let expires = hb.temporaryUnlockExpiresAt, expires > Date() {
                    continue
                }
                return true
            }
        }
        return false
    }

    @ViewBuilder
    private var tertiaryLine: some View {
        let hasPenalty = penaltyTimer != nil
        let hasSelfUnlocks = (selfUnlockBudget ?? 0) > 0
        let jailbreakReasons = devices.compactMap({ dev in heartbeats.first(where: { $0.deviceID == dev.id })?.jailbreakReason })
        let hasJailbreak = !jailbreakReasons.isEmpty || devices.compactMap({ dev in heartbeats.first(where: { $0.deviceID == dev.id })?.jailbreakDetected }).contains(true)
        let hasShieldMismatch = isShieldMismatch

        if hasPenalty || hasSelfUnlocks || hasJailbreak || hasShieldMismatch {
            HStack(spacing: 4) {
                if let penaltyTimer {
                    Image(systemName: isPenaltyRunning ? "timer" : "hourglass")
                        .foregroundStyle(Self.mutedRed)
                    Text(penaltyTimer)
                        .foregroundStyle(Self.mutedRed)
                }

                if let used = selfUnlocksUsed, let budget = selfUnlockBudget, budget > 0 {
                    let remaining = max(0, budget - used)
                    if hasPenalty {
                        Text("\u{00B7}").foregroundStyle(.secondary)
                    }
                    Text("\(remaining) of \(budget) self-unlocks")
                        .foregroundStyle(Self.mutedTeal)
                }

                if hasJailbreak {
                    if hasPenalty || hasSelfUnlocks {
                        Text("\u{00B7}").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.red)
                        Text("jailbreak")
                            .foregroundStyle(.red)
                        if let reason = jailbreakReasons.first {
                            Text("(\(reason))")
                                .foregroundStyle(.red.opacity(0.7))
                        }
                    }
                    .accessibilityLabel("Warning: jailbreak detected on device")
                }

                if hasShieldMismatch {
                    if hasPenalty || hasSelfUnlocks || hasJailbreak {
                        Text("\u{00B7}").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "shield.slash")
                            .font(.system(size: 8))
                            .foregroundStyle(.red)
                        Text("SHIELDS DOWN")
                            .fontWeight(.bold)
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Warning: device reports locked but shields are not active")
                }
            }
            .font(.caption2.monospacedDigit())
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Usage & Heartbeat Line (Line 4): Screen Time + Online Status

    @ViewBuilder
    private var usageAndHeartbeatLine: some View {
        HStack(spacing: 4) {
            // Screen time
            if let minutes = screenTimeMinutes {
                let hours = minutes / 60
                let mins = minutes % 60
                let display = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
                HStack(spacing: 3) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text("screen time \(display)")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Total screen time today: \(hours) hours \(mins) minutes")
            }

            // Online/heartbeat indicator
            if let lastSeen = latestHeartbeatAge {
                if screenTimeMinutes != nil {
                    Text("\u{00B7}").foregroundStyle(.tertiary)
                }
                if lastSeen < 30 {
                    HStack(spacing: 2) {
                        Circle().fill(Self.mutedGreen).frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                        Text("online")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Device online")
                } else if isAppForceClosed {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Self.mutedOrange)
                            .accessibilityHidden(true)
                        Text("app not running")
                            .foregroundStyle(Self.mutedOrange)
                    }
                    .accessibilityLabel("Warning, app not running on device")
                } else {
                    HStack(spacing: 2) {
                        Circle().fill(Self.mutedRed).frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                        Text(formatAge(lastSeen))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Device offline, last seen \(formatAge(lastSeen))")
                }

                // Lock state — always show when we have data, regardless of online threshold.
                // Heartbeats come every 5 min; the lock state from the last heartbeat is still valid.
                if let locked = isDeviceLocked {
                    Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 8))
                        .foregroundColor(locked ? .secondary : .yellow)
                        .accessibilityLabel(locked ? "Screen off" : "Screen on")
                }
            }
        }
        .font(.caption2.monospacedDigit())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Location Line (Line 5) — iPhone only

    @ViewBuilder
    private var locationLine: some View {
        if let loc = locationInfo {
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Self.mutedBlue)
                Text(loc.address)
                    .foregroundStyle(.secondary)
                Text("\u{00B7}")
                    .foregroundStyle(.tertiary)
                Text(formatAge(loc.age))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Location: \(loc.address), \(formatAge(loc.age))")
        } else if isLocationExpected {
            HStack(spacing: 4) {
                Image(systemName: "location.slash.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Self.mutedRed)
                Text("location disabled")
                    .foregroundStyle(Self.mutedRed)
            }
            .font(.caption2)
            .accessibilityLabel("Warning: location tracking is disabled on this device")
        }
    }

    /// True if location tracking is configured for this child but no location data is arriving from the iPhone.
    private var isLocationExpected: Bool {
        guard let iphone = iphoneDevice,
              let hb = heartbeats.first(where: { $0.deviceID == iphone.id }) else { return false }
        // If the device is online but has no location, location is likely denied.
        let isOnline = Date().timeIntervalSince(hb.timestamp) < 120
        return isOnline && hb.latitude == nil
    }

    /// The first iPhone device for this child (location tracking is iPhone-only).
    private var iphoneDevice: ChildDevice? {
        devices.first { $0.modelIdentifier.hasPrefix("iPhone") }
    }

    /// Seconds since latest heartbeat, preferring iPhone over iPad.
    /// The `devices` array is pre-sorted with iPhones first by the view model.
    private var latestHeartbeatAge: TimeInterval? {
        // Prefer the first device's (iPhone if available) heartbeat.
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }) {
                return Date().timeIntervalSince(hb.timestamp)
            }
        }
        return nil
    }

    /// Latest location data from heartbeats (preferring iPhone).
    /// Resolves to named place (Home, School, etc.) if the child is near one.
    private var locationInfo: (address: String, age: TimeInterval)? {
        guard let iphone = iphoneDevice,
              let hb = heartbeats.first(where: { $0.deviceID == iphone.id }),
              let locTime = hb.locationTimestamp else { return nil }

        // Try to resolve to a named place
        if let lat = hb.latitude, let lon = hb.longitude {
            if let placeName = resolveNamedPlace(latitude: lat, longitude: lon, device: iphone) {
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
            if loc.distance(from: home) < 500 {
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

    /// Screen time minutes from the child's heartbeat (preferring iPhone).
    private var screenTimeMinutes: Int? {
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }),
               let minutes = hb.screenTimeMinutes {
                return minutes
            }
        }
        return nil
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
                .font(.caption)
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

    private var cardAccessibilityLabel: String {
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
        if let lastSeen = latestHeartbeatAge {
            if lastSeen < 30 {
                parts.append("Online")
            } else if isAppForceClosed {
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

    // MARK: - Helpers

    private var isUnlocked: Bool {
        dominantMode == .unlocked
    }

    /// True if the main app was force-closed (or killed by iOS): Monitor is alive but heartbeats stopped.
    /// Detected when monitorLastActiveAt is recent but heartbeat is stale.
    /// When unlocked, uses a longer 2-hour threshold to avoid false positives from
    /// iOS suspending the app during resource-intensive games.
    private var isAppForceClosed: Bool {
        let deviceIDs = Set(devices.map(\.id))
        let childHeartbeats = heartbeats.filter { deviceIDs.contains($0.deviceID) }
        guard let hb = childHeartbeats.first else { return false }
        let heartbeatAge = Date().timeIntervalSince(hb.timestamp)
        // When unlocked, use 2-hour threshold — iOS aggressively suspends the app
        // during games but BGTask still wakes it within ~30 min. If 2+ hours pass
        // with no heartbeat while unlocked, the app is truly dead.
        // When locked, use 1-hour threshold.
        let threshold: TimeInterval = dominantMode == .unlocked ? 7200 : 3600
        guard heartbeatAge > threshold else { return false }
        // Monitor must have been active recently (within 2 hours) to confirm
        // the device itself is still powered on and running.
        guard let monitorActive = hb.monitorLastActiveAt else { return false }
        let monitorAge = Date().timeIntervalSince(monitorActive)
        return monitorAge < 7200
    }

    /// True if ANY of this child's devices is running an older build than current.
    private var isOnOldBuild: Bool {
        let deviceIDs = Set(devices.map(\.id))
        let builds = heartbeats
            .filter { deviceIDs.contains($0.deviceID) }
            .compactMap(\.appBuildNumber)
        guard let minBuild = builds.min() else { return false }
        // Worst case: if any device is old, show the indicator.
        return minBuild < AppConstants.appBuildNumber
    }

    /// Vivid color — used only for avatar glow.
    private var modeColor: Color {
        switch dominantMode {
        case .unlocked: return .green
        case .dailyMode: return .blue
        case .essentialOnly: return .purple
        }
    }

    /// Muted color — used for text, pill buttons, left border.
    private var mutedModeColor: Color {
        switch dominantMode {
        case .unlocked: return Color(.systemGreen).opacity(0.7)
        case .dailyMode: return Color(.systemBlue).opacity(0.7)
        case .essentialOnly: return Color(.systemPurple).opacity(0.7)
        }
    }

    private static let mutedGreen = Color(.systemGreen).opacity(0.7)
    private static let mutedBlue = Color(.systemBlue).opacity(0.7)
    private static let mutedPurple = Color(.systemPurple).opacity(0.7)
    private static let mutedOrange = Color(.systemOrange).opacity(0.7)
    private static let mutedTeal = Color(.systemTeal).opacity(0.7)
    private static let mutedRed = Color(red: 1.0, green: 0.45, blue: 0.4).opacity(0.8)

    static var secondsUntilMidnight: Int {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        return max(60, Int(midnight.timeIntervalSince(now)))
    }
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
