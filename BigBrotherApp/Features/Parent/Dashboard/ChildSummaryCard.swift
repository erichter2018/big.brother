import SwiftUI
import BigBrotherCore

/// Card showing a child profile summary with device status.
struct ChildSummaryCard: View {
    let child: ChildProfile
    let devices: [ChildDevice]
    let heartbeats: [DeviceHeartbeat]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name)
                        .font(.headline)
                    Text("\(devices.count) device\(devices.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if devices.isEmpty {
                Text("No devices enrolled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(devices) { device in
                    deviceRow(device)
                }
            }

            // Show warnings
            let hasAuthIssue = devices.contains { !$0.familyControlsAuthorized }
            if hasAuthIssue {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Authorization issue on one or more devices")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func deviceRow(_ device: ChildDevice) -> some View {
        HStack(spacing: 8) {
            DeviceIcon(modelIdentifier: device.modelIdentifier)

            Text(device.displayName)
                .font(.subheadline)

            Spacer()

            if let mode = device.confirmedMode {
                ModeBadge(mode: mode)
            }

            if device.isOnline {
                StatusBadge.online()
            } else {
                StatusBadge.offline()
            }
        }
    }
}
