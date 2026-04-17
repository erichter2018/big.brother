import SwiftUI
import BigBrotherCore

#if canImport(FamilyControls)
import FamilyControls
import ManagedSettings

/// Proactive app naming — child uses FamilyActivityPicker to select apps,
/// then names each one. Builds a token-to-name dictionary for future use.
///
/// When the child later hits a shield and types the app name, the cached
/// token can be automatically matched for fast unlocking.
struct NameMyAppsView: View {
    let appState: AppState
    @State private var selection = FamilyActivitySelection()
    @State private var pendingTokens: [(token: ApplicationToken, tokenBase64: String)] = []
    @State private var currentIndex = 0
    @State private var currentName = ""
    @State private var phase: Phase = .picking
    @State private var savedCount = 0
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case picking
        case naming
        case done
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .picking:
                    pickingView
                case .naming:
                    namingView
                case .done:
                    doneView
                }
            }
            .navigationTitle("Name My Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if phase == .picking {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next") { startNaming() }
                            .disabled(selection.applicationTokens.isEmpty)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pickingView: some View {
        VStack(spacing: 12) {
            Text("Select the apps you want to name. You'll type a name for each one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            FamilyActivityPicker(selection: $selection)
                .onChange(of: selection) { _, newSelection in
                    AppNameHarvester.harvest(from: newSelection)
                }
        }
    }

    @ViewBuilder
    private var namingView: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("App \(currentIndex + 1) of \(pendingTokens.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: Double(currentIndex), total: Double(pendingTokens.count))
                .padding(.horizontal)

            Image(systemName: "app.badge.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("What is this app called?")
                .font(.title3)
                .fontWeight(.semibold)

            // Show existing name if we have one.
            if let existing = existingName {
                Text("Previously named: \(existing)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("App name", text: $currentName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .padding(.horizontal)
                .onSubmit { saveAndAdvance() }

            HStack(spacing: 16) {
                Button("Skip") { advance() }
                    .buttonStyle(.bordered)

                Button("Save & Next") { saveAndAdvance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var doneView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Named \(savedCount) app\(savedCount == 1 ? "" : "s")")
                .font(.title3)
                .fontWeight(.semibold)

            Text("These names will appear when you request access or in your parent's dashboard.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    private var existingName: String? {
        guard currentIndex < pendingTokens.count else { return nil }
        let base64 = pendingTokens[currentIndex].tokenBase64
        return appState.storage.cachedAppName(forTokenKey: base64)
    }

    private func startNaming() {
        var tokens: [(token: ApplicationToken, tokenBase64: String)] = []
        for token in selection.applicationTokens {
            guard let data = try? JSONEncoder().encode(token) else { continue }
            tokens.append((token: token, tokenBase64: data.base64EncodedString()))
        }
        guard !tokens.isEmpty else { return }
        pendingTokens = tokens
        currentIndex = 0
        prepareCurrentName()
        phase = .naming
    }

    private func prepareCurrentName() {
        guard currentIndex < pendingTokens.count else { return }
        let base64 = pendingTokens[currentIndex].tokenBase64
        // Pre-fill with existing cached name if available.
        if let existing = appState.storage.cachedAppName(forTokenKey: base64) {
            currentName = existing
        } else {
            currentName = ""
        }
    }

    private func saveAndAdvance() {
        let trimmed = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, currentIndex < pendingTokens.count else {
            advance()
            return
        }

        let base64 = pendingTokens[currentIndex].tokenBase64
        appState.storage.cacheAppName(trimmed, forTokenKey: base64)

        // Also update UserDefaults so extensions see it.
        let defaults = UserDefaults.appGroup
        var nameMap = defaults?.dictionary(forKey: AppGroupKeys.tokenToAppName) as? [String: String] ?? [:]
        nameMap[base64] = trimmed
        defaults?.set(nameMap, forKey: AppGroupKeys.tokenToAppName)

        savedCount += 1
        advance()
    }

    private func advance() {
        currentIndex += 1
        if currentIndex >= pendingTokens.count {
            phase = .done
        } else {
            prepareCurrentName()
        }
    }
}
#endif
