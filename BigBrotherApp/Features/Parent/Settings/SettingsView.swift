import SwiftUI
import CloudKit
import BigBrotherCore

struct SettingsView: View {
    let appState: AppState
    @State private var showNukeConfirm = false
    @State private var nukeStatus: String?
    @State private var isNuking = false

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

                NavigationLink {
                    ChildOrderView(appState: appState)
                } label: {
                    Label("Reorder Children", systemImage: "arrow.up.arrow.down")
                }

                NavigationLink {
                    ManageChildrenView(appState: appState)
                } label: {
                    Label("Remove Children", systemImage: "person.badge.minus")
                }

                NavigationLink {
                    ParentInviteView(appState: appState)
                } label: {
                    Label("Invite Parent", systemImage: "person.2.badge.key")
                }

                if appState.parentState?.isPrimaryParent == true {
                    NavigationLink {
                        ManageParentsView(appState: appState)
                    } label: {
                        Label("Manage Parent Access", systemImage: "person.badge.minus")
                    }
                }
            }

            Section("Monitoring") {
                NavigationLink {
                    HeartbeatProfileListView(
                        viewModel: HeartbeatProfileListViewModel(appState: appState)
                    )
                } label: {
                    Label("Monitoring Profiles", systemImage: "heart.text.clipboard")
                }
            }

            Section("Integrations") {
                NavigationLink {
                    TimerIntegrationSettingsView(appState: appState)
                } label: {
                    Label("AllowanceTracker Timers", systemImage: "timer")
                }
            }

            Section("System") {
                Button {
                    showNukeConfirm = true
                } label: {
                    Label("Purge All CloudKit Data", systemImage: "trash.circle")
                        .foregroundStyle(.red)
                }

                if let nukeStatus {
                    Text(nukeStatus)
                        .font(.caption)
                        .foregroundStyle(nukeStatus.contains("Error") ? .red : .green)
                }

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
        .disabled(isNuking)
        .alert("Purge All CloudKit Data?", isPresented: $showNukeConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Purge Everything", role: .destructive) {
                Task { await nukeCloudKit() }
            }
        } message: {
            Text("This deletes ALL commands, receipts, events, heartbeats, devices, and policies. Only your family record and schedule templates are kept. You'll need to re-enroll all devices.")
        }
    }

    private func nukeCloudKit() async {
        guard let cloudKit = appState.cloudKit as? CloudKitServiceImpl,
              let familyID = appState.parentState?.familyID else {
            nukeStatus = "Error: CloudKit unavailable"
            return
        }
        isNuking = true
        nukeStatus = "Purging..."

        let allPredicate = NSPredicate(format: "%K == %@", "familyID", familyID.rawValue)
        let truePredicate = NSPredicate(value: true)
        var total = 0

        let typesToDelete = [
            CKRecordType.remoteCommand,
            CKRecordType.commandReceipt,
            CKRecordType.eventLog,
            CKRecordType.heartbeat,
            CKRecordType.childDevice,
            CKRecordType.policy,
            CKRecordType.enrollmentInvite,
            CKRecordType.schedule,
        ]

        for type in typesToDelete {
            do {
                // Try familyID filter first, fall back to true predicate.
                let count = try await cloudKit.deleteRecords(type: type, predicate: allPredicate)
                total += count
                nukeStatus = "Purging... \(total) deleted"
            } catch {
                // Some record types might not have familyID field indexed.
                let count = (try? await cloudKit.deleteRecords(type: type, predicate: truePredicate)) ?? 0
                total += count
            }
        }

        // Clear local state.
        appState.childProfiles = []
        appState.childDevices = []
        appState.latestHeartbeats = []
        appState.approvedApps = []

        nukeStatus = "Done — \(total) records deleted"
        isNuking = false
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
