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

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
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
                    heartbeatBlock
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
                    idsBlock
                }
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onReceive(timer) { now = $0 }
            .onAppear {
                refreshAuthStrings()
            }
            .onReceive(timer) { _ in
                refreshAuthStrings()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerBlock: some View {
        Text(cachedDeviceDisplayName() ?? "device")
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
        let netConnected = appState.networkMonitor.isConnected
        let vpn = appState.vpnManager?.connectionStatus.rawValue ?? -1
        let vpnStr = vpnStatusString(vpn)
        let tunnelLast = defaults?.double(forKey: AppGroupKeys.tunnelLastActiveAt) ?? 0
        let mainAliveLast = defaults?.double(forKey: AppGroupKeys.mainAppLastActiveAt) ?? 0
        let internetBlockUntil = defaults?.double(forKey: AppGroupKeys.internetBlockedUntil) ?? 0
        let tunnelInetBlocked = defaults?.bool(forKey: AppGroupKeys.tunnelInternetBlocked) ?? false
        let tunnelInetReason = defaults?.string(forKey: AppGroupKeys.tunnelInternetBlockedReason) ?? ""
        let dnsJson = defaults?.string(forKey: AppGroupKeys.dnsFilteringStateJSON) ?? ""
        let buildMismatch = defaults?.bool(forKey: AppGroupKeys.buildMismatchDNSBlock) == true

        Text("NET: \(netConnected ? "online" : "OFFLINE")  VPN: \(vpnStr)")
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
        let mismatch = (mon != 0 && mon != app) || (tun != 0 && tun != app) || (sh != 0 && sh != app)
        Text("BLD  app:\(app) mon:\(mon) sh:\(sh) sha:\(sha) tun:\(tun)")
            .foregroundStyle(mismatch ? .orange : .primary)
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
        let delta = now.timeIntervalSince(d)
        return "\(timeStr(d)) (\(compactDelta(delta)) ago)"
    }

    /// Compact age string like "3s" or "42m" or "2h15m" — for inline use.
    private func compactAge(_ epochSeconds: TimeInterval) -> String {
        guard epochSeconds > 0 else { return "never" }
        let delta = now.timeIntervalSince(Date(timeIntervalSince1970: epochSeconds))
        return compactDelta(delta)
    }

    private func futureAge(_ date: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "past" }
        return "in \(compactDelta(delta))"
    }

    private func compactDelta(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
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
}
