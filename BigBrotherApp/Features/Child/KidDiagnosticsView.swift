import SwiftUI
import UIKit
import BigBrotherCore
#if canImport(FamilyControls)
import FamilyControls
import ManagedSettings
#endif
import CoreLocation
import CoreMotion
import UserNotifications

/// Single-screen diagnostic dump for kid devices. Presented when the kid
/// taps "Diagnostics" — typically while reporting a problem to the parent.
/// Every useful piece of state fits on one screen so the kid can screenshot
/// it and send it along.
///
/// Design rules:
///   - Monospaced font, small size, tight spacing so everything fits.
///   - Shorthand labels (MODE/VPN/TUN/HB/etc.) — parent knows what to look for.
///   - Timestamps include absolute time AND age-from-now where useful.
///   - No interactive state — pure read, refreshed every second so a
///     screenshot always shows current values.
struct KidDiagnosticsView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var now = Date()
    @State private var fcAuthString = "?"
    @State private var locAuthString = "?"
    @State private var motionAuthString = "?"
    @State private var notifAuthString = "?"
    @State private var showCopiedToast = false
    @State private var childName: String?

    private let locationManager = CLLocationManager()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    headerBlock
                    separator
                    modeBlock
                    separator
                    networkBlock
                    separator
                    dnsStatsBlock
                    separator
                    heartbeatBlock
                    separator
                    heartbeatHistoryBlock
                    separator
                    permissionsBlock
                    separator
                    cloudKitBlock
                    separator
                    appsBlock
                    separator
                    commandsBlock
                    separator
                    buildsBlock
                    separator
                    restrictionsBlock
                    separator
                    scheduleWindowsBlock
                    separator
                    timeLimitsBlock
                    separator
                    systemBlock
                    separator
                    eventLogBlock
                    separator
                    diagEntriesBlock
                    separator
                    idsBlock
                }
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        UIPasteboard.general.string = buildPlainTextDump()
                        withAnimation { showCopiedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showCopiedToast = false }
                        }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if showCopiedToast {
                    Text("Copied — paste in a text to your parent")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
            .task {
                // Tick `now` every second so on-screen ages stay current.
                // A Task loop is used instead of Combine's Timer.publish
                // because Timer.publish on a View struct's `let` property
                // was observed to stop firing after ~30s, leaving ages
                // displayed as negative (timestamps written after the last
                // tick looked "in the future"). `.task` is bound to view
                // lifecycle and cancels cleanly on dismiss.
                refreshAuthStrings()
                await fetchChildNameIfNeeded()
                while !Task.isCancelled {
                    now = Date()
                    refreshAuthStrings()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Fetch the kid's ChildProfile.name from CloudKit once per view
    /// presentation. Cached in App Group so future launches see it
    /// immediately without needing the network.
    private func fetchChildNameIfNeeded() async {
        let defaults = UserDefaults.appGroup
        if let cached = defaults?.string(forKey: "cachedChildName"), !cached.isEmpty {
            childName = cached
            return
        }
        guard let enroll = appState.enrollmentState,
              let cloudKit = appState.cloudKit else { return }
        if let profiles = try? await cloudKit.fetchChildProfiles(familyID: enroll.familyID),
           let profile = profiles.first(where: { $0.id == enroll.childProfileID }) {
            childName = profile.name
            defaults?.set(profile.name, forKey: "cachedChildName")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerBlock: some View {
        let name = childName ?? "(kid name loading…)"
        let dev = cachedDeviceDisplayName() ?? UIDevice.current.model
        Text("\(name) — \(dev)")
            .font(.system(size: 14, weight: .bold, design: .monospaced))
        Text("\(UIDevice.current.model) (\(hardwareIdentifier())) iOS \(UIDevice.current.systemVersion)")
        Text(Self.dateStampFormatter.string(from: now))
    }

    private static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy HH:mm:ss EEE"
        return f
    }()

    @ViewBuilder
    private var modeBlock: some View {
        let mode = appState.currentEffectivePolicy?.resolvedMode.rawValue ?? "?"
        let isTemp = appState.currentEffectivePolicy?.isTemporaryUnlock == true
        let tempExpiry = appState.storage.readTemporaryUnlockState()?.expiresAt
        let timedInfo = appState.storage.readTimedUnlockInfo()
        let lockUntil: Date? = {
            let defaults = UserDefaults.appGroup
            let ts = defaults?.double(forKey: AppGroupKeys.lockUntilExpiresAt) ?? 0
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }()
        let sched = appState.storage.readActiveScheduleProfile()
        let scheduleDriven: String = {
            let defaults = UserDefaults.appGroup
            guard let v = defaults?.object(forKey: AppGroupKeys.scheduleDrivenMode) as? Bool else { return "?" }
            return v ? "yes" : "no"
        }()

        Text("MODE: \(mode)  schedDriven:\(scheduleDriven)")
        if let sched {
            let curMode = sched.resolvedMode(at: now).rawValue
            let nextT = sched.nextTransitionTime(from: now)
            let nextStr: String = {
                guard let nextT else { return "-" }
                let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
                return f.string(from: nextT) + " (\(futureAge(nextT)))"
            }()
            Text("SCH: \"\(sched.name)\" now:\(curMode) next:\(nextStr)")
        } else {
            Text("SCH: (none)")
        }
        let tmpStr = tempExpiry.map { "until \(timeStr($0)) (\(futureAge($0)))" } ?? "off"
        let timedStr = timedPhaseDescription(timedInfo)
        Text("TMP: \(tmpStr)")
        Text("TIMED: \(timedStr)")
        Text("LCK: \(lockUntil.map { "until \(timeStr($0)) (\(futureAge($0)))" } ?? "off")  isTempFlag:\(isTemp ? "yes" : "no")")
    }

    private func timedPhaseDescription(_ info: TimedUnlockInfo?) -> String {
        guard let info else { return "off" }
        if now < info.unlockAt {
            return "penalty until \(timeStr(info.unlockAt)) (\(futureAge(info.unlockAt)))"
        } else if now < info.lockAt {
            return "free until \(timeStr(info.lockAt)) (\(futureAge(info.lockAt)))"
        } else {
            return "expired \(absAge(info.lockAt.timeIntervalSince1970))"
        }
    }

    @ViewBuilder
    private var networkBlock: some View {
        let defaults = UserDefaults.appGroup
        let vpn = appState.vpnManager?.connectionStatus.rawValue ?? -1
        let vpnStr = vpnStatusString(vpn)
        let tunnelLast = defaults?.double(forKey: AppGroupKeys.tunnelLastActiveAt) ?? 0
        let mainAliveLast = defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
        let internetBlockUntil = defaults?.double(forKey: AppGroupKeys.internetBlockedUntil) ?? 0
        let tunnelInetBlocked = defaults?.bool(forKey: AppGroupKeys.tunnelInternetBlocked) ?? false
        let tunnelInetReason = defaults?.string(forKey: AppGroupKeys.tunnelInternetBlockedReason) ?? ""
        let dnsJson = defaults?.string(forKey: AppGroupKeys.dnsFilteringStateJSON) ?? ""
        let buildMismatch = defaults?.bool(forKey: AppGroupKeys.buildMismatchDNSBlock) == true

        Text("NET: \(networkLabel())")
        Text("VPN: \(vpnStr)")
        Text("TUN: last \(absAge(tunnelLast))  MAIN: last \(absAge(mainAliveLast))")

        if internetBlockUntil > now.timeIntervalSince1970 {
            let untilDate = Date(timeIntervalSince1970: internetBlockUntil)
            Text("INET: BLOCKED until \(timeStr(untilDate)) (\(futureAge(untilDate)))")
                .foregroundStyle(.red)
        } else if tunnelInetBlocked {
            Text("INET: BLOCKED (tunnel)")
                .foregroundStyle(.red)
            if !tunnelInetReason.isEmpty {
                Text("  reason: \(tunnelInetReason)")
                    .foregroundStyle(.red)
            }
        } else {
            Text("INET: allowed")
        }

        if buildMismatch {
            Text("BLD MISMATCH: dns block active")
                .foregroundStyle(.orange)
        }

        // Parse DNS blackhole reasons if present
        if let data = dnsJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let reasons = obj["activeReasons"] as? [String] ?? []
            if reasons.isEmpty {
                Text("DNS: clean (no blackhole)")
            } else {
                Text("DNS BLACKHOLE: \(reasons.joined(separator: ","))")
                    .foregroundStyle(.red)
            }
        } else {
            Text("DNS: -")
        }
    }

    @ViewBuilder
    private var dnsStatsBlock: some View {
        let defaults = UserDefaults.appGroup
        let total = defaults?.integer(forKey: AppGroupKeys.dnsActivityTotalQueries) ?? 0
        let date = defaults?.string(forKey: AppGroupKeys.dnsActivityDate) ?? "?"
        let hits = decodeDNSDomainHits().sorted { $0.count > $1.count }
        let top = Array(hits.prefix(8))
        Text("DNS today (\(date)): \(total) queries  domains:\(hits.count)")
        if top.isEmpty {
            Text("  (no domains tracked — tunnel may not be receiving DNS)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.orange)
        } else {
            ForEach(top.indices, id: \.self) { i in
                let h = top[i]
                let flag = h.flagged ? " [\(h.category ?? "flagged")]" : ""
                Text("  \(h.count)× \(h.domain)\(flag)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func decodeDNSDomainHits() -> [DomainHit] {
        guard let data = UserDefaults.appGroup?.data(forKey: AppGroupKeys.dnsActivityDomains) else { return [] }
        return (try? JSONDecoder().decode([DomainHit].self, from: data)) ?? []
    }

    @ViewBuilder
    private var heartbeatHistoryBlock: some View {
        let ring = decodeHeartbeatRing()
        if ring.isEmpty {
            Text("HB history: (none yet — first HB pending)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text("HB history (last \(ring.count)):")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            ForEach(ring.indices, id: \.self) { i in
                let e = ring[i]
                let d = Date(timeIntervalSince1970: e.epoch)
                Text("  #\(e.seq)  \(Self.hmsFormatter.string(from: d)) (\(compactAge(e.epoch)) ago)  \(e.mode)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func decodeHeartbeatRing() -> [HeartbeatRingEntry] {
        guard let data = UserDefaults.appGroup?.data(forKey: AppGroupKeys.recentHeartbeats) else { return [] }
        return (try? JSONDecoder().decode([HeartbeatRingEntry].self, from: data)) ?? []
    }

    @ViewBuilder
    private var heartbeatBlock: some View {
        let defaults = UserDefaults.appGroup
        let lastHBSentAt = defaults?.double(forKey: AppGroupKeys.lastHeartbeatSentAt) ?? 0
        let monitorLast = defaults?.double(forKey: AppGroupKeys.monitorLastActiveAt) ?? 0
        let tunnelLast = defaults?.double(forKey: AppGroupKeys.tunnelLastActiveAt) ?? 0
        let mainLast = defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
        let monitorReconcile = defaults?.double(forKey: AppGroupKeys.monitorLastReconcileAt) ?? 0

        Text("HB sent: \(absAge(lastHBSentAt))")
        Text("ALIVE  main:\(compactAge(mainLast))  mon:\(compactAge(monitorLast))  tun:\(compactAge(tunnelLast))")
        if monitorReconcile > 0 {
            Text("MON reconcile: \(absAge(monitorReconcile))")
        }
    }

    @ViewBuilder
    private var permissionsBlock: some View {
        let allOK = UserDefaults.appGroup?.bool(forKey: AppGroupKeys.allPermissionsGranted) ?? false
        Text("PERM: FC:\(fcAuthString)  LOC:\(locAuthString)  MOT:\(motionAuthString)  NOTIF:\(notifAuthString)")
        Text("      allGranted:\(allOK ? "yes" : "NO")")
            .foregroundStyle(allOK ? Color.primary : Color.orange)
    }

    @ViewBuilder
    private var cloudKitBlock: some View {
        let defaults = UserDefaults.appGroup
        let apnsAt = defaults?.double(forKey: AppGroupKeys.apnsTokenRegisteredAt) ?? 0
        let apnsErr = defaults?.string(forKey: AppGroupKeys.apnsTokenError) ?? ""
        let lastPush = defaults?.double(forKey: AppGroupKeys.lastPushReceivedAt) ?? 0
        let ckStatus = UserDefaults.appGroup?.integer(forKey: "lastCKAccountStatus") ?? -1
        let ckStatusStr = ckStatusString(ckStatus)

        Text("CK: \(ckStatusStr)  APNS: \(apnsAt > 0 ? "reg \(absAge(apnsAt))" : "NONE")")
        if !apnsErr.isEmpty {
            Text("  apns err: \(apnsErr.prefix(40))")
                .foregroundStyle(.orange)
        }
        Text("PUSH: last \(absAge(lastPush))")
    }

    @ViewBuilder
    private var appsBlock: some View {
        let limits = appState.storage.readAppTimeLimits()
        let exhausted = appState.storage.readTimeLimitExhaustedApps()
        let allowedCount = decodeAllowedTokenCount()
        let shielded = UserDefaults.appGroup?.integer(forKey: AppGroupKeys.shieldedAppCount) ?? 0
        let pendingCount: Int = {
            guard let data = appState.storage.readRawData(forKey: AppGroupKeys.pendingReviewLocalJSON) else { return 0 }
            return (try? JSONDecoder().decode([PendingAppReview].self, from: data))?.count ?? 0
        }()

        Text("APPS  allowed:\(allowedCount)  limited:\(limits.count)  exhausted:\(exhausted.count)")
        Text("      shielded:\(shielded)  pending:\(pendingCount)")
    }

    /// Wrapped in a function so the FamilyControls-only `Set<ApplicationToken>`
    /// type doesn't appear inside a ViewBuilder, which confuses the compiler
    /// when FamilyControls is unavailable (e.g. simulator).
    private func decodeAllowedTokenCount() -> Int {
        guard let data = appState.storage.readRawData(forKey: StorageKeys.allowedAppTokens) else { return 0 }
        #if canImport(FamilyControls)
        if let set = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
            return set.count
        }
        #endif
        return 0
    }

    @ViewBuilder
    private var commandsBlock: some View {
        let defaults = UserDefaults.appGroup
        let lastCmdAt = defaults?.double(forKey: AppGroupKeys.lastCommandProcessedAt) ?? 0
        let lastCmdID = defaults?.string(forKey: AppGroupKeys.lastCommandID) ?? ""
        let applyStart = defaults?.double(forKey: AppGroupKeys.enforcementApplyStartedAt) ?? 0
        let applyEnd = defaults?.double(forKey: AppGroupKeys.enforcementApplyFinishedAt) ?? 0
        let lastShieldReason = defaults?.string(forKey: AppGroupKeys.lastShieldChangeReason) ?? "-"
        let lastShieldAudit = defaults?.string(forKey: AppGroupKeys.lastShieldAudit) ?? "-"

        Text("CMD  last \(absAge(lastCmdAt))  id:\(lastCmdID.prefix(8))")
        Text("APPLY start:\(absAge(applyStart))  end:\(absAge(applyEnd))")
        Text("SHIELD \(lastShieldReason) / \(lastShieldAudit.prefix(50))")
    }

    @ViewBuilder
    private var buildsBlock: some View {
        let defaults = UserDefaults.appGroup
        let app = AppConstants.appBuildNumber
        let mon = defaults?.integer(forKey: AppGroupKeys.monitorBuildNumber) ?? 0
        let sh = defaults?.integer(forKey: AppGroupKeys.shieldBuildNumber) ?? 0
        let sha = defaults?.integer(forKey: AppGroupKeys.shieldActionBuildNumber) ?? 0
        let tun = defaults?.integer(forKey: AppGroupKeys.tunnelBuildNumber) ?? 0
        // sh/sha stay at 0 until the extension first runs — that's normal on
        // a quiet device. Only flag MISMATCH when the extension HAS run
        // (value != 0) and disagrees with the app build.
        let mismatch = (mon != 0 && mon != app) || (tun != 0 && tun != app) || (sh != 0 && sh != app) || (sha != 0 && sha != app)
        Text("BLD  app:\(app) mon:\(mon) sh:\(sh) sha:\(sha) tun:\(tun)\(mismatch ? "  ⚠️ MISMATCH" : "")")
            .foregroundStyle(mismatch ? Color.orange : Color.primary)
    }

    @ViewBuilder
    private var restrictionsBlock: some View {
        let r = appState.storage.readDeviceRestrictions() ?? DeviceRestrictions()
        Text("RESTRICT  denyWebRestricted:\(boolStr(r.denyWebWhenRestricted))  denyAppRemoval:\(boolStr(r.denyAppRemoval))")
        Text("          denyExplicit:\(boolStr(r.denyExplicitContent))  lockAccts:\(boolStr(r.lockAccounts))  autoDT:\(boolStr(r.requireAutomaticDateAndTime))")
    }

    @ViewBuilder
    private var scheduleWindowsBlock: some View {
        if let sched = appState.storage.readActiveScheduleProfile() {
            Text("SCHED \"\(sched.name)\"  lockedMode:\(sched.lockedMode.rawValue)")
            if sched.unlockedWindows.isEmpty && sched.lockedWindows.isEmpty {
                Text("  (no windows)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                if !sched.unlockedWindows.isEmpty {
                    Text("  unlocked:")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ForEach(sched.unlockedWindows.indices, id: \.self) { i in
                        Text("    \(windowDescription(sched.unlockedWindows[i]))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if !sched.lockedWindows.isEmpty {
                    Text("  locked:")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ForEach(sched.lockedWindows.indices, id: \.self) { i in
                        Text("    \(windowDescription(sched.lockedWindows[i]))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("SCHED: (no active profile)")
        }
    }

    @ViewBuilder
    private var timeLimitsBlock: some View {
        let limits = appState.storage.readAppTimeLimits()
        let exhausted = appState.storage.readTimeLimitExhaustedApps()
        let exhaustedFPs = Set(exhausted.map(\.fingerprint))
        if limits.isEmpty {
            Text("LIMITS: (none)")
        } else {
            Text("LIMITS (\(limits.count)):")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            ForEach(limits.indices, id: \.self) { i in
                let l = limits[i]
                let exhaustedMark = exhaustedFPs.contains(l.fingerprint) ? " [EXHAUSTED]" : ""
                Text("  \(l.appName.prefix(28)): \(l.dailyLimitMinutes)m/day\(exhaustedMark)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var eventLogBlock: some View {
        let events = Array(appState.storage.readPendingEventLogs().suffix(10))
        if events.isEmpty {
            Text("EVENTS: (queue empty)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text("EVENTS pending upload (last \(events.count)):")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            ForEach(events.indices, id: \.self) { i in
                Text("  \(Self.hmsFormatter.string(from: events[i].timestamp)) \(events[i].eventType.rawValue) — \(String((events[i].details ?? "").prefix(60)))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func windowDescription(_ w: ActiveWindow) -> String {
        let days = w.daysOfWeek.sorted().map { dayAbbrev($0.rawValue) }.joined(separator: "")
        let start = String(format: "%02d:%02d", w.startTime.hour, w.startTime.minute)
        let end = String(format: "%02d:%02d", w.endTime.hour, w.endTime.minute)
        return "\(days) \(start)-\(end)"
    }

    private func dayAbbrev(_ d: Int) -> String {
        switch d {
        case 1: return "Su"
        case 2: return "M"
        case 3: return "Tu"
        case 4: return "W"
        case 5: return "Th"
        case 6: return "F"
        case 7: return "Sa"
        default: return "?"
        }
    }

    private func boolStr(_ b: Bool) -> String { b ? "yes" : "no" }

    @ViewBuilder
    private var systemBlock: some View {
        Text("SYS  bat:\(batteryDescription())  lowPower:\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no")  thermal:\(thermalDescription())")
        Text("     free:\(freeDiskDescription())")
    }

    private func batteryDescription() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return "?" }
        let pct = Int(level * 100)
        let state: String = {
            switch UIDevice.current.batteryState {
            case .charging: return "chg"
            case .full: return "full"
            case .unplugged: return "unplug"
            case .unknown: return "?"
            @unknown default: return "?"
            }
        }()
        return "\(pct)% \(state)"
    }

    private func thermalDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "?"
        }
    }

    private func freeDiskDescription() -> String {
        guard let bytes = freeDiskBytes() else { return "?" }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    @ViewBuilder
    private var diagEntriesBlock: some View {
        let entries = Array(appState.storage.readDiagnosticEntries(category: nil).suffix(20))
        if entries.isEmpty {
            Text("DIAG: (no recent entries)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text("DIAG (last \(entries.count)):")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            ForEach(entries.indices, id: \.self) { i in
                Text("• \(Self.hmsFormatter.string(from: entries[i].timestamp)) [\(entries[i].category.rawValue)] \(String(entries[i].message.prefix(80)))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private static let hmsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func freeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return bytes
    }

    @ViewBuilder
    private var idsBlock: some View {
        let enroll = appState.enrollmentState
        let fam = enroll?.familyID.rawValue ?? "?"
        let dev = enroll?.deviceID.rawValue ?? "?"
        let prof = enroll?.childProfileID.rawValue ?? "?"
        Text("IDS  fam:\(shortID(fam))  dev:\(shortID(dev))  prof:\(shortID(prof))")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 0.5)
            .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private func cachedDeviceDisplayName() -> String? {
        guard let data = appState.storage.readRawData(forKey: StorageKeys.cachedEnrollmentIDs),
              let cached = try? JSONDecoder().decode(CachedEnrollmentIDs.self, from: data) else { return nil }
        return cached.deviceDisplayName
    }

    private func hardwareIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let data = Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN))
        return String(data: data, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? "?"
    }

    private func refreshAuthStrings() {
        #if canImport(FamilyControls)
        if let enf = appState.enforcement {
            switch enf.authorizationStatus {
            case .authorized: fcAuthString = "auth"
            case .denied: fcAuthString = "DENY"
            case .notDetermined: fcAuthString = "n/d"
            }
        } else {
            fcAuthString = "n/a"
        }
        #else
        fcAuthString = "n/a"
        #endif

        switch locationManager.authorizationStatus {
        case .authorizedAlways: locAuthString = "always"
        case .authorizedWhenInUse: locAuthString = "wiu"
        case .denied: locAuthString = "DENY"
        case .restricted: locAuthString = "RSTR"
        case .notDetermined: locAuthString = "n/d"
        @unknown default: locAuthString = "?"
        }

        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: motionAuthString = "auth"
        case .denied: motionAuthString = "DENY"
        case .restricted: motionAuthString = "RSTR"
        case .notDetermined: motionAuthString = "n/d"
        @unknown default: motionAuthString = "?"
        }

        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized: notifAuthString = "auth"
            case .denied: notifAuthString = "DENY"
            case .notDetermined: notifAuthString = "n/d"
            case .provisional: notifAuthString = "prov"
            case .ephemeral: notifAuthString = "eph"
            @unknown default: notifAuthString = "?"
            }
        }
    }

    /// Clean network label with hotspot detection built in.
    /// A wifi interface marked "expensive" is iOS's signal that the Wi-Fi
    /// network is actually a Personal Hotspot being shared by another
    /// Apple device — shows up as `wifi-hotspot`. Cellular + expensive is
    /// redundant so we just say `cell`.
    private func networkLabel() -> String {
        let nm = appState.networkMonitor
        guard nm.isConnected else { return "OFFLINE" }
        var kind = nm.interfaceKind
        if kind == "wifi" && nm.isExpensive {
            kind = "wifi-hotspot"
        }
        var flags: [String] = []
        if nm.isConstrained { flags.append("lowData") }
        let flagStr = flags.isEmpty ? "" : " (\(flags.joined(separator: ",")))"
        return "online via \(kind)\(flagStr)"
    }

    private func vpnStatusString(_ raw: Int) -> String {
        switch raw {
        case 0: return "invalid"
        case 1: return "disconnected"
        case 2: return "connecting"
        case 3: return "connected"
        case 4: return "reasserting"
        case 5: return "disconnecting"
        default: return "?(\(raw))"
        }
    }

    private func ckStatusString(_ raw: Int) -> String {
        switch raw {
        case 0: return "couldNotDetermine"
        case 1: return "available"
        case 2: return "restricted"
        case 3: return "noAccount"
        case 4: return "tempUnavail"
        default: return "unknown"
        }
    }

    /// "12:45:03" (absolute) + " (3m ago)" if the timestamp is non-zero.
    private func absAge(_ epochSeconds: TimeInterval) -> String {
        guard epochSeconds > 0 else { return "never" }
        let d = Date(timeIntervalSince1970: epochSeconds)
        let delta = max(0, now.timeIntervalSince(d))
        return "\(timeStr(d)) (\(compactDelta(delta)) ago)"
    }

    /// Compact age string like "3s" or "42m" or "2h15m" — for inline use.
    private func compactAge(_ epochSeconds: TimeInterval) -> String {
        guard epochSeconds > 0 else { return "never" }
        let delta = max(0, now.timeIntervalSince(Date(timeIntervalSince1970: epochSeconds)))
        return compactDelta(delta)
    }

    private func futureAge(_ date: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "past" }
        return "in \(compactDelta(delta))"
    }

    private func compactDelta(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        if s < 86400 {
            let h = s / 3600
            let m = (s % 3600) / 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(s/86400)d"
    }

    private func timeStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func shortID(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(6))..\(s.suffix(4))"
    }

    // MARK: - Plain Text Dump (for clipboard / text message)

    /// Builds a plain text version of every diagnostic section. Designed
    /// to paste into a text message to the parent — human-readable but
    /// still compact. Must cover the same ground as the on-screen view.
    private func buildPlainTextDump() -> String {
        var lines: [String] = []
        let defaults = UserDefaults.appGroup
        let enroll = appState.enrollmentState

        // Header
        lines.append("— BigBrother Diagnostics —")
        let name = childName ?? (UserDefaults.appGroup?.string(forKey: "cachedChildName") ?? "(kid)")
        let dev = cachedDeviceDisplayName() ?? UIDevice.current.model
        lines.append("\(name) — \(dev)")
        lines.append("\(UIDevice.current.model) (\(hardwareIdentifier())) iOS \(UIDevice.current.systemVersion)")
        lines.append(Self.dateStampFormatter.string(from: now))
        lines.append("")

        // Mode
        let mode = appState.currentEffectivePolicy?.resolvedMode.rawValue ?? "?"
        let isTemp = appState.currentEffectivePolicy?.isTemporaryUnlock == true
        let schedDriven = (defaults?.object(forKey: AppGroupKeys.scheduleDrivenMode) as? Bool).map { $0 ? "yes" : "no" } ?? "?"
        lines.append("MODE: \(mode)  schedDriven:\(schedDriven)  isTempFlag:\(isTemp ? "yes" : "no")")
        if let sched = appState.storage.readActiveScheduleProfile() {
            let curMode = sched.resolvedMode(at: now).rawValue
            let nextT = sched.nextTransitionTime(from: now)
            let nextStr: String = {
                guard let nextT else { return "-" }
                let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
                return "\(f.string(from: nextT)) (\(futureAge(nextT)))"
            }()
            lines.append("SCH: \"\(sched.name)\" now:\(curMode) next:\(nextStr)")
        } else {
            lines.append("SCH: (none)")
        }
        if let tempExpiry = appState.storage.readTemporaryUnlockState()?.expiresAt {
            lines.append("TMP: until \(timeStr(tempExpiry)) (\(futureAge(tempExpiry)))")
        } else {
            lines.append("TMP: off")
        }
        lines.append("TIMED: \(timedPhaseDescription(appState.storage.readTimedUnlockInfo()))")
        let lockUntilTS = defaults?.double(forKey: AppGroupKeys.lockUntilExpiresAt) ?? 0
        if lockUntilTS > 0 {
            let d = Date(timeIntervalSince1970: lockUntilTS)
            lines.append("LCK: until \(timeStr(d)) (\(futureAge(d)))")
        } else {
            lines.append("LCK: off")
        }
        lines.append("")

        // Network / Internet
        lines.append("NET: \(networkLabel())")
        let vpnRaw = appState.vpnManager?.connectionStatus.rawValue ?? -1
        lines.append("VPN: \(vpnStatusString(vpnRaw))")
        lines.append("TUN last alive: \(absAge(defaults?.double(forKey: AppGroupKeys.tunnelLastActiveAt) ?? 0))")
        let inetUntil = defaults?.double(forKey: AppGroupKeys.internetBlockedUntil) ?? 0
        let tunInetBlocked = defaults?.bool(forKey: AppGroupKeys.tunnelInternetBlocked) ?? false
        let tunInetReason = defaults?.string(forKey: AppGroupKeys.tunnelInternetBlockedReason) ?? ""
        if inetUntil > now.timeIntervalSince1970 {
            let d = Date(timeIntervalSince1970: inetUntil)
            lines.append("INET: BLOCKED until \(timeStr(d)) (\(futureAge(d)))")
        } else if tunInetBlocked {
            lines.append("INET: BLOCKED (tunnel)\(tunInetReason.isEmpty ? "" : " — \(tunInetReason)")")
        } else {
            lines.append("INET: allowed")
        }
        if defaults?.bool(forKey: AppGroupKeys.buildMismatchDNSBlock) == true {
            lines.append("BLD MISMATCH: dns block active")
        }
        if let s = defaults?.string(forKey: AppGroupKeys.dnsFilteringStateJSON),
           let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let reasons = obj["activeReasons"] as? [String] ?? []
            lines.append("DNS: \(reasons.isEmpty ? "clean" : "blackhole: \(reasons.joined(separator: ","))")")
        } else {
            lines.append("DNS: -")
        }
        lines.append("")

        // DNS stats (tunnel DNSProxy)
        let totalQueries = defaults?.integer(forKey: AppGroupKeys.dnsActivityTotalQueries) ?? 0
        let dnsDate = defaults?.string(forKey: AppGroupKeys.dnsActivityDate) ?? "?"
        let hits = decodeDNSDomainHits().sorted { $0.count > $1.count }
        lines.append("DNS today (\(dnsDate)): \(totalQueries) queries, \(hits.count) unique domains")
        if hits.isEmpty {
            lines.append("  (!) no domains tracked — tunnel DNS proxy may not be receiving traffic")
        } else {
            for h in hits.prefix(10) {
                let flag = h.flagged ? " [\(h.category ?? "flagged")]" : ""
                lines.append("  \(h.count)× \(h.domain)\(flag)")
            }
        }
        lines.append("")

        // Heartbeat / liveness
        lines.append("HB sent: \(absAge(defaults?.double(forKey: AppGroupKeys.lastHeartbeatSentAt) ?? 0))")
        lines.append("ALIVE  main:\(compactAge(defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0))"
                     + "  mon:\(compactAge(defaults?.double(forKey: AppGroupKeys.monitorLastActiveAt) ?? 0))"
                     + "  tun:\(compactAge(defaults?.double(forKey: AppGroupKeys.tunnelLastActiveAt) ?? 0))")
        let ring = decodeHeartbeatRing()
        if !ring.isEmpty {
            lines.append("HB history (last \(ring.count)):")
            for e in ring {
                let d = Date(timeIntervalSince1970: e.epoch)
                lines.append("  #\(e.seq)  \(Self.hmsFormatter.string(from: d)) (\(compactAge(e.epoch)) ago)  \(e.mode)")
            }
        }
        lines.append("")

        // Permissions
        let allOK = defaults?.bool(forKey: AppGroupKeys.allPermissionsGranted) ?? false
        lines.append("PERM: FC:\(fcAuthString) LOC:\(locAuthString) MOT:\(motionAuthString) NOTIF:\(notifAuthString) all:\(allOK ? "yes" : "NO")")
        lines.append("")

        // CK / APNs
        let ckStatus = ckStatusString(defaults?.integer(forKey: "lastCKAccountStatus") ?? -1)
        let apnsAt = defaults?.double(forKey: AppGroupKeys.apnsTokenRegisteredAt) ?? 0
        let apnsErr = defaults?.string(forKey: AppGroupKeys.apnsTokenError) ?? ""
        let lastPush = defaults?.double(forKey: AppGroupKeys.lastPushReceivedAt) ?? 0
        lines.append("CK: \(ckStatus)  APNS reg: \(apnsAt > 0 ? absAge(apnsAt) : "NONE")")
        if !apnsErr.isEmpty { lines.append("  apns err: \(apnsErr)") }
        lines.append("PUSH last: \(absAge(lastPush))")
        lines.append("")

        // Apps
        let limits = appState.storage.readAppTimeLimits()
        let exhausted = appState.storage.readTimeLimitExhaustedApps()
        let allowed = decodeAllowedTokenCount()
        let shielded = defaults?.integer(forKey: AppGroupKeys.shieldedAppCount) ?? 0
        let pending: Int = {
            guard let data = appState.storage.readRawData(forKey: AppGroupKeys.pendingReviewLocalJSON) else { return 0 }
            return (try? JSONDecoder().decode([PendingAppReview].self, from: data))?.count ?? 0
        }()
        lines.append("APPS allowed:\(allowed) limited:\(limits.count) exhausted:\(exhausted.count) shielded:\(shielded) pending:\(pending)")
        lines.append("")

        // Commands
        let lastCmdAt = defaults?.double(forKey: AppGroupKeys.lastCommandProcessedAt) ?? 0
        let lastCmdID = defaults?.string(forKey: AppGroupKeys.lastCommandID) ?? ""
        let applyStart = defaults?.double(forKey: AppGroupKeys.enforcementApplyStartedAt) ?? 0
        let applyEnd = defaults?.double(forKey: AppGroupKeys.enforcementApplyFinishedAt) ?? 0
        let shieldReason = defaults?.string(forKey: AppGroupKeys.lastShieldChangeReason) ?? "-"
        let shieldAudit = defaults?.string(forKey: AppGroupKeys.lastShieldAudit) ?? "-"
        lines.append("CMD last: \(absAge(lastCmdAt))  id:\(lastCmdID.prefix(8))")
        lines.append("APPLY start:\(absAge(applyStart))  end:\(absAge(applyEnd))")
        lines.append("SHIELD: \(shieldReason) / \(shieldAudit)")
        lines.append("")

        // Builds
        let app = AppConstants.appBuildNumber
        let mon = defaults?.integer(forKey: AppGroupKeys.monitorBuildNumber) ?? 0
        let sh = defaults?.integer(forKey: AppGroupKeys.shieldBuildNumber) ?? 0
        let sha = defaults?.integer(forKey: AppGroupKeys.shieldActionBuildNumber) ?? 0
        let tun = defaults?.integer(forKey: AppGroupKeys.tunnelBuildNumber) ?? 0
        let mismatch = (mon != 0 && mon != app) || (tun != 0 && tun != app) || (sh != 0 && sh != app) || (sha != 0 && sha != app)
        lines.append("BLD  app:\(app) mon:\(mon) sh:\(sh) sha:\(sha) tun:\(tun)\(mismatch ? "  ⚠️ MISMATCH" : "")")
        lines.append("")

        // Device restrictions
        let r = appState.storage.readDeviceRestrictions() ?? DeviceRestrictions()
        lines.append("RESTRICT denyWebRestricted:\(boolStr(r.denyWebWhenRestricted)) denyAppRemoval:\(boolStr(r.denyAppRemoval)) denyExplicit:\(boolStr(r.denyExplicitContent)) lockAccts:\(boolStr(r.lockAccounts)) autoDT:\(boolStr(r.requireAutomaticDateAndTime))")
        lines.append("")

        // Schedule windows
        if let sched = appState.storage.readActiveScheduleProfile() {
            lines.append("SCHED \"\(sched.name)\" lockedMode:\(sched.lockedMode.rawValue)")
            if !sched.unlockedWindows.isEmpty {
                lines.append("  unlocked windows:")
                for w in sched.unlockedWindows {
                    lines.append("    " + windowDescription(w))
                }
            }
            if !sched.lockedWindows.isEmpty {
                lines.append("  locked windows:")
                for w in sched.lockedWindows {
                    lines.append("    " + windowDescription(w))
                }
            }
        } else {
            lines.append("SCHED: (no active profile)")
        }
        lines.append("")

        // Time limits
        let allLimits = appState.storage.readAppTimeLimits()
        let exhaustedApps = appState.storage.readTimeLimitExhaustedApps()
        let exhaustedFPs = Set(exhaustedApps.map(\.fingerprint))
        if allLimits.isEmpty {
            lines.append("LIMITS: (none)")
        } else {
            lines.append("LIMITS (\(allLimits.count)):")
            for l in allLimits {
                let mark = exhaustedFPs.contains(l.fingerprint) ? " [EXHAUSTED]" : ""
                lines.append("  \(l.appName): \(l.dailyLimitMinutes)m/day\(mark)")
            }
        }
        lines.append("")

        // System
        UIDevice.current.isBatteryMonitoringEnabled = true
        let bat = UIDevice.current.batteryLevel
        let batPct = bat < 0 ? "?" : "\(Int(bat * 100))%"
        let batState: String = {
            switch UIDevice.current.batteryState {
            case .charging: return "chg"
            case .full: return "full"
            case .unplugged: return "unplug"
            default: return "?"
            }
        }()
        let thermal: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "SERIOUS"
            case .critical: return "CRITICAL"
            @unknown default: return "?"
            }
        }()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no"
        let freeGB = freeDiskBytes().map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "?"
        lines.append("SYS bat:\(batPct) \(batState)  lowPower:\(lowPower)  thermal:\(thermal)  free:\(freeGB)")
        lines.append("")

        // Event log (last 10 pending)
        let events = Array(appState.storage.readPendingEventLogs().suffix(10))
        if !events.isEmpty {
            lines.append("EVENTS pending upload (last \(events.count)):")
            for e in events {
                lines.append("  \(Self.hmsFormatter.string(from: e.timestamp)) \(e.eventType.rawValue) — \((e.details ?? "").prefix(80))")
            }
            lines.append("")
        }

        // Recent diagnostic entries
        let recent = Array(appState.storage.readDiagnosticEntries(category: nil).suffix(20))
        if !recent.isEmpty {
            lines.append("DIAG (last \(recent.count)):")
            for entry in recent {
                lines.append("  \(Self.hmsFormatter.string(from: entry.timestamp)) [\(entry.category.rawValue)] \(entry.message.prefix(100))")
            }
            lines.append("")
        }

        // IDs
        lines.append("FAM:\(enroll?.familyID.rawValue ?? "?")")
        lines.append("DEV:\(enroll?.deviceID.rawValue ?? "?")")
        lines.append("PROF:\(enroll?.childProfileID.rawValue ?? "?")")

        return lines.joined(separator: "\n")
    }
}
