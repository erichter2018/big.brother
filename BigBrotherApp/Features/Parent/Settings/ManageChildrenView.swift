import SwiftUI
import BigBrotherCore

struct ManageChildrenView: View {
    let appState: AppState
    @State private var childToDelete: ChildProfile?
    @State private var feedback: String?

    var body: some View {
        List {
            Section {
                ForEach(appState.orderedChildProfiles) { child in
                    HStack {
                        Text(child.name)
                        Spacer()
                        let deviceCount = appState.childDevices.filter { $0.childProfileID == child.id }.count
                        Text("\(deviceCount) device\(deviceCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            childToDelete = child
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Swipe left on a child to remove them.")
            }

            if let feedback {
                Section {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Remove Children")
        .alert("Delete \(childToDelete?.name ?? "")?", isPresented: Binding(
            get: { childToDelete != nil },
            set: { if !$0 { childToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                childToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let child = childToDelete {
                    deleteChild(child)
                }
            }
        } message: {
            Text("This removes \(childToDelete?.name ?? "") and all their devices. Cannot be undone.")
        }
    }

    private func deleteChild(_ child: ChildProfile) {
        let devices = appState.childDevices.filter { $0.childProfileID == child.id }

        // Clear local state FIRST — instant UI update.
        appState.childDevices.removeAll { $0.childProfileID == child.id }
        appState.latestHeartbeats.removeAll { hb in devices.contains { $0.id == hb.deviceID } }
        appState.childProfiles.removeAll { $0.id == child.id }
        appState.approvedApps.removeAll { app in devices.contains { $0.id == app.deviceID } }
        childToDelete = nil
        feedback = "Deleted \(child.name)"

        // CloudKit cleanup in background — non-blocking.
        Task {
            try? await appState.cloudKit?.deleteChildProfile(child.id)
            for device in devices {
                try? await appState.cloudKit?.deleteDevice(device.id)
            }

            // Clean up associated records by profileID (invites, schedules).
            let profilePredicate = NSPredicate(format: "%K == %@", CKFieldName.profileID, child.id.rawValue)
            for type in [CKRecordType.enrollmentInvite, CKRecordType.schedule] {
                _ = try? await appState.cloudKit?.deleteRecords(type: type, predicate: profilePredicate)
            }

            // Clean up commands targeting this child profile.
            let childTargetPredicate = NSPredicate(format: "%K == %@", CKFieldName.targetID, child.id.rawValue)
            _ = try? await appState.cloudKit?.deleteRecords(type: CKRecordType.remoteCommand, predicate: childTargetPredicate)

            // Clean up per-device records (heartbeats, events, policies, receipts, device-targeted commands).
            for device in devices {
                let devicePredicate = NSPredicate(format: "%K == %@", CKFieldName.deviceID, device.id.rawValue)
                for type in [CKRecordType.heartbeat, CKRecordType.eventLog, CKRecordType.policy, CKRecordType.commandReceipt] {
                    _ = try? await appState.cloudKit?.deleteRecords(type: type, predicate: devicePredicate)
                }
                let deviceTargetPredicate = NSPredicate(format: "%K == %@", CKFieldName.targetID, device.id.rawValue)
                _ = try? await appState.cloudKit?.deleteRecords(type: CKRecordType.remoteCommand, predicate: deviceTargetPredicate)
            }
        }
    }
}
