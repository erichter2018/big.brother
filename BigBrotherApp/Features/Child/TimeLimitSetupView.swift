#if canImport(FamilyControls)
import SwiftUI
import FamilyControls
import ManagedSettings
import BigBrotherCore

/// Picker for selecting apps to track with time limits.
/// Flow: parent triggers from parent UI → picker opens on child device →
/// parent/child selects ONE app → names it → sets time limit → repeat or done.
struct TimeLimitSetupView: View {
    let appState: AppState
    @State private var selection = FamilyActivitySelection()
    @State private var showingPicker = false
    @State private var pendingToken: ApplicationToken?
    @State private var pendingTokenData: Data?
    @State private var appName = ""
    @State private var dailyMinutes = 60
    @State private var savedApps: [AppTimeLimit] = []
    @State private var isSaving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    private let minuteOptions = [15, 30, 45, 60, 90, 120, 180, 240]

    var body: some View {
        NavigationStack {
            List {
                // Already configured apps
                if !savedApps.isEmpty {
                    Section("Configured") {
                        ForEach(savedApps, id: \.id) { app in
                            HStack {
                                Text(app.appName)
                                Spacer()
                                if app.dailyLimitMinutes > 0 {
                                    Text(formatMinutes(app.dailyLimitMinutes))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("No limit set")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let decoder = JSONDecoder()
                            for idx in offsets {
                                let app = savedApps[idx]
                                // Only remove from allowed list if it wasn't already allowed before
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

                // Naming flow for just-picked app
                if pendingToken != nil {
                    Section("Name This App") {
                        TextField("App name (e.g. YouTube, Roblox)", text: $appName)
                            .textInputAutocapitalization(.words)

                        Picker("Daily Limit", selection: $dailyMinutes) {
                            ForEach(minuteOptions, id: \.self) { mins in
                                Text(formatMinutes(mins)).tag(mins)
                            }
                        }

                        Button {
                            saveCurrentApp()
                        } label: {
                            Label("Add App", systemImage: "plus.circle.fill")
                        }
                        .disabled(appName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let err = saveError {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                // Add another
                Section {
                    Button {
                        pendingToken = nil
                        pendingTokenData = nil
                        appName = ""
                        dailyMinutes = 60
                        selection = FamilyActivitySelection()
                        showingPicker = true
                    } label: {
                        Label("Select App", systemImage: "plus.app")
                    }
                }
            }
            .familyActivityPicker(isPresented: $showingPicker, selection: $selection)
            .onChange(of: selection) { _, newSelection in
                guard let token = newSelection.applicationTokens.first else { return }
                let encoder = JSONEncoder()
                guard let data = try? encoder.encode(token) else { return }

                let fp = TokenFingerprint.fingerprint(for: data)
                if savedApps.contains(where: { $0.fingerprint == fp }) {
                    return
                }

                pendingToken = token
                pendingTokenData = data

                let app = Application(token: token)
                let resolved = app.localizedDisplayName ?? app.bundleIdentifier
                if let resolved, !resolved.isEmpty, resolved != "App" {
                    appName = resolved
                } else {
                    appName = ""
                }
            }
            .navigationTitle("App Time Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                loadExisting()
                if savedApps.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showingPicker = true
                    }
                }
            }
        }
    }

    private func loadExisting() {
        let storage = AppGroupStorage()
        var apps = storage.readAppTimeLimits()
        // Clean up any unnamed "App" entries from previous buggy builds
        apps.removeAll { $0.appName == "App" && $0.dailyLimitMinutes == 0 }
        if apps.count != storage.readAppTimeLimits().count {
            try? storage.writeAppTimeLimits(apps)
        }
        savedApps = apps
    }

    private func saveCurrentApp() {
        guard let data = pendingTokenData, let token = pendingToken else { return }
        let name = appName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let fingerprint = TokenFingerprint.fingerprint(for: data)
        // Check if this token was already in the allowed list before we add it
        let checkStorage = AppGroupStorage()
        let alreadyAllowed: Bool = {
            guard let allowedData = checkStorage.readRawData(forKey: StorageKeys.allowedAppTokens),
                  let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: allowedData) else { return false }
            return tokens.contains(token)
        }()
        let limit = AppTimeLimit(
            appName: name,
            tokenData: data,
            bundleID: Application(token: token).bundleIdentifier,
            fingerprint: fingerprint,
            dailyLimitMinutes: dailyMinutes,
            wasAlreadyAllowed: alreadyAllowed
        )
        savedApps.append(limit)
        persistAll()

        // Add to always-allowed so the app works until limit fires
        addToAllowedTokens(token)

        // Re-apply enforcement so the newly allowed token takes effect immediately
        reapplyEnforcement()

        // Cache name
        let storage = AppGroupStorage()
        storage.cacheAppName(name, forTokenKey: data.base64EncodedString())

        // Sync to CloudKit so parent can see the configured limit
        syncToCloudKit(limit)

        // Log
        if let enrollment = try? KeychainManager().get(ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState) {
            let entry = EventLogEntry(
                deviceID: enrollment.deviceID,
                familyID: enrollment.familyID,
                eventType: .timeLimitSetupCompleted,
                details: "Time limit added: \(name) (\(dailyMinutes)m/day)"
            )
            try? storage.appendEventLog(entry)
        }

        // Reset for next app
        pendingToken = nil
        pendingTokenData = nil
        appName = ""
        dailyMinutes = 60
        saveError = nil
    }

    private func syncToCloudKit(_ limit: AppTimeLimit) {
        guard let cloudKit = appState.cloudKit,
              let enrollment = try? KeychainManager().get(
                  ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
              ) else { return }

        let config = TimeLimitConfig(
            familyID: enrollment.familyID,
            childProfileID: enrollment.childProfileID,
            appFingerprint: limit.fingerprint,
            appName: limit.appName,
            dailyLimitMinutes: limit.dailyLimitMinutes,
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
            let readBack = storage.readAppTimeLimits()
            if readBack.count != savedApps.count {
                saveError = "Write OK but read-back got \(readBack.count)/\(savedApps.count)"
            }
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func addToAllowedTokens(_ token: ApplicationToken) {
        let storage = AppGroupStorage()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var tokens: Set<ApplicationToken>
        if let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
           let existing = try? decoder.decode(Set<ApplicationToken>.self, from: data) {
            tokens = existing
        } else {
            tokens = []
        }
        tokens.insert(token)
        if let encoded = try? encoder.encode(tokens) {
            try? storage.writeRawData(encoded, forKey: StorageKeys.allowedAppTokens)
        }
    }

    private func removeFromAllowedTokens(_ token: ApplicationToken) {
        let storage = AppGroupStorage()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        guard let data = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
              var tokens = try? decoder.decode(Set<ApplicationToken>.self, from: data) else { return }
        tokens.remove(token)
        if let encoded = try? encoder.encode(tokens) {
            try? storage.writeRawData(encoded, forKey: StorageKeys.allowedAppTokens)
        }
    }

    private func deleteFromCloudKit(_ limit: AppTimeLimit) {
        guard let cloudKit = appState.cloudKit,
              let enrollment = try? KeychainManager().get(
                  ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
              ) else { return }
        // Find and delete the matching TimeLimitConfig
        Task {
            if let configs = try? await cloudKit.fetchTimeLimitConfigs(childProfileID: enrollment.childProfileID) {
                for config in configs where config.appFingerprint == limit.fingerprint {
                    try? await cloudKit.deleteTimeLimitConfig(config.id)
                }
            }
        }
    }

    private func reapplyEnforcement() {
        // Force enforcement re-apply with current policy
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
