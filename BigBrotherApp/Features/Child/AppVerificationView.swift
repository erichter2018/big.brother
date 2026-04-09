#if canImport(FamilyControls)
import SwiftUI
import ManagedSettings
import BigBrotherCore

/// Shows all allowed apps with their system-rendered name (from Label(token))
/// next to the child-entered name. Parent picks up the device and visually
/// compares to verify the child named apps honestly.
struct AppVerificationView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tokenEntries: [(token: ApplicationToken, enteredName: String)] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading app names...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if tokenEntries.isEmpty {
                    Text("No allowed apps configured.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(tokenEntries, id: \.enteredName) { entry in
                            HStack(spacing: 12) {
                                // System-rendered real app icon + name
                                Label(entry.token)
                                    .labelStyle(.titleAndIcon)
                                    .font(.subheadline)
                                    .frame(minWidth: 120, alignment: .leading)
                                    .lineLimit(1)

                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                // Child-entered name
                                Text(entry.enteredName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        HStack {
                            Text("Real App")
                                .frame(minWidth: 120, alignment: .leading)
                            Spacer()
                            Text("Entered Name")
                        }
                        .font(.caption2)
                    } footer: {
                        Text("The left column shows the real app name from iOS. Compare with the name your child entered on the right.")
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle("Verify Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { loadTokens() }
        }
    }

    private func loadTokens() {
        Task {
            let storage = AppGroupStorage()
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()

            // Load allowed tokens
            guard let tokenData = storage.readRawData(forKey: StorageKeys.allowedAppTokens),
                  let tokens = try? decoder.decode(Set<ApplicationToken>.self, from: tokenData)
            else {
                await MainActor.run { isLoading = false }
                return
            }

            // Load local name sources
            let nameCache = storage.readAllCachedAppNames()
            let timeLimits = storage.readAppTimeLimits()

            // Fetch CloudKit TimeLimitConfigs for parent-entered names
            var ckNames: [String: String] = [:] // fingerprint → name
            if let cloudKit = appState.cloudKit,
               let enrollment = try? KeychainManager().get(
                   ChildEnrollmentState.self, forKey: StorageKeys.enrollmentState
               ) {
                if let configs = try? await cloudKit.fetchTimeLimitConfigs(childProfileID: enrollment.childProfileID) {
                    for config in configs where config.isActive {
                        ckNames[config.appFingerprint] = config.appName
                    }
                }
            }

            var entries: [(token: ApplicationToken, enteredName: String)] = []
            var seenFingerprints = Set<String>()

            for token in tokens {
                guard let encoded = try? encoder.encode(token) else { continue }
                let fingerprint = TokenFingerprint.fingerprint(for: encoded)

                // Deduplicate by fingerprint
                guard seenFingerprints.insert(fingerprint).inserted else { continue }

                let tokenKey = encoded.base64EncodedString()

                // Priority: CloudKit name > local cache > local time limits > unnamed
                let enteredName: String
                if let ckName = ckNames[fingerprint], !ckName.isEmpty {
                    enteredName = ckName
                } else if let cached = nameCache[tokenKey], !cached.isEmpty, cached != "App", cached.count > 2 {
                    enteredName = cached
                } else if let limit = timeLimits.first(where: { $0.fingerprint == fingerprint }) {
                    enteredName = limit.appName
                } else {
                    enteredName = "(unnamed)"
                }

                entries.append((token: token, enteredName: enteredName))
            }

            let sorted = entries.sorted { $0.enteredName.lowercased() < $1.enteredName.lowercased() }
            await MainActor.run {
                tokenEntries = sorted
                isLoading = false
            }
        }
    }
}
#endif
