#if canImport(FamilyControls)
import SwiftUI
import FamilyControls
import ManagedSettings
import BigBrotherCore

/// Picker for selecting apps to track with time limits.
/// Streamlined flow: parent triggers → picker opens on child → select one or more apps → done.
/// Names are captured automatically from the picker. Default limit is 60 minutes.
/// Parent can adjust limits later via long-press in the time limits section.
struct TimeLimitSetupView: View {
    let appState: AppState
    @State private var selection = FamilyActivitySelection()
    @State private var showingPicker = false
    @State private var savedApps: [AppTimeLimit] = []
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var justAdded: Set<String> = []
    @State private var duplicateMessage: String?
    @State private var showNaming = false
    @State private var pendingTokens: [ApplicationToken] = []
    @State private var pendingLimits: [AppTimeLimit] = []
    @State private var enteredNames: [String: String] = [:] // fingerprint -> name
    @State private var lockedNames: Set<String> = [] // fingerprints with CloudKit-resolved names
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !savedApps.isEmpty {
                    Section("Configured") {
                        ForEach(savedApps, id: \.id) { app in
                            HStack {
                                Text(app.appName)
                                    .fontWeight(justAdded.contains(app.fingerprint) ? .semibold : .regular)
                                Spacer()
                                if app.dailyLimitMinutes > 0 {
                                    Text(formatMinutes(app.dailyLimitMinutes))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("No limit set")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                }
                                if justAdded.contains(app.fingerprint) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let decoder = JSONDecoder()
                            for idx in offsets {
                                let app = savedApps[idx]
                                if !app.wasAlreadyAllowed,
                                   let token = try? decoder.decode(ApplicationToken.self, from: app.tokenData) {
                                    removeFromAllowedTokens(token)
                                }
                                deleteFromCloudKit(app)
                            }
                            savedApps.remove(atOffsets: offsets)
                            persistAll()
                            reapplyEnforcement()
                        }
                    }
                }

                if let err = saveError {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if let msg = duplicateMessage {
                    Section {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button {
                        selection = FamilyActivitySelection()
                        showingPicker = true
                    } label: {
                        Label("Select App", systemImage: "plus.app")
                    }
                } footer: {
                    Text("Select one or more apps. They'll be added with a 60-minute daily limit. Adjust from the parent app.")
                }
            }
            .navigationTitle("App Time Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .familyActivityPicker(isPresented: $showingPicker, selection: $selection)
            .onChange(of: selection) { _, newSelection in
                AppNameHarvester.harvest(from: newSelection)
                processPickerSelection(newSelection)
            }
            .onAppear {
                loadExisting()
                if savedApps.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showingPicker = true
                    }
                }
            }
            .sheet(isPresented: $showNaming) {
                namingSheet
            }
        }
    }

    @ViewBuilder
    private var namingSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Type the name you see next to each app icon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Name These Apps") {
                    ForEach(Array(zip(pendingTokens, pendingLimits).enumerated()), id: \.element.1.fingerprint) { idx, pair in
                        let (token, limit) = pair
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                Label(token)
                                    .labelStyle(.titleAndIcon)
                                    .font(.subheadline)
                                    .frame(minWidth: 80, alignment: .leading)
                                    .lineLimit(1)

                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)

                                if lockedNames.contains(limit.fingerprint) {
                                    Text(enteredNames[limit.fingerprint] ?? limit.appName)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                } else {
                                    TextField("Type name", text: nameBinding(for: limit.fingerprint))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.subheadline)
                                        .autocorrectionDisabled()
                                }
                            }

                            Picker("Limit", selection: limitBinding(for: idx)) {
                                Text("Always Allowed").tag(0)
                                Text("15 min").tag(15)
                                Text("30 min").tag(30)
                                Text("1 hour").tag(60)
                                Text("90 min").tag(90)
                                Text("2 hours").tag(120)
                                Text("3 hours").tag(180)
                            }
                            .pickerStyle(.segmented)
                            .font(.caption2)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Name Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        finalizePendingApps()
                        showNaming = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        applyEnteredNames()
                        finalizePendingApps()
                        showNaming = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func nameBinding(for fingerprint: String) -> Binding<String> {
        Binding(
            get: { enteredNames[fingerprint] ?? "" },
            set: { enteredNames[fingerprint] = $0 }
        )
    }

    private func limitBinding(for index: Int) -> Binding<Int> {
        Binding(
            get: { pendingLimits[index].dailyLimitMinutes },
            set: { pendingLimits[index].dailyLimitMinutes = $0 }
        )
    }

    private func applyEnteredNames() {
        for i in pendingLimits.indices {
            let fp = pendingLimits[i].fingerprint
            if let name = enteredNames[fp], !name.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingLimits[i].appName = name.trimmingCharacters(in: .whitespaces)
                pendingLimits[i].pendingNameResolution = false
                pendingLimits[i].resolvedDailyLimitMinutes = nil
            }
        }
    }

    private func finalizePendingApps() {
        // Separate always-allowed (0 min) from time-limited
        let _ = pendingLimits.filter { $0.dailyLimitMinutes == 0 }
        let timeLimited = pendingLimits.filter { $0.dailyLimitMinutes > 0 }

        // Add time-limited apps to saved list
        savedApps.append(contentsOf: timeLimited)
        justAdded = Set(pendingLimits.map(\.fingerprint))
        persistAll()
        reapplyEnforcement()
        ScheduleRegistrar.registerTimeLimitEvents(limits: savedApps)

        // Sync time-limited to CloudKit
        for limit in timeLimited {
            syncToCloudKit(limit)
        }

        // Always-allowed apps don't need time limit configs — just keep in allowed tokens
        // (they were already added to allowedAppTokens in processPickerSelection)

        pendingLimits = []
        pendingTokens = []
        enteredNames = [:]

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            justAdded = []
        }
    }

    /// Process all selected apps from the picker — show naming sheet for parent to enter names.
    private func processPickerSelection(_ sel: FamilyActivitySelection) {
        let storage = AppGroupStorage()
        let encoder = JSONEncoder()
        var added: [AppTimeLimit] = []
        var tokens: [ApplicationToken] = []

        var appByToken: [Data: Application] = [:]
        for application in sel.applications {
            guard let token = application.token,
                  let data = try? encoder.encode(token) else { continue }
            appByToken[data] = application
        }

        for token in sel.applicationTokens {
            guard let data = try? encoder.encode(token) else { continue }
            let fp = TokenFingerprint.fingerprint(for: data)

            if savedApps.contains(where: { $0.fingerprint == fp }) {
                let existingName = savedApps.first(where: { $0.fingerprint == fp })?.appName ?? "app"
                duplicateMessage = "\(existingName) is already configured"
                continue
            }

            let application = appByToken[data]
            let name = application?.localizedDisplayName
                ?? application?.bundleIdentifier
                ?? "App \(savedApps.count + added.count + 1)"

            let alreadyAllowed: Bool = {
                guard let allowedData = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                      let existingTokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: allowedData) else { return false }
                return existingTokens.contains(token)
            }()

            let limit = AppTimeLimit(
                appName: name,
                tokenData: data,
                bundleID: application?.bundleIdentifier,
                fingerprint: fp,
                dailyLimitMinutes: 60,
                wasAlreadyAllowed: alreadyAllowed,
                pendingNameResolution: true,
                resolvedDailyLimitMinutes: 60
            )
            added.append(limit)
            tokens.append(token)

            addToAllowedTokens(token)
            storage.cacheAppName(name, forTokenKey: data.base64EncodedString())

            if let enrollment = try? KeychainManager().get(ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState) {
                let entry = EventLogEntry(
                    deviceID: enrollment.deviceID,
                    familyID: enrollment.familyID,
                    eventType: .timeLimitSetupCompleted,
                    details: "Time limit added: \(name) (60m/day)"
                )
                try? storage.appendEventLog(entry)
            }
        }

        if !added.isEmpty {
            pendingTokens = tokens
            pendingLimits = added
            enteredNames = [:]
            lockedNames = []
            // Look up existing names from CloudKit (preserved from previous add/remove cycles)
            lookupExistingNames(for: added)
            showNaming = true
        }
    }

    private func lookupExistingNames(for limits: [AppTimeLimit]) {
        guard let cloudKit = appState.cloudKit,
              let enrollment = try? KeychainManager().get(
                  ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
              ) else { return }

        // Also check local name cache
        let storage = AppGroupStorage()
        let nameCache = storage.readAllCachedAppNames()
        for limit in limits {
            let tokenKey = limit.tokenData.base64EncodedString()
            if let cached = nameCache[tokenKey], !cached.hasPrefix("App "), !cached.hasPrefix("Temporary") {
                enteredNames[limit.fingerprint] = cached
                lockedNames.insert(limit.fingerprint)
            }
        }

        // Check CloudKit for previously-named apps (includes inactive/revoked)
        Task {
            if let configs = try? await cloudKit.fetchTimeLimitConfigs(childProfileID: enrollment.childProfileID) {
                await MainActor.run {
                    for limit in limits {
                        if let match = configs.first(where: { $0.appFingerprint == limit.fingerprint }),
                           !match.appName.hasPrefix("App "), !match.appName.hasPrefix("Temporary") {
                            enteredNames[limit.fingerprint] = match.appName
                            lockedNames.insert(limit.fingerprint)
                        }
                    }
                }
            }
        }
    }

    private func loadExisting() {
        let storage = AppGroupStorage()
        var apps = storage.readAppTimeLimits()
        apps.removeAll { $0.appName == "App" && $0.dailyLimitMinutes == 0 }
        if apps.count != storage.readAppTimeLimits().count {
            try? storage.writeAppTimeLimits(apps)
        }
        savedApps = apps
    }

    private func syncToCloudKit(_ limit: AppTimeLimit) {
        guard let cloudKit = appState.cloudKit,
              let enrollment = try? KeychainManager().get(
                  ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
              ) else { return }

        // Use the resolved limit for CloudKit, not the 1-minute probe value.
        // This prevents the parent from seeing a confusing 1-minute limit
        // while name resolution is pending on the child device.
        let syncedMinutes = limit.pendingNameResolution == true
            ? (limit.resolvedDailyLimitMinutes ?? 60)
            : limit.dailyLimitMinutes

        let config = TimeLimitConfig(
            familyID: enrollment.familyID,
            childProfileID: enrollment.childProfileID,
            appFingerprint: limit.fingerprint,
            appName: limit.appName.hasPrefix("Temporary Name") ? (limit.bundleID ?? limit.appName) : limit.appName,
            dailyLimitMinutes: syncedMinutes,
            isActive: true
        )
        Task {
            try? await cloudKit.saveTimeLimitConfig(config)
        }
    }

    private func persistAll() {
        let storage = AppGroupStorage()
        do {
            try storage.writeAppTimeLimits(savedApps)
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func addToAllowedTokens(_ token: ApplicationToken) {
        let storage = AppGroupStorage()
        var tokens: Set<ApplicationToken>
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let existing = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
            tokens = existing
        } else {
            tokens = []
        }
        tokens.insert(token)
        if let encoded = try? JSONEncoder().encode(tokens) {
            try? storage.writeRawData(encoded, forKey: StorageKeys.allowedAppTokens)
        }
    }

    private func removeFromAllowedTokens(_ token: ApplicationToken) {
        let storage = AppGroupStorage()
        guard let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
              var tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) else { return }
        tokens.remove(token)
        if let encoded = try? JSONEncoder().encode(tokens) {
            try? storage.writeRawData(encoded, forKey: StorageKeys.allowedAppTokens)
        }
    }

    private func deleteFromCloudKit(_ limit: AppTimeLimit) {
        guard let cloudKit = appState.cloudKit,
              let enrollment = try? KeychainManager().get(
                  ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
              ) else { return }
        Task {
            if let configs = try? await cloudKit.fetchTimeLimitConfigs(childProfileID: enrollment.childProfileID) {
                for config in configs where config.appFingerprint == limit.fingerprint {
                    try? await cloudKit.deleteTimeLimitConfig(config.id)
                }
            }
        }
    }

    private func reapplyEnforcement() {
        if let snapshot = appState.snapshotStore?.loadCurrentSnapshot() {
            try? appState.enforcement?.apply(snapshot.effectivePolicy)
        }
    }

    private func formatMinutes(_ mins: Int) -> String {
        let h = mins / 60, m = mins % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}
#endif
