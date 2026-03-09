import SwiftUI
import BigBrotherCore

struct SettingsView: View {
    let appState: AppState

    var body: some View {
        List {
            Section("Security") {
                NavigationLink {
                    SecuritySettingsView(appState: appState)
                } label: {
                    Label("PIN & Authentication", systemImage: "lock.shield")
                }
            }

            Section("Family") {
                HStack {
                    Text("Family ID")
                    Spacer()
                    Text(appState.parentState?.familyID.rawValue.prefix(8) ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Children")
                    Spacer()
                    Text("\(appState.childProfiles.count)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Devices")
                    Spacer()
                    Text("\(appState.childDevices.count)")
                        .foregroundStyle(.secondary)
                }
            }

            Section("System") {
                NavigationLink {
                    DiagnosticsView(viewModel: DiagnosticsViewModel(appState: appState))
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }

                NavigationLink {
                    cloudKitStatusView
                } label: {
                    Label("CloudKit Status", systemImage: "icloud")
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var cloudKitStatusView: some View {
        List {
            Section("CloudKit Container") {
                HStack {
                    Text("Container")
                    Spacer()
                    Text(AppConstants.cloudKitContainerIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Database")
                    Spacer()
                    Text("Public")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Account Status")
                    Spacer()
                    if let status = appState.cloudKitStatusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Available")
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Sync") {
                HStack {
                    Text("Children synced")
                    Spacer()
                    Text("\(appState.childProfiles.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Devices synced")
                    Spacer()
                    Text("\(appState.childDevices.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("CloudKit Status")
    }
}
