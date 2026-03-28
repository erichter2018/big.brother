import SwiftUI
import BigBrotherCore

/// Parent UI for configuring web content filtering per child.
struct WebFilterConfigView: View {
    let child: ChildProfile
    let onApply: ([String]) async -> Void

    @State private var config: WebFilterConfig
    @State private var isApplying = false
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    init(child: ChildProfile, onApply: @escaping ([String]) async -> Void) {
        self.child = child
        self.onApply = onApply
        // Load saved config from UserDefaults
        let key = "webFilterConfig.\(child.id.rawValue)"
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(WebFilterConfig.self, from: data) {
            self._config = State(initialValue: saved)
        } else {
            self._config = State(initialValue: WebFilterConfig())
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $config.mode) {
                    Text("Off").tag(WebFilterConfig.Mode.off)
                    Text("Block All Web").tag(WebFilterConfig.Mode.blockAll)
                    Text("Allow Selected Categories").tag(WebFilterConfig.Mode.allowCategories)
                }
                .pickerStyle(.menu)
            } footer: {
                switch config.mode {
                case .off:
                    Text("Web browsing is unrestricted.")
                case .blockAll:
                    Text("All web browsing is blocked when the device is locked.")
                case .allowCategories:
                    Text("Only websites from selected categories are accessible when locked.")
                }
            }

            if config.mode == .allowCategories {
                Section("Allowed Categories") {
                    ForEach(WebFilterCatalog.allowCategories) { category in
                        Toggle(isOn: binding(for: category.id)) {
                            Label(category.name, systemImage: category.icon)
                        }
                    }
                }

                let domainCount = config.resolvedDomains(from: WebFilterCatalog.allowCategories).count
                if domainCount > 0 {
                    Section {
                        Text("\(domainCount) domains will be accessible")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let feedback {
                Section {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Web Filter")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await apply() }
                } label: {
                    if isApplying {
                        ProgressView()
                    } else {
                        Text("Apply")
                    }
                }
                .disabled(isApplying)
            }
        }
    }

    private func binding(for categoryID: String) -> Binding<Bool> {
        Binding(
            get: { config.selectedCategoryIDs.contains(categoryID) },
            set: { enabled in
                if enabled {
                    config.selectedCategoryIDs.insert(categoryID)
                } else {
                    config.selectedCategoryIDs.remove(categoryID)
                }
            }
        )
    }

    private func apply() async {
        isApplying = true

        // Compute effective domain list
        let domains: [String]
        switch config.mode {
        case .off:
            domains = ["*"] // Special value meaning "allow all" — enforcement clears web blocking
        case .blockAll:
            domains = [] // Empty = block all
        case .allowCategories:
            domains = config.resolvedDomains(from: WebFilterCatalog.allowCategories)
        }

        await onApply(domains)

        // Persist config
        let key = "webFilterConfig.\(child.id.rawValue)"
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }

        feedback = "Web filter applied"
        isApplying = false
    }
}
